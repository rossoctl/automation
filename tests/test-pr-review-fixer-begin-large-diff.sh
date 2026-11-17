#!/usr/bin/env bash
# Regression test: `pr-review-fixer.sh begin --live` must survive a PR whose
# parsed diff_map is larger than one argv string.
#
# Linux caps a SINGLE argument at MAX_ARG_STRLEN (128 KiB), independently of the
# much larger total ARG_MAX (~2 MB). The fixer used to hand the parsed diff_map
# to jq via `--argjson diff_map "$DIFF_MAP"`, and then hand the whole enriched
# entry to jq again via `--argjson entry "$enriched"`. Once a PR's diff_map
# crossed 128 KiB both calls died with E2BIG ("Argument list too long") — after
# the PR was marked in_progress in the temp state, but before
# pr_review_state_write, so nothing was persisted and the scanner re-queued the
# PR on every run. Seen on rossoctl/repoman#12 (2026-10-29) and
# rossoctl/moca#701 (2026-11-10).
#
# Drives the REAL fixer with gh stubbed to return a large fixture diff. The
# prefix of this test fails on the unfixed script with E2BIG and passes once
# diff_map travels through a file (--slurpfile) instead of argv.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXER="$SCRIPT_DIR/../scripts/pr-review-fixer.sh"
PARSER="$SCRIPT_DIR/../scripts/parse-diff-map.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

# --- Fixture diff: comfortably past MAX_ARG_STRLEN once parsed --------------
# 5000 added lines of ~58 bytes parse to roughly 700 KB of JSON, well over the
# 256 KiB floor asserted below.
DIFF="$TEST_TMPDIR/large.diff"
{
  echo "diff --git a/big.txt b/big.txt"
  echo "index 0000000..1111111 100644"
  echo "--- a/big.txt"
  echo "+++ b/big.txt"
  echo "@@ -0,0 +1,5000 @@"
  i=1
  while [ "$i" -le 5000 ]; do
    printf '+added line %d: the quick brown fox jumps over the lazy dog\n' "$i"
    i=$((i + 1))
  done
} > "$DIFF"

PARSED="$TEST_TMPDIR/expected-diff-map.json"
bash "$PARSER" "$DIFF" > "$PARSED"
map_bytes=$(wc -c < "$PARSED" | tr -d ' ')
if [ "$map_bytes" -gt 262144 ]; then
  echo "PASS: fixture diff_map is $map_bytes bytes (> 256 KiB)"
else
  echo "FAIL: fixture diff_map is only $map_bytes bytes; it must exceed 256 KiB to"
  echo "      cross MAX_ARG_STRLEN and reproduce the bug"; fail=1
fi

# --- gh stub: only `pr diff` matters; everything else is empty-success -----
BIN="$TEST_TMPDIR/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"pr diff"*) cat "$DIFF"; exit 0 ;;
  *) echo "[]"; exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"

REPORTS="$TEST_TMPDIR/reports"; mkdir -p "$REPORTS"
cat > "$REPORTS/latest.json" <<'JSON'
{"scan_id":"test-1","date":"2026-11-10T00:00:00Z","repos_scanned":1,
 "candidates_found":1,
 "eligible_prs":[{"repo":"alice/a","number":42,"head_sha":"aaaabbbbccccdddd"}]}
JSON

QUEUE="$TEST_TMPDIR/queue.json"
ERRLOG="$TEST_TMPDIR/stderr.txt"
PATH="$BIN:$PATH" bash "$FIXER" begin --live --reports-dir "$REPORTS" \
  > "$QUEUE" 2> "$ERRLOG"
rc=$?

if [ "$rc" -eq 0 ]; then
  echo "PASS: begin --live exited 0 on a $map_bytes-byte diff_map"
else
  echo "FAIL: begin --live exited $rc on a $map_bytes-byte diff_map"
  tail -3 "$ERRLOG" | sed 's/^/      /'
  fail=1
fi

if jq -e 'type == "array" and length == 1' "$QUEUE" >/dev/null 2>&1; then
  echo "PASS: stdout is a one-entry JSON queue"
else
  echo "FAIL: stdout is not a one-entry JSON queue"; fail=1
fi

# diff_map must arrive intact (same JSON, key order irrelevant).
if [ "$(jq -S -c '.[0].diff_map' "$QUEUE" 2>/dev/null)" = "$(jq -S -c '.' "$PARSED")" ]; then
  echo "PASS: queued diff_map is identical to the parser output"
else
  echo "FAIL: queued diff_map does not match the parser output"; fail=1
fi

# State must be persisted (the crash used to land before pr_review_state_write).
ip=$(jq -r '[.program_data.in_progress[]?
             | select(.repo=="alice/a" and .number==42
                      and .head_sha=="aaaabbbbccccdddd")] | length' \
  "$REPORTS/state.json" 2>/dev/null)
if [ "$ip" = "1" ]; then
  echo "PASS: state.json records alice/a#42 in_progress at the right head_sha"
else
  echo "FAIL: state.json missing the in_progress entry (count=${ip:-none});"
  echo "      a crash before pr_review_state_write leaves the PR re-queueing"; fail=1
fi

# No argv-sized JSON handoff may come back: diff_map (or an entry carrying it)
# must travel through a file, never --argjson.
if grep -Eq -- '--argjson[[:space:]]+(diff_map|entry)' "$FIXER"; then
  echo "FAIL: pr-review-fixer.sh still passes diff_map/entry to jq via --argjson:"
  grep -nE -- '--argjson[[:space:]]+(diff_map|entry)' "$FIXER" | sed 's/^/      /'
  fail=1
else
  echo "PASS: no --argjson handoff of diff_map or the enriched entry"
fi

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
