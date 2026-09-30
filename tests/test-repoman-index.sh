#!/usr/bin/env bash
# Tests for scripts/repoman-index.sh (the _index.json writer).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IDX="$SCRIPT_DIR/../scripts/repoman-index.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0
run_idx() { bash "$IDX" "$@"; }

# Case 1: fresh index (file absent) -> entry created, valid JSON, one program,
# last_run present and ISO-8601 Z form.
INDEX="$TEST_TMPDIR/_index.json"
out=$(run_idx --index "$INDEX" --program link-health \
      --display-name "Link Health" --report-path "/r/link-health" 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c1: exit $rc: $out"; fail=1; }
[ -f "$INDEX" ] || { echo "FAIL c1: index not created"; fail=1; }
jq -e . "$INDEX" >/dev/null 2>&1 || { echo "FAIL c1: invalid JSON"; fail=1; }
[ "$(jq -r '.["link-health"].display_name' "$INDEX")" = "Link Health" ] \
  || { echo "FAIL c1: display_name"; fail=1; }
[ "$(jq -r '.["link-health"].report_path' "$INDEX")" = "/r/link-health" ] \
  || { echo "FAIL c1: report_path"; fail=1; }
[ "$(jq 'keys | length' "$INDEX")" = "1" ] || { echo "FAIL c1: not exactly one program"; fail=1; }
lr=$(jq -r '.["link-health"].last_run' "$INDEX")
printf '%s' "$lr" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  || { echo "FAIL c1: last_run not ISO-8601 Z: $lr"; fail=1; }

# Case 2: upsert a different program into an existing index -> both present,
# pre-existing entry preserved byte-for-byte.
before=$(jq -c '.["link-health"]' "$INDEX")
run_idx --index "$INDEX" --program dep-bump \
        --display-name "Dependency Bumps" --report-path "/r/dep-bump" >/dev/null 2>&1
[ "$(jq 'keys | length' "$INDEX")" = "2" ] || { echo "FAIL c2: not two programs"; fail=1; }
after=$(jq -c '.["link-health"]' "$INDEX")
[ "$before" = "$after" ] || { echo "FAIL c2: link-health entry mutated"; fail=1; }

# Case 3: upsert same id twice -> single entry, second report_path wins,
# last_run refreshed (not identical if we force a difference; here assert path).
run_idx --index "$INDEX" --program dep-bump \
        --display-name "Dependency Bumps" --report-path "/r/dep-bump-2" >/dev/null 2>&1
[ "$(jq -r '.["dep-bump"].report_path' "$INDEX")" = "/r/dep-bump-2" ] \
  || { echo "FAIL c3: second report_path did not win"; fail=1; }
[ "$(jq '.["dep-bump"] | length' "$INDEX")" = "3" ] \
  || { echo "FAIL c3: entry has extra/missing fields"; fail=1; }

# Case 4: invalid-JSON index -> fail loud, names file, original unchanged.
BAD="$TEST_TMPDIR/bad.json"; printf '{not json' > "$BAD"; orig=$(cat "$BAD")
out=$(run_idx --index "$BAD" --program x --display-name X --report-path /r/x 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL c4: expected non-zero"; fail=1; }
printf '%s' "$out" | grep -q "$BAD" || { echo "FAIL c4: error did not name file"; fail=1; }
[ "$(cat "$BAD")" = "$orig" ] || { echo "FAIL c4: bad index was modified"; fail=1; }

# Case 5: missing required flag -> fail loud, usage to stderr.
out=$(run_idx --index "$TEST_TMPDIR/i2.json" --program x --display-name X 2>&1); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL c5: expected non-zero"; fail=1; }
printf '%s' "$out" | grep -q "report-path is required" || { echo "FAIL c5: no usage/req msg"; fail=1; }

# Case 6: --dry-run -> prints resulting index, writes nothing.
DRYIDX="$TEST_TMPDIR/dry.json"
out=$(run_idx --index "$DRYIDX" --program p --display-name P --report-path /r/p --dry-run 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c6: exit $rc"; fail=1; }
[ ! -e "$DRYIDX" ] || { echo "FAIL c6: file was created on dry-run"; fail=1; }
printf '%s' "$out" | jq -e '.p.display_name == "P"' >/dev/null 2>&1 \
  || { echo "FAIL c6: dry-run output wrong"; fail=1; }

# Case 7: --help -> usage, exit 0.
out=$(run_idx --help 2>&1); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL c7: help exit $rc"; fail=1; }
printf '%s' "$out" | grep -q "Usage: repoman-index.sh" || { echo "FAIL c7: no usage"; fail=1; }

# Case 8: display-name with shell/JSON metacharacters round-trips (jq escaping).
META='He said "$x" & <b> | done'
MIDX="$TEST_TMPDIR/meta.json"
run_idx --index "$MIDX" --program m --display-name "$META" --report-path /r/m >/dev/null 2>&1
[ "$(jq -r '.m.display_name' "$MIDX")" = "$META" ] \
  || { echo "FAIL c8: metacharacter round-trip failed"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
