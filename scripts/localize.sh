#!/usr/bin/env bash

# Runs only on the repository's default branch. The caller supplies
# FORTHWITH_AUTH_TOKEN and GH_TOKEN as environment variables; neither is
# echoed or passed as a command-line argument.
# shellcheck disable=SC2016 # Markdown backticks in printf format strings are literal.
set -euo pipefail

readonly release_repo="Forthwith-LLC/forthwith-releases"
readonly pr_branch="forthwith/localize"
readonly pr_title="chore(i18n): update translations"

die() {
  printf 'Forthwith localization: %s\n' "$*" >&2
  exit 1
}

validate_output_path() {
  local path="$1"
  [[ -n "$path" && "$path" != /* && "$path" != . && "$path" != .. ]] || return 1
  [[ "$path" != ./* && "$path" != ../* && "$path" != */../* && "$path" != */.. ]] || return 1
  [[ "$path" != .git && "$path" != .git/* && "$path" != .github/* ]] || return 1
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* && "$path" != *'`'* ]] || return 1
  return 0
}

first_run_project_id_only() {
  git show HEAD:.forthwith.yml | ruby -ryaml -e '
    old_config = YAML.safe_load(STDIN.read, aliases: false)
    new_config = YAML.safe_load(File.read(".forthwith.yml"), aliases: false)
    exit 1 unless old_config.is_a?(Hash) && new_config.is_a?(Hash)
    old_id = old_config.delete("project_id")
    new_id = new_config.delete("project_id")
    exit 1 unless old_id.nil? || (old_id.is_a?(String) && old_id.strip.empty?)
    exit 1 unless new_id.is_a?(String) &&
      new_id.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i)
    exit(old_config == new_config ? 0 : 1)
  '
}

install_cli() {
  local version="$1" install_dir="$2"
  local normalized archive tmpdir expected actual

  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "cli-version must be an exact vX.Y.Z tag"
  normalized="${version#v}"
  archive="forthwith_${normalized}_linux_amd64.tar.gz"
  tmpdir="$install_dir/download"
  mkdir -p "$tmpdir"

  curl --fail --location --silent --show-error \
    "https://github.com/${release_repo}/releases/download/${version}/checksums.txt" \
    -o "$tmpdir/checksums.txt"
  curl --fail --location --silent --show-error \
    "https://github.com/${release_repo}/releases/download/${version}/${archive}" \
    -o "$tmpdir/$archive"

  expected="$(awk -v file="$archive" '$2 == file || $2 == "*" file { print $1; exit }' "$tmpdir/checksums.txt")"
  [[ -n "$expected" ]] || die "release checksums do not contain $archive"
  actual="$(sha256sum "$tmpdir/$archive" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || die "checksum verification failed for $archive"

  tar -xzf "$tmpdir/$archive" -C "$tmpdir"
  [[ -x "$tmpdir/forthwith" ]] || die "release archive did not contain an executable forthwith binary"
  mkdir -p "$install_dir"
  install -m 0755 "$tmpdir/forthwith" "$install_dir/forthwith"
  rm -r -- "$tmpdir"
}

prepare_branch() {
  local base="$1" lookup historical owner matching_prs

  git fetch --no-tags origin "$base"
  [[ -z "$(git status --porcelain)" ]] || die "checkout has changes before translation; refusing to include unrelated files"
  git config user.name 'github-actions[bot]'
  git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

  set +e
  git ls-remote --exit-code --heads origin "refs/heads/$pr_branch" >/dev/null
  lookup=$?
  set -e
  case "$lookup" in
    0)
      branch_existed=true
      owner="${GITHUB_REPOSITORY%%/*}"
      matching_prs="$(gh pr list --repo "$GITHUB_REPOSITORY" --state all --head "$pr_branch" \
        --base "$base" --limit 1000 --json number,state,headRepositoryOwner)"
      historical="$(jq --arg owner "$owner" \
        '[.[] | select(((.headRepositoryOwner.login // "") | ascii_downcase) == ($owner | ascii_downcase) and .state != "OPEN")] | length' <<<"$matching_prs")"
      [[ "$historical" == 0 ]] || die "$pr_branch has a closed PR; delete or resolve that branch before rerunning"
      existing_pr="$(jq -r --arg owner "$owner" \
        '[.[] | select(((.headRepositoryOwner.login // "") | ascii_downcase) == ($owner | ascii_downcase) and .state == "OPEN") | .number] | first // empty' <<<"$matching_prs")"
      git fetch --no-tags origin "$pr_branch"
      old_branch_sha="$(git rev-parse FETCH_HEAD)"
      git switch --create forthwith-localize-work "$old_branch_sha"
      if ! git rebase "origin/$base"; then
        git rebase --abort || true
        die "the localization branch conflicts with $base; resolve it before retrying (no translation job was started)"
      fi
      ;;
    2)
      git switch --create forthwith-localize-work "origin/$base"
      ;;
    *) die "could not check for the existing localization branch" ;;
  esac
}

read_report() {
  local report="$1" exit_code="$2"

  if ! jq -e 'type == "object" and (.status | type == "string")' "$report" >/dev/null 2>&1; then
    die "CLI did not return a valid JSON report (exit $exit_code)"
  fi

  report_status="$(jq -r '.status' "$report")"
  if ((exit_code != 0)) || [[ "$report_status" == error ]]; then
    local message
    message="$(jq -r '.message // .error // "unknown CLI error"' "$report" | tr '\r\n' '  ' | cut -c 1-300)"
    die "CLI translation failed: $message"
  fi
  case "$report_status" in
    success|no_changes) ;;
    *) die "unexpected CLI status: $report_status" ;;
  esac

  jq -e '(.files_updated // [] | type == "array") and
    all(.files_updated[]?; type == "string" and
      (index("\u0000") == null) and (index("\n") == null) and
      (index("\r") == null) and (index("\t") == null))' "$report" >/dev/null ||
    die "CLI returned invalid files_updated paths"

  strings_translated="$(jq -r '.summary.strings_translated // .strings.total // 0' "$report")"
  failed_strings="$(jq -r '.summary.failed_strings_count // 0' "$report")"
  failure_groups="$(jq -r '[(.failures // {}) | .[] | length] | add // 0' "$report")"
  [[ "$strings_translated" =~ ^[0-9]+$ && "$failed_strings" =~ ^[0-9]+$ && "$failure_groups" =~ ^[0-9]+$ ]] ||
    die "CLI returned invalid translation counts"
  partial=false
  if ((failed_strings > 0 || failure_groups > 0)); then partial=true; fi
}

stage_outputs() {
  local report="$1" path candidate allowed
  local -a declared=() changed=()

  while IFS= read -r -d '' path; do
    declared+=("$path")
  done < <(jq -j '.files_updated[]? | . + "\u0000"' "$report")
  for path in "${declared[@]+"${declared[@]}"}"; do
    validate_output_path "$path" || die "CLI reported an unsafe output path"
    if ! git ls-files --error-unmatch -- ":(literal)$path" >/dev/null 2>&1; then
      [[ -e "$path" ]] || die "CLI reported an output file that does not exist: $path"
      if git check-ignore -q -- "$path"; then
        die "translated output is gitignored and cannot be included in the PR: $path"
      fi
    fi
  done

  allow_config=false
  if ! git diff --quiet HEAD -- .forthwith.yml; then
    first_run_project_id_only || die ".forthwith.yml changed beyond first-run project_id generation"
    allow_config=true
  fi

  while IFS= read -r -d '' path; do
    changed+=("$path")
  done < <(
    git diff --name-only --no-renames -z HEAD
    git ls-files --others --exclude-standard -z
  )
  for path in "${changed[@]+"${changed[@]}"}"; do
    validate_output_path "$path" || die "working tree contains an unsafe path"
    allowed=false
    if [[ "$path" == .forthwith.lock || ( "$path" == .forthwith.yml && "$allow_config" == true ) ]]; then
      allowed=true
    fi
    for candidate in "${declared[@]+"${declared[@]}"}"; do
      if [[ "$path" == "$candidate" ]]; then allowed=true; break; fi
    done
    [[ "$allowed" == true ]] || die "unexpected file changed by translation: $path"
    git add -A -- ":(literal)$path"
  done
}

write_pr_body() {
  local body="$1" report="$2" base="$3" path languages
  local -a files=()

  languages="$(jq -r '(.summary.languages // .languages // []) | join(", ")' "$report")"
  [[ -n "$languages" ]] || languages='not reported (no translation this run)'
  while IFS= read -r -d '' path; do
    files+=("$path")
  done < <(git diff --name-only --no-renames -z "origin/$base"...HEAD)
  {
    printf '## Automated localization update\n\n'
    printf 'Source commit: `%s`\n\n' "$(git rev-parse "origin/$base")"
    printf 'Target languages: %s\n\n' "$languages"
    printf 'Strings translated this run: %s\n\n' "$strings_translated"
    if [[ "$partial" == true ]]; then
      printf '**Partial result:** some translation jobs or strings failed. Review the workflow log and rerun after resolving them.\n\n'
    fi
    printf 'Files changed in this PR:\n'
    for path in "${files[@]+"${files[@]}"}"; do
      validate_output_path "$path" || die "PR contains an unsafe path"
      printf -- '- `%s`\n' "$path"
    done
    printf '\nMachine-generated translations require human review. This PR will not be merged automatically.\n'
  } >"$body"
}

publish_branch_and_pr() {
  local base="$1" body="$2" url

  if [[ "$branch_existed" == false ]] && git diff --cached --quiet; then
    printf 'No localization changes to publish.\n'
    return 0
  fi

  if ! git diff --cached --quiet; then
    git commit -m "$pr_title"
  fi

  if [[ "$branch_existed" == true ]]; then
    if [[ "$(git rev-parse HEAD)" != "$old_branch_sha" ]]; then
      git push --force-with-lease="refs/heads/$pr_branch:$old_branch_sha" origin "HEAD:refs/heads/$pr_branch" ||
        die "$pr_branch changed remotely or force-push is disabled; no PR was modified"
    fi
  else
    git push origin "HEAD:refs/heads/$pr_branch" ||
      die "could not push $pr_branch; check contents: write permissions"
  fi

  write_pr_body "$body" "$report_path" "$base"
  if [[ -n "$existing_pr" ]]; then
    gh pr edit "$existing_pr" --repo "$GITHUB_REPOSITORY" --title "$pr_title" --body-file "$body" ||
      die "could not update PR #$existing_pr; check pull-requests: write permissions"
    url="$(gh pr view "$existing_pr" --repo "$GITHUB_REPOSITORY" --json url --jq .url)"
  else
    url="$(gh pr create --repo "$GITHUB_REPOSITORY" --base "$base" --head "$pr_branch" \
      --title "$pr_title" --body-file "$body")" ||
      die "could not create a PR; allow Actions to create pull requests and grant pull-requests: write"
  fi
  pr_url="$url"
  printf 'Localization PR: %s\n' "$pr_url"
}

main() {
  local version="${FORTHWITH_CLI_VERSION:-}" max_strings="${FORTHWITH_MAX_STRINGS:-}"
  local base exit_code

  [[ "$max_strings" =~ ^[1-9][0-9]*$ ]] || die "max-strings must be a positive integer"
  [[ -n "${FORTHWITH_AUTH_TOKEN:-}" ]] || die "FORTHWITH_AUTH_TOKEN is required"
  [[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is required"
  [[ -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_REF:-}" ]] || die "GitHub repository context is required"
  [[ "${GITHUB_EVENT_NAME:-}" == push || "${GITHUB_EVENT_NAME:-}" == workflow_dispatch ]] ||
    die "only push and workflow_dispatch events are supported"
  for command in curl tar sha256sum jq gh git ruby; do
    command -v "$command" >/dev/null || die "$command is required"
  done
  [[ -f .forthwith.yml ]] || die ".forthwith.yml must be committed at the repository root"

  base="$(gh api "repos/$GITHUB_REPOSITORY" --jq .default_branch)"
  [[ -n "$base" && "$GITHUB_REF" == "refs/heads/$base" ]] ||
    die "this secret-bearing workflow must run on the repository default branch"

  branch_existed=false
  existing_pr=""
  old_branch_sha=""
  pr_url=""
  prepare_branch "$base"

  tool_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/forthwith-cli.XXXXXX")"
  report_path="$(mktemp "${RUNNER_TEMP:-/tmp}/forthwith-localize.XXXXXX")"
  body="$(mktemp "${RUNNER_TEMP:-/tmp}/forthwith-pr-body.XXXXXX")"
  trap 'rm -rf -- "$tool_dir"; rm -f -- "$report_path" "$body"' EXIT
  install_cli "$version" "$tool_dir"

  set +e
  "$tool_dir/forthwith" translate --json --yes --force --max-strings="$max_strings" >"$report_path"
  exit_code=$?
  set -e
  read_report "$report_path" "$exit_code"
  stage_outputs "$report_path"
  publish_branch_and_pr "$base" "$body"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
      printf 'status=%s\n' "$report_status"
      printf 'strings-translated=%s\n' "$strings_translated"
      printf 'pull-request-url=%s\n' "$pr_url"
    } >>"$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf '## Forthwith localization PR\n\n'
      printf 'CLI status: `%s` · strings translated: %s\n\n' "$report_status" "$strings_translated"
      if [[ -n "$pr_url" ]]; then printf '[Review localization PR](%s)\n' "$pr_url"; fi
      if [[ "$partial" == true ]]; then printf '\nSome translations failed; the completed work was saved in the PR.\n'; fi
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  [[ "$partial" == false ]] || die "some translations failed; completed work was saved in the PR"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
