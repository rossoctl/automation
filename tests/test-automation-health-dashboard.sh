#!/usr/bin/env bash
# Hermetic tests for automation-health-dashboard.sh discovery behavior.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASH="$SCRIPT_DIR/../scripts/automation-health-dashboard.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

STUB_DIR="$TEST_TMPDIR/bin"; mkdir -p "$STUB_DIR"
for t in gh git; do printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_DIR/$t"; chmod +x "$STUB_DIR/$t"; done

# repoman_config (sourced via program-lib.sh) reads ~/.repoman/config.json by
# default; override with REPOMAN_CONFIG_FILE so the test stays hermetic (same
# idiom as tests/test-repoman-config.sh and friends).
export REPOMAN_CONFIG_FILE="$TEST_TMPDIR/repoman-config.json"
printf '{"repos_dir":"%s","fork_owner":"tester"}\n' "$TEST_TMPDIR/repos" > "$REPOMAN_CONFIG_FILE"

REPORTS="$TEST_TMPDIR/reports"; mkdir -p "$REPORTS/link-health" "$REPORTS/dep-bump"
# Minimal valid latest.json/history.json per program so presence checks pass.
seed() { # $1 = program dir
  printf '{"date":"2026-09-30","repos_scanned":1,"total_links_checked":0,"broken":[]}\n' > "$1/latest.json"
  printf '[{"date":"2026-09-30"}]\n' > "$1/history.json"
}
seed "$REPORTS/link-health"; seed "$REPORTS/dep-bump"

run_dash() { PATH="$STUB_DIR:$PATH" bash "$DASH" --reports-dir "$REPORTS" --dry-run "$@"; }

# Case 1: index present with both entries -> both sections, headings from display_name.
IDX="$REPORTS/_index.json"
cat > "$IDX" <<EOF
{"link-health":{"display_name":"Link Health","report_path":"$REPORTS/link-health","last_run":"2026-09-30T00:00:00Z"},
 "dep-bump":{"display_name":"Dependency Bumps","report_path":"$REPORTS/dep-bump","last_run":"2026-09-30T00:00:00Z"}}
EOF
out=$(run_dash --index "$IDX" 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c1: exit $rc: $out"; fail=1; }
printf '%s' "$out" | grep -q "Link Health" || { echo "FAIL c1: no Link Health heading"; fail=1; }
printf '%s' "$out" | grep -q "Dependency Bumps" || { echo "FAIL c1: no Dep heading"; fail=1; }

# Case 2: index with only link-health -> only that section (no dep-bump).
# Both report dirs exist on disk, so a regression that fell through to
# disk-derived discovery would render Dependency Bumps anyway; the negative
# assertion gives the index-driven path teeth.
cat > "$IDX" <<EOF
{"link-health":{"display_name":"Link Health","report_path":"$REPORTS/link-health","last_run":"2026-09-30T00:00:00Z"}}
EOF
out=$(run_dash --index "$IDX" 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c2: exit $rc: $out"; fail=1; }
printf '%s' "$out" | grep -q "Link Health" || { echo "FAIL c2: link-health missing"; fail=1; }
printf '%s' "$out" | grep -q "Dependency Bumps" && { echo "FAIL c2: dep-bump rendered despite index with only link-health"; fail=1; }

# Case 3: unknown program id -> known sections render, unknown skipped + logged, exit 0.
cat > "$IDX" <<EOF
{"link-health":{"display_name":"Link Health","report_path":"$REPORTS/link-health","last_run":"2026-09-30T00:00:00Z"},
 "mystery":{"display_name":"Mystery","report_path":"$REPORTS/mystery","last_run":"2026-09-30T00:00:00Z"}}
EOF
out=$(run_dash --index "$IDX" 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c3: exit $rc"; fail=1; }
printf '%s' "$out" | grep -qi "mystery" || { echo "FAIL c3: unknown id not logged"; fail=1; }

# Case 4: index absent, both dirs present -> disk-derived, correct headings.
rm -f "$IDX"
out=$(run_dash 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c4: exit $rc: $out"; fail=1; }
printf '%s' "$out" | grep -q "Link Health" || { echo "FAIL c4: disk-derived link heading"; fail=1; }
printf '%s' "$out" | grep -q "Dependency Bumps" || { echo "FAIL c4: disk-derived dep heading"; fail=1; }

# Case 5: index absent, no report dirs -> existing "no reports" error path.
EMPTY="$TEST_TMPDIR/empty"; mkdir -p "$EMPTY"
out=$(PATH="$STUB_DIR:$PATH" bash "$DASH" --reports-dir "$EMPTY" --dry-run 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL c5: expected non-zero on no reports"; fail=1; }
printf '%s' "$out" | grep -qi "no .*reports" || { echo "FAIL c5: wrong error"; fail=1; }

# Case 6: index present but invalid JSON -> fail loud, names file.
printf '{bad' > "$IDX"
out=$(run_dash --index "$IDX" 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL c6: expected non-zero"; fail=1; }
printf '%s' "$out" | grep -q "$IDX" || { echo "FAIL c6: error did not name index"; fail=1; }

# Case 7: cross-program coverage join keys on the full owner/name ref, so two
# different owners of the same bare repo name stay DISTINCT rows and never
# collapse into one bucket. Under the RepoMan owner model the enrolled set can
# span owners, so "cortex" alone is ambiguous; the join must treat
# rossoctl/cortex and alice/cortex as separate repos. link-health reports a
# broken link in rossoctl/cortex; dep-bump reports a stale PR in alice/cortex.
rm -f "$IDX"
cat > "$REPORTS/link-health/latest.json" <<'EOF'
{"date":"2026-10-05","repos_scanned":1,"total_links_checked":1,
 "broken":[{"repo":"rossoctl/cortex","file":"docs/x.md","url":"https://e","status":"404","category":"external"}]}
EOF
cat > "$REPORTS/dep-bump/latest.json" <<'EOF'
{"date":"2026-10-05","repos_scanned":1,"repos_with_dependabot":1,"total_open_prs":1,
 "stale_prs":[{"repo":"alice/cortex","number":7,"category":"minor","is_stale":true}],
 "coverage_gaps":[]}
EOF
out=$(run_dash 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c7: exit $rc: $out"; fail=1; }
# Both owner-qualified rows must appear as distinct table rows ("| <repo> |").
printf '%s' "$out" | grep -qF '| rossoctl/cortex |' \
  || { echo "FAIL c7: rossoctl/cortex row missing"; fail=1; }
printf '%s' "$out" | grep -qF '| alice/cortex |' \
  || { echo "FAIL c7: alice/cortex row missing"; fail=1; }
# And they must NOT collapse into a single bare "cortex" bucket: a row whose
# repo cell is exactly "cortex" (owner stripped) is the regression we guard.
printf '%s' "$out" | grep -qE '^\| cortex \|' \
  && { echo "FAIL c7: owners collapsed into a bare 'cortex' row"; fail=1; }
# Exactly two coverage rows carry the "cortex" name, one per owner.
cortex_rows=$(printf '%s' "$out" | grep -cE '^\| [a-z]+/cortex \|' || true)
[ "$cortex_rows" -eq 2 ] \
  || { echo "FAIL c7: expected 2 distinct cortex rows, got $cortex_rows"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
