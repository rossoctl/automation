#!/usr/bin/env bash
set -euo pipefail

# Verifies snapshot/lib-snapshot.sh:
#   - snapshot_secret_paths() lists host-level secret files that exist under
#     $SNAPSHOT_HOME, skips absent ones, and NEVER prints file contents
#   - read_openclaw_version() prints the version token, fails if openclaw missing
#   - read_node_version() prints `node --version` verbatim
# Hermetic: $SNAPSHOT_HOME points at a temp fixture tree, and fake
# openclaw/node binaries are injected on PATH. No real host state is read.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../snapshot/lib-snapshot.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

# Build a fake home with SOME secret files present and SOME absent.
FAKE_HOME="$TEST_TMPDIR/home"
mkdir -p "$FAKE_HOME/.openclaw" "$FAKE_HOME/.ssh"

# A distinctive marker no real secret would contain; used to prove contents
# never leak into snapshot_secret_paths output.
MARKER="SECRET_CONTENT_MARKER_zzz987"
printf 'TOKEN=%s\n' "$MARKER" > "$FAKE_HOME/.openclaw/.env"
printf 'GATEWAY_ENV=%s\n' "$MARKER" > "$FAKE_HOME/.openclaw/gateway.systemd.env"
printf '//registry.npmjs.org/:_authToken=%s\n' "$MARKER" > "$FAKE_HOME/.npmrc"
printf -- '-----BEGIN KEY-----\n%s\n' "$MARKER" > "$FAKE_HOME/.ssh/id_ecdsa"
# Deliberately absent: new_pat.txt (a stored-PAT candidate). Must be SKIPPED.

# snapshot_secret_paths lists the present secret files, one per line.
got=$(SNAPSHOT_HOME="$FAKE_HOME" snapshot_secret_paths)

# Every present secret file must appear in the listing.
for want in \
  "$FAKE_HOME/.openclaw/.env" \
  "$FAKE_HOME/.openclaw/gateway.systemd.env" \
  "$FAKE_HOME/.npmrc" \
  "$FAKE_HOME/.ssh/id_ecdsa"; do
  if ! printf '%s\n' "$got" | grep -Fxq "$want"; then
    echo "FAIL secret_paths: present file not listed: $want"
    fail=1
  fi
done

# The absent candidate must not appear.
if printf '%s\n' "$got" | grep -Fq "new_pat.txt"; then
  echo "FAIL secret_paths: absent file listed"
  fail=1
fi

# CRITICAL: file contents must never be printed.
if printf '%s\n' "$got" | grep -Fq "$MARKER"; then
  echo "FAIL secret_paths: leaked file CONTENTS into output"
  fail=1
fi

# Absent-home edge: no candidates present -> empty output, exit 0.
empty=$(SNAPSHOT_HOME="$TEST_TMPDIR/nonexistent-home" snapshot_secret_paths || true)
if [ -n "$empty" ]; then
  echo "FAIL secret_paths: expected empty for absent home, got [$empty]"
  fail=1
fi

# Fake openclaw / node on PATH for the version readers.
FAKE_BIN="$TEST_TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/openclaw" <<'EOF'
#!/usr/bin/env bash
# Mimics the `openclaw --version` banner shape.
echo "OpenClaw 2026.5.12 (f066dd2)"
EOF
cat > "$FAKE_BIN/node" <<'EOF'
#!/usr/bin/env bash
echo "v22.22.2"
EOF
chmod +x "$FAKE_BIN/openclaw" "$FAKE_BIN/node"

# read_openclaw_version prints just the version token.
got=$(PATH="$FAKE_BIN:$PATH" read_openclaw_version)
if [ "$got" != "2026.5.12" ]; then
  echo "FAIL read_openclaw_version: got [$got]"
  fail=1
fi

# read_node_version prints node --version verbatim.
got=$(PATH="$FAKE_BIN:$PATH" read_node_version)
if [ "$got" != "v22.22.2" ]; then
  echo "FAIL read_node_version: got [$got]"
  fail=1
fi

# read_openclaw_version fails (nonzero) when openclaw is absent.
if ( PATH="/usr/bin:/bin"; read_openclaw_version ) >/dev/null 2>&1; then
  echo "FAIL read_openclaw_version: should fail when openclaw missing"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: lib-snapshot (secret allowlist names-only, version readers)"
else
  exit 1
fi
