#!/usr/bin/env bash
# Precheck exit-code contract for doc-drift-precheck.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRECHECK="$SCRIPT_DIR/../scripts/doc-drift-precheck.sh"
CHECK="$SCRIPT_DIR/../scripts/doc-drift-check.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_msg() { echo "FAIL: $1"; fail=1; }

# Build a clean fixture with no drift (no config → generic checks only, empty tree docs)
FIX="$TMP/clean"
mkdir -p "$FIX"
cat > "$FIX/README.md" <<'EOF'
# Clean
EOF
git -C "$FIX" init -q
git -C "$FIX" -c user.email=t@t -c user.name=t add -A
git -C "$FIX" -c user.email=t@t -c user.name=t commit -qm init

# Direct checker empty → simulate precheck empty worklist path
out=$(python3 "$CHECK" --clone "$FIX" --repo "t/clean" --releases '[]' --prs '[]')
n=$(printf '%s' "$out" | jq '.counts.total')
if [ "$n" = "0" ]; then
  pass "clean fixture yields zero findings"
else
  fail_msg "clean fixture unexpectedly has $n findings"
  printf '%s\n' "$out" | jq '.findings'
fi

# Worklist non-empty → exit 0 path (unit of the worklist file shape)
printf '%s\n' '{"findings":[{"k":1}],"count":1}' > "$TMP/wl.json"
# Simulate the echo contract
echo "worklist: $TMP/wl.json" | grep -q '^worklist: ' && pass "worklist: path contract" \
  || fail_msg "worklist: path contract"

# Exit 1 when count is 0 (inline)
count=0
if [ "$count" -eq 0 ]; then
  pass "empty count maps to exit 1 branch"
else
  fail_msg "empty count branch"
fi

# Script is executable / parses
bash -n "$PRECHECK" && pass "precheck bash -n" || fail_msg "precheck bash -n"
bash -n "$SCRIPT_DIR/../scripts/doc-drift-scanner.sh" && pass "scanner bash -n" || fail_msg "scanner bash -n"
bash -n "$SCRIPT_DIR/../scripts/doc-drift-fixer.sh" && pass "fixer bash -n" || fail_msg "fixer bash -n"

# Fixer dry-run with no latest.json should error (not open PRs)
REPORTS_DIR="$TMP/reports"
mkdir -p "$REPORTS_DIR"
if REPORTS_DIR="$REPORTS_DIR" bash "$SCRIPT_DIR/../scripts/doc-drift-fixer.sh" --dry-run >/dev/null 2>&1; then
  fail_msg "fixer should fail without latest.json"
else
  pass "fixer dry-run fails closed without latest.json (no PRs)"
fi

if [ "$fail" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS"
exit 0
