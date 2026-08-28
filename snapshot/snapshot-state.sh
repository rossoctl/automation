#!/usr/bin/env bash
set -euo pipefail

# snapshot-state.sh -- guarded wrapper around the first-class OpenClaw backup.
# Runs `openclaw backup create --verify --output <outdir> --json`, captures the
# JSON result to <outdir>/state-backup.json, and confirms the written archive
# exists. Do NOT hand-roll a tar of ~/.openclaw; the backup command owns that.
#
# Usage:
#   snapshot-state.sh --outdir <dir>
#
# Portability: bash 3.2+ (macOS default). No bash-4-only features.
#
# Backup JSON contract (pinned in Task 0 / snapshot/README.md, OpenClaw 2026.5.12):
# top-level fields include createdAt, archiveRoot, archivePath (absolute path to
# the written .tar.gz), dryRun, includeWorkspace, onlyConfig, verified,
# assets[], skipped[], skippedVolatileCount.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
      echo "Usage: snapshot-state.sh --outdir <dir>" >&2
      exit 1
      ;;
  esac
done

# --outdir is required.
if [ -z "$OUTDIR" ]; then
  echo "ERROR: --outdir is required." >&2
  exit 1
fi

# The openclaw binary must be present.
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
if ! command -v "$OPENCLAW_BIN" >/dev/null 2>&1; then
  echo "ERROR: openclaw binary not found: $OPENCLAW_BIN" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
STATE_JSON="$OUTDIR/state-backup.json"

# Run the backup. --verify validates the archive right after writing it, so
# corruption is caught while re-capture is still cheap. --json gives us the
# machine-readable result we tee to state-backup.json. If the command fails,
# propagate the failure explicitly rather than leaving a half-written JSON.
if ! "$OPENCLAW_BIN" backup create --verify --output "$OUTDIR" --json > "$STATE_JSON"; then
  echo "ERROR: 'openclaw backup create' failed; see $STATE_JSON" >&2
  exit 1
fi

# The captured result must be valid JSON.
if ! jq empty "$STATE_JSON" >/dev/null 2>&1; then
  echo "ERROR: backup result is not valid JSON: $STATE_JSON" >&2
  exit 1
fi

# Confirm the archive the backup claims it wrote actually exists on disk.
archive_path=$(jq -r '.archivePath // empty' "$STATE_JSON")
if [ -z "$archive_path" ] || [ ! -f "$archive_path" ]; then
  echo "ERROR: backup archive missing (archivePath=$archive_path)" >&2
  exit 1
fi

# Confirm the archive was verified (we asked for --verify).
verified=$(jq -r '.verified // false' "$STATE_JSON")
if [ "$verified" != "true" ]; then
  echo "WARNING: backup reports verified=$verified; archive may not be validated." >&2
fi

skipped_volatile=$(jq -r '.skippedVolatileCount // 0' "$STATE_JSON")
echo "State backup written: $archive_path"
echo "  result JSON: $STATE_JSON"
echo "  verified: $verified, volatile paths skipped: $skipped_volatile"
