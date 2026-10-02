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

# =============================================================================
# issue_has_open_pr -- regex-matcher regressions (rossoctl/automation#103)
#
# The matcher logic lives inside the --jq filter (Layer 2) and the grep -Eq
# (Layer 3) of issue_has_open_pr. We stub gh so that `gh pr list ... --jq EXPR`
# runs the REAL jq against canned JSON using the EXACT expression the function
# passes, and `gh pr diff` emits a canned diff. This exercises the actual regex
# strings in github-api.sh, not a reimplementation of them.
# =============================================================================
fail2=0

# --- Layer 2: issue-number boundary -- #12 must NOT match "fixes #123" ---
# Shared stub: canned `pr list --json number,body`; GraphQL (Layer 1) returns
# nothing so control falls through to Layer 2.
PR_LIST_BODY='[{"number":123,"body":"fixes #123"},{"number":12,"body":"closes #12"}]'
gh() {
  case "$1 $2" in
    "api graphql") printf '' ;;              # Layer 1: no closing PR
    "pr list")
      # locate the --jq expression this invocation passed, run real jq on canned JSON
      local jq_expr=""; shift
      while [ "$#" -gt 0 ]; do
        [ "$1" = "--jq" ] && { jq_expr="$2"; break; }
        shift
      done
      printf '%s' "$PR_LIST_BODY" | jq -r "$jq_expr"
      ;;
    *) return 1 ;;
  esac
}

# issue 12 is covered (its own PR #12 says "closes #12"); #123 must not leak in.
out=$(issue_has_open_pr "rossoctl/automation" 12 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "12" ] \
  || { echo "FAIL issue_has_open_pr: #12 should match 'closes #12' (got rc=$rc out=[$out])"; fail2=1; }

# issue 1 has no matching close/fix body (neither "#123" nor "#12" is "#1(?![0-9])").
out=$(issue_has_open_pr "rossoctl/automation" 1 2>/dev/null); rc=$?
[ "$rc" -ne 0 ] \
  || { echo "FAIL issue_has_open_pr: #1 must NOT match '#12'/'#123' bodies (prefix bug), got [$out]"; fail2=1; }

# --- Layer 3: broken-URL match -- grep -Eq must honor sed -E escaping ---
# Only source_file + broken_url trigger Layer 3. Stub returns one candidate PR
# whose diff removes a query-string URL (contains '?', which sed -E escapes).
BROKEN_URL='https://example.com/path?a=1&b=2'
gh() {
  case "$1 $2" in
    "api graphql") printf '' ;;      # Layer 1: none
    "pr list")
      # Distinguish Layer 2 (--json number,body) from Layer 3 (--json number,files).
      case " $* " in
        *" number,files "*) echo 7 ;;   # Layer 3 file-overlap candidate
        *) printf '' ;;                   # Layer 2: no keyword match
      esac
      ;;
    "pr diff") printf -- '-see %s for details\n' "$BROKEN_URL" ;;
    *) return 1 ;;
  esac
}
out=$(issue_has_open_pr "rossoctl/automation" 99 "docs/x.md" "$BROKEN_URL" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "7" ] \
  || { echo "FAIL issue_has_open_pr: Layer 3 should match query-string URL via grep -Eq (got rc=$rc out=[$out])"; fail2=1; }

unset -f gh
[ "$fail2" -eq 0 ] && echo "PASS: issue_has_open_pr regex matchers" || exit 1
