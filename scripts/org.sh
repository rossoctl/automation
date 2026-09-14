#!/usr/bin/env bash
# RepoMan input model: reads ~/.repoman/config.json and ~/.repoman/repos.json
# (repoman_config, repoman_get_repos, is_enrolled), plus repos-dir validation.
#
# ## Portability
# Targets bash 3.2+ (macOS default) through modern bash.
#
# No intra-library deps: functions invoke gh/git/jq/builtins directly, so this
# module sources no sibling module. Self-contained for vendoring. (repoman_config
# and repoman_get_repos do read runtime JSON data files under ~/.repoman -- that
# is caller data, not a module.)
[ -n "${_ORG_SH_LOADED:-}" ] && return
_ORG_SH_LOADED=1

# =============================================================================
# PATH VALIDATION
# =============================================================================

# Validate that REPOS_DIR is set and not pointing to a dangerous path.
# Rejects root filesystem paths, system directories, and $HOME itself
# (without a subdirectory). Intended to prevent accidental scanning or
# modification of system files.
#
# Usage: validate_repos_dir "$REPOS_DIR"
# Args:
#   $1 - the repos directory path to validate
# Returns: 0 if valid, exits with error message if invalid
validate_repos_dir() {
  local path="$1"

  if [ -z "$path" ]; then
    echo "ERROR: REPOS_DIR is not set." >&2
    echo "Export it to the directory containing your org's cloned repos:" >&2
    echo "  export REPOS_DIR=~/my-org" >&2
    exit 1
  fi

  # Resolve to absolute path for comparison
  local resolved
  resolved=$(cd "$path" 2>/dev/null && pwd) || resolved="$path"

  # Reject obviously dangerous paths
  local dangerous_paths=("/" "/etc" "/usr" "/var" "/sys" "/proc" "/bin" "/sbin" "/lib" "/tmp")
  for dangerous in "${dangerous_paths[@]}"; do
    if [ "$resolved" = "$dangerous" ]; then
      echo "ERROR: REPOS_DIR cannot be '$resolved' -- this is a system directory." >&2
      exit 1
    fi
  done

  # Reject $HOME itself (must be a subdirectory)
  if [ "$resolved" = "$HOME" ]; then
    echo "ERROR: REPOS_DIR cannot be your home directory itself." >&2
    echo "Use a subdirectory, e.g.: export REPOS_DIR=~/my-org" >&2
    exit 1
  fi

  # Check the directory exists
  if [ ! -d "$path" ]; then
    echo "ERROR: REPOS_DIR '$path' does not exist." >&2
    echo "Create it and clone your org's repos there, or set REPOS_DIR to an existing directory." >&2
    exit 1
  fi

  return 0
}

# =============================================================================
# REPOMAN INPUT MODEL
# =============================================================================
#
# RepoMan reads two user-managed files under ~/.repoman:
#   config.json : deployment-wide constants ({repos_dir, fork_owner})
#   repos.json  : the enrolled set (array of {owner, name})
# There is no $ORG and no core-repos.txt. Repos are addressed as owner/name,
# and clone dirs are owner-namespaced ($REPOS_DIR/<owner>/<name>/).

# Read ~/.repoman/config.json and export the deployment-wide constants.
# Sets: REPOS_DIR (from .repos_dir, leading ~ expanded to $HOME), FORK_OWNER
# (from .fork_owner). Override the path with $REPOMAN_CONFIG_FILE (tests).
# Fails loud (return 1) on a missing file or a missing/empty required key --
# report/source targets are NOT read here; they are per-program (Phase 2).
repoman_config() {
  local config_file="${REPOMAN_CONFIG_FILE:-$HOME/.repoman/config.json}"
  if [ ! -f "$config_file" ]; then
    echo "ERROR: RepoMan config not found: $config_file" >&2
    return 1
  fi

  local repos_dir fork_owner
  repos_dir=$(jq -r '.repos_dir // empty' "$config_file")
  fork_owner=$(jq -r '.fork_owner // empty' "$config_file")

  if [ -z "$repos_dir" ]; then
    echo "ERROR: config.json missing required key: repos_dir ($config_file)" >&2
    return 1
  fi
  if [ -z "$fork_owner" ]; then
    echo "ERROR: config.json missing required key: fork_owner ($config_file)" >&2
    return 1
  fi

  # Expand a leading ~ to $HOME. jq returns the literal string "~", so these
  # patterns match a literal tilde and we expand to $HOME by hand -- SC2088's
  # "tilde does not expand in quotes" is exactly the intent here, not a bug.
  # shellcheck disable=SC2088
  case "$repos_dir" in
    "~") repos_dir="$HOME" ;;
    "~/"*) repos_dir="$HOME/${repos_dir#"~/"}" ;;
  esac

  REPOS_DIR="$repos_dir"
  FORK_OWNER="$fork_owner"
  export REPOS_DIR FORK_OWNER
}

# Print the enrolled repo set, one "owner/name" per line, in file order.
# Reads ~/.repoman/repos.json (array of {owner,name}); override the path with
# $REPOMAN_REPOS_FILE (tests). Fails loud (return 1) on a missing/empty file
# or an entry missing owner or name -- never silently scan an empty set.
#
# Usage (portable; no mapfile on bash 3.2):
#   REPOS=(); while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done \
#     < <(repoman_get_repos)
repoman_get_repos() {
  local repos_file="${REPOMAN_REPOS_FILE:-$HOME/.repoman/repos.json}"
  if [ ! -f "$repos_file" ]; then
    echo "ERROR: RepoMan repos file not found: $repos_file" >&2
    return 1
  fi

  # jq -e exits non-zero if the array is empty or any entry lacks owner/name;
  # the guarded expression fails the whole read rather than emit a bad ref.
  local out
  if ! out=$(jq -er '
      if length == 0 then error("empty repos array")
      else .[] | (.owner // error("entry missing owner")) as $o
                 | (.name  // error("entry missing name"))  as $n
                 | "\($o)/\($n)"
      end' "$repos_file" 2>/dev/null); then
    echo "ERROR: repos.json is empty or has a malformed entry: $repos_file" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# Return 0 if the given "owner/name" is in the enrolled set, else 1.
# Exact whole-line match (grep -Fx) to avoid substring false positives.
# Args: $1 - "owner/name"
is_enrolled() {
  local repo="$1"
  repoman_get_repos | grep -qxF "$repo"
}

# =============================================================================
# REPO SELECTION
# =============================================================================
#
# Single source of truth for which repos the programs act on: the enrolled set
# in ~/.repoman/repos.json (see REPOMAN INPUT MODEL above). Programs derive
# their repo set from repoman_get_repos()/is_enrolled(), so coverage is defined
# in one place rather than hardcoded per script. Repos are addressed as
# owner/name and clone dirs are owner-namespaced, so there is no canonical-name
# remap step: each repo's directory is its owner/name pair, unambiguously.
