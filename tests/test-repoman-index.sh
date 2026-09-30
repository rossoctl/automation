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

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
