#!/usr/bin/env bash
# Precheck exit-code / stdout contract for doc-drift-precheck.sh.
# Exercises the real script against a fixture (gh stubbed; checker is live).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRECHECK="$SCRIPT_DIR/../scripts/doc-drift-precheck.sh"
CHECK="$SCRIPT_DIR/../scripts/doc-drift-check.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_msg() { echo "FAIL: $1"; fail=1; }

# ---------------------------------------------------------------------------
# Shared stubs: fake ~/.repoman state + gh that returns empty releases/PRs
# ---------------------------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
# Minimal stub: release/PR fetches fail → precheck falls back to [].
exit 1
EOF
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

HOME_FAKE="$TMP/home"
mkdir -p "$HOME_FAKE"
export HOME="$HOME_FAKE"

REPOS_DIR="$TMP/repos"
mkdir -p "$REPOS_DIR"
cat > "$TMP/config.json" <<EOF
{"repos_dir":"$REPOS_DIR","fork_owner":"testfork"}
EOF
cat > "$TMP/repos.json" <<'EOF'
[{"owner":"fixture","name":"clean"}]
EOF
export REPOMAN_CONFIG_FILE="$TMP/config.json"
export REPOMAN_REPOS_FILE="$TMP/repos.json"

# ---------------------------------------------------------------------------
# Clean clone → exit 1, no worklist line
# ---------------------------------------------------------------------------
CLEAN="$REPOS_DIR/fixture/clean"
mkdir -p "$CLEAN"
cat > "$CLEAN/README.md" <<'EOF'
# Clean
EOF
git -C "$CLEAN" init -q
git -C "$CLEAN" -c user.email=t@t -c user.name=t add -A
git -C "$CLEAN" -c user.email=t@t -c user.name=t commit -qm init

WL_CLEAN="$TMP/wl-clean.json"
set +e
out_clean=$(bash "$PRECHECK" --worklist "$WL_CLEAN" 2>/dev/null)
rc_clean=$?
set -e
if [ "$rc_clean" -eq 1 ]; then
  pass "precheck exit 1 on empty worklist"
else
  fail_msg "precheck expected exit 1 on clean fixture, got $rc_clean"
fi
case "$out_clean" in
  *"worklist:"*) fail_msg "precheck must not print worklist: on empty" ;;
  *) pass "precheck silent on empty worklist" ;;
esac

# Direct checker sanity (same clean tree)
out=$(python3 "$CHECK" --clone "$CLEAN" --repo "fixture/clean" --releases '[]' --prs '[]')
n=$(printf '%s' "$out" | jq '.counts.total')
if [ "$n" = "0" ]; then
  pass "clean fixture yields zero findings"
else
  fail_msg "clean fixture unexpectedly has $n findings"
fi

# ---------------------------------------------------------------------------
# Drift clone → exit 0 + worklist: <path>
# ---------------------------------------------------------------------------
cat > "$TMP/repos.json" <<'EOF'
[{"owner":"fixture","name":"drift"}]
EOF
DRIFT="$REPOS_DIR/fixture/drift"
mkdir -p "$DRIFT/.repoman" "$DRIFT/scripts"
cat > "$DRIFT/README.md" <<'EOF'
# Drift fixture with Kagenti branding leftover
EOF
cat > "$DRIFT/scripts/note.sh" <<'EOF'
#!/usr/bin/env bash
# Automated by Kagenti helper
echo ok
EOF
cat > "$DRIFT/.repoman/doc-drift.yaml" <<'EOF'
boundary: main
retired_names:
  - { name: kagenti, replace_with: "" }
ignore_paths: [CHANGELOG.md]
EOF
git -C "$DRIFT" init -q
git -C "$DRIFT" -c user.email=t@t -c user.name=t add -A
git -C "$DRIFT" -c user.email=t@t -c user.name=t commit -qm drift

WL_DRIFT="$TMP/wl-drift.json"
set +e
out_drift=$(bash "$PRECHECK" --worklist "$WL_DRIFT" 2>/dev/null)
rc_drift=$?
set -e
if [ "$rc_drift" -eq 0 ]; then
  pass "precheck exit 0 when findings exist"
else
  fail_msg "precheck expected exit 0 on drift fixture, got $rc_drift (out=$out_drift)"
fi
case "$out_drift" in
  "worklist: $WL_DRIFT") pass "precheck prints worklist: path" ;;
  *) fail_msg "precheck worklist line wrong: [$out_drift]" ;;
esac
if [ -f "$WL_DRIFT" ] && jq -e '.count > 0' "$WL_DRIFT" >/dev/null 2>&1; then
  pass "worklist file has count > 0"
else
  fail_msg "worklist file missing or empty"
fi

# ---------------------------------------------------------------------------
# Syntax + fixer fail-closed
# ---------------------------------------------------------------------------
bash -n "$PRECHECK" && pass "precheck bash -n" || fail_msg "precheck bash -n"
bash -n "$SCRIPT_DIR/../scripts/doc-drift-scanner.sh" && pass "scanner bash -n" || fail_msg "scanner bash -n"
bash -n "$SCRIPT_DIR/../scripts/doc-drift-fixer.sh" && pass "fixer bash -n" || fail_msg "fixer bash -n"

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
