#!/usr/bin/env bash
# End-to-end test for the REAL doc-drift-scanner.sh (rossoctl/automation#128).
#
# Drives scripts/doc-drift-scanner.sh with gh stubbed and the live checker
# (doc-drift-check.py) against on-disk git fixtures. A gh stub logs every
# invocation to a call-log file so each case can assert that issue
# create/edit/close happened — or did not. Each case rebuilds fresh fixtures
# and a fresh gh stub so cases do not bleed into one another.
#
# bash 3.2-safe: no mapfile, no associative arrays, no ${x,,}/${x^^}.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$SCRIPT_DIR/../scripts/doc-drift-scanner.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0
pass() { echo "PASS: $1"; }
fail_msg() { echo "FAIL: $1"; fail=1; }

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------
# A clone with retired-name drift: README + a script mention "Kagenti", and a
# .repoman/doc-drift.yaml that retires the name. The live checker emits
# retired_names corrections for it.
make_drift_clone() {
  local dir="$1"
  mkdir -p "$dir/.repoman" "$dir/scripts"
  cat > "$dir/README.md" <<'EOF'
# Drift fixture with Kagenti branding leftover
EOF
  cat > "$dir/scripts/note.sh" <<'EOF'
#!/usr/bin/env bash
# Automated by Kagenti helper
echo ok
EOF
  cat > "$dir/.repoman/doc-drift.yaml" <<'EOF'
boundary: main
retired_names:
  - { name: kagenti, replace_with: "" }
ignore_paths: [CHANGELOG.md]
EOF
  git -C "$dir" init -q
  git -C "$dir" -c user.email=t@t -c user.name=t add -A
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm drift
}

# A clean clone: no drift config, plain README -> zero findings.
make_clean_clone() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/README.md" <<'EOF'
# Clean
EOF
  git -C "$dir" init -q
  git -C "$dir" -c user.email=t@t -c user.name=t add -A
  git -C "$dir" -c user.email=t@t -c user.name=t commit -qm init
}

# Write the shared repoman config/enrollment for one owner/name.
write_env() {
  local root="$1" owner="$2" name="$3"
  printf '{"repos_dir":"%s","fork_owner":"tester"}\n' "$root" > "$CONFIG_FILE"
  printf '[{"owner":"%s","name":"%s"}]\n' "$owner" "$name" > "$REPOS_FILE"
}

# A gh stub. $1 = call log. $2 = existing issue number for gh_issue_exists
# ("" => none). $3 = repo whose `gh pr list` emits invalid JSON (checker
# failure) or "" for none. All read subcommands return the shapes the scanner
# consumes; write subcommands succeed and log.
write_gh_stub() {
  local bin="$1" log="$2" existing="$3" failrepo="$4"
  mkdir -p "$bin"
  cat > "$bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\$*" in
  *"release list"*)
    # Success with no tags: skips release view, lets pr list run.
    echo "[]"; exit 0 ;;
  *"release view"*)
    echo "{}"; exit 0 ;;
  *"pr list"*)
    if [ -n "$failrepo" ] && printf '%s' "\$*" | grep -q "$failrepo"; then
      # Invalid JSON -> python checker json.load raises -> rc!=0.
      echo "}{ not json"; exit 0
    fi
    echo "[]"; exit 0 ;;
  *"issue list"*)
    # gh_issue_exists: gh applies --jq, so print the resolved value.
    printf '%s' "$existing"; exit 0 ;;
  *"issue create"*)
    # scanner uses --jq '.number' -> gh prints the number.
    echo "4242"; exit 0 ;;
  *"issue edit"*)   exit 0 ;;
  *"issue close"*)  exit 0 ;;
  *"issue comment"*) exit 0 ;;
  *"label create"*) exit 0 ;;
  *"api"*)          exit 1 ;;
  *)                echo "[]"; exit 0 ;;
esac
STUB
  chmod +x "$bin/gh"
}

export REPOMAN_CONFIG_FILE=""
CONFIG_FILE="$TEST_TMPDIR/config.json"
REPOS_FILE="$TEST_TMPDIR/repos.json"
export REPOMAN_CONFIG_FILE="$CONFIG_FILE"
export REPOMAN_REPOS_FILE="$REPOS_FILE"

# ===========================================================================
# Case 1: findings, no prior issue -> gh issue create called; latest.json
# written with corrections/additions.
# ===========================================================================
C1="$TEST_TMPDIR/c1"; mkdir -p "$C1"
C1_ROOT="$C1/repos"; C1_LOG="$C1/gh.log"; : > "$C1_LOG"
make_drift_clone "$C1_ROOT/acme/widget"
write_env "$C1_ROOT" "acme" "widget"
write_gh_stub "$C1/bin" "$C1_LOG" "" ""
C1_REPORTS="$C1/reports"; mkdir -p "$C1_REPORTS"
REPORTS_DIR="$C1_REPORTS" PATH="$C1/bin:$PATH" bash "$SCANNER" >/dev/null 2>&1
rc1=$?

if [ "$rc1" -eq 0 ]; then
  pass "case1: scanner exits 0"
else
  fail_msg "case1: scanner exit $rc1"
fi
if grep -q "issue create" "$C1_LOG" && grep -q "\[doc-drift\] acme/widget" "$C1_LOG"; then
  pass "case1: gh issue create with title [doc-drift] acme/widget"
else
  fail_msg "case1: no issue create with expected title"; cat "$C1_LOG"
fi
if grep -q "issue edit" "$C1_LOG"; then
  fail_msg "case1: unexpected issue edit (no prior issue existed)"
else
  pass "case1: no issue edit (create path, not update)"
fi
if [ -f "$C1_REPORTS/latest.json" ]; then
  c1corr=$(jq -r '.corrections' "$C1_REPORTS/latest.json" 2>/dev/null)
  c1finds=$(jq -r '.findings | length' "$C1_REPORTS/latest.json" 2>/dev/null)
  if [ "${c1corr:-0}" -ge 1 ] && [ "${c1finds:-0}" -ge 1 ]; then
    pass "case1: latest.json written with corrections ($c1corr) and findings ($c1finds)"
  else
    fail_msg "case1: latest.json lacks corrections/findings (corr=$c1corr finds=$c1finds)"
  fi
else
  fail_msg "case1: latest.json not written"
fi

# ===========================================================================
# Case 2: checker FAILS for a repo with prior findings -> previous findings
# carried into latest.json, issue NOT closed, exit 0, repos_failed==1.
# The failure is forced by invalid `gh pr list` JSON for that repo, so the
# clone stays a real git repo (required for enrolled_clone_dirs to emit it).
# ===========================================================================
C2="$TEST_TMPDIR/c2"; mkdir -p "$C2"
C2_ROOT="$C2/repos"; C2_LOG="$C2/gh.log"; : > "$C2_LOG"
make_drift_clone "$C2_ROOT/acme/widget"
write_env "$C2_ROOT" "acme" "widget"
# existing issue #77 so we can assert it is NOT closed on a checker failure.
write_gh_stub "$C2/bin" "$C2_LOG" "77" "acme/widget"
C2_REPORTS="$C2/reports"; mkdir -p "$C2_REPORTS"
# Prior latest.json with one finding for acme/widget.
cat > "$C2_REPORTS/latest.json" <<'JSON'
{
  "scan_id": "prev-1",
  "date": "2026-10-01T00:00:00Z",
  "repos_scanned": 1,
  "repos_failed": 0,
  "corrections": 1,
  "additions": 0,
  "findings": [
    {"repo":"acme/widget","check":"retired_names","kind":"correction",
     "doc_path":"README.md","doc_line":1,"code_path":".repoman/doc-drift.yaml",
     "claim":"retired name `kagenti` must not appear","evidence":"found `Kagenti`",
     "key":"acme/widget|retired_names|README.md|retired name `kagenti` must not appear|.repoman/doc-drift.yaml|1"}
  ],
  "delta": {"new":1,"fixed":0,"recurring":0}
}
JSON
printf '[{"scan_id":"prev-1"}]\n' > "$C2_REPORTS/history.json"
REPORTS_DIR="$C2_REPORTS" PATH="$C2/bin:$PATH" bash "$SCANNER" >/dev/null 2>&1
rc2=$?

if [ "$rc2" -eq 0 ]; then
  pass "case2: scanner exits 0 despite checker failure"
else
  fail_msg "case2: scanner exit $rc2 (expected 0)"
fi
c2failed=$(jq -r '.repos_failed' "$C2_REPORTS/latest.json" 2>/dev/null)
if [ "${c2failed:-0}" = "1" ]; then
  pass "case2: repos_failed == 1"
else
  fail_msg "case2: repos_failed=$c2failed (expected 1)"
fi
c2carried=$(jq -r '[.findings[] | select(.repo=="acme/widget")] | length' "$C2_REPORTS/latest.json" 2>/dev/null)
if [ "${c2carried:-0}" -ge 1 ]; then
  pass "case2: prior findings carried into latest.json (count=$c2carried)"
else
  fail_msg "case2: prior findings not carried (count=$c2carried)"; jq -c '.findings' "$C2_REPORTS/latest.json" 2>/dev/null
fi
if grep -q "issue close" "$C2_LOG"; then
  fail_msg "case2: issue was closed on a checker failure"; cat "$C2_LOG"
else
  pass "case2: issue NOT closed on checker failure"
fi

# ===========================================================================
# Case 3: all findings gone (clean clone) + prior latest.json had findings +
# a known existing issue number -> close path invoked (gh issue close).
# ===========================================================================
C3="$TEST_TMPDIR/c3"; mkdir -p "$C3"
C3_ROOT="$C3/repos"; C3_LOG="$C3/gh.log"; : > "$C3_LOG"
make_clean_clone "$C3_ROOT/acme/widget"
write_env "$C3_ROOT" "acme" "widget"
write_gh_stub "$C3/bin" "$C3_LOG" "99" ""   # existing issue #99
C3_REPORTS="$C3/reports"; mkdir -p "$C3_REPORTS"
cat > "$C3_REPORTS/latest.json" <<'JSON'
{
  "scan_id": "prev-1",
  "date": "2026-10-01T00:00:00Z",
  "repos_scanned": 1,
  "repos_failed": 0,
  "corrections": 1,
  "additions": 0,
  "findings": [
    {"repo":"acme/widget","check":"retired_names","kind":"correction",
     "doc_path":"README.md","doc_line":1,"code_path":".repoman/doc-drift.yaml",
     "claim":"retired name `kagenti` must not appear","evidence":"found `Kagenti`",
     "key":"acme/widget|retired_names|README.md|retired name `kagenti` must not appear|.repoman/doc-drift.yaml|1"}
  ],
  "delta": {"new":1,"fixed":0,"recurring":0}
}
JSON
printf '[{"scan_id":"prev-1"}]\n' > "$C3_REPORTS/history.json"
REPORTS_DIR="$C3_REPORTS" PATH="$C3/bin:$PATH" bash "$SCANNER" >/dev/null 2>&1
rc3=$?

if [ "$rc3" -eq 0 ]; then
  pass "case3: scanner exits 0"
else
  fail_msg "case3: scanner exit $rc3"
fi
if grep -q "issue close 99" "$C3_LOG"; then
  pass "case3: gh issue close invoked for existing issue #99"
else
  fail_msg "case3: existing issue not closed when findings gone"; cat "$C3_LOG"
fi

# ===========================================================================
# Case 4: --dry-run -> NO gh issue create/edit/close in the log AND latest.json
# NOT written (prior content unchanged).
# ===========================================================================
C4="$TEST_TMPDIR/c4"; mkdir -p "$C4"
C4_ROOT="$C4/repos"; C4_LOG="$C4/gh.log"; : > "$C4_LOG"
make_drift_clone "$C4_ROOT/acme/widget"
write_env "$C4_ROOT" "acme" "widget"
write_gh_stub "$C4/bin" "$C4_LOG" "" ""
C4_REPORTS="$C4/reports"; mkdir -p "$C4_REPORTS"
printf '{"scan_id":"prev-1"}\n' > "$C4_REPORTS/latest.json"
printf '[{"scan_id":"prev-1"}]\n' > "$C4_REPORTS/history.json"
C4_PRE=$(cat "$C4_REPORTS/latest.json")
C4_HIST_PRE=$(cat "$C4_REPORTS/history.json")
REPORTS_DIR="$C4_REPORTS" PATH="$C4/bin:$PATH" bash "$SCANNER" --dry-run >/dev/null 2>&1
rc4=$?

if [ "$rc4" -eq 0 ]; then
  pass "case4: --dry-run exits 0"
else
  fail_msg "case4: --dry-run exit $rc4"
fi
# Reject EVERY remote write, not just create/edit/close: also issue comment and
# label create (Jim, #132) — dry-run must touch nothing on GitHub.
if grep -Eq "issue (create|edit|close|comment)|label create" "$C4_LOG"; then
  fail_msg "case4: --dry-run made a remote-write gh call"; cat "$C4_LOG"
else
  pass "case4: --dry-run made no remote write (create/edit/close/comment/label)"
fi
if [ "$(cat "$C4_REPORTS/latest.json")" = "$C4_PRE" ]; then
  pass "case4: --dry-run left latest.json unchanged"
else
  fail_msg "case4: --dry-run overwrote latest.json"
fi
if [ "$(cat "$C4_REPORTS/history.json")" = "$C4_HIST_PRE" ]; then
  pass "case4: --dry-run left history.json unchanged"
else
  fail_msg "case4: --dry-run appended to history.json"
fi

# ===========================================================================
# Case 5: --issue-limit 1 -> at most one repo's issue touched. Two drifting
# repos, both with findings and no prior issues; only one create must occur.
# ===========================================================================
C5="$TEST_TMPDIR/c5"; mkdir -p "$C5"
C5_ROOT="$C5/repos"; C5_LOG="$C5/gh.log"; : > "$C5_LOG"
make_drift_clone "$C5_ROOT/acme/widget"
make_drift_clone "$C5_ROOT/acme/gadget"
printf '{"repos_dir":"%s","fork_owner":"tester"}\n' "$C5_ROOT" > "$CONFIG_FILE"
printf '[{"owner":"acme","name":"widget"},{"owner":"acme","name":"gadget"}]\n' > "$REPOS_FILE"
write_gh_stub "$C5/bin" "$C5_LOG" "" ""
C5_REPORTS="$C5/reports"; mkdir -p "$C5_REPORTS"
REPORTS_DIR="$C5_REPORTS" PATH="$C5/bin:$PATH" bash "$SCANNER" --issue-limit 1 >/dev/null 2>&1
rc5=$?

if [ "$rc5" -eq 0 ]; then
  pass "case5: --issue-limit exits 0"
else
  fail_msg "case5: --issue-limit exit $rc5"
fi
c5creates=$(grep -c "issue create" "$C5_LOG" 2>/dev/null || true)
# Assert EXACTLY one create, not <=1: with two drifting fixtures, <=1 would also
# pass if --issue-limit wrongly suppressed ALL creation (0). (Jim, #132)
if [ "${c5creates:-0}" -eq 1 ]; then
  pass "case5: exactly one issue create with --issue-limit 1 (got $c5creates)"
else
  fail_msg "case5: expected exactly 1 issue create with --issue-limit 1, got $c5creates"; cat "$C5_LOG"
fi
# And the limit must cap ISSUE WRITES, not the SCAN: both repos are still scanned.
c5scanned=$(jq -r '.repos_scanned' "$C5_REPORTS/latest.json" 2>/dev/null)
if [ "${c5scanned:-0}" -eq 2 ]; then
  pass "case5: both repos scanned despite --issue-limit 1 (repos_scanned=$c5scanned)"
else
  fail_msg "case5: --issue-limit limited the scan, not issue writes (repos_scanned=$c5scanned, expected 2)"
fi

# ===========================================================================
# Case 6: latest.json shape (repos_scanned/corrections/additions/delta) and
# history.json gains exactly one row on a live run.
# ===========================================================================
C6="$TEST_TMPDIR/c6"; mkdir -p "$C6"
C6_ROOT="$C6/repos"; C6_LOG="$C6/gh.log"; : > "$C6_LOG"
make_drift_clone "$C6_ROOT/acme/widget"
write_env "$C6_ROOT" "acme" "widget"
write_gh_stub "$C6/bin" "$C6_LOG" "" ""
C6_REPORTS="$C6/reports"; mkdir -p "$C6_REPORTS"
REPORTS_DIR="$C6_REPORTS" PATH="$C6/bin:$PATH" bash "$SCANNER" >/dev/null 2>&1
rc6=$?

if [ "$rc6" -eq 0 ]; then
  pass "case6: scanner exits 0"
else
  fail_msg "case6: scanner exit $rc6"
fi
shape_ok=$(jq -r '
  (has("repos_scanned") and has("corrections") and has("additions")
   and (.delta | has("new") and has("fixed") and has("recurring")))
' "$C6_REPORTS/latest.json" 2>/dev/null)
if [ "$shape_ok" = "true" ]; then
  pass "case6: latest.json has repos_scanned/corrections/additions/delta{new,fixed,recurring}"
else
  fail_msg "case6: latest.json shape wrong"; jq -c '.' "$C6_REPORTS/latest.json" 2>/dev/null
fi
h6=$(jq 'length' "$C6_REPORTS/history.json" 2>/dev/null)
if [ "${h6:-0}" = "1" ]; then
  pass "case6: history.json gained exactly one row"
else
  fail_msg "case6: history.json has $h6 rows (expected 1)"
fi

# ---------------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "FAILURES"
exit 1
