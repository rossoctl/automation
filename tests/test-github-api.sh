#!/usr/bin/env bash
set -uo pipefail   # NOT -e: we deliberately run gh_with_backoff expecting failures
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../scripts/program-lib.sh"
fail=0
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# --- retry then success: gh fails with 429 once, then succeeds ---
COUNTER_FILE="$TEST_TMPDIR/attempts"
echo 0 > "$COUNTER_FILE"
gh() {
  local n; n=$(cat "$COUNTER_FILE"); n=$((n+1)); echo "$n" > "$COUNTER_FILE"
  if [ "$n" -lt 2 ]; then echo "HTTP 429: secondary rate limit" >&2; return 1; fi
  echo "ok"; return 0
}
export -f gh 2>/dev/null || true
RATE_LIMIT_BACKOFF=0
# Speed: stub sleep so backoff does not actually wait.
sleep() { :; }
out=$(gh_with_backoff api user 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "ok" ] \
  || { echo "FAIL gh_with_backoff should succeed after one retry: rc=$rc out=[$out]"; fail=1; }
attempts=$(cat "$COUNTER_FILE")
[ "$attempts" -eq 2 ] || { echo "FAIL gh_with_backoff should have retried once (2 calls): got $attempts"; fail=1; }

# --- persistent rate limit: hard-stop error after max attempts ---
gh() { echo "HTTP 403: rate limit exceeded" >&2; return 1; }
RATE_LIMIT_BACKOFF=0
err=$(gh_with_backoff api user 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL gh_with_backoff should fail on persistent rate limit"; fail=1; }
case "$err" in
  *"Rate limit persisted"*) ;;
  *) echo "FAIL gh_with_backoff persistent should emit hard-stop message, got: [$err]"; fail=1 ;;
esac

# --- non-rate-limit error is NOT retried (returns 1 immediately) ---
CALLS="$TEST_TMPDIR/calls"; echo 0 > "$CALLS"
gh() { local n; n=$(cat "$CALLS"); echo $((n+1)) > "$CALLS"; echo "not found" >&2; return 1; }
# shellcheck disable=SC2034  # read by gh_with_backoff (sourced from github-api.sh), not in this file
RATE_LIMIT_BACKOFF=0
gh_with_backoff api nope >/dev/null 2>&1
[ "$(cat "$CALLS")" -eq 1 ] || { echo "FAIL gh_with_backoff should not retry a non-rate-limit error"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: gh_with_backoff" || exit 1
