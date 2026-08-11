#!/usr/bin/env bash
# Org identity and core-repo resolution: profile loading (load_org_profile),
# core-repo allowlist reads, canonical-name remap, and repos-dir validation.
#
# ## Portability
# Targets bash 3.2+ (macOS default) through modern bash.
#
# No intra-library deps: functions invoke gh/git/jq/builtins directly, so this
# module sources no sibling module. Self-contained for vendoring. (load_org_profile
# does source a runtime org-profile data file — that is caller data, not a module.)
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
# REPO SELECTION
# =============================================================================
#
# Single source of truth for which repos the programs act on. All programs
# derive their repo set from config/core-repos.txt via get_core_repos(), so
# coverage is defined in one place rather than hardcoded per script.
#
# The on-disk clone directories still carry pre-rename names (e.g. "kagenti",
# "kagenti-extensions"), so scripts that iterate clones must map a directory
# basename to its canonical repo via canonical_repo_for_dir() before building
# an API reference. Never rely on the rename redirect for filtered `gh pr list`
# queries (--label/--author silently return empty across a redirect).

# Load org identity from a profile file and resolve each fact by precedence:
#   --flag > env var > profile value > built-in default.
#
# The profile file assigns ONLY PROFILE_-prefixed names (PROFILE_ORG, ...),
# so sourcing it can never clobber an env-provided ORG before resolution.
#
# Profile selection: $ORG_PROFILE_FILE (absolute path, used by tests) wins;
# else --profile/$ORG_PROFILE names config/org.<name>.env; else config/org.env.
#
# Callers may pre-set *_FLAG vars from their own arg parsing (ORG_FLAG,
# FORK_OWNER_FLAG, MAIN_REPO_FLAG, REPOS_DIR_FLAG) and env vars (ORG, ...).
#
# Sets (caller should treat as exported): ORG FORK_OWNER MAIN_REPO REPOS_DIR REMAP.
# The first four honor the full flag > env > profile > default precedence; REMAP
# is profile-only (see note at its assignment below).
# Fails loud: missing profile file -> return 1; unresolvable ORG -> hard error.
#
# Only ORG has no built-in default (it must be resolved from flag/env/profile).
# The other facts fall back to sensible defaults derived from ORG, except
# FORK_OWNER, whose built-in fallback "clawgenti" is the rossoctl deployment's
# fork account. Any other org should set PROFILE_FORK_OWNER in its profile
# (config/org.env sets it explicitly) rather than rely on that fallback.
load_org_profile() {
  local lib_dir profile_file name
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [ -n "${ORG_PROFILE_FILE:-}" ]; then
    profile_file="$ORG_PROFILE_FILE"
  else
    name="${PROFILE_FLAG:-${ORG_PROFILE:-}}"
    if [ -n "$name" ]; then
      profile_file="$lib_dir/../config/org.$name.env"
    else
      profile_file="$lib_dir/../config/org.env"
    fi
  fi

  if [ ! -f "$profile_file" ]; then
    echo "ERROR: org profile not found: $profile_file" >&2
    return 1
  fi

  # Safe to source: file sets only PROFILE_* names.
  # shellcheck source=/dev/null
  . "$profile_file"

  ORG="${ORG_FLAG:-${ORG:-${PROFILE_ORG:-}}}"
  if [ -z "$ORG" ]; then
    echo "ERROR: ORG could not be resolved (flag/env/profile all empty)" >&2
    return 1
  fi
  FORK_OWNER="${FORK_OWNER_FLAG:-${FORK_OWNER:-${PROFILE_FORK_OWNER:-clawgenti}}}"
  MAIN_REPO="${MAIN_REPO_FLAG:-${MAIN_REPO:-${PROFILE_MAIN_REPO:-$ORG/$ORG}}}"
  REPOS_DIR="${REPOS_DIR_FLAG:-${REPOS_DIR:-${PROFILE_REPOS_DIR:-$HOME/$ORG}}}"
  # SOURCE_REPO: the owner/name of the repo where this suite (scripts, skills,
  # standing orders) is version-controlled. Used to link report PRs back to the
  # invoking program's standing order for auditability. Defaults to the
  # automation repo under the active org; a fork can override via env or profile.
  # No --flag tier: this is a deploy-level constant, not a per-invocation knob.
  SOURCE_REPO="${SOURCE_REPO:-${PROFILE_SOURCE_REPO:-$ORG/automation}}"
  # REMAP is profile-only by design (no flag/env tier): it is a transitional
  # field that self-retires once clone dirs are renamed (rossoctl/automation#37),
  # so it never earns a durable --flag/env knob. An exported REMAP is ignored.
  REMAP="${PROFILE_REMAP:-}"

  export ORG FORK_OWNER MAIN_REPO REPOS_DIR SOURCE_REPO REMAP
}

# Print the core repo allowlist, one "owner/name" per line.
#
# Reads config/core-repos.txt, which holds BARE repo names (comments starting
# with "#" and blank lines are stripped). The owner is derived by prepending
# the loaded $ORG, so the same list works for any org the suite targets. Call
# load_org_profile (or otherwise set ORG) before this function.
#
# The file path is resolved relative to THIS library's location, not the
# caller's, so it works no matter which script sources program-lib.sh.
# Override with $CORE_REPOS_FILE (used by tests).
#
# Fails loud: if ORG is unset, or the file is missing or yields zero repos,
# prints an error to stderr and returns 1 -- callers must never silently scan
# an empty repo set or emit ownerless refs.
#
# Usage (portable; mapfile is bash 4+ and absent on macOS bash 3.2):
#   REPOS=(); while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done \
#     < <(get_core_repos)
get_core_repos() {
  if [ -z "${ORG:-}" ]; then
    echo "ERROR: ORG is unset; call load_org_profile before get_core_repos" >&2
    return 1
  fi

  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local repos_file="${CORE_REPOS_FILE:-$lib_dir/../config/core-repos.txt}"

  if [ ! -f "$repos_file" ]; then
    echo "ERROR: core repos file not found: $repos_file" >&2
    return 1
  fi

  # Strip comments (full-line and trailing), trim whitespace, drop blanks.
  local repos
  repos=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' \
    "$repos_file" | grep -v '^$' || true)

  if [ -z "$repos" ]; then
    echo "ERROR: core repos file is empty: $repos_file" >&2
    return 1
  fi

  # Prepend the loaded org to each bare name.
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && printf '%s/%s\n' "$ORG" "$line"
  done <<EOF
$repos
EOF
}

# Print just the bare repo names (owner stripped) from the core allowlist.
# Useful for membership tests against local clone directory names.
#
# Usage (portable): NAMES=(); while IFS= read -r n; do NAMES+=("$n"); done \
#   < <(core_repo_names)
core_repo_names() {
  get_core_repos | sed 's|^[^/]*/||'
}

# Return 0 if the given bare repo name is in the core allowlist, else 1.
#
# Intended for filtering local clone iteration: pass the canonical name
# (see canonical_repo_for_dir) so pre-rename clone dirs are matched correctly.
# Uses an exact, whole-line match (grep -Fx) to avoid substring false positives.
#
# Usage:
#   canon=$(canonical_repo_for_dir "$repo_name")
#   is_core_repo "$canon" || continue
# Args:
#   $1 - bare repo name (no owner prefix)
is_core_repo() {
  local name="$1"
  core_repo_names | grep -qxF "$name"
}

# Map a local clone directory basename to its canonical bare repo name.
#
# Clone dirs may still use pre-rename names; the remap table lives in the org
# profile's $REMAP (format: space-separated "basename:canonical" pairs, set by
# load_org_profile), so every script agrees and the mapping is data, not code.
# An empty $REMAP makes this pure identity; unknown names pass through
# unchanged (identity), so non-remapped repos need no special handling.
#
# TRANSITIONAL: $REMAP is a temporary bridge for the kagenti->rossoctl rename
# while stale-named clone dirs still exist on disk. Once clone dirs are renamed
# to canonical names, the PROFILE_REMAP line is deleted and this becomes pure
# identity. See rossoctl/automation#37. It is a lookup table, not a rename
# detector -- do not treat it as protection against future renames.
#
# A malformed entry (no colon) is skipped with a warning, non-fatal.
#
# Returns: the bare repo name only (e.g. "rossoctl"), NOT an owner/name pair.
#          Prepend the owner to build a full API reference, e.g. "$ORG/$canon".
#
# Usage: canon=$(canonical_repo_for_dir "$repo_dir_basename")
# Args:
#   $1 - clone directory basename (e.g. "kagenti", "cortex")
canonical_repo_for_dir() {
  local dir_name="$1"
  local pair basename_part canon_part
  # Intentional word-split on space-separated pairs.
  # shellcheck disable=SC2086
  for pair in ${REMAP:-}; do
    basename_part="${pair%%:*}"
    canon_part="${pair#*:}"
    if [ -z "$basename_part" ] || [ "$basename_part" = "$pair" ]; then
      # Malformed entry (no colon) -- skip with a warning, non-fatal.
      echo "WARN: ignoring malformed REMAP entry: $pair" >&2
      continue
    fi
    if [ "$dir_name" = "$basename_part" ]; then
      echo "$canon_part"
      return 0
    fi
  done
  # No match (or empty REMAP): identity.
  echo "$dir_name"
}
