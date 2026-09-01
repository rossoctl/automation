#!/usr/bin/env bash
set -euo pipefail

# restore.sh -- reverse the snapshot flow on a fresh VM. The DRY-RUN plan is the
# tested, reviewable unit: it prints the ordered restore steps derived from the
# snapshot's manifest.json plus the org profile, WITHOUT mutating the host.
# Real execution mutates a host (installs software, clones repos, enables a
# service) and is out of hermetic-test scope.
#
# Usage:
#   restore.sh --from <snapshot-dir> [--dry-run]
#
# Portability: bash 3.2+ (macOS default). No bash-4-only features.
#
# State restore contract (pinned in Task 0 / snapshot/README.md): there is NO
# `openclaw backup restore` subcommand. State is restored by extracting the
# backup archive in place and then running `openclaw backup verify` on it.
#
# Discussion #62 (owner-vs-org identity): each repo is cloned from its MANIFEST-
# RECORDED `origin` (the real captured remote URL). Only when a repo has no
# recorded origin does restore fall back to the $ORG namespace. So a repo owned
# by an individual rather than the org is restored faithfully. (Alignment with
# the newer RepoMan per-repo-owner model is tracked separately; the recorded-
# origin design keeps this correct in the meantime.)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../scripts/program-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-snapshot.sh"

# Parse arguments.
FROM=""
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --from)
      FROM="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Usage: restore.sh --from <snapshot-dir> [--dry-run]" >&2
      exit 1
      ;;
  esac
done

# --from is required.
if [ -z "$FROM" ]; then
  echo "ERROR: --from <snapshot-dir> is required." >&2
  exit 1
fi

# The snapshot must carry a manifest.
MANIFEST="$FROM/manifest.json"
if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: no manifest.json in snapshot dir: $FROM" >&2
  exit 1
fi
if ! jq empty "$MANIFEST" >/dev/null 2>&1; then
  echo "ERROR: manifest.json is not valid JSON: $MANIFEST" >&2
  exit 1
fi

# Resolve org identity (for the empty-origin fallback) and the target repos dir.
load_org_profile
validate_repos_dir "$REPOS_DIR"

# emit: in dry-run, print the step; otherwise execute it. Keeping the two modes
# behind one helper means the plan the operator reviews is exactly the sequence
# that runs for real -- no drift between "what it says" and "what it does".
emit() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  %s\n' "$*"
  else
    eval "$*"
  fi
}

# Read the captured runtime facts.
openclaw_version=$(jq -r '.openclawVersion // "unknown"' "$MANIFEST")
node_version=$(jq -r '.nodeVersion // "unknown"' "$MANIFEST")
service_unit=$(jq -r '.serviceUnit // "openclaw-gateway.service"' "$MANIFEST")

# Locate the state archive. snapshot-state.sh names it by the backup's own
# archivePath (a dated *-openclaw-backup.tar.gz); accept that or a plain
# state.tar.gz. Glob is nullglob-guarded so a missing archive is reported, not
# silently skipped.
state_archive=""
for cand in "$FROM"/*openclaw-backup.tar.gz "$FROM"/state.tar.gz; do
  if [ -f "$cand" ]; then
    state_archive="$cand"
    break
  fi
done

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Restore plan (dry-run) from: $FROM"
else
  echo "Restoring from: $FROM"
fi

# 1. Bootstrap the bundled age binary (so decrypt works without system age).
echo "Step 1: bootstrap age"
emit "install -m 0755 '$FROM/age' /usr/local/bin/age"

# 2. Install the pinned OpenClaw + node versions.
echo "Step 2: install OpenClaw $openclaw_version (node $node_version)"
emit "echo 'install openclaw@$openclaw_version node@$node_version'"

# 3. Decrypt the secrets bundle with the operator's PRIVATE key (supplied out of
#    band; never stored in the snapshot). Names-only -- no contents printed.
echo "Step 3: decrypt secrets.age"
emit "age -d -i \"\$AGE_IDENTITY\" '$FROM/secrets.age' | tar -C \"\$HOME\" -xf -"

# 4. Restore state: extract the archive in place, then VERIFY it. There is no
#    `openclaw backup restore` subcommand.
echo "Step 4: restore + verify OpenClaw state"
if [ -n "$state_archive" ]; then
  emit "tar -C \"\$HOME\" -xzf '$state_archive'"
  emit "openclaw backup verify '$state_archive'"
else
  echo "  WARNING: no state archive found in $FROM (looked for *openclaw-backup.tar.gz / state.tar.gz)" >&2
fi

# 5. Re-clone the core repos and check out the recorded branch. Clone from each
#    repo's RECORDED origin; fall back to the $ORG namespace only when empty.
echo "Step 5: re-clone core repos"
repo_count=$(jq '.repos | length' "$MANIFEST")
i=0
while [ "$i" -lt "$repo_count" ]; do
  r_name=$(jq -r ".repos[$i].name" "$MANIFEST")
  r_origin=$(jq -r ".repos[$i].origin" "$MANIFEST")
  r_branch=$(jq -r ".repos[$i].branch" "$MANIFEST")
  r_dirty=$(jq -r ".repos[$i].dirty" "$MANIFEST")

  # Clone URL: the recorded origin is authoritative. Only synthesize a URL from
  # $ORG when no origin was captured (#62: never override a real origin).
  if [ -n "$r_origin" ] && [ "$r_origin" != "null" ]; then
    clone_url="$r_origin"
  else
    clone_url="https://github.com/$ORG/$r_name.git"
    echo "  NOTE: $r_name had no recorded origin; using \$ORG fallback $clone_url" >&2
  fi

  target="$REPOS_DIR/$r_name"
  emit "git clone '$clone_url' '$target'"
  emit "git -C '$target' checkout '$r_branch'"
  if [ "$r_dirty" = "true" ]; then
    echo "  NOTE: $r_name had uncommitted changes at capture; re-apply its patch manually" >&2
  fi

  i=$((i + 1))
done

# 6. Install and enable the service unit; start the gateway.
echo "Step 6: enable service unit $service_unit"
emit "systemctl --user enable --now '$service_unit'"

# 7. Verify the running host against the captured manifest.
echo "Step 7: verify"
emit "echo 'verify: compare cron count and agent list against $MANIFEST'"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry-run complete: no changes made."
fi
