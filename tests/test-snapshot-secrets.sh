#!/usr/bin/env bash
set -euo pipefail

# Verifies snapshot/snapshot-secrets.sh:
#   - encrypts the host-level secret files into <outdir>/secrets.age
#   - pipes tar straight into age (NEVER writes plaintext .tar to disk)
#   - the encrypted blob does not contain the plaintext marker
#   - prints a names-only checklist (file names, never contents)
#   - fails loud when age is missing or no secrets are found
# Hermetic: $SNAPSHOT_HOME points at a fixture tree; a fake `age` on PATH
# consumes stdin and emits only a header (it does not echo its input).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_SH="$SCRIPT_DIR/../snapshot/snapshot-secrets.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

# Fixture home with secret files whose CONTENTS carry a distinctive marker.
FAKE_HOME="$TEST_TMPDIR/home"
mkdir -p "$FAKE_HOME/.openclaw" "$FAKE_HOME/.ssh"
MARKER="PLAINTEXT_SECRET_MARKER_qqq424"
printf 'TOKEN=%s\n' "$MARKER" > "$FAKE_HOME/.openclaw/.env"
printf 'GATEWAY_ENV=%s\n' "$MARKER" > "$FAKE_HOME/.openclaw/gateway.systemd.env"
printf '//registry.npmjs.org/:_authToken=%s\n' "$MARKER" > "$FAKE_HOME/.npmrc"
printf -- '-----BEGIN KEY-----\n%s\n' "$MARKER" > "$FAKE_HOME/.ssh/id_ecdsa"

# Fake `age`: read all of stdin, discard it, and emit a fixed header only.
# This models a real recipient-encrypt: the plaintext must NOT survive to the
# output, so if the script ever echoed plaintext instead of piping through age
# the marker would appear in secrets.age and the test would catch it.
FAKE_BIN="$TEST_TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/age" <<'EOF'
#!/usr/bin/env bash
# Consume and discard stdin; require a recipient flag; emit an armored-ish header.
recipient=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -r) recipient="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -z "$recipient" ]; then
  echo "fake-age: missing -r recipient" >&2
  exit 2
fi
cat >/dev/null
printf 'age-encryption.org/v1 FAKE-HEADER recipient=%s\n' "$recipient"
EOF
chmod +x "$FAKE_BIN/age"

OUTDIR="$TEST_TMPDIR/out"
mkdir -p "$OUTDIR"
PUBKEY="age1faketestrecipientkeyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

# Run the capture with all seams pointed at the fixtures. Capture output and
# tolerate a nonzero exit here (the assertions below judge the result), so a
# missing script surfaces as a FAIL assertion rather than aborting under set -e.
checklist=$(
  SNAPSHOT_HOME="$FAKE_HOME" \
  AGE_BIN="$FAKE_BIN/age" \
  bash "$SECRETS_SH" --outdir "$OUTDIR" --pubkey "$PUBKEY" 2>&1
) || true

BLOB="$OUTDIR/secrets.age"

# secrets.age must exist.
if [ ! -f "$BLOB" ]; then
  echo "FAIL secrets: $BLOB not created"
  fail=1
fi

# CRITICAL: the plaintext marker must NOT appear in the encrypted blob.
if [ -f "$BLOB" ] && grep -Fq "$MARKER" "$BLOB"; then
  echo "FAIL secrets: plaintext marker leaked into secrets.age"
  fail=1
fi

# CRITICAL: no plaintext .tar (or .tar.gz) may be left behind anywhere in outdir.
leftover=$(find "$OUTDIR" -name '*.tar' -o -name '*.tar.gz' 2>/dev/null)
if [ -n "$leftover" ]; then
  echo "FAIL secrets: plaintext tar left on disk: $leftover"
  fail=1
fi

# The checklist must list file NAMES but never the marker (contents).
if ! printf '%s\n' "$checklist" | grep -Fq ".openclaw/.env"; then
  echo "FAIL secrets: checklist missing a captured file name"
  fail=1
fi
if printf '%s\n' "$checklist" | grep -Fq "$MARKER"; then
  echo "FAIL secrets: checklist leaked file CONTENTS"
  fail=1
fi

# Fail loud when age is missing.
if (
  SNAPSHOT_HOME="$FAKE_HOME" \
  AGE_BIN="$TEST_TMPDIR/no-such-age" \
  bash "$SECRETS_SH" --outdir "$OUTDIR" --pubkey "$PUBKEY"
) >/dev/null 2>&1; then
  echo "FAIL secrets: should fail when age binary is missing"
  fail=1
fi

# Fail loud when no secrets are found (empty home).
EMPTY_HOME="$TEST_TMPDIR/empty-home"
mkdir -p "$EMPTY_HOME"
if (
  SNAPSHOT_HOME="$EMPTY_HOME" \
  AGE_BIN="$FAKE_BIN/age" \
  bash "$SECRETS_SH" --outdir "$TEST_TMPDIR/out2" --pubkey "$PUBKEY"
) >/dev/null 2>&1; then
  echo "FAIL secrets: should fail when no secret files are found"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: snapshot-secrets (encrypt-only, no plaintext on disk, names-only checklist)"
else
  exit 1
fi
