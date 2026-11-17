#!/usr/bin/env bash
# Unchecked (egress refusal) must never open or auto-close issues.
# Drives the real link-health-scanner.sh with gh + lychee (and, for the
# crash-containment case, python3) stubbed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/../scripts/link-health-scanner.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

BIN="$TEST_TMPDIR/bin"; mkdir -p "$BIN"
CREATE_LOG="$TEST_TMPDIR/issue_create.txt"; : > "$CREATE_LOG"
CLOSE_LOG="$TEST_TMPDIR/issue_close.txt"; : > "$CLOSE_LOG"

cat > "$BIN/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"issue create"*) echo "CREATE \$*" >> "$CREATE_LOG"; echo "https://github.com/alice/a/issues/1"; exit 0 ;;
  *"issue close"*)  echo "CLOSE \$*" >> "$CLOSE_LOG"; exit 0 ;;
  *"issue list"*)   exit 0 ;;
  *"search"*)       exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"

# Stub emits one real 404 and one unchecked egress refusal.
cat > "$BIN/lychee" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{
  "total": 2,
  "successful": 0,
  "errors": 1,
  "unchecked": 1,
  "error_map": {
    "README.md": [
      {"url": "https://dead.example.net/x", "status": {"code": 404, "text": "404"}},
      {"url": "https://blocked.example.net/y", "status": {"text": "unchecked", "details": "Tunnel connection failed: 403 Forbidden"}}
    ]
  }
}
JSON
exit 0
STUB
chmod +x "$BIN/lychee"

export REPOMAN_CONFIG_FILE="$TEST_TMPDIR/config.json"
export REPOMAN_REPOS_FILE="$TEST_TMPDIR/repos.json"
REPOS_ROOT="$TEST_TMPDIR/repos"; mkdir -p "$REPOS_ROOT/alice/a/.git"
printf 'links\n' > "$REPOS_ROOT/alice/a/README.md"
printf '{"repos_dir":"%s","fork_owner":"tester"}\n' "$REPOS_ROOT" > "$REPOMAN_CONFIG_FILE"
printf '[{"owner":"alice","name":"a"}]\n' > "$REPOMAN_REPOS_FILE"
REPORTS="$TEST_TMPDIR/reports/link-health"; mkdir -p "$REPORTS"

# --- Case 1: unchecked never opens an issue; 404 does ---
# Pinned to LINK_CHECKER=lychee: this case exercises the checker-agnostic
# split/re-injection logic via the lychee stub (the default is python).
REPORTS_DIR="$REPORTS" LINK_CHECKER=lychee PATH="$BIN:$PATH" bash "$SCANNER" >/dev/null 2>&1

created=$(grep -c "CREATE" "$CREATE_LOG" 2>/dev/null || true)
created=${created:-0}
if [ "$created" = "1" ]; then
  echo "PASS: case1 filed exactly one issue (the 404)"
else
  echo "FAIL: case1 filed $created issues (expected 1)"; fail=1
fi

if ! grep -q "dead.example.net/x" "$CREATE_LOG"; then
  echo "FAIL: case1 create log missing the 404 URL"; fail=1
else
  echo "PASS: case1 create targets the 404 URL"
fi

if grep -q "blocked.example.net" "$CREATE_LOG"; then
  echo "FAIL: case1 opened an issue for an unchecked URL"; fail=1
else
  echo "PASS: case1 did not open an issue for unchecked URL"
fi

uc=$(jq '.unchecked_count // -1' "$REPORTS/latest.json" 2>/dev/null || echo -1)
if [ "$uc" = "1" ]; then
  echo "PASS: case1 unchecked_count == 1"
else
  echo "FAIL: case1 unchecked_count=$uc (expected 1)"; fail=1
fi

broken_has_unchecked=$(jq '[.broken[] | select(.url | test("blocked.example.net"))] | length' \
  "$REPORTS/latest.json" 2>/dev/null || echo 1)
if [ "$broken_has_unchecked" = "0" ]; then
  echo "PASS: case1 unchecked URL absent from broken[]"
else
  echo "FAIL: case1 unchecked URL leaked into broken[]"; fail=1
fi

# --- Case 2: previously broken + now unchecked must not auto-close ---
: > "$CREATE_LOG"
: > "$CLOSE_LOG"
# Seed baseline with the URL that the stub will report as unchecked this run.
cat > "$REPORTS/latest.json" <<'JSON'
{
  "scan_id": "seed",
  "date": "2026-01-01T00:00:00Z",
  "repos_scanned": 1,
  "repos_failed": 0,
  "total_links_checked": 1,
  "broken": [
    {
      "repo": "alice/a",
      "file": "README.md",
      "url": "https://blocked.example.net/y",
      "status": "404",
      "category": "external",
      "issue_number": 9,
      "first_detected": "2026-01-01",
      "context": ""
    }
  ],
  "delta": {"new": 1, "fixed": 0, "recurring": 0}
}
JSON

# Stub now only reports the previously-broken URL as unchecked (no other errors).
cat > "$BIN/lychee" <<'STUB'
#!/usr/bin/env bash
cat <<'JSON'
{
  "total": 1,
  "successful": 0,
  "errors": 0,
  "unchecked": 1,
  "error_map": {
    "README.md": [
      {"url": "https://blocked.example.net/y", "status": {"text": "unchecked", "details": "Tunnel connection failed: 403 Forbidden"}}
    ]
  }
}
JSON
exit 0
STUB
chmod +x "$BIN/lychee"

# Make gh_issue_exists return the seeded issue number so a close would fire
# if the scanner incorrectly treated unchecked as fixed.
cat > "$BIN/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"issue create"*) echo "CREATE \$*" >> "$CREATE_LOG"; echo "https://github.com/alice/a/issues/2"; exit 0 ;;
  *"issue close"*)  echo "CLOSE \$*" >> "$CLOSE_LOG"; exit 0 ;;
  *"issue list"*)   echo '[{"number":9}]'; exit 0 ;;
  *"search"*)       exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"

REPORTS_DIR="$REPORTS" LINK_CHECKER=lychee PATH="$BIN:$PATH" bash "$SCANNER" >/dev/null 2>&1

closed=$(grep -c "CLOSE" "$CLOSE_LOG" 2>/dev/null || true)
closed=${closed:-0}
if [ "$closed" = "0" ]; then
  echo "PASS: case2 did not auto-close on unchecked"
else
  echo "FAIL: case2 closed $closed issues (expected 0)"; fail=1
fi

created2=$(grep -c "CREATE" "$CREATE_LOG" 2>/dev/null || true)
created2=${created2:-0}
if [ "$created2" = "0" ]; then
  echo "PASS: case2 did not open a new issue for unchecked"
else
  echo "FAIL: case2 created $created2 issues (expected 0)"; fail=1
fi

# Carry-forward keeps the prior broken record in broken[] so it stays recurring.
still_broken=$(jq '[.broken[] | select(.url == "https://blocked.example.net/y")] | length' \
  "$REPORTS/latest.json" 2>/dev/null || echo 0)
if [ "$still_broken" = "1" ]; then
  echo "PASS: case2 carried prior broken record forward"
else
  echo "FAIL: case2 lost the prior broken record (still_broken=$still_broken)"; fail=1
fi

# --- Case 3: a crashing python checker must fail the repo, not the run ---
: > "$CREATE_LOG"
: > "$CLOSE_LOG"
rm -f "$REPORTS/latest.json"

# Emulates link-check.py dying mid-write: truncated JSON on stdout, exit 0.
# Before the JSON-validity guard this killed the whole scanner via set -e
# on the jq reads; it must instead count the repo as failed and continue.
cat > "$BIN/python3" <<'STUB'
#!/usr/bin/env bash
printf '{"total": '
exit 0
STUB
chmod +x "$BIN/python3"

REPORTS_DIR="$REPORTS" LINK_CHECKER=python PATH="$BIN:$PATH" bash "$SCANNER" >/dev/null 2>&1

rf=$(jq '.repos_failed // -1' "$REPORTS/latest.json" 2>/dev/null || echo -1)
if [ "$rf" = "1" ]; then
  echo "PASS: case3 truncated checker JSON fails the repo, not the run"
else
  echo "FAIL: case3 repos_failed=$rf (expected 1)"; fail=1
fi

rs=$(jq '.repos_scanned // -1' "$REPORTS/latest.json" 2>/dev/null || echo -1)
if [ "$rs" = "0" ]; then
  echo "PASS: case3 truncated-JSON repo not counted as scanned"
else
  echo "FAIL: case3 repos_scanned=$rs (expected 0)"; fail=1
fi

# A non-zero python checker exit is fatal for the repo even with valid JSON
# (link-check.py exits 0 unless it crashed).
cat > "$BIN/python3" <<'STUB'
#!/usr/bin/env bash
printf '{"total": 0, "errors": 0, "unchecked": 0, "error_map": {}}\n'
exit 3
STUB
chmod +x "$BIN/python3"
rm -f "$REPORTS/latest.json"

REPORTS_DIR="$REPORTS" LINK_CHECKER=python PATH="$BIN:$PATH" bash "$SCANNER" >/dev/null 2>&1

rf=$(jq '.repos_failed // -1' "$REPORTS/latest.json" 2>/dev/null || echo -1)
if [ "$rf" = "1" ]; then
  echo "PASS: case3 non-zero checker exit fails the repo"
else
  echo "FAIL: case3 repos_failed=$rf (expected 1)"; fail=1
fi

rm -f "$BIN/python3"

# --- Case 3b: a failed repo must not auto-close its prior issues ---
# A checker crash drops the repo's findings entirely; without carry-forward
# every previously broken link in it diffs as "fixed" and its issue closes
# while repos_failed merely ticks up (violates standing orders: no closing
# without evidence the link was fixed).
: > "$CREATE_LOG"
: > "$CLOSE_LOG"

cat > "$REPORTS/latest.json" <<'JSON'
{
  "scan_id": "seed",
  "date": "2026-01-01T00:00:00Z",
  "repos_scanned": 1,
  "repos_failed": 0,
  "total_links_checked": 1,
  "broken": [
    {
      "repo": "alice/a",
      "file": "README.md",
      "url": "https://dead.example.net/x",
      "status": "404",
      "category": "external",
      "issue_number": 9,
      "first_detected": "2026-01-01",
      "context": ""
    }
  ],
  "delta": {"new": 1, "fixed": 0, "recurring": 0}
}
JSON

# gh reports the seeded issue as open, so a close would fire if the scanner
# incorrectly treated the failed repo's links as fixed.
cat > "$BIN/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"issue create"*) echo "CREATE \$*" >> "$CREATE_LOG"; echo "https://github.com/alice/a/issues/4"; exit 0 ;;
  *"issue close"*)  echo "CLOSE \$*" >> "$CLOSE_LOG"; exit 0 ;;
  *"issue list"*)   echo '[{"number":9}]'; exit 0 ;;
  *"search"*)       exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"

cat > "$BIN/python3" <<'STUB'
#!/usr/bin/env bash
printf '{"total": '
exit 0
STUB
chmod +x "$BIN/python3"

REPORTS_DIR="$REPORTS" LINK_CHECKER=python PATH="$BIN:$PATH" bash "$SCANNER" >/dev/null 2>&1

closed3b=$(grep -c "CLOSE" "$CLOSE_LOG" 2>/dev/null || true)
closed3b=${closed3b:-0}
if [ "$closed3b" = "0" ]; then
  echo "PASS: case3b failed repo did not auto-close its prior issue"
else
  echo "FAIL: case3b closed $closed3b issues (expected 0)"; fail=1
fi

carried3b=$(jq '[.broken[] | select(.url == "https://dead.example.net/x")] | length' \
  "$REPORTS/latest.json" 2>/dev/null || echo 0)
if [ "$carried3b" = "1" ]; then
  echo "PASS: case3b failed repo's prior finding carried forward"
else
  echo "FAIL: case3b prior finding lost (carried=$carried3b)"; fail=1
fi

rf3b=$(jq '.repos_failed // -1' "$REPORTS/latest.json" 2>/dev/null || echo -1)
if [ "$rf3b" = "1" ]; then
  echo "PASS: case3b repo counted as failed"
else
  echo "FAIL: case3b repos_failed=$rf3b (expected 1)"; fail=1
fi

fixed3b=$(jq '.delta.fixed // -1' "$REPORTS/latest.json" 2>/dev/null || echo -1)
if [ "$fixed3b" = "0" ]; then
  echo "PASS: case3b nothing counted as fixed"
else
  echo "FAIL: case3b delta.fixed=$fixed3b (expected 0)"; fail=1
fi

rm -f "$BIN/python3"

# --- Case 4: the default checker is python (real link-check.py, no stub) ---
: > "$CREATE_LOG"
: > "$CLOSE_LOG"
rm -f "$REPORTS/latest.json" "$REPORTS/history.json"

# A malformed URL: a deterministic error that needs no network, so the case
# cannot flap with proxy/DNS conditions (an unresolvable host behind an
# egress proxy surfaces as an accepted 502, for example).
printf 'Docs: see http://[::1 for internals.\n' > "$REPOS_ROOT/alice/a/README.md"

# No pre-existing issues (the case-2 stub reports issue 9 for every search).
cat > "$BIN/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"issue create"*) echo "CREATE \$*" >> "$CREATE_LOG"; echo "https://github.com/alice/a/issues/3"; exit 0 ;;
  *"issue close"*)  echo "CLOSE \$*" >> "$CLOSE_LOG"; exit 0 ;;
  *"issue list"*)   exit 0 ;;
  *"search"*)       exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/gh"

# No LINK_CHECKER in the environment: the scanner must default to python.
REPORTS_DIR="$REPORTS" PATH="$BIN:$PATH" env -u LINK_CHECKER bash "$SCANNER" >/dev/null 2>&1

rf=$(jq '.repos_failed // -1' "$REPORTS/latest.json" 2>/dev/null || echo -1)
if [ "$rf" = "0" ]; then
  echo "PASS: case4 default python checker scanned the repo cleanly"
else
  echo "FAIL: case4 repos_failed=$rf (expected 0)"; fail=1
fi

rs=$(jq '.repos_scanned // -1' "$REPORTS/latest.json" 2>/dev/null || echo -1)
if [ "$rs" = "1" ]; then
  echo "PASS: case4 repo counted as scanned"
else
  echo "FAIL: case4 repos_scanned=$rs (expected 1)"; fail=1
fi

malformed=$(jq --arg u "http://[::1" '[.broken[] | select(.url == $u)] | length' \
  "$REPORTS/latest.json" 2>/dev/null || echo 0)
if [ "$malformed" = "1" ]; then
  echo "PASS: case4 malformed URL reported as broken"
else
  echo "FAIL: case4 malformed URL missing from broken[]"; fail=1
fi

if grep -Fq "http://[::1" "$CREATE_LOG"; then
  echo "PASS: case4 issue filed for the malformed URL"
else
  echo "FAIL: case4 create log missing the malformed URL"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
