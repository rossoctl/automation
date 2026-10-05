#!/usr/bin/env bash
# Verifies dep-bump-scanner.sh registers itself in _index.json after writing
# reports, and that a failing registry write is non-fatal to the scan.
#
# Isolation: drives the REAL scanner as a subprocess, mirroring
# tests/test-link-health-index-wiring.sh. repoman_config / repoman_load_enrolled
# are pointed at fixture files via their documented REPOMAN_CONFIG_FILE /
# REPOMAN_REPOS_FILE overrides. The enrolled repo has NO local clone under
# REPOS_DIR, so enrolled_clone_dirs() skips it: Step 1's ecosystem-detection
# loop never runs, ecosystems.jsonl stays empty, so Step 2's Dependabot-PR
# loop (which reads ecosystems.jsonl) also never runs -- no gh pr list, no
# gh api dependabot/alerts calls. stale_prs.jsonl and prev_stale.jsonl both
# end up empty, so diff_against_previous's new_keys.txt/fixed_keys.txt are
# both empty too -- Step 6 (gh issue create) and Step 7 (gh issue list /
# close_issue_if_valid) loops are no-ops. The scan then flows straight to
# write_report_latest -> append_history_row -> the new index call, with zero
# network calls required. A `gh` stub is included defensively (unreached in
# practice) in case any future change adds an unconditional gh call before
# the index-call point. --dry-run additionally guards issue creation.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/../scripts/dep-bump-scanner.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

STUB_DIR="$TEST_TMPDIR/bin"; mkdir -p "$STUB_DIR"

# gh stub: no-op success for any invocation -- the scan reaches its
# report-write tail before any gh call that matters here (see header).
cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$STUB_DIR/gh"

# Fixtures: config.json + repos.json via the readers' env overrides. The
# enrolled repo has no clone on disk, so the scan loop is a no-op.
export REPOMAN_CONFIG_FILE="$TEST_TMPDIR/config.json"
export REPOMAN_REPOS_FILE="$TEST_TMPDIR/repos.json"
REPOS_ROOT="$TEST_TMPDIR/repos"
mkdir -p "$REPOS_ROOT"
printf '{"repos_dir":"%s","fork_owner":"tester"}\n' "$REPOS_ROOT" > "$REPOMAN_CONFIG_FILE"
printf '[{"owner":"alice","name":"tool"}]\n' > "$REPOMAN_REPOS_FILE"

# Point reports at a temp dir; index resolves to its parent per the contract.
REPORTS="$TEST_TMPDIR/reports/dep-bump"
export REPOMAN_INDEX_FILE="$TEST_TMPDIR/reports/_index.json"

run_scanner() {
  REPORTS_DIR="$REPORTS" PATH="$STUB_DIR:$PATH" bash "$SCANNER" --dry-run
}

# Case 1: after a scan, _index.json has the dep-bump entry with the correct
# display_name and report_path.
out=$(run_scanner 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c1: scanner exit $rc"; echo "$out"; fail=1; }
[ -f "$REPOMAN_INDEX_FILE" ] || { echo "FAIL c1: index not written"; fail=1; }
[ "$(jq -r '.["dep-bump"].display_name' "$REPOMAN_INDEX_FILE" 2>/dev/null)" = "Dependency Bumps" ] \
  || { echo "FAIL c1: dep-bump entry missing/wrong"; fail=1; }
[ "$(jq -r '.["dep-bump"].report_path' "$REPOMAN_INDEX_FILE" 2>/dev/null)" = "$REPORTS" ] \
  || { echo "FAIL c1: report_path wrong"; fail=1; }

# Case 2: the index write fails -> the scan still exits 0, and the failure is
# logged with a WARNING naming the index file (surfaced, not swallowed).
#
# The scanner invokes the writer via an absolute "$SCRIPT_DIR/repoman-index.sh"
# path (SCRIPT_DIR = the scanner's own dir), not a PATH lookup, so a PATH stub
# cannot intercept it. Instead, run a COPY of scripts/ (real files symlinked
# through) with repoman-index.sh swapped for a failing stub -- this still
# exercises the real scanner + real other scripts, only the one dependency
# under test is faked.
rm -rf "$TEST_TMPDIR/reports"
FAKE_SCRIPTS="$TEST_TMPDIR/scripts"; mkdir -p "$FAKE_SCRIPTS"
for f in "$SCRIPT_DIR/../scripts"/*; do
  base=$(basename "$f")
  [ "$base" = "repoman-index.sh" ] && continue
  ln -s "$f" "$FAKE_SCRIPTS/$base"
done
cat > "$FAKE_SCRIPTS/repoman-index.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub: simulated repoman-index.sh failure" >&2
exit 1
STUB
chmod +x "$FAKE_SCRIPTS/repoman-index.sh"

out=$(REPORTS_DIR="$REPORTS" PATH="$STUB_DIR:$PATH" bash "$FAKE_SCRIPTS/dep-bump-scanner.sh" --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c2: scan should stay exit 0 despite index-write failure, got $rc"; echo "$out"; fail=1; }
printf '%s' "$out" | grep -qi "WARNING.*$REPOMAN_INDEX_FILE" \
  || { echo "FAIL c2: failure not logged with the index path"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
