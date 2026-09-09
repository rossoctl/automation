#!/usr/bin/env bash
set -euo pipefail

# snapshot-secrets.sh -- capture host-level secret files into a single
# age-encrypted blob, <outdir>/secrets.age.
#
# Usage:
#   snapshot-secrets.sh --outdir <dir> --pubkey <age-recipient>
#
# Portability: bash 3.2+ (macOS default). No bash-4-only features.
#
# Security contract:
#   - NEVER writes plaintext to disk: tar streams straight into age via a pipe.
#   - NEVER prints file contents: the checklist lists NAMES only.
#   - The blob is encrypted to the operator's PUBLIC key; the private key stays
#     off every VM (see snapshot/README.md).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-snapshot.sh"

# Parse arguments.
OUTDIR=""
PUBKEY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --outdir)
      OUTDIR="$2"
      shift 2
      ;;
    --pubkey)
      PUBKEY="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      echo "Usage: snapshot-secrets.sh --outdir <dir> --pubkey <age-recipient>" >&2
      exit 1
      ;;
  esac
done

# Both flags are required.
if [ -z "$OUTDIR" ]; then
  echo "ERROR: --outdir is required." >&2
  exit 1
fi
if [ -z "$PUBKEY" ]; then
  echo "ERROR: --pubkey <age-recipient> is required." >&2
  exit 1
fi

# The age binary must be present (bundled binary or system age).
AGE_BIN="${AGE_BIN:-age}"
if ! command -v "$AGE_BIN" >/dev/null 2>&1; then
  echo "ERROR: age binary not found: $AGE_BIN" >&2
  echo "Bundle snapshot/bin/age or set AGE_BIN to a static age binary." >&2
  exit 1
fi

# Gather the host-level secret files that exist. Fail loud if none: an empty
# secrets bundle almost certainly means a misconfigured $SNAPSHOT_HOME, and a
# silent empty blob would be a dangerous surprise at restore time.
secret_paths=$(snapshot_secret_paths)
if [ -z "$secret_paths" ]; then
  echo "ERROR: no secret files found under ${SNAPSHOT_HOME:-$HOME}." >&2
  echo "Nothing to encrypt; refusing to write an empty secrets bundle." >&2
  exit 1
fi

mkdir -p "$OUTDIR"
BLOB="$OUTDIR/secrets.age"

# Base directory the archived paths are made relative to, so restore can extract
# them back under the target home.
base="${SNAPSHOT_HOME:-$HOME}"

# Build the tar member list as paths relative to $base (one per line).
# Using -C "$base" with relative members keeps the archive home-relative and
# avoids leading-slash absolute paths.
rel_members=()
while IFS= read -r p; do
  if [ -z "$p" ]; then
    continue
  fi
  # Strip the "$base/" prefix to get a home-relative member path.
  rel_members+=( "${p#"$base"/}" )
done <<EOF
$secret_paths
EOF

# Encrypt: tar the secret files and pipe STRAIGHT into age. No intermediate
# plaintext file ever touches disk. `set -o pipefail` makes a tar or age
# failure fail the whole pipeline.
tar -C "$base" -cf - "${rel_members[@]}" | "$AGE_BIN" -r "$PUBKEY" > "$BLOB"

# Names-only checklist (never contents), so the operator can confirm coverage.
echo "Captured secrets -> $BLOB"
echo "Included files (names only):"
while IFS= read -r p; do
  if [ -z "$p" ]; then
    continue
  fi
  echo "  - ${p#"$base"/}"
done <<EOF
$secret_paths
EOF
