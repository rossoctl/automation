#!/usr/bin/env bash
# Asserts the public function surface of program-lib.sh is unchanged.
# This is the equivalence guard for the decomposition refactor (#35):
# functions may move between module files, but none may be lost or renamed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"

WANT="append_history_row
atomic_write_file
canonical_repo_for_dir
close_issue_if_valid
core_repo_names
create_fork_pr
diff_against_previous
ensure_fork
generate_scan_id
get_core_repos
gh_issue_exists
gh_with_backoff
is_core_repo
iso_to_epoch
issue_has_open_pr
load_org_profile
pick_best_candidate
score_path_suffix
setup_workspace
validate_issue_fields
validate_json_schema
validate_repos_dir
write_report_latest"

GOT=$(
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/program-lib.sh" 2>/dev/null
  declare -F | awk '{print $3}' | sort
)

if [ "$GOT" = "$WANT" ]; then
  echo "PASS: lib function inventory (23 functions, none lost/renamed)"
  exit 0
else
  echo "FAIL: lib function inventory mismatch"
  echo "--- diff (want vs got) ---"
  diff <(printf '%s\n' "$WANT") <(printf '%s\n' "$GOT")
  exit 1
fi
