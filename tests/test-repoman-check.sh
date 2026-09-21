#!/usr/bin/env bash
# Tests for scripts/repoman-check.sh (RepoMan Phase 3 Deliverable C).
#
# Isolation mechanism: repoman-check.sh is invoked as a SUBPROCESS
# (`bash "$CHECK"`), not sourced, so a function-shadow of `gh` in this test's
# shell would NOT be visible to it. Instead we put a scripted `gh` STUB
# executable at the front of PATH; the subprocess's own `gh` lookup finds the
# stub. The stub's behavior is driven by GH_STUB_* env vars this test sets
# per-case.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../scripts/repoman-check.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

# --- build a gh stub on PATH ---
STUB_DIR="$TEST_TMPDIR/bin"; mkdir -p "$STUB_DIR"
PROBE_COUNT_FILE="$TEST_TMPDIR/probe_count"      # counts accepted-scope probes (api -i .../labels)
VIS_COUNT_FILE="$TEST_TMPDIR/vis_count"          # counts visibility lookups (api repos/<repo>)
echo 0 > "$PROBE_COUNT_FILE"
echo 0 > "$VIS_COUNT_FILE"
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
# Scripted gh stub. Reads GH_STUB_* env to decide responses.
# Recognizes:  api -i user  |  api -i repos/.../labels  |  api repos/<repo> (visibility)
#              |  label list --json name --jq ...  |  label create ...
# NOTE: 'label list' is matched ONLY in its --json name form, which is how the
# checker calls it. Real 'gh label list' without --json prints a TSV table
# (name<TAB>desc<TAB>color), NOT bare names; modelling only the --json form keeps
# this test honest — a checker that parsed the bare table would fail here.
case "\$*" in
  *"-i user"*)
    printf 'X-OAuth-Scopes: %s\r\n' "\${GH_STUB_SCOPES-repo}"
    printf '\r\n{}\n'
    exit 0 ;;
  *"api -i "*"/labels"*)
    n=\$(cat "$PROBE_COUNT_FILE"); n=\$((n + 1)); echo "\$n" > "$PROBE_COUNT_FILE"
    printf 'X-Accepted-OAuth-Scopes: %s\r\n' "\${GH_STUB_ACCEPTED-repo}"
    printf '\r\n[]\n'
    exit 0 ;;
  *"api repos/"*)
    # Visibility lookup: 'gh api repos/<owner>/<name> --jq .private'
    v=\$(cat "$VIS_COUNT_FILE"); v=\$((v + 1)); echo "\$v" > "$VIS_COUNT_FILE"
    printf '%s\n' "\${GH_STUB_PRIVATE-false}"
    exit 0 ;;
  *"label list"*"--json name"*)
    # The checker asks for bare names one per line via --json name --jq '.[].name'.
    printf '%s\n' "\${GH_STUB_LABELS-}"
    exit 0 ;;
  *"label list"*)
    # Bare 'label list' (no --json): emit a realistic TSV table so any consumer
    # that forgot --json is caught. GH_STUB_LABELS names, tab-padded.
    for lbl in \${GH_STUB_LABELS-}; do printf '%s\tsome description\t#ededed\n' "\$lbl"; done
    exit 0 ;;
  *"label create"*)
    echo "created"; exit 0 ;;
  *) echo "unhandled gh args: \$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$STUB_DIR/gh"

PROGRAMS_DIR="$TEST_TMPDIR/programs"; mkdir -p "$PROGRAMS_DIR"
REPOS_FILE="$TEST_TMPDIR/repos.json"
echo '[{"owner":"alice","name":"tool"}]' > "$REPOS_FILE"

run_check() { # $1..= extra args; env: GH_STUB_*
  PATH="$STUB_DIR:$PATH" REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" REPOMAN_REPOS_FILE="$REPOS_FILE" \
    bash "$CHECK" "$@" 2>&1
}

# --- scope present, label present -> ok, exit 0, and the present label is NOT
# reported missing. This is the case that catches a checker parsing the wrong
# `gh label list` output shape: if it read the TSV table instead of bare names,
# an existing label would still be flagged "missing" here. ---
echo '{"pat_scopes":["repo"],"labels_required":["ready-for-ai-review"]}' > "$PROGRAMS_DIR/pr-review.json"
out=$(GH_STUB_SCOPES="gist, repo" GH_STUB_LABELS="ready-for-ai-review" run_check --program pr-review); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL all-good should exit 0: rc=$rc out=[$out]"; fail=1; }
case "$out" in
  *"'ready-for-ai-review' missing"*) echo "FAIL present label wrongly reported missing (label-list output not parsed as bare names): [$out]"; fail=1 ;;
esac

# --- missing scope -> hard fail (non-zero), names the scope in a SCOPE FAIL line ---
out=$(GH_STUB_SCOPES="gist" GH_STUB_LABELS="ready-for-ai-review" run_check --program pr-review); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL missing scope should hard-fail"; fail=1; }
# Assert the hard-fail phrasing, not a bare "repo" substring (which also appears
# in unrelated guidance and would pass even if the scope were not named).
case "$out" in
  *"SCOPE FAIL: PAT is missing required scope(s): "*"repo"*) ;;
  *) echo "FAIL missing-scope should name 'repo' in a SCOPE FAIL line, got: [$out]"; fail=1 ;;
esac

# --- fine-grained token (empty scopes header) -> hard fail with guidance ---
out=$(GH_STUB_SCOPES="" GH_STUB_LABELS="ready-for-ai-review" run_check --program pr-review); rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL empty-scope (fine-grained) should hard-fail"; fail=1; }
case "$out" in *"fine-grained"*) ;; *) echo "FAIL fine-grained should be named, got: [$out]"; fail=1 ;; esac

# --- label missing, PAT can create, no flag -> instructs gh label create, exit 0 ---
out=$(GH_STUB_SCOPES="repo" GH_STUB_LABELS="" GH_STUB_ACCEPTED="repo" run_check --program pr-review); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL label-missing-createable should not hard-fail: rc=$rc"; fail=1; }
case "$out" in *"gh label create"*) ;; *) echo "FAIL should instruct gh label create, got: [$out]"; fail=1 ;; esac

# --- label missing, PAT can create, --create-missing-labels -> creates it ---
out=$(GH_STUB_SCOPES="repo" GH_STUB_LABELS="" GH_STUB_ACCEPTED="repo" run_check --program pr-review --create-missing-labels); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL create-flag should exit 0: rc=$rc"; fail=1; }
case "$out" in *"created"*|*"Created"*) ;; *) echo "FAIL create-flag should report creation, got: [$out]"; fail=1 ;; esac

# --- label missing, PAT CANNOT create -> web UI remediation, NO gh label create command ---
out=$(GH_STUB_SCOPES="read:org" GH_STUB_LABELS="" GH_STUB_ACCEPTED="repo" run_check --program pr-review); rc=$?
# scope gate: pat_scopes is ["repo"] but token has only read:org -> this ALSO hard-fails the scope gate.
# Use a program whose pat_scopes are satisfied but that still cannot create labels:
echo '{"pat_scopes":["read:org"],"labels_required":["ready-for-ai-review"]}' > "$PROGRAMS_DIR/pr-review.json"
out=$(GH_STUB_SCOPES="read:org" GH_STUB_LABELS="" GH_STUB_ACCEPTED="repo" run_check --program pr-review); rc=$?
case "$out" in
  *"web UI"*|*"Settings"*) ;;
  *) echo "FAIL under-scoped-for-create should point to web UI, got: [$out]"; fail=1 ;;
esac
case "$out" in
  *"gh label create"*) echo "FAIL under-scoped-for-create must NOT emit a gh label create command"; fail=1 ;;
esac

# --- multi-repo aggregation: two repos both missing the label, both reported ---
echo '[{"owner":"alice","name":"tool"},{"owner":"bob","name":"kit"}]' > "$REPOS_FILE"
echo '{"pat_scopes":["repo"],"labels_required":["ready-for-ai-review"]}' > "$PROGRAMS_DIR/pr-review.json"
echo 0 > "$PROBE_COUNT_FILE"
echo 0 > "$VIS_COUNT_FILE"
out=$(GH_STUB_SCOPES="repo" GH_STUB_LABELS="" GH_STUB_ACCEPTED="repo" run_check --program pr-review); rc=$?
case "$out" in *"alice/tool"*) ;; *) echo "FAIL aggregation should mention alice/tool"; fail=1 ;; esac
case "$out" in *"bob/kit"*) ;; *) echo "FAIL aggregation should mention bob/kit"; fail=1 ;; esac

# --- performance: accepted-scope probe cached by visibility (<=2 across 2 repos) ---
probe_count=$(cat "$PROBE_COUNT_FILE")
[ "$probe_count" -le 2 ] || { echo "FAIL accepted-scope probe should be cached (<=2 probes across 2 repos), got: $probe_count"; fail=1; }

# --- performance: visibility looked up at most once per repo (<=2 across 2 repos),
# even though each repo is missing a label (would be >2 if looked up per-label) ---
vis_count=$(cat "$VIS_COUNT_FILE")
[ "$vis_count" -le 2 ] || { echo "FAIL visibility should be looked up <=once/repo (<=2 across 2 repos), got: $vis_count"; fail=1; }

# --- private repo: visibility=true branch is exercised, still succeeds (exit 0) ---
echo '[{"owner":"alice","name":"secret"}]' > "$REPOS_FILE"
echo '{"pat_scopes":["repo"],"labels_required":["ready-for-ai-review"]}' > "$PROGRAMS_DIR/pr-review.json"
out=$(GH_STUB_SCOPES="repo" GH_STUB_LABELS="" GH_STUB_ACCEPTED="repo" GH_STUB_PRIVATE="true" run_check --program pr-review); rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL private-repo label warning should not hard-fail: rc=$rc out=[$out]"; fail=1; }
case "$out" in *"alice/secret"*) ;; *) echo "FAIL private-repo case should mention alice/secret, got: [$out]"; fail=1 ;; esac

[ "$fail" -eq 0 ] && echo "PASS: repoman-check.sh" || exit 1
