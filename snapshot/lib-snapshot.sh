#!/usr/bin/env bash
# Shared helpers for the OpenClaw snapshot toolkit. Keeps the entry-point
# scripts (snapshot-*.sh, restore.sh) thin.
#
# Source this at the top of a snapshot script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/lib-snapshot.sh"
#
# Portability: bash 3.2+ (macOS default). No bash-4-only features.
#
# Contract: NEVER print secret file contents. snapshot_secret_paths emits
# path NAMES only; reading/encrypting the contents is snapshot-secrets.sh's job.

# Guard against double-sourcing.
if [ -n "${_LIB_SNAPSHOT_LOADED:-}" ]; then
  return 0
fi
_LIB_SNAPSHOT_LOADED=1

# Print the host-level secret files that exist, one absolute path per line.
#
# These are the secrets that must survive migration but must NEVER sit in the
# openclaw state archive: the OpenClaw env file, the gateway service env file,
# the npm registry token, stored PAT files, and the SSH private key. The base
# directory is $SNAPSHOT_HOME (default $HOME) so the allowlist can be exercised
# hermetically against a fixture tree.
#
# Absent candidates are silently skipped. Only names are printed, never the
# contents of any file. Exits 0 even when nothing matches (the caller decides
# whether an empty set is an error).
snapshot_secret_paths() {
  local base="${SNAPSHOT_HOME:-$HOME}"

  # Candidate secret files, relative to the base home directory.
  # MAINTAINERS: this array is the whole secret-capture allowlist. Nothing else
  # discovers secrets automatically -- to capture a newly added secret file, add
  # its path here, or capture will silently omit it.
  local candidates=(
    ".openclaw/.env"                 # OpenClaw runtime env (API keys, tokens)
    ".openclaw/gateway.systemd.env"  # env file the gateway systemd unit reads
    ".npmrc"                         # npm registry auth (may hold a token)
    "new_pat.txt"                    # stored GitHub PAT used by the automation
    ".ssh/id_ecdsa"                  # SSH private key for git remote access
  )

  # Emit only the candidates that actually exist as regular files.
  local rel
  for rel in "${candidates[@]}"; do
    if [ -f "$base/$rel" ]; then
      printf '%s\n' "$base/$rel"
    fi
  done
}

# Print the OpenClaw version token (e.g. "2026.5.12").
#
# `openclaw --version` prints a banner like "OpenClaw 2026.5.12 (f066dd2)";
# this extracts just the dotted version field. Returns 1 if openclaw is not
# on PATH. The binary is overridable via $OPENCLAW_BIN (default "openclaw").
read_openclaw_version() {
  local bin="${OPENCLAW_BIN:-openclaw}"

  # Fail loud when the binary is missing so callers can react.
  if ! command -v "$bin" >/dev/null 2>&1; then
    return 1
  fi

  # The version is the second whitespace-delimited field of the banner.
  "$bin" --version 2>/dev/null | awk '{ print $2; exit }'
}

# Print `node --version` verbatim (e.g. "v22.22.2").
#
# Returns 1 if node is not on PATH. The binary is overridable via $NODE_BIN
# (default "node").
read_node_version() {
  local bin="${NODE_BIN:-node}"

  # Fail loud when the binary is missing.
  if ! command -v "$bin" >/dev/null 2>&1; then
    return 1
  fi

  "$bin" --version 2>/dev/null
}
