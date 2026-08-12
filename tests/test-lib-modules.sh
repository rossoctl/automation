#!/usr/bin/env bash
# Proves each library module sources standalone (self-sourcing guards + relative
# dep resolution work) and defines its expected functions. This is what makes a
# module safe to vendor as a subset.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
fail=0

check_module() {
  local module="$1"; shift
  local got
  got=$(
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$module" 2>/dev/null
    for fn in "$@"; do
      if ! declare -F "$fn" >/dev/null 2>&1; then echo "MISSING:$fn"; fi
    done
  )
  if [ -n "$got" ]; then
    echo "FAIL $module: $got"; fail=1
  else
    echo "ok   $module (sourced standalone; all functions defined)"
  fi
}

check_module core.sh setup_workspace generate_scan_id iso_to_epoch atomic_write_file validate_json_schema diff_against_previous write_report_latest append_history_row
check_module github-api.sh gh_with_backoff gh_issue_exists close_issue_if_valid issue_has_open_pr
check_module fork.sh validate_issue_fields score_path_suffix pick_best_candidate ensure_fork create_fork_pr
check_module org.sh load_org_profile get_core_repos core_repo_names is_core_repo canonical_repo_for_dir validate_repos_dir

if [ "$fail" -eq 0 ]; then
  echo "PASS: all four modules source standalone with their functions defined"
  exit 0
fi
exit 1
