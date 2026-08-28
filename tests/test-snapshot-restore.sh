#!/usr/bin/env bash
set -euo pipefail

# Verifies snapshot/restore.sh --dry-run (the testable unit):
#   - prints an ordered plan derived from manifest.json + the org profile
#   - clones each repo from its RECORDED origin (not a re-derived $ORG/<name>)
#   - falls back to $ORG/<name> ONLY when a repo has no recorded origin
#   - names the captured OpenClaw version, a `checkout <branch>`, the service
#     unit, extract + `openclaw backup verify` (NOT a `backup restore` subcommand)
#   - creates NOTHING under REPOS_DIR (dry-run mutates nothing)
# Hermetic: hand-authored manifest.json + empty state/secrets files, a fake org
# profile via $ORG_PROFILE_FILE/$CORE_REPOS_FILE, a temp REPOS_DIR. No network,
# no real host, no real openclaw/age/git clone.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTORE_SH="$SCRIPT_DIR/../snapshot/restore.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

# Fake org profile: ORG=acme (used for the empty-origin fallback only).
cat > "$TEST_TMPDIR/org.env" <<'EOF'
PROFILE_ORG=acme
PROFILE_FORK_OWNER=acmefork
PROFILE_REMAP=""
EOF

# Core repo allowlist (matches the manifest's repo names).
cat > "$TEST_TMPDIR/core.txt" <<'EOF'
tool-one
tool-two
EOF

REPOS_DIR="$TEST_TMPDIR/repos"
mkdir -p "$REPOS_DIR"

# The snapshot dir being restored FROM.
SNAP="$TEST_TMPDIR/snap"
mkdir -p "$SNAP"

# Hand-authored manifest:
#   tool-one -> recorded origin owned by someone else, on feat/x
#   tool-two -> NO recorded origin (empty) -> must use the $ORG fallback
NONACME_ORIGIN="git@github.com:someone-else/tool-one.git"
cat > "$SNAP/manifest.json" <<EOF
{
  "openclawVersion": "2026.5.12",
  "nodeVersion": "v22.22.2",
  "gatewayPort": 18789,
  "serviceUnit": "openclaw-gateway.service",
  "repos": [
    { "name": "tool-one", "origin": "$NONACME_ORIGIN", "branch": "feat/x", "dirty": true,  "unpushed": false },
    { "name": "tool-two", "origin": "",                 "branch": "main",   "dirty": false, "unpushed": false }
  ]
}
EOF

# Empty state + secrets artifacts (the planner only references them by name).
: > "$SNAP/state.tar.gz"
: > "$SNAP/secrets.age"

# Run the dry-run planner; capture the plan. Tolerate a nonzero exit so a
# missing script surfaces as a FAIL assertion rather than aborting under set -e.
plan=$(
  ORG_PROFILE_FILE="$TEST_TMPDIR/org.env" \
  CORE_REPOS_FILE="$TEST_TMPDIR/core.txt" \
  REPOS_DIR="$REPOS_DIR" \
  bash "$RESTORE_SH" --from "$SNAP" --dry-run 2>&1
) || true

# The captured OpenClaw version must appear.
if ! printf '%s\n' "$plan" | grep -Fq "2026.5.12"; then
  echo "FAIL restore: plan does not name the captured OpenClaw version"
  fail=1
fi

# tool-one must clone from its RECORDED origin, not acme/tool-one.
if ! printf '%s\n' "$plan" | grep -Fq "$NONACME_ORIGIN"; then
  echo "FAIL restore: tool-one not cloned from its recorded origin"
  fail=1
fi
if printf '%s\n' "$plan" | grep -Eq 'acme[:/]tool-one'; then
  echo "FAIL restore: tool-one wrongly cloned from an \$ORG-derived URL"
  fail=1
fi

# tool-two has no recorded origin -> must fall back to the $ORG namespace.
if ! printf '%s\n' "$plan" | grep -Eq 'acme[:/]tool-two'; then
  echo "FAIL restore: tool-two not cloned from the \$ORG fallback (acme/tool-two)"
  fail=1
fi

# The recorded branch must be checked out.
if ! printf '%s\n' "$plan" | grep -Fq "feat/x"; then
  echo "FAIL restore: plan does not checkout the recorded branch feat/x"
  fail=1
fi

# The service unit must be named.
if ! printf '%s\n' "$plan" | grep -Fq "openclaw-gateway.service"; then
  echo "FAIL restore: plan does not name the service unit"
  fail=1
fi

# State restore = verify, NOT a `backup restore` subcommand (pinned in Task 0).
if ! printf '%s\n' "$plan" | grep -Fq "backup verify"; then
  echo "FAIL restore: plan does not include an 'openclaw backup verify' step"
  fail=1
fi
if printf '%s\n' "$plan" | grep -Fq "backup restore"; then
  echo "FAIL restore: plan uses a non-existent 'backup restore' subcommand"
  fail=1
fi

# Dry-run must mutate NOTHING under REPOS_DIR.
leftover=$(find "$REPOS_DIR" -mindepth 1 2>/dev/null)
if [ -n "$leftover" ]; then
  echo "FAIL restore: dry-run created something under REPOS_DIR: $leftover"
  fail=1
fi

# Missing --from must fail loud.
if (
  ORG_PROFILE_FILE="$TEST_TMPDIR/org.env" \
  CORE_REPOS_FILE="$TEST_TMPDIR/core.txt" \
  REPOS_DIR="$REPOS_DIR" \
  bash "$RESTORE_SH" --dry-run
) >/dev/null 2>&1; then
  echo "FAIL restore: should fail when --from is missing"
  fail=1
fi

# A --from dir without a manifest must fail loud.
EMPTY_SNAP="$TEST_TMPDIR/empty-snap"
mkdir -p "$EMPTY_SNAP"
if (
  ORG_PROFILE_FILE="$TEST_TMPDIR/org.env" \
  CORE_REPOS_FILE="$TEST_TMPDIR/core.txt" \
  REPOS_DIR="$REPOS_DIR" \
  bash "$RESTORE_SH" --from "$EMPTY_SNAP" --dry-run
) >/dev/null 2>&1; then
  echo "FAIL restore: should fail when the snapshot has no manifest.json"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: snapshot-restore (dry-run plan: recorded-origin clone, \$ORG fallback, verify-not-restore)"
else
  exit 1
fi
