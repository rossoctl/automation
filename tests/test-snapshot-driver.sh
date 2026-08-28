#!/usr/bin/env bash
set -euo pipefail

# Verifies snapshot/snapshot.sh (top-level capture driver):
#   - creates a dated output dir openclaw-snapshot-<DATE> under --output
#   - runs the three capture commands into that dir
#   - copies the age binary in alongside the artifacts
#   - refuses to overwrite an existing dated dir (second run exits non-zero)
#   - fails loud on missing --output/--pubkey
# Hermetic: the three capture commands and the age source are stubbed via the
# documented seams ($SNAPSHOT_{STATE,SECRETS,MANIFEST}_CMD, $AGE_BIN_SRC), and
# $SNAPSHOT_DATE pins the date so the dir name is deterministic. No real host
# state, no network, no real openclaw/age.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER_SH="$SCRIPT_DIR/../snapshot/snapshot.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

# A fake age binary source: the driver should copy this into the snapshot dir
# so the operator can decrypt on a machine without age installed.
AGE_SRC="$TEST_TMPDIR/age-src"
printf '#!/usr/bin/env bash\necho fake-age\n' > "$AGE_SRC"
chmod +x "$AGE_SRC"

# Stub capture commands. Each records that it ran (into a marker file keyed by
# name) and drops a token artifact into the --outdir it was handed, so we can
# assert the driver invoked all three against the same dated dir.
STUB_BIN="$TEST_TMPDIR/stubs"
mkdir -p "$STUB_BIN"

# state stub: takes --outdir <dir>
cat > "$STUB_BIN/state" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
outdir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --outdir) outdir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'ran\n' > "$outdir/.state-ran"
EOF

# manifest stub: takes --outdir <dir>
cat > "$STUB_BIN/manifest" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
outdir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --outdir) outdir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'ran\n' > "$outdir/.manifest-ran"
EOF

# secrets stub: takes --outdir <dir> --pubkey <recipient>; records the pubkey it
# was handed so we can assert the driver forwards --pubkey through.
cat > "$STUB_BIN/secrets" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
outdir=""
pubkey=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --outdir) outdir="$2"; shift 2 ;;
    --pubkey) pubkey="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$pubkey" > "$outdir/.secrets-pubkey"
EOF

chmod +x "$STUB_BIN/state" "$STUB_BIN/manifest" "$STUB_BIN/secrets"

OUTPUT="$TEST_TMPDIR/snapshots"
PUBKEY="age1faketestrecipientkeyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
DATE="2026-01-02"
EXPECTED_DIR="$OUTPUT/openclaw-snapshot-$DATE"

run_driver() {
  SNAPSHOT_DATE="$DATE" \
  SNAPSHOT_STATE_CMD="$STUB_BIN/state" \
  SNAPSHOT_MANIFEST_CMD="$STUB_BIN/manifest" \
  SNAPSHOT_SECRETS_CMD="$STUB_BIN/secrets" \
  AGE_BIN_SRC="$AGE_SRC" \
  bash "$DRIVER_SH" --output "$OUTPUT" --pubkey "$PUBKEY"
}

# First run: tolerate a nonzero exit so a missing script surfaces as a FAIL
# assertion below rather than aborting under set -e.
run_driver || true

# The dated dir must exist.
if [ ! -d "$EXPECTED_DIR" ]; then
  echo "FAIL driver: dated dir not created: $EXPECTED_DIR"
  fail=1
fi

# All three capture commands must have run into the dated dir.
if [ ! -f "$EXPECTED_DIR/.state-ran" ]; then
  echo "FAIL driver: state capture did not run into the dated dir"
  fail=1
fi
if [ ! -f "$EXPECTED_DIR/.manifest-ran" ]; then
  echo "FAIL driver: manifest capture did not run into the dated dir"
  fail=1
fi
if [ ! -f "$EXPECTED_DIR/.secrets-ran" ] && [ ! -f "$EXPECTED_DIR/.secrets-pubkey" ]; then
  echo "FAIL driver: secrets capture did not run into the dated dir"
  fail=1
fi

# The driver must forward --pubkey to the secrets command verbatim.
if [ -f "$EXPECTED_DIR/.secrets-pubkey" ]; then
  got_pubkey=$(cat "$EXPECTED_DIR/.secrets-pubkey")
  if [ "$got_pubkey" != "$PUBKEY" ]; then
    echo "FAIL driver: secrets pubkey not forwarded (got [$got_pubkey])"
    fail=1
  fi
fi

# The age binary must be copied into the dated dir and remain executable.
if [ ! -x "$EXPECTED_DIR/age" ]; then
  echo "FAIL driver: age binary not copied into the snapshot dir (or not executable)"
  fail=1
fi

# Second run against the same date must REFUSE to overwrite (non-zero).
if run_driver >/dev/null 2>&1; then
  echo "FAIL driver: second run should refuse to overwrite existing dated dir"
  fail=1
fi

# Missing --output must fail loud.
if (
  SNAPSHOT_DATE="$DATE" \
  AGE_BIN_SRC="$AGE_SRC" \
  bash "$DRIVER_SH" --pubkey "$PUBKEY"
) >/dev/null 2>&1; then
  echo "FAIL driver: should fail when --output is missing"
  fail=1
fi

# Missing --pubkey must fail loud.
if (
  SNAPSHOT_DATE="$DATE" \
  AGE_BIN_SRC="$AGE_SRC" \
  bash "$DRIVER_SH" --output "$TEST_TMPDIR/snapshots2"
) >/dev/null 2>&1; then
  echo "FAIL driver: should fail when --pubkey is missing"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: snapshot-driver (dated dir, three captures, age copied, no-overwrite)"
else
  exit 1
fi
