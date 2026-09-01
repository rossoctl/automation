#!/usr/bin/env bash
set -euo pipefail

# snapshot-manifest.sh -- read-only introspection that records the facts needed
# to reconstruct the host on a fresh VM. Writes:
#   <outdir>/manifest.json  -- runtime facts + per-core-repo git state
#   <outdir>/RUNBOOK.md      -- human-readable restore steps, from the manifest
#
# Usage:
#   snapshot-manifest.sh --outdir <dir>
#
# Portability: bash 3.2+ (macOS default). No bash-4-only features.
#
# Read-only: this script never mutates host state and never prints or records
# secret file contents.
#
# Discussion #62 (owner-vs-org identity): each repo's `origin` is read from the
# clone's REAL `git remote get-url origin`, never rebuilt as "$ORG/<name>". The
# origin is the authoritative clone identity; the bare name is only a locator.
# So a repo owned by an individual rather than the org is captured faithfully,
# and the manifest stays correct whether or not core-repos.txt later grows from
# bare names to full OWNER/repo slugs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../scripts/program-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-snapshot.sh"

# Parse arguments.
OUTDIR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --outdir)
      OUTDIR="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Usage: snapshot-manifest.sh --outdir <dir>" >&2
      exit 1
      ;;
  esac
done

# --outdir is required.
if [ -z "$OUTDIR" ]; then
  echo "ERROR: --outdir is required." >&2
  exit 1
fi

# Resolve org identity and validate the repos directory before touching clones.
load_org_profile
validate_repos_dir "$REPOS_DIR"

mkdir -p "$OUTDIR"

# Runtime facts. Versions come from the Task 1 readers; port and unit are read
# from the environment so the caller (or a test) can supply them. On the real
# host the driver populates them from the running systemd user unit.
openclaw_version=$(read_openclaw_version || echo "unknown")
node_version=$(read_node_version || echo "unknown")
gateway_port="${GATEWAY_PORT:-18789}"
service_unit="${SERVICE_UNIT:-openclaw-gateway.service}"

# Collect per-repo git state into a JSON array, one object per core repo that
# exists as a clone under $REPOS_DIR. Absent clones are skipped.
repos_json="[]"
while IFS= read -r name; do
  # Skip blank lines defensively.
  if [ -z "$name" ]; then
    continue
  fi

  repo_dir="$REPOS_DIR/$name"

  # Only record repos that are actually cloned locally.
  if [ ! -d "$repo_dir/.git" ]; then
    continue
  fi

  # origin: the REAL remote URL, or empty when the clone has no origin.
  # (#62: never reconstruct this from $ORG.)
  origin=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || echo "")

  # branch: the checked-out branch name (or a detached-HEAD marker).
  branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

  # dirty: true when the working tree has uncommitted changes.
  if [ -n "$(git -C "$repo_dir" status --porcelain 2>/dev/null)" ]; then
    dirty="true"
  else
    dirty="false"
  fi

  # unpushed: true when HEAD has commits not present on its upstream. When no
  # upstream is configured we cannot compare, so report false (nothing to push
  # to a known remote); the dirty flag and origin still carry the local state.
  unpushed="false"
  if git -C "$repo_dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
    ahead=$(git -C "$repo_dir" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo "0")
    if [ "$ahead" != "0" ]; then
      unpushed="true"
    fi
  fi

  # Append this repo as a JSON object. jq handles all string escaping.
  repo_obj=$(jq -n \
    --arg name "$name" \
    --arg origin "$origin" \
    --arg branch "$branch" \
    --argjson dirty "$dirty" \
    --argjson unpushed "$unpushed" \
    '{name: $name, origin: $origin, branch: $branch, dirty: $dirty, unpushed: $unpushed}')
  repos_json=$(printf '%s\n' "$repos_json" | jq --argjson obj "$repo_obj" '. + [$obj]')
done <<EOF
$(core_repo_names)
EOF

# Assemble the manifest.
jq -n \
  --arg openclawVersion "$openclaw_version" \
  --arg nodeVersion "$node_version" \
  --argjson gatewayPort "$gateway_port" \
  --arg serviceUnit "$service_unit" \
  --argjson repos "$repos_json" \
  '{
    openclawVersion: $openclawVersion,
    nodeVersion: $nodeVersion,
    gatewayPort: $gatewayPort,
    serviceUnit: $serviceUnit,
    repos: $repos
  }' > "$OUTDIR/manifest.json"

# Generate the human runbook from the manifest just written.
runbook="$OUTDIR/RUNBOOK.md"
{
  echo "# OpenClaw Restore Runbook"
  echo
  echo "Generated from manifest.json. Follow the steps in order; stop on the first failure."
  echo
  echo "## Captured runtime"
  echo
  echo "- OpenClaw version: \`$openclaw_version\`"
  echo "- node version: \`$node_version\`"
  echo "- Gateway port: \`$gateway_port\`"
  echo "- Service unit: \`$service_unit\`"
  echo
  echo "## Restore order"
  echo
  echo "1. Bootstrap the bundled \`age\` binary."
  echo "2. Install OpenClaw pinned to \`$openclaw_version\` and node \`$node_version\`."
  echo "3. Decrypt \`secrets.age\` with the operator's private key and place the secret files."
  echo "4. Extract \`state.tar.gz\` in place, then run \`openclaw backup verify\` on it."
  echo "5. Re-clone the core repos below, checkout each recorded branch, re-apply any dirty diff."
  echo "6. Install and enable the service unit; start the gateway."
  echo "7. Verify (cron count and agent list vs. this manifest)."
  echo
  echo "## Core repos"
  echo
} > "$runbook"

# One runbook line per repo, built in plain shell (readable, and the origin
# fallback text is easier to get right here than inside a jq interpolation).
# Iterate by index and pull each field with its own jq call: this sidesteps the
# TSV pitfall where bash `read` collapses the empty-origin field (a tab is an
# IFS-whitespace char, so consecutive tabs merge and shift the columns).
repo_count=$(jq '.repos | length' "$OUTDIR/manifest.json")
i=0
while [ "$i" -lt "$repo_count" ]; do
  r_name=$(jq -r ".repos[$i].name" "$OUTDIR/manifest.json")
  r_origin=$(jq -r ".repos[$i].origin" "$OUTDIR/manifest.json")
  r_branch=$(jq -r ".repos[$i].branch" "$OUTDIR/manifest.json")
  r_dirty=$(jq -r ".repos[$i].dirty" "$OUTDIR/manifest.json")
  r_unpushed=$(jq -r ".repos[$i].unpushed" "$OUTDIR/manifest.json")

  # Clone target: the recorded origin, or a fallback note when none was captured.
  if [ -n "$r_origin" ]; then
    clone_target="clone \`$r_origin\`"
  else
    clone_target="clone (no origin recorded; fall back to \$ORG/$r_name)"
  fi

  line="- \`$r_name\` -> $clone_target, checkout \`$r_branch\`"
  if [ "$r_dirty" = "true" ]; then
    line="$line (had uncommitted changes -- see patch)"
  fi
  if [ "$r_unpushed" = "true" ]; then
    line="$line (had UNPUSHED commits -- verify remote)"
  fi

  echo "$line" >> "$runbook"
  i=$((i + 1))
done

echo "Wrote $OUTDIR/manifest.json and $runbook"
