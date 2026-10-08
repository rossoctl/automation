#!/usr/bin/env bash
set -euo pipefail

# Integration test for the PR review scanner/fixer pipeline.
# Runs the full flow against a real (or specified) PR to validate:
#   - Scanner discovers PRs and writes well-formed reports
#   - Fixer begin produces an enriched queue with diff_map
#   - Fixer finalize checks the reviews API
#
# Usage:
#   bash tests/test-pr-review-integration.sh
#   bash tests/test-pr-review-integration.sh --repo kagenti/kagenti --pr 1881
#
# Prerequisites: gh (authenticated), jq

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/../scripts"

# Defaults: use a known PR that has the label (or was reviewed)
TEST_REPO="kagenti/kagenti"
TEST_PR=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --repo) TEST_REPO="$2"; shift 2 ;;
    --pr) TEST_PR="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: test-pr-review-integration.sh [--repo OWNER/REPO] [--pr NUMBER]"
      echo "  If --pr is given, seeds the reports to include that PR regardless of label."
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

TMPDIR=$(mktemp -d "/tmp/test-pr-review-int-XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT
REPORTS_DIR="$TMPDIR/reports"
mkdir -p "$REPORTS_DIR"

# The scanner resolves its repo set from the RepoMan enrolled set
# (~/.repoman/repos.json) via repoman_get_repos. Point it at a stub so the test
# is hermetic -- it must not depend on the operator's real enrollment, and it
# must run in CI where no ~/.repoman exists. $TEST_REPO is the single enrolled
# repo so the scanner has exactly one place to look.
export REPOMAN_REPOS_FILE="$TMPDIR/repos.json"
jq -n --arg full "$TEST_REPO" \
  '[{owner: ($full | split("/")[0]), name: ($full | split("/")[1])}]' \
  > "$REPOMAN_REPOS_FILE"

PASS=0
FAIL=0

check() {
  local name="$1"
  local condition="$2"

  if eval "$condition"; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== PR Review Integration Test ==="
echo "Reports dir: $REPORTS_DIR"
echo ""

# --- Phase 1: Scanner ---
echo "Phase 1: Scanner"

SCANNER_OUTPUT=$("$SCRIPTS_DIR/pr-review-scanner.sh" \
  --verbose \
  --reports-dir "$REPORTS_DIR" \
  2>"$TMPDIR/scanner_stderr.txt")

check "scanner exits cleanly" "true"
check "scanner stdout is valid JSON" "echo '$SCANNER_OUTPUT' | jq empty 2>/dev/null"
check "scanner stdout is an array" "[ \$(echo '$SCANNER_OUTPUT' | jq 'type') = '\"array\"' ]"
check "latest.json exists" "[ -f '$REPORTS_DIR/latest.json' ]"
check "state.json exists" "[ -f '$REPORTS_DIR/state.json' ]"
check "history.json exists" "[ -f '$REPORTS_DIR/history.json' ]"
check "latest.json has scan_id" "jq -e '.scan_id' '$REPORTS_DIR/latest.json' >/dev/null 2>&1"
check "latest.json has eligible_prs array" "jq -e '.eligible_prs | type == \"array\"' '$REPORTS_DIR/latest.json' >/dev/null 2>&1"
check "state.json has in_progress array" "jq -e '.in_progress | type == \"array\"' '$REPORTS_DIR/state.json' >/dev/null 2>&1"
check "state.json has reviewed array" "jq -e '.reviewed | type == \"array\"' '$REPORTS_DIR/state.json' >/dev/null 2>&1"

echo ""

# --- Phase 1b: If --pr given, seed latest.json with that PR ---
if [ -n "$TEST_PR" ]; then
  echo "Seeding latest.json with $TEST_REPO#$TEST_PR for fixer test..."
  HEAD_SHA=$(gh pr view "$TEST_PR" --repo "$TEST_REPO" --json headRefOid --jq '.headRefOid' 2>/dev/null || echo "unknown")

  jq --arg repo "$TEST_REPO" --argjson num "$TEST_PR" --arg sha "$HEAD_SHA" \
    '.eligible_prs = [{"repo": $repo, "number": $num, "head_sha": $sha}]' \
    "$REPORTS_DIR/latest.json" > "$TMPDIR/latest_seeded.json"
  mv "$TMPDIR/latest_seeded.json" "$REPORTS_DIR/latest.json"
  echo ""
fi

# --- Phase 2: Fixer begin (dry-run by default) ---
echo "Phase 2: Fixer begin"

ELIGIBLE_COUNT=$(jq '.eligible_prs | length' "$REPORTS_DIR/latest.json")

if [ "$ELIGIBLE_COUNT" -eq 0 ] && [ -z "$TEST_PR" ]; then
  echo "  SKIP: No eligible PRs found (use --pr to seed one)"
  echo ""
else
  FIXER_BEGIN_OUTPUT=$("$SCRIPTS_DIR/pr-review-fixer.sh" begin \
    --verbose \
    --reports-dir "$REPORTS_DIR" \
    2>"$TMPDIR/fixer_begin_stderr.txt")

  check "fixer begin exits cleanly" "true"
  check "fixer begin stdout is valid JSON" "echo '$FIXER_BEGIN_OUTPUT' | jq empty 2>/dev/null"
  check "fixer begin stdout is an array" "[ \$(echo '$FIXER_BEGIN_OUTPUT' | jq 'type') = '\"array\"' ]"

  QUEUE_LEN=$(echo "$FIXER_BEGIN_OUTPUT" | jq 'length')
  check "fixer begin returns non-empty queue" "[ $QUEUE_LEN -gt 0 ]"

  if [ "$QUEUE_LEN" -gt 0 ]; then
    check "queue entries have diff_map" "echo '$FIXER_BEGIN_OUTPUT' | jq -e '.[0].diff_map | type == \"array\"' >/dev/null 2>&1"
    check "queue entries have repo" "echo '$FIXER_BEGIN_OUTPUT' | jq -e '.[0].repo' >/dev/null 2>&1"
    check "queue entries have number" "echo '$FIXER_BEGIN_OUTPUT' | jq -e '.[0].number' >/dev/null 2>&1"
    check "queue entries have head_sha" "echo '$FIXER_BEGIN_OUTPUT' | jq -e '.[0].head_sha' >/dev/null 2>&1"

    DIFF_MAP_LEN=$(echo "$FIXER_BEGIN_OUTPUT" | jq '[.[0].diff_map[].hunks[].lines[]] | length')
    check "diff_map has parsed lines" "[ $DIFF_MAP_LEN -gt 0 ]"

    FIRST_LINE=$(echo "$FIXER_BEGIN_OUTPUT" | jq '.[0].diff_map[0].hunks[0].lines[0].line')
    check "diff_map lines have line numbers" "[ $FIRST_LINE -gt 0 ] 2>/dev/null"

    FIRST_SIDE=$(echo "$FIXER_BEGIN_OUTPUT" | jq -r '.[0].diff_map[0].hunks[0].lines[0].side')
    check "diff_map lines have side (LEFT or RIGHT)" "[ '$FIRST_SIDE' = 'LEFT' ] || [ '$FIRST_SIDE' = 'RIGHT' ]"
  fi

  # Dry-run: state.json should NOT have changed
  check "dry-run did not write state" "[ \$(jq '.in_progress | length' '$REPORTS_DIR/state.json') -eq 0 ]"
  echo ""
fi

# --- Phase 3: Fixer begin --live (writes state) ---
if [ "$ELIGIBLE_COUNT" -gt 0 ] || [ -n "$TEST_PR" ]; then
  echo "Phase 3: Fixer begin --live"

  "$SCRIPTS_DIR/pr-review-fixer.sh" begin \
    --live \
    --verbose \
    --reports-dir "$REPORTS_DIR" \
    > "$TMPDIR/fixer_live_output.json" \
    2>"$TMPDIR/fixer_live_stderr.txt"

  check "live mode wrote state.json" "[ \$(jq '.in_progress | length' '$REPORTS_DIR/state.json') -gt 0 ]"
  echo ""

  # --- Phase 4: Fixer finalize ---
  echo "Phase 4: Fixer finalize"

  FINALIZE_OUTPUT=$("$SCRIPTS_DIR/pr-review-fixer.sh" finalize \
    --live \
    --verbose \
    --reports-dir "$REPORTS_DIR" \
    2>"$TMPDIR/fixer_finalize_stderr.txt")

  check "fixer finalize exits cleanly" "true"
  check "finalize stdout is valid JSON" "echo '$FINALIZE_OUTPUT' | jq empty 2>/dev/null"
  check "finalize has prs_processed" "echo '$FINALIZE_OUTPUT' | jq -e '.prs_processed' >/dev/null 2>&1"
  check "finalize has prs_reviewed" "echo '$FINALIZE_OUTPUT' | jq -e '.prs_reviewed >= 0' >/dev/null 2>&1"
  check "finalize has prs_failed" "echo '$FINALIZE_OUTPUT' | jq -e '.prs_failed >= 0' >/dev/null 2>&1"
  echo ""
fi

# --- Summary ---
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Scanner stderr:"
  cat "$TMPDIR/scanner_stderr.txt"
  if [ -f "$TMPDIR/fixer_begin_stderr.txt" ]; then
    echo ""
    echo "Fixer begin stderr:"
    cat "$TMPDIR/fixer_begin_stderr.txt"
  fi
  exit 1
fi
