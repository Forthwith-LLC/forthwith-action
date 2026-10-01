#!/usr/bin/env bash

# This action intentionally runs without FORTHWITH_AUTH_TOKEN. `forthwith
# check` only reads the checkout, so it is safe to use for pull requests from
# forks and must remain free of Forthwith credentials.
set -euo pipefail

readonly release_repo="Forthwith-LLC/forthwith-releases"
readonly max_annotations=50

die() {
  echo "Forthwith check action: $*" >&2
  exit 1
}

require_boolean() {
  case "$1" in
    true|false) ;;
    *) die "$2 must be 'true' or 'false', got '$1'" ;;
  esac
}

escape_workflow_value() {
  local value="$1"
  value="${value//'%'/'%25'}"
  value="${value//$'\r'/'%0D'}"
  value="${value//$'\n'/'%0A'}"
  printf '%s' "$value"
}

resolve_cli_version() {
  local version="$1" latest_url release_prefix

  if [[ "$version" == latest ]]; then
    release_prefix="https://github.com/${release_repo}/releases/tag/"
    latest_url="$(curl --fail --silent --show-error --location --head \
      --retry 3 --output /dev/null --write-out '%{url_effective}' \
      "https://github.com/${release_repo}/releases/latest")" ||
      die "could not resolve the latest Forthwith CLI release"
    [[ "$latest_url" == "$release_prefix"* ]] ||
      die "latest Forthwith CLI release redirected to an unexpected URL"
    version="${latest_url#"$release_prefix"}"
  fi

  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "cli-version must be 'latest' or an exact vX.Y.Z release tag, got '$version'"
  printf '%s\n' "$version"
}

install_cli() {
  local version="$1"
  local install_dir="$2"
  local normalized_version archive checksums_url archive_url expected actual tmpdir

  normalized_version="${version#v}"
  archive="forthwith_${normalized_version}_linux_amd64.tar.gz"
  checksums_url="https://github.com/${release_repo}/releases/download/${version}/checksums.txt"
  archive_url="https://github.com/${release_repo}/releases/download/${version}/${archive}"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  curl --fail --location --silent --show-error "$checksums_url" -o "$tmpdir/checksums.txt"
  curl --fail --location --silent --show-error "$archive_url" -o "$tmpdir/$archive"

  expected="$(awk -v file="$archive" '$2 == file || $2 == "*" file { print $1; exit }' "$tmpdir/checksums.txt")"
  [[ -n "$expected" ]] || die "release checksums do not contain $archive"
  actual="$(sha256sum "$tmpdir/$archive" | awk '{print $1}')"
  [[ "$expected" == "$actual" ]] || die "checksum verification failed for $archive"

  tar -xzf "$tmpdir/$archive" -C "$tmpdir"
  [[ -x "$tmpdir/forthwith" ]] || die "release archive did not contain an executable forthwith binary"
  mkdir -p "$install_dir"
  install -m 0755 "$tmpdir/forthwith" "$install_dir/forthwith"
}

write_summary() {
  local report="$1"
  local version="$2"
  local safe_message
  {
    echo "## Forthwith localization check"
    echo
    printf 'CLI version: %s\n' "\`$version\`"
    echo
    echo "| Result | Errors | Warnings |"
    echo "| --- | ---: | ---: |"
    jq -r '[.status, (.summary.errors // 0), (.summary.warnings // 0)] | "| \(.[0]) | \(.[1]) | \(.[2]) |"' "$report"
    echo
    echo "### Diagnostics"
    echo
    echo "| Severity | Code | Location | Key | Message |"
    echo "| --- | --- | --- | --- | --- |"
    jq -r '.issues[]? | [(.severity // "unknown"), (.code // ""), ((.file // "") + (if (.line // 0) > 0 then ":" + (.line|tostring) else "" end)), (.key // ""), (.message // "")] | @tsv' "$report" |
      while IFS=$'\t' read -r severity code location key message; do
        safe_message="${message//|/\\|}"
        safe_message="${safe_message//$'\n'/<br>}"
        printf '| %s | `%s` | `%s` | `%s` | %s |\n' \
          "$severity" "$code" "$location" "$key" "$safe_message"
      done
  } >>"$GITHUB_STEP_SUMMARY"
}

write_sarif() {
  local report="$1" output="$2"
  jq '{
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    version: "2.1.0",
    runs: [{
      tool: { driver: {
        name: "Forthwith",
        informationUri: "https://forthwith.io",
        rules: ([.issues[]? | .code // "unknown" | select(. != "")] | unique | map({id: ., shortDescription: {text: .}}))
      }},
      results: [.issues[]? | {
        ruleId: (.code // "unknown"),
        level: (if .severity == "error" then "error" elif .severity == "warning" then "warning" else "note" end),
        message: {text: (.message // "Localization issue")},
        locations: (if ((.file // .source_file // "") != "") then [{physicalLocation: ({artifactLocation: {uri: (.file // .source_file)}} + (if ((.line // 0) > 0) then {region: {startLine: .line}} else {} end))}] else [] end)
      }]
    }]
  }' "$report" >"$output"
}

annotate_issues() {
  local report="$1"
  local count=0 severity file line message command

  while IFS=$'\t' read -r severity file line message; do
    ((count += 1))
    if ((count > max_annotations)); then
      echo "::notice::Forthwith reported more than ${max_annotations} diagnostics; see the step summary for the complete list."
      break
    fi
    case "$severity" in
      error) command="error" ;;
      warning) command="warning" ;;
      *) command="notice" ;;
    esac
    message="$(escape_workflow_value "$message")"
    if [[ -n "$file" && "$line" =~ ^[1-9][0-9]*$ ]]; then
      printf '::%s file=%s,line=%s::%s\n' "$command" "$(escape_workflow_value "$file")" "$line" "$message"
    else
      printf '::%s::%s\n' "$command" "$message"
    fi
  done < <(jq -r '.issues[]? | [(.severity // "notice"), (.file // .source_file // ""), (.line // 0), (.message // "")] | @tsv' "$report")
}

main() {
  local version="${FORTHWITH_CLI_VERSION:-}" working_directory="${FORTHWITH_WORKING_DIRECTORY:-.}"
  local warnings_as_errors="${FORTHWITH_WARNINGS_AS_ERRORS:-false}" annotate="${FORTHWITH_ANNOTATE:-true}"
  local write_step_summary="${FORTHWITH_WRITE_SUMMARY:-true}" resolved_version tool_dir report sarif exit_code status errors warnings
  local -a check_args=(check --json)

  require_boolean "$warnings_as_errors" "warnings-as-errors"
  require_boolean "$annotate" "annotate"
  require_boolean "$write_step_summary" "write-summary"
  [[ -d "$working_directory" ]] || die "working-directory does not exist: $working_directory"
  command -v curl >/dev/null || die "curl is required"
  command -v tar >/dev/null || die "tar is required"
  command -v sha256sum >/dev/null || die "sha256sum is required"
  command -v jq >/dev/null || die "jq is required (it is preinstalled on GitHub-hosted Ubuntu runners)"

  resolved_version="$(resolve_cli_version "$version")"
  echo "Using Forthwith CLI ${resolved_version}"
  tool_dir="${RUNNER_TEMP:-/tmp}/forthwith-cli-${GITHUB_ACTION:-check}"
  install_cli "$resolved_version" "$tool_dir"
  report="$(mktemp "${RUNNER_TEMP:-/tmp}/forthwith-check.XXXXXX.json")"
  if [[ "$warnings_as_errors" == true ]]; then check_args+=(--warnings-as-errors); fi

  pushd "$working_directory" >/dev/null
  set +e
  "$tool_dir/forthwith" "${check_args[@]}" >"$report"
  exit_code=$?
  set -e
  popd >/dev/null

  if ! jq -e '.status and .summary' "$report" >/dev/null 2>&1; then
    echo "## Forthwith localization check" >>"$GITHUB_STEP_SUMMARY"
    echo >>"$GITHUB_STEP_SUMMARY"
    echo "The CLI did not return a structured report. Review the job log for the failure." >>"$GITHUB_STEP_SUMMARY"
    cat "$report" >&2
    # A zero exit without a report is still a broken action result.
    if ((exit_code == 0)); then exit_code=1; fi
    exit "$exit_code"
  fi

  status="$(jq -r '.status' "$report")"
  errors="$(jq -r '.summary.errors // 0' "$report")"
  warnings="$(jq -r '.summary.warnings // 0' "$report")"
  sarif="${report%.json}.sarif"
  write_sarif "$report" "$sarif"
  {
    echo "status=$status"
    echo "errors=$errors"
    echo "warnings=$warnings"
    echo "cli-version=$resolved_version"
    echo "report-path=$report"
    echo "sarif-path=$sarif"
  } >>"$GITHUB_OUTPUT"

  if [[ "$write_step_summary" == true ]]; then write_summary "$report" "$resolved_version"; fi
  if [[ "$annotate" == true ]]; then annotate_issues "$report"; fi

  exit "$exit_code"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
