#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/check.sh"

fail() {
  echo "check action test: $*" >&2
  exit 1
}

assert_rejected() {
  local expected="$1" output
  shift
  if output="$("$@" 2>&1)"; then
    fail "expected rejection, got success: $*"
  fi
  [[ "$output" == *"$expected"* ]] || fail "unexpected error: $output"
}

curl() {
  [[ "$*" == *"https://github.com/Forthwith-LLC/forthwith-releases/releases/latest"* ]] ||
    fail "latest release lookup used an unexpected URL"
  case "${mock_curl_response:-}" in
    error) return 22 ;;
    *) printf '%s' "${mock_curl_response:-}" ;;
  esac
}

[[ "$(resolve_cli_version v1.0.3)" == v1.0.3 ]] || fail "exact version changed"
assert_rejected "cli-version must be" resolve_cli_version v1.0.3-rc.1
assert_rejected "cli-version must be" resolve_cli_version v1.0.3/other

mock_curl_response="https://github.com/Forthwith-LLC/forthwith-releases/releases/tag/v1.2.3"
[[ "$(resolve_cli_version latest)" == v1.2.3 ]] || fail "latest version not resolved"

mock_curl_response="https://example.com/Forthwith-LLC/forthwith-releases/releases/tag/v1.2.3"
assert_rejected "unexpected URL" resolve_cli_version latest

mock_curl_response="https://github.com/Forthwith-LLC/forthwith-releases/releases/tag/v1.2.3-rc.1"
assert_rejected "cli-version must be" resolve_cli_version latest

mock_curl_response=error
assert_rejected "could not resolve" resolve_cli_version latest

echo "check action version tests passed"
