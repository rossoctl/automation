#!/usr/bin/env bash
# Regression test for huang195's round-2 must-fix: a --dry-run run must NOT
# write the baseline (latest.json / history.json). If it did, the next REAL run
# would see the dry-run's findings as "recurring" (not "new") and skip filing
# them — and skip closing anything the dry run showed as fixed.
#
# Drives the REAL link-health-scanner.sh with gh + lychee stubbed. Sequence:
# (run 1) --dry-run against a repo with one broken link; (run 2) real run.
# Expectation: run 2 files exactly one issue (the dry run left no baseline, so
# the link is still "new"). Also: run 1 wrote no latest.json / history.json.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/../scripts/link-health-scanner.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

BIN="$TEST_TMPDIR/bin"; mkdir -p "$BIN"
CREATE_LOG="$TEST_TMPDIR/issue_create.txt"; : > "$CREATE_LOG"
# gh stub: record `issue create`; no open issues exist yet (search empty).
cat > "$BIN/gh" <<STUB
#!/usr/bin/env bash
# issue list/search use --jq to extract a number; "no match" must print NOTHING
# (empty), not "[]" — the caller reads the stdout as the issue number, and a
# literal "[]" would read as "issue #[] already exists" and suppress creation.
case "\$*" in
  *"issue create"*) echo "CREATE \$*" >> "$CREATE_LOG"; echo "https://github.com/alice/a/issues/1"; exit 0 ;;
  *"issue list"*) exit 0 ;;        # empty -> .[0].number is empty -> "not found"
  *"search"*)     exit 0 ;;        # empty search result set
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"
# lychee stub: one broken external link in alice/a.
cat > "$BIN/lychee" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{"total":1,"successful":0,"errors":1,"error_map":{"README.md":[{"url":"https://dead.example.net/x","status":{"code":404,"text":"Not Found"}}]}}
JSON
exit 0
STUB
chmod +x "$BIN/lychee"

export REPOMAN_CONFIG_FILE="$TEST_TMPDIR/config.json"
export REPOMAN_REPOS_FILE="$TEST_TMPDIR/repos.json"
REPOS_ROOT="$TEST_TMPDIR/repos"; mkdir -p "$REPOS_ROOT/alice/a/.git"
printf 'broken link: https://dead.example.net/x\n' > "$REPOS_ROOT/alice/a/README.md"
printf '{"repos_dir":"%s","fork_owner":"tester"}\n' "$REPOS_ROOT" > "$REPOMAN_CONFIG_FILE"
printf '[{"owner":"alice","name":"a"}]\n' > "$REPOMAN_REPOS_FILE"
REPORTS="$TEST_TMPDIR/reports/link-health"; mkdir -p "$REPORTS"

# --- run 1: dry run ---
# Pinned to LINK_CHECKER=lychee: this test drives the lychee stub (the
# default checker is python).
REPORTS_DIR="$REPORTS" LINK_CHECKER=lychee PATH="$BIN:$PATH" bash "$SCANNER" --dry-run >/dev/null 2>&1

# run 1 must not have written the baseline
[ ! -f "$REPORTS/latest.json" ] \
  || { echo "FAIL: dry run wrote latest.json (baseline must be untouched)"; fail=1; }
[ ! -f "$REPORTS/history.json" ] \
  || { echo "FAIL: dry run wrote history.json"; fail=1; }
[ ! -s "$CREATE_LOG" ] \
  || { echo "FAIL: dry run created an issue"; fail=1; }

# --- run 2: real run ---
: > "$CREATE_LOG"
REPORTS_DIR="$REPORTS" LINK_CHECKER=lychee PATH="$BIN:$PATH" bash "$SCANNER" >/dev/null 2>&1

# run 2 must file exactly one issue (the link is still "new" — dry run left no baseline)
created=$(grep -c "CREATE" "$CREATE_LOG" 2>/dev/null || echo 0)
if [ "$created" = "1" ]; then
  echo "PASS: real run after dry run filed the new issue (1 create)"
else
  echo "FAIL: real run filed $created issues (expected 1 — dry run must not have poisoned the baseline)"; fail=1
fi
[ -f "$REPORTS/latest.json" ] \
  || { echo "FAIL: real run did not write latest.json"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
