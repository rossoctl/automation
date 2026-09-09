#!/usr/bin/env bash
set -euo pipefail

# Verifies snapshot/snapshot-state.sh:
#   - runs `openclaw backup create --verify --output <outdir> --json`
#   - captures the backup JSON to <outdir>/state-backup.json
#   - confirms the archive named by the JSON's archivePath exists
#   - exits non-zero when the backup command fails
# Hermetic: a fake `openclaw` on PATH (via $OPENCLAW_BIN) writes a fake archive
# and emits plausible backup JSON. No real host state is touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_SH="$SCRIPT_DIR/../snapshot/snapshot-state.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

# A fake openclaw that mimics `backup create --verify --output <dir> --json`:
# it writes a fake archive into the output dir and prints JSON whose top-level
# shape matches the Task 0 pinned contract (archivePath, verified,
# skippedVolatileCount, assets, skipped).
FAKE_BIN="$TEST_TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/openclaw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Only handle: backup create ... --output <dir> ...
outdir=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  if [ "${args[$i]}" = "--output" ]; then
    j=$((i + 1))
    outdir="${args[$j]}"
  fi
  i=$((i + 1))
done
if [ -z "$outdir" ]; then
  echo "fake-openclaw: no --output given" >&2
  exit 3
fi
mkdir -p "$outdir"
archive="$outdir/2026-01-01T00-00-00.000Z-openclaw-backup.tar.gz"
# Write a fake (non-empty) archive payload.
printf 'FAKE-ARCHIVE-BYTES' > "$archive"
# Emit JSON matching the pinned top-level shape.
cat <<JSON
{
  "createdAt": "2026-01-01T00:00:00.000Z",
  "archiveRoot": "2026-01-01T00-00-00.000Z-openclaw-backup",
  "archivePath": "$archive",
  "dryRun": false,
  "includeWorkspace": true,
  "onlyConfig": false,
  "verified": true,
  "assets": [
    { "kind": "state", "sourcePath": "/x/.openclaw", "displayPath": "~/.openclaw", "archivePath": "r/payload/x" }
  ],
  "skipped": [],
  "skippedVolatileCount": 4
}
JSON
EOF
chmod +x "$FAKE_BIN/openclaw"

OUTDIR="$TEST_TMPDIR/out"

# Success case: run the wrapper, expect state-backup.json + archive present.
# Tolerate a nonzero exit here so a missing script surfaces as a FAIL assertion
# below rather than aborting under set -e.
OPENCLAW_BIN="$FAKE_BIN/openclaw" bash "$STATE_SH" --outdir "$OUTDIR" || true

STATE_JSON="$OUTDIR/state-backup.json"

# state-backup.json must exist and be valid JSON.
if [ ! -f "$STATE_JSON" ]; then
  echo "FAIL state: $STATE_JSON not created"
  fail=1
elif ! jq empty "$STATE_JSON" 2>/dev/null; then
  echo "FAIL state: state-backup.json not valid JSON"
  fail=1
fi

# The pinned field names must be present and sensible.
if [ -f "$STATE_JSON" ]; then
  if [ "$(jq -r '.verified' "$STATE_JSON")" != "true" ]; then
    echo "FAIL state: verified not true"
    fail=1
  fi
  if [ "$(jq -r '.skippedVolatileCount' "$STATE_JSON")" != "4" ]; then
    echo "FAIL state: skippedVolatileCount not captured"
    fail=1
  fi

  # The archive named by archivePath must actually exist on disk.
  archive_path=$(jq -r '.archivePath' "$STATE_JSON")
  if [ ! -f "$archive_path" ]; then
    echo "FAIL state: archivePath does not point at an existing file: $archive_path"
    fail=1
  fi
fi

# Failure case: a fake openclaw that exits 1 -> wrapper must exit non-zero.
cat > "$FAKE_BIN/openclaw-fail" <<'EOF'
#!/usr/bin/env bash
echo '{"error":"backup failed"}' >&2
exit 1
EOF
chmod +x "$FAKE_BIN/openclaw-fail"

if OPENCLAW_BIN="$FAKE_BIN/openclaw-fail" bash "$STATE_SH" --outdir "$TEST_TMPDIR/out-fail" >/dev/null 2>&1; then
  echo "FAIL state: wrapper should exit non-zero when backup fails"
  fail=1
fi

# Missing-binary case: wrapper must fail loud.
if OPENCLAW_BIN="$TEST_TMPDIR/no-such-openclaw" bash "$STATE_SH" --outdir "$TEST_TMPDIR/out-nobin" >/dev/null 2>&1; then
  echo "FAIL state: wrapper should fail when openclaw binary is missing"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: snapshot-state (backup JSON captured, archive verified, failure propagated)"
else
  exit 1
fi
