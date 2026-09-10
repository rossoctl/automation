#!/usr/bin/env bash
set -euo pipefail

# Test harness for extract-broken-links.sh
# Run: bash automation/tests/test-extract-broken-links.sh
# Exit code 0 = all tests pass, 1 = at least one failure.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTRACTOR="$SCRIPT_DIR/../scripts/extract-broken-links.sh"
TEST_TMPDIR=$(mktemp -d "/tmp/test-extract-broken-XXXXXX")
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Arg 2 is now a full "owner/name" reference, emitted verbatim in .repo.
REPO="rossoctl/cortex"
REPOS_PREFIX="/home/claw/kagenti/cortex/"

PASS=0
FAIL=0

# --- Helper: write a lychee-shaped JSON fixture with a single error_map entry ---
# Args: <out-file> <filepath-key> <url> <status-json>
# status-json is the raw .status object, e.g. '{"text":"Network error"}' or '{"code":404}'.
write_fixture() {
  local out="$1" filepath="$2" url="$3" status="$4"
  jq -n \
    --arg fp "$filepath" \
    --arg url "$url" \
    --argjson status "$status" \
    '{ error_map: { ($fp): [ { url: $url, status: $status } ] } }' \
    > "$out"
}

# --- Helper: run extractor on a fixture, apply a jq check to the JSONL output ---
# Args: <name> <fixture-file> <jq-check> <expected>
# The extractor emits zero-or-more JSON objects (one per line); we slurp them.
run_test() {
  local name="$1" fixture="$2" jq_check="$3" expected="$4"

  local output actual
  output=$("$EXTRACTOR" "$fixture" "$REPO" "$REPOS_PREFIX")
  actual=$(printf '%s\n' "$output" | jq -s -r "$jq_check")

  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "    Expected: $expected"
    echo "    Got:      $actual"
    FAIL=$((FAIL + 1))
  fi
}

# =============================================================================
# Fix #1: bare .svc hostnames must be suppressed
# =============================================================================
echo "Test 1: bare .svc URL is suppressed"
write_fixture "$TEST_TMPDIR/svc.json" \
  "authbridge/demos/github-issue/demo-aiac.md" \
  "http://keycloak-service.keycloak.svc:8080/realms/" \
  '{"text":"Network error"}'
run_test "bare .svc suppressed (0 records)" "$TEST_TMPDIR/svc.json" 'length' '0'

# =============================================================================
# Regressions: previously-suppressed classes stay suppressed
# =============================================================================
echo "Test 2: .svc.cluster.local still suppressed"
write_fixture "$TEST_TMPDIR/clusterlocal.json" \
  "docs/a.md" \
  "http://svc.foo.svc.cluster.local:8080/x" \
  '{"text":"Network error"}'
run_test ".svc.cluster.local suppressed" "$TEST_TMPDIR/clusterlocal.json" 'length' '0'

echo "Test 3: .local still suppressed"
write_fixture "$TEST_TMPDIR/local.json" \
  "docs/b.md" \
  "http://my-box.local/status" \
  '{"text":"Network error"}'
run_test ".local suppressed" "$TEST_TMPDIR/local.json" 'length' '0'

echo "Test 4: RFC1918 ranges still suppressed"
write_fixture "$TEST_TMPDIR/rfc10.json" "docs/c.md" \
  "http://10.20.4.11:9090/api" '{"text":"Network error"}'
run_test "10.x suppressed" "$TEST_TMPDIR/rfc10.json" 'length' '0'

write_fixture "$TEST_TMPDIR/rfc172.json" "docs/c.md" \
  "http://172.16.0.5/api" '{"text":"Network error"}'
run_test "172.16-31.x suppressed" "$TEST_TMPDIR/rfc172.json" 'length' '0'

write_fixture "$TEST_TMPDIR/rfc192.json" "docs/c.md" \
  "http://192.168.1.1/api" '{"text":"Network error"}'
run_test "192.168.x suppressed" "$TEST_TMPDIR/rfc192.json" 'length' '0'

# =============================================================================
# Genuine broken links must still pass through with correct fields
# =============================================================================
echo "Test 5: genuine external broken link passes through"
write_fixture "$TEST_TMPDIR/ext.json" \
  "docs/d.md" \
  "https://example.invalid/gone" \
  '{"code":404}'
run_test "external record count" "$TEST_TMPDIR/ext.json" 'length' '1'
run_test "external status normalized" "$TEST_TMPDIR/ext.json" '.[0].status' '404'
run_test "external category" "$TEST_TMPDIR/ext.json" '.[0].category' 'external'
run_test "external repo emitted verbatim" "$TEST_TMPDIR/ext.json" '.[0].repo' 'rossoctl/cortex'
run_test "external file prefix stripped" "$TEST_TMPDIR/ext.json" '.[0].file' 'docs/d.md'
run_test "external url preserved" "$TEST_TMPDIR/ext.json" '.[0].url' 'https://example.invalid/gone'

# "internal" means "same owner as the repo being scanned" ($REPO owner is
# rossoctl), so it follows the enrolled owner rather than a hardcoded org list.
echo "Test 6: GitHub URL under the scanned repo's own owner is category internal"
write_fixture "$TEST_TMPDIR/int-rossoctl.json" \
  "docs/e.md" \
  "https://github.com/rossoctl/rossoctl/blob/main/missing.md" \
  '{"code":404}'
run_test "internal category (same owner)" "$TEST_TMPDIR/int-rossoctl.json" '.[0].category' 'internal'

echo "Test 6b: GitHub URL under a different owner is category external"
write_fixture "$TEST_TMPDIR/ext-otherowner.json" \
  "docs/e2.md" \
  "https://github.com/kagenti/kagenti/blob/main/missing.md" \
  '{"code":404}'
run_test "external category (different owner)" "$TEST_TMPDIR/ext-otherowner.json" '.[0].category' 'external'

echo "Test 7: text status normalized to unreachable"
write_fixture "$TEST_TMPDIR/unreach.json" \
  "docs/f.md" \
  "https://real-host.example.org/x" \
  '{"text":"Connection refused"}'
run_test "unreachable status token" "$TEST_TMPDIR/unreach.json" '.[0].status' 'unreachable'

# =============================================================================
# Status normalization: remaining text-status branches (timeout, dns, error)
# and the null-status catch-all (unknown).
# =============================================================================
echo "Test 7b: text status normalized to timeout"
write_fixture "$TEST_TMPDIR/timeout.json" \
  "docs/f.md" "https://real-host.example.org/t" '{"text":"Timeout"}'
run_test "timeout status token" "$TEST_TMPDIR/timeout.json" '.[0].status' 'timeout'

echo "Test 7c: text status normalized to dns"
write_fixture "$TEST_TMPDIR/dns.json" \
  "docs/f.md" "https://real-host.example.org/d" '{"text":"Failed to resolve host"}'
run_test "dns status token (resolve)" "$TEST_TMPDIR/dns.json" '.[0].status' 'dns'

write_fixture "$TEST_TMPDIR/dns2.json" \
  "docs/f.md" "https://real-host.example.org/d2" '{"text":"DNS error"}'
run_test "dns status token (dns)" "$TEST_TMPDIR/dns2.json" '.[0].status' 'dns'

echo "Test 7d: unrecognized text status falls back to error"
write_fixture "$TEST_TMPDIR/err.json" \
  "docs/f.md" "https://real-host.example.org/e" '{"text":"Something weird happened"}'
run_test "error catch-all token" "$TEST_TMPDIR/err.json" '.[0].status' 'error'

echo "Test 7e: null status normalized to unknown"
jq -n '{ error_map: { "docs/f.md": [ { url: "https://real-host.example.org/u", status: null } ] } }' \
  > "$TEST_TMPDIR/unknown.json"
run_test "unknown status token" "$TEST_TMPDIR/unknown.json" '.[0].status' 'unknown'

# =============================================================================
# Edge cases: empty / missing error_map yields no output; valid JSONL
# =============================================================================
echo "Test 8: missing error_map yields no output"
echo '{"total":5,"errors":0}' > "$TEST_TMPDIR/noerrors.json"
run_test "no error_map -> empty" "$TEST_TMPDIR/noerrors.json" 'length' '0'

echo "Test 9: empty error_map yields no output"
echo '{"error_map":{}}' > "$TEST_TMPDIR/emptymap.json"
run_test "empty error_map -> empty" "$TEST_TMPDIR/emptymap.json" 'length' '0'

echo "Test 10: non-URL error entries are skipped"
jq -n '{ error_map: { "docs/g.md": [ { url: "Error building URL", status: {text:"Invalid"} } ] } }' \
  > "$TEST_TMPDIR/nonurl.json"
run_test "non-URL entry skipped" "$TEST_TMPDIR/nonurl.json" 'length' '0'

# =============================================================================
# Stdin path: reading the report via "-" behaves like reading from a file
# =============================================================================
echo "Test 11: stdin (-) path works"
write_fixture "$TEST_TMPDIR/stdin.json" \
  "docs/h.md" \
  "https://example.invalid/stdin-gone" \
  '{"code":404}'
STDIN_URL=$(cat "$TEST_TMPDIR/stdin.json" | "$EXTRACTOR" - "$REPO" "$REPOS_PREFIX" | jq -s -r '.[0].url')
if [ "$STDIN_URL" = "https://example.invalid/stdin-gone" ]; then
  echo "  PASS: stdin path emits the broken link"
  PASS=$((PASS + 1))
else
  echo "  FAIL: stdin path emits the broken link"
  echo "    Expected: https://example.invalid/stdin-gone"
  echo "    Got:      $STDIN_URL"
  FAIL=$((FAIL + 1))
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
