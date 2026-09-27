#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2329 # Globals/functions are consumed by the sourced action.
set -euo pipefail

# shellcheck source=../scripts/localize.sh
source "$(dirname "$0")/../scripts/localize.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() {
  if ("$@") >/dev/null 2>&1; then fail "expected failure: $*"; fi
}

validate_output_path 'priv/gettext/pt_BR/LC_MESSAGES/default.po' || fail 'valid path rejected'
grep -Fq 'run: "$FORTHWITH_ACTION_PATH/../scripts/localize.sh"' \
  "$(dirname "$0")/../localize/action.yml" || fail 'subdirectory action script path is invalid'
[[ -x "$(dirname "$0")/../localize/../scripts/localize.sh" ]] || fail 'subdirectory action script is not executable'
expect_failure validate_output_path '../outside.po'
expect_failure validate_output_path '.github/workflows/bad.yml'
expect_failure validate_output_path '/tmp/outside.po'
expect_failure validate_output_path $'locale/bad\nfile.po'

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
git init --bare -q "$test_root/origin.git"
git init -q -b main "$test_root/seed"
git -C "$test_root/seed" config user.name Test
git -C "$test_root/seed" config user.email test@example.com
printf 'version: 1\nframework: react\n' >"$test_root/seed/.forthwith.yml"
printf '{}\n' >"$test_root/seed/source.json"
git -C "$test_root/seed" add .forthwith.yml source.json
git -C "$test_root/seed" commit -qm initial
git -C "$test_root/seed" remote add origin "$test_root/origin.git"
git -C "$test_root/seed" push -q -u origin main
git --git-dir="$test_root/origin.git" symbolic-ref HEAD refs/heads/main

git clone -q "$test_root/origin.git" "$test_root/first"
cd "$test_root/first"
GITHUB_REPOSITORY=example/repo
branch_existed=false
existing_pr=""
old_branch_sha=""
prepare_branch main
[[ "$branch_existed" == false ]] || fail 'unexpected existing branch'
branch_was_present=false
pr_created_by_run=false
preflight_empty_commit=false
preflight_pushed=false
published=false
body="$test_root/body.md"
gh() {
  case "$1 $2" in
    'pr create') [[ " $* " == *' --draft '* ]] || fail 'preflight PR was not a draft'; printf 'https://github.com/example/repo/pull/1\n' ;;
    'pr edit') return 0 ;;
    'pr ready') touch "$test_root/ready-marker" ;;
    'pr view') printf 'https://github.com/example/repo/pull/1\n' ;;
    *) fail "unexpected gh call: $*" ;;
  esac
}
preflight_pull_request main "$body"
[[ "$pr_created_by_run" == true && "$preflight_empty_commit" == true ]] ||
  fail 'first run did not create a draft PR before translation'
git --git-dir="$test_root/origin.git" rev-parse refs/heads/forthwith/localize >/dev/null
[[ "$(git --git-dir="$test_root/origin.git" log -1 --format=%s refs/heads/forthwith/localize)" == *'[skip ci]' ]] ||
  fail 'empty preflight commit did not skip redundant checks'

mkdir -p locale/pt_BR
printf '{"hello":"olá"}\n' >locale/pt_BR/messages.json
printf '{"version":1}\n' >.forthwith.lock
printf 'version: 1\nproject_id: 0f591a70-c3de-46e8-9548-a7ac0e8986a8\nframework: react\n' >.forthwith.yml
first_run_project_id_only || fail 'first-run project ID update was rejected'
printf 'framework: android\nproject_id: 0f591a70-c3de-46e8-9548-a7ac0e8986a8\nversion: 1\n' >.forthwith.yml
expect_failure first_run_project_id_only
printf 'framework: react\nproject_id: 0f591a70-c3de-46e8-9548-a7ac0e8986a8\nversion: 1\n' >.forthwith.yml
first_run_project_id_only || fail 'harmless YAML reordering was rejected'
report_path="$test_root/success.json"
printf '%s\n' '{"status":"success","files_updated":["locale/pt_BR/messages.json"],"summary":{"strings_translated":1},"languages":["pt-BR"]}' >"$report_path"
read_report "$report_path" 0
stage_outputs "$report_path"
[[ "$(git diff --cached --name-only | wc -l | tr -d ' ')" == 3 ]] || fail 'wrong staged file count'
publish_branch_and_pr main "$body"
[[ "$pr_url" == 'https://github.com/example/repo/pull/1' ]] || fail 'PR URL missing'
[[ -e "$test_root/ready-marker" ]] || fail 'translated PR was not marked ready'
grep -Fq 'Strings translated this run: 1' "$body" || fail 'PR count missing'
git --git-dir="$test_root/origin.git" rev-parse refs/heads/forthwith/localize >/dev/null
[[ "$(git --git-dir="$test_root/origin.git" rev-list --count main..forthwith/localize)" == 1 ]] ||
  fail 'empty preflight commit was not replaced by the translation commit'
[[ "$(git --git-dir="$test_root/origin.git" log -1 --format=%s refs/heads/forthwith/localize)" == "$pr_title" ]] ||
  fail 'final translation commit retained skip-ci marker'

# A later default-branch push must preserve the unmerged translations and
# lockfile before the next paid translation request.
printf '{"hello":"Hello","bye":"Bye"}\n' >"$test_root/seed/source.json"
git -C "$test_root/seed" add source.json
git -C "$test_root/seed" commit -qm 'add source string'
git -C "$test_root/seed" push -q origin main
git clone -q "$test_root/origin.git" "$test_root/second"
cd "$test_root/second"
gh() {
  case "$*" in
    *'--state all'*) printf '%s\n' '[{"number":999,"state":"CLOSED","headRepositoryOwner":{"login":"fork"}},{"number":1,"state":"OPEN","headRepositoryOwner":{"login":"example"}}]' ;;
    *'--state open'*) printf '1\n' ;;
    pr\ edit*) return 0 ;;
    pr\ view*) printf 'https://github.com/example/repo/pull/1\n' ;;
    *) fail "unexpected gh call: $*" ;;
  esac
}
branch_existed=false
existing_pr=""
old_branch_sha=""
prepare_branch main
[[ "$branch_existed" == true && "$existing_pr" == 1 ]] || fail 'existing PR not found'
pr_created_by_run=false
preflight_empty_commit=false
published=false
preflight_pull_request main "$test_root/updated-body.md"
grep -Fq 'olá' locale/pt_BR/messages.json || fail 'unmerged translation was lost'
test -f .forthwith.lock || fail 'unmerged lockfile was lost'
grep -Fq 'bye' source.json || fail 'new default-branch source was lost'

# Fail closed when the CLI changes a path it did not declare as output.
printf 'unexpected\n' >other.txt
expect_failure stage_outputs "$report_path"
rm -- other.txt

# A declared but ignored output must not be silently omitted from the PR.
printf 'ignored.json\n' >>.git/info/exclude
printf '{"hello":"olá"}\n' >ignored.json
printf '%s\n' '{"status":"success","files_updated":["ignored.json"],"summary":{"strings_translated":1}}' >"$report_path"
expect_failure stage_outputs "$report_path"
rm -- ignored.json

printf '{"hello":"olá","bye":"tchau"}\n' >locale/pt_BR/messages.json
printf '%s\n' '{"status":"success","files_updated":["locale/pt_BR/messages.json"],"summary":{"strings_translated":1},"languages":["pt-BR"]}' >"$report_path"
read_report "$report_path" 0
stage_outputs "$report_path"
body="$test_root/updated-body.md"
publish_branch_and_pr main "$body"
git --git-dir="$test_root/origin.git" show refs/heads/forthwith/localize:source.json | grep -Fq 'bye' || fail 'source update missing from branch'
git --git-dir="$test_root/origin.git" show refs/heads/forthwith/localize:locale/pt_BR/messages.json | grep -Fq 'tchau' || fail 'updated translation missing from branch'

printf '%s\n' '{"status":"success","failures":{"strings":["missing"]},"summary":{"failed_strings_count":1}}' >"$report_path"
read_report "$report_path" 0
[[ "$partial" == true ]] || fail 'partial failure was not detected'

printf '%s\n' '{"status":"no_changes","message":"nothing to translate"}' >"$report_path"
read_report "$report_path" 0
[[ "$report_status" == no_changes && "$strings_translated" == 0 && "$partial" == false ]] ||
  fail 'no-change report was not handled'

# Exercise main without network or billing, including no-change outputs and
# cleanup after the function returns and its EXIT trap runs.
git clone -q "$test_root/origin.git" "$test_root/third"
(
  cd "$test_root/third"
  GH_TOKEN=test-token
  FORTHWITH_AUTH_TOKEN=test-token
  FORTHWITH_CLI_VERSION=v1.0.3
  FORTHWITH_MAX_STRINGS=1
  GITHUB_EVENT_NAME=workflow_dispatch
  GITHUB_REF=refs/heads/main
  GITHUB_OUTPUT="$test_root/action-output"
  GITHUB_STEP_SUMMARY="$test_root/action-summary"
  RUNNER_TEMP="$test_root"
  gh() {
    case "$*" in
      'api repos/example/repo --jq .default_branch') printf 'main\n' ;;
      *'--state all'*) printf '%s\n' '[{"number":1,"state":"OPEN","headRepositoryOwner":{"login":"example"}}]' ;;
      pr\ edit*) return 0 ;;
      pr\ view*) printf 'https://github.com/example/repo/pull/1\n' ;;
      *) fail "unexpected gh call: $*" ;;
    esac
  }
  install_cli() {
    mkdir -p "$2"
    printf '%s\n' '#!/bin/sh' 'echo "{\"status\":\"no_changes\"}"' >"$2/forthwith"
    chmod +x "$2/forthwith"
  }
  main
  printf '%s\n' "$tool_dir" >"$test_root/tool-path"
)
[[ ! -e "$(<"$test_root/tool-path")" ]] || fail 'temporary CLI directory was not cleaned up'
grep -Fq 'status=no_changes' "$test_root/action-output" || fail 'no-change output missing'
grep -Fq 'pull-request-url=https://github.com/example/repo/pull/1' "$test_root/action-output" ||
  fail 'PR output missing'
grep -Fq 'Review localization PR' "$test_root/action-summary" || fail 'step summary missing'

# A PR-creation denial must stop before the paid CLI runs, and remove the
# temporary branch created only for the permission preflight.
git --git-dir="$test_root/origin.git" update-ref -d refs/heads/forthwith/localize
git clone -q "$test_root/origin.git" "$test_root/denied"
if (
  cd "$test_root/denied"
  GH_TOKEN=test-token
  FORTHWITH_AUTH_TOKEN=test-token
  FORTHWITH_CLI_VERSION=v1.0.3
  FORTHWITH_MAX_STRINGS=1
  GITHUB_EVENT_NAME=workflow_dispatch
  GITHUB_REF=refs/heads/main
  RUNNER_TEMP="$test_root"
  gh() {
    case "$1 $2" in
      'api repos/example/repo') printf 'main\n' ;;
      'pr create') return 1 ;;
      *) fail "unexpected gh call: $*" ;;
    esac
  }
  install_cli() {
    mkdir -p "$2"
    printf '#!/bin/sh\ntouch "%s"\n' "$test_root/paid-marker" >"$2/forthwith"
    chmod +x "$2/forthwith"
  }
  main
) >"$test_root/denied.log" 2>&1; then
  fail 'PR denial did not stop the action'
fi
grep -Fq 'could not create a PR before translation' "$test_root/denied.log" ||
  fail 'PR denial did not explain the setting'
[[ ! -e "$test_root/paid-marker" ]] || fail 'paid CLI ran after PR denial'
expect_failure git --git-dir="$test_root/origin.git" rev-parse --verify refs/heads/forthwith/localize

# If translation itself fails, an empty draft from this run is closed and its
# temporary branch removed. No paid result is published in that case.
git clone -q "$test_root/origin.git" "$test_root/translation-failed"
if (
  cd "$test_root/translation-failed"
  GH_TOKEN=test-token
  FORTHWITH_AUTH_TOKEN=test-token
  FORTHWITH_CLI_VERSION=v1.0.3
  FORTHWITH_MAX_STRINGS=1
  GITHUB_EVENT_NAME=workflow_dispatch
  GITHUB_REF=refs/heads/main
  RUNNER_TEMP="$test_root"
  gh() {
    case "$1 $2" in
      'api repos/example/repo') printf 'main\n' ;;
      'pr create') printf 'https://github.com/example/repo/pull/3\n' ;;
      'pr close')
        touch "$test_root/failure-cleanup-marker"
        git --git-dir="$test_root/origin.git" update-ref -d refs/heads/forthwith/localize
        ;;
      *) fail "unexpected gh call: $*" ;;
    esac
  }
  install_cli() {
    mkdir -p "$2"
    printf '%s\n' '#!/bin/sh' 'echo "{\"status\":\"error\",\"message\":\"test failure\"}"' >"$2/forthwith"
    chmod +x "$2/forthwith"
  }
  main
) >"$test_root/translation-failed.log" 2>&1; then
  fail 'translation error did not fail the action'
fi
[[ -e "$test_root/failure-cleanup-marker" ]] || fail 'failed translation left an empty draft PR'
expect_failure git --git-dir="$test_root/origin.git" rev-parse --verify refs/heads/forthwith/localize

# A successful preflight with nothing to translate closes its temporary draft.
git clone -q "$test_root/origin.git" "$test_root/no-changes"
(
  cd "$test_root/no-changes"
  GH_TOKEN=test-token
  FORTHWITH_AUTH_TOKEN=test-token
  FORTHWITH_CLI_VERSION=v1.0.3
  FORTHWITH_MAX_STRINGS=1
  GITHUB_EVENT_NAME=workflow_dispatch
  GITHUB_REF=refs/heads/main
  GITHUB_OUTPUT="$test_root/no-change-output"
  RUNNER_TEMP="$test_root"
  gh() {
    case "$1 $2" in
      'api repos/example/repo') printf 'main\n' ;;
      'pr create') printf 'https://github.com/example/repo/pull/2\n' ;;
      'pr close') git --git-dir="$test_root/origin.git" update-ref -d refs/heads/forthwith/localize ;;
      *) fail "unexpected gh call: $*" ;;
    esac
  }
  install_cli() {
    mkdir -p "$2"
    printf '%s\n' '#!/bin/sh' 'echo "{\"status\":\"no_changes\"}"' >"$2/forthwith"
    chmod +x "$2/forthwith"
  }
  main
)
grep -Fq 'status=no_changes' "$test_root/no-change-output" || fail 'no-change status missing'
grep -Fxq 'pull-request-url=' "$test_root/no-change-output" || fail 'empty PR URL missing'
expect_failure git --git-dir="$test_root/origin.git" rev-parse --verify refs/heads/forthwith/localize

printf 'localize tests passed\n'
