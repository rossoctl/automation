#!/usr/bin/env bash
set -euo pipefail

# snapshot.sh -- top-level capture driver. Creates one dated snapshot directory
# and runs the three capture scripts into it, then copies the age binary in so
# the bundle is self-contained for decrypt/restore on a fresh VM:
#
#   openclaw-snapshot-<DATE>/
#     state-backup.json + *-openclaw-backup.tar.gz  (snapshot-state.sh)
#     secrets.age                                    (snapshot-secrets.sh)
#     manifest.json + RUNBOOK.md                     (snapshot-manifest.sh)
#     age                                            (bundled binary)
#
# Usage:
#   snapshot.sh --output <base-dir> --pubkey <age-recipient>
#
# Portability: bash 3.2+ (macOS default). No bash-4-only features.
#
# Test seams (env overrides, all optional):
#   SNAPSHOT_DATE          date stamp for the dir name    (default: date +%F)
#   SNAPSHOT_STATE_CMD     state capture command          (default: sibling script)
#   SNAPSHOT_SECRETS_CMD   secrets capture command        (default: sibling script)
#   SNAPSHOT_MANIFEST_CMD  manifest capture command       (default: sibling script)
#   AGE_BIN_SRC            age binary to copy in           (default: snapshot/bin/age)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments.
OUTPUT=""
PUBKEY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    --pubkey)
      PUBKEY="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Usage: snapshot.sh --output <base-dir> --pubkey <age-recipient>" >&2
      exit 1
      ;;
  esac
done

# Both flags are required.
if [ -z "$OUTPUT" ]; then
  echo "ERROR: --output <base-dir> is required." >&2
  exit 1
fi
if [ -z "$PUBKEY" ]; then
  echo "ERROR: --pubkey <age-recipient> is required." >&2
  exit 1
fi

# Resolve the capture commands. Default to the sibling scripts; tests override
# these to hermetic stubs.
STATE_CMD="${SNAPSHOT_STATE_CMD:-$SCRIPT_DIR/snapshot-state.sh}"
SECRETS_CMD="${SNAPSHOT_SECRETS_CMD:-$SCRIPT_DIR/snapshot-secrets.sh}"
MANIFEST_CMD="${SNAPSHOT_MANIFEST_CMD:-$SCRIPT_DIR/snapshot-manifest.sh}"

# Resolve the age binary to bundle. Default to the checked-in static binary.
AGE_BIN_SRC="${AGE_BIN_SRC:-$SCRIPT_DIR/bin/age}"

# Compute the dated snapshot directory. SNAPSHOT_DATE is a test seam; in
# production the date comes from `date +%F` (YYYY-MM-DD).
SNAPSHOT_DATE="${SNAPSHOT_DATE:-$(date +%F)}"
SNAP_DIR="$OUTPUT/openclaw-snapshot-$SNAPSHOT_DATE"

# Refuse to overwrite an existing dated dir: a snapshot is a point-in-time
# artifact and silently clobbering one could destroy the only good capture.
if [ -e "$SNAP_DIR" ]; then
  echo "ERROR: snapshot dir already exists: $SNAP_DIR" >&2
  echo "Refusing to overwrite. Remove it or wait for a new date." >&2
  exit 1
fi

mkdir -p "$SNAP_DIR"

# Invoke the sibling capture scripts through `bash` rather than executing them
# directly. They are bash scripts with a bash shebang, so this is equivalent --
# but it does NOT depend on the execute bit surviving. A fresh `git clone`, or a
# tarball repacked without preserving mode, can land these scripts as mode 0644;
# invoking `"$CMD"` there fails with "Permission denied", while `bash "$CMD"`
# works regardless. (Test seams may still point at executable stubs; bash runs
# those fine too.)
run_capture() {
  bash "$@"
}

# Capture runtime facts + per-repo git state (manifest.json + RUNBOOK.md).
echo "==> manifest"
run_capture "$MANIFEST_CMD" --outdir "$SNAP_DIR"

# Capture the authoritative OpenClaw state via the first-class backup.
echo "==> state"
run_capture "$STATE_CMD" --outdir "$SNAP_DIR"

# Capture host secrets into a single age-encrypted blob.
echo "==> secrets"
run_capture "$SECRETS_CMD" --outdir "$SNAP_DIR" --pubkey "$PUBKEY"

# Bundle the age binary so decrypt/restore works on a VM without age installed.
# Only warn (do not fail) if the source is absent: the state + manifest are
# still valuable, and the operator may supply age out of band.
if [ -f "$AGE_BIN_SRC" ]; then
  cp "$AGE_BIN_SRC" "$SNAP_DIR/age"
  chmod +x "$SNAP_DIR/age"
else
  echo "WARNING: age binary not found at $AGE_BIN_SRC; not bundled." >&2
  echo "         Supply an age binary manually before restoring secrets.age." >&2
fi

echo "Snapshot written: $SNAP_DIR"
