#!/usr/bin/env bash
# RepoMan invocation-time capability checker.
#
# Verifies, BEFORE a program runs, that the active PAT holds the scopes the
# program's SKILL.md declared (programs/<name>.json: pat_scopes) and reports
# which enrolled repos are missing the program's required labels
# (labels_required). Scope gaps are hard failures (exit non-zero); label gaps
# are warnings (exit 0 unless a scope gate also failed) because a missing
# label degrades a program's usefulness but does not make it unsafe to run.
#
# Usage:
#   repoman-check.sh --program <name> [--create-missing-labels]
#
# Read-only by default. --create-missing-labels is the only flag that mutates
# (creates missing labels), and only when the PAT's scopes intersect the
# accepted-scopes for the labels endpoint (i.e. the PAT actually CAN create
# labels there).
#
# ## Portability
# Targets bash 3.2+ (macOS default): no mapfile, no declare -A, no
# associative arrays. "Sets" are newline-accumulator strings.
#
# set -uo pipefail (NOT -e): this script aggregates gaps across every repo
# and every required label before deciding whether to exit non-zero, so one
# repo's gap must not abort the loop before later repos are checked.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/program-lib.sh"

usage() {
  cat <<'EOF'
Usage: repoman-check.sh --program <name> [--create-missing-labels]

Invocation-time capability check for a RepoMan program. Reads
programs/<name>.json (pat_scopes, labels_required) and:

  1. Scope check (hard gate): confirms the active PAT (`gh api -i user`)
     holds every scope in pat_scopes. A fine-grained PAT (no X-OAuth-Scopes
     header) always hard-fails this gate. Missing scopes hard-fail too.

  2. Label check (per enrolled repo, warning only): for each label in
     labels_required missing from a repo, reports one of:
       - PAT can create + --create-missing-labels: creates it via
         `gh label create` and reports success.
       - PAT can create + no flag: prints the exact `gh label create`
         command to run.
       - PAT cannot create (its scopes do not cover the labels endpoint's
         accepted scopes): points at a wider PAT or the GitHub web UI
         (Settings -> Labels). Never prints a `gh label create` command in
         this case, since running it would just fail.

Flags:
  --program <name>          Required. Selects programs/<name>.json.
  --create-missing-labels   Create missing labels where the PAT can.
  --help                    Show this help and exit 0.

Exit status: non-zero iff any scope gate failed. Label gaps alone exit 0.

Path overrides (same as the rest of RepoMan):
  REPOMAN_PROGRAMS_DIR (default ~/.repoman/programs)
  REPOMAN_REPOS_FILE   (default ~/.repoman/repos.json)
EOF
}

# -----------------------------------------------------------------------------
# Aggregated findings (newline-accumulator strings; bash 3.2 has no arrays of
# structs). scope_gate_failed is the only thing that flips the exit code.
# -----------------------------------------------------------------------------
scope_gate_failed=0
findings=""

add_finding() {
  findings="${findings}$1"$'\n'
}

# -----------------------------------------------------------------------------
# check_scopes <required-scopes-newline-list>
# Hard gate. Sets PAT_SCOPES (newline-list of the token's own scopes) as a
# side effect for later label-capability checks. Returns via scope_gate_failed
# / findings, not via exit -- callers must keep going to check labels too.
# -----------------------------------------------------------------------------
PAT_SCOPES=""

check_scopes() {
  local required="$1"
  local hdr scopes_line scopes_value req missing=""

  # gh_with_backoff writes its error to stderr and returns 1 on a non-rate-limit
  # failure, so an unguarded `$(...)` would capture an empty string and fall
  # through to the empty-scopes branch below, misreporting a transport/auth
  # failure as "fine-grained token". Check the status explicitly ($SCRIPT set
  # -e is off by design). tr -d '\r' must run on its own line, not piped inside
  # the substitution -- there the status would be tr's, not gh's.
  if ! hdr=$(gh_with_backoff api -i user); then
    add_finding "SCOPE FAIL: could not query the active token via 'gh api -i user' (see stderr above). This is a transport or authentication failure, not a token-type problem -- check 'gh auth status' and network reachability, then re-run."
    scope_gate_failed=1
    PAT_SCOPES=""
    return
  fi
  hdr=$(printf '%s' "$hdr" | tr -d '\r')

  scopes_line=$(printf '%s\n' "$hdr" | grep -i '^X-OAuth-Scopes:' | head -1)
  scopes_value="${scopes_line#*:}"
  # trim leading/trailing whitespace
  scopes_value="${scopes_value#"${scopes_value%%[![:space:]]*}"}"
  scopes_value="${scopes_value%"${scopes_value##*[![:space:]]}"}"

  if [ -z "$scopes_value" ]; then
    add_finding "SCOPE FAIL: token appears to be a fine-grained personal access token (no X-OAuth-Scopes header). This checker validates classic-PAT OAuth scopes; a fine-grained token cannot be verified the same way. Re-run with a classic PAT that has: $(printf '%s' "$required" | tr '\n' ' ')"
    scope_gate_failed=1
    PAT_SCOPES=""
    return
  fi

  # Normalize token scopes to a newline list for membership tests.
  PAT_SCOPES=$(printf '%s' "$scopes_value" | tr ',' '\n' | while IFS= read -r s || [ -n "$s" ]; do
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    [ -n "$s" ] && printf '%s\n' "$s"
  done)

  while IFS= read -r req || [ -n "$req" ]; do
    [ -n "$req" ] || continue
    if ! printf '%s\n' "$PAT_SCOPES" | grep -qxF "$req"; then
      missing="${missing}${req}"$'\n'
    fi
  done <<EOF
$required
EOF

  if [ -n "$missing" ]; then
    add_finding "SCOPE FAIL: PAT is missing required scope(s): $(printf '%s' "$missing" | tr '\n' ' ')(have: $(printf '%s' "$PAT_SCOPES" | tr '\n' ' '))"
    scope_gate_failed=1
  fi
}

# -----------------------------------------------------------------------------
# Accepted-scope probe cache, keyed by repo visibility (private/public), so a
# multi-repo run does at most 2 "/labels" probes total rather than one per
# repo.
#
# Backed by files under CACHE_DIR rather than a plain variable: callers invoke
# probe_accepted_scopes via command substitution ($(...)) to capture its
# stdout, which runs the function in a SUBSHELL -- any plain-variable writes
# inside it are invisible once the subshell exits. A file survives across
# subshells, so it is the only persistence mechanism available here.
# -----------------------------------------------------------------------------
CACHE_DIR=""

init_probe_cache() {
  CACHE_DIR=$(mktemp -d)
  # Clean up unconditionally: cleanup_probe_cache is also called on the happy
  # path, but a trap catches SIGINT (plausible during a wide per-repo label
  # loop) and any future early return between init and the explicit cleanup.
  trap 'cleanup_probe_cache' EXIT INT TERM
}

cleanup_probe_cache() {
  [ -n "$CACHE_DIR" ] && rm -rf "$CACHE_DIR"
}

# probe_accepted_scopes <owner/name>
# Prints the newline-list of accepted scopes for the labels endpoint,
# caching by the repo's visibility (private/public) so repeated calls for
# repos of the same visibility do not re-probe.
probe_accepted_scopes() {
  local repo="$1" is_private hdr line value cache_file vis_file vis_key

  # Cache the visibility lookup per repo so `gh api repos/<repo>` fires at most
  # once per repo (not once per missing label), then key the accepted-scope
  # probe on the visibility class so it fires at most once per class.
  vis_key=$(printf '%s' "$repo" | tr '/' '_')
  vis_file="$CACHE_DIR/vis_$vis_key"
  if [ -f "$vis_file" ]; then
    is_private=$(cat "$vis_file")
  else
    is_private=$(gh_with_backoff api "repos/$repo" --jq '.private' 2>/dev/null)
    printf '%s' "$is_private" > "$vis_file"
  fi
  case "$is_private" in
    true) cache_file="$CACHE_DIR/accepted_private" ;;
    *) cache_file="$CACHE_DIR/accepted_public" ;;
  esac

  if [ -f "$cache_file" ]; then
    cat "$cache_file"
    return
  fi

  hdr=$(gh_with_backoff api -i "repos/$repo/labels" | tr -d '\r')
  line=$(printf '%s\n' "$hdr" | grep -i '^X-Accepted-OAuth-Scopes:' | head -1)
  value="${line#*:}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  local accepted
  accepted=$(printf '%s' "$value" | tr ',' '\n' | while IFS= read -r s || [ -n "$s" ]; do
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    [ -n "$s" ] && printf '%s\n' "$s"
  done)

  printf '%s\n' "$accepted" > "$cache_file"
  printf '%s\n' "$accepted"
}

# can_create_labels <accepted-scopes-newline-list>
# Returns 0 if PAT_SCOPES intersects the given accepted-scopes list.
can_create_labels() {
  local accepted="$1" s
  while IFS= read -r s || [ -n "$s" ]; do
    [ -n "$s" ] || continue
    if printf '%s\n' "$PAT_SCOPES" | grep -qxF "$s"; then
      return 0
    fi
  done <<EOF
$accepted
EOF
  return 1
}

# -----------------------------------------------------------------------------
# check_labels <owner/name> <required-labels-newline-list> <create_flag 0|1>
# Warning-only. Never touches scope_gate_failed.
# -----------------------------------------------------------------------------
check_labels() {
  local repo="$1" required="$2" create_flag="$3"
  local existing label accepted

  # `gh label list` prints a TSV table (name<TAB>description<TAB>color); ask for
  # bare names one per line so the whole-line match below is correct.
  # Guard the call: on failure (repo renamed/deleted, permissions, transient
  # 5xx) gh_with_backoff returns 1 with empty stdout, and an unchecked capture
  # would report every required label as missing on this repo. Skip the repo's
  # label check instead, so one unreachable repo is one finding, not N false gaps.
  if ! existing=$(gh_with_backoff label list --repo "$repo" --json name --jq '.[].name'); then
    add_finding "LABEL WARN: could not list labels on $repo (see stderr above); skipping its label check rather than reporting every required label as missing."
    return
  fi

  while IFS= read -r label || [ -n "$label" ]; do
    [ -n "$label" ] || continue
    if printf '%s\n' "$existing" | grep -qxF "$label"; then
      continue
    fi

    accepted=$(probe_accepted_scopes "$repo")

    if can_create_labels "$accepted"; then
      if [ "$create_flag" -eq 1 ]; then
        if gh_with_backoff label create "$label" --repo "$repo" >/dev/null 2>&1; then
          add_finding "LABEL created: '$label' on $repo"
        else
          add_finding "LABEL WARN: attempted to create '$label' on $repo but the create call failed; run: gh label create \"$label\" --repo \"$repo\""
        fi
      else
        add_finding "LABEL WARN: '$label' missing on $repo. PAT can create it. Run: gh label create \"$label\" --repo \"$repo\""
      fi
    else
      add_finding "LABEL WARN: '$label' missing on $repo. This program can launch but may not be useful without it. PAT's scopes do not cover label creation on this repo. Remediate with (a) a wider-scoped PAT, or (b) create it by hand via the GitHub web UI (Settings -> Labels) for $repo."
    fi
  done <<EOF
$required
EOF
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
main() {
  local program="" create_flag=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --program)
        if [ $# -ge 2 ]; then
          program="$2"
          shift 2
        else
          echo "ERROR: --program requires a value" >&2
          return 1
        fi
        ;;
      --create-missing-labels)
        create_flag=1
        shift
        ;;
      --help)
        usage
        return 0
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        usage >&2
        return 1
        ;;
    esac
  done

  if [ -z "$program" ]; then
    echo "ERROR: --program is required" >&2
    usage >&2
    return 1
  fi

  local programs_dir program_file
  programs_dir="${REPOMAN_PROGRAMS_DIR:-$HOME/.repoman/programs}"
  program_file="$programs_dir/$program.json"

  if [ ! -f "$program_file" ]; then
    echo "ERROR: program file not found: $program_file" >&2
    return 1
  fi

  local pat_scopes labels_required
  pat_scopes=$(jq -r '.pat_scopes // [] | .[]' "$program_file")
  labels_required=$(jq -r '.labels_required // [] | .[]' "$program_file")

  check_scopes "$pat_scopes"

  local repos repo
  repos=$(repoman_get_repos) || return 1

  if [ -n "$labels_required" ]; then
    init_probe_cache
    while IFS= read -r repo || [ -n "$repo" ]; do
      [ -n "$repo" ] || continue
      check_labels "$repo" "$labels_required" "$create_flag"
    done <<EOF
$repos
EOF
    cleanup_probe_cache
  fi

  if [ -n "$findings" ]; then
    echo "== repoman-check: $program =="
    printf '%s' "$findings"
  else
    echo "== repoman-check: $program: all checks passed =="
  fi

  if [ "$scope_gate_failed" -eq 1 ]; then
    return 1
  fi
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
  exit $?
fi
