#!/usr/bin/env bash
# Regression test for the subset-run carry-forward fix (PR #117, huang195
# must-fix): a named-subset run of link-health must NOT close the issues of
# repos OUTSIDE the subset, and must carry their prior findings forward into
# latest.json so the next full run does not re-file them.
#
# Drives the REAL link-health-scanner.sh with gh + lychee stubbed. Scenario
# (Hai's repro): two enrolled repos alice/a and bob/b; a prior latest.json holds
# one broken link in bob/b with an open issue (#42). We scan ONLY alice/a
# (REPOMAN_SUBSET_REPOS=alice/a, REPOMAN_REPOS_FILE=subset). lychee reports
# alice/a clean. Expectations:
#   1. NO `gh issue close` is invoked for bob/b's #42.
#   2. latest.json still contains bob/b's broken link (carried forward).
#   3. history.json is NOT appended (subset run).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/../scripts/link-health-scanner.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

BIN="$TEST_TMPDIR/bin"; mkdir -p "$BIN"
CLOSE_LOG="$TEST_TMPDIR/close_calls.txt"; : > "$CLOSE_LOG"

# gh stub: record `issue close` invocations; succeed (empty) for everything else
# (issue search/create/list). Keeps the scanner's gh_with_backoff happy.
cat > "$BIN/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"issue close"*) echo "CLOSE \$*" >> "$CLOSE_LOG"; exit 0 ;;
  *"issue list"*|*"search"*) echo "[]"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"

# lychee stub: emit a minimal valid report with zero errors (alice/a is clean).
cat > "$BIN/lychee" <<'STUB'
#!/usr/bin/env bash
echo '{"total":1,"successful":1,"errors":0,"error_map":{}}'
exit 0
STUB
chmod +x "$BIN/lychee"

# Enrolled set: two repos, each with a clone on disk (so enrolled_clone_dirs
# yields them; the subset env still narrows the current scan).
export REPOMAN_CONFIG_FILE="$TEST_TMPDIR/config.json"
export REPOMAN_REPOS_FILE="$TEST_TMPDIR/repos.json"          # full enrolled set
REPOS_ROOT="$TEST_TMPDIR/repos"
mkdir -p "$REPOS_ROOT/alice/a/.git" "$REPOS_ROOT/bob/b/.git"
printf '{"repos_dir":"%s","fork_owner":"tester"}\n' "$REPOS_ROOT" > "$REPOMAN_CONFIG_FILE"
printf '[{"owner":"alice","name":"a"},{"owner":"bob","name":"b"}]\n' > "$REPOMAN_REPOS_FILE"

REPORTS="$TEST_TMPDIR/reports/link-health"; mkdir -p "$REPORTS"
# Prior FULL-set latest.json: one broken link in bob/b with an open issue #42.
cat > "$REPORTS/latest.json" <<'JSON'
{
  "scan_id": "prev-1",
  "date": "2026-10-01T00:00:00Z",
  "repos_scanned": 2,
  "broken": [
    {"repo":"bob/b","file":"README.md","url":"https://dead.example.net/x",
     "category":"external","status":"404","issue_number":42,
     "first_detected":"2026-10-01","context":""}
  ],
  "delta": {"new":1,"fixed":0,"recurring":0}
}
JSON
# A prior history so append-vs-skip is observable (1 row to start).
printf '[{"scan_id":"prev-1","fixed":0}]\n' > "$REPORTS/history.json"

# Subset run: scan ONLY alice/a. The orchestrator would set both envs; emulate.
SUBSET="$TEST_TMPDIR/subset.json"
printf '[{"owner":"alice","name":"a"}]\n' > "$SUBSET"
# Pinned to LINK_CHECKER=lychee: this test drives the lychee stub (the
# default checker is python).
REPORTS_DIR="$REPORTS" LINK_CHECKER=lychee PATH="$BIN:$PATH" \
  REPOMAN_REPOS_FILE="$SUBSET" REPOMAN_SUBSET_REPOS="alice/a" \
  bash "$SCANNER" >/dev/null 2>&1

# 1. bob/b's issue #42 must NOT have been closed.
if grep -q "issue close" "$CLOSE_LOG" 2>/dev/null; then
  echo "FAIL: a subset run closed an out-of-subset issue:"; cat "$CLOSE_LOG"; fail=1
else
  echo "PASS: no out-of-subset issue closed"
fi

# 2. latest.json must still contain bob/b's broken link (carried forward).
carried=$(jq -r '[.broken[] | select(.repo=="bob/b")] | length' "$REPORTS/latest.json" 2>/dev/null)
if [ "$carried" = "1" ]; then
  echo "PASS: bob/b finding carried forward into latest.json"
else
  echo "FAIL: bob/b finding not carried forward (count=$carried):"; jq -c '.broken' "$REPORTS/latest.json" 2>/dev/null; fail=1
fi

# 3. history.json must NOT have grown (subset run skips the append).
hrows=$(jq 'length' "$REPORTS/history.json" 2>/dev/null)
if [ "$hrows" = "1" ]; then
  echo "PASS: history.json not appended on subset run (still $hrows row)"
else
  echo "FAIL: history.json grew to $hrows rows on a subset run (expected 1)"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
