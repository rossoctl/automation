#!/usr/bin/env bash
set -euo pipefail

# Verifies repoman_get_repos() and is_enrolled() in program-lib.sh:
#   - repoman_get_repos prints owner/name per line, in file order
#   - fails loud on missing/empty/malformed repos.json
#   - is_enrolled: exact whole-line match (no substring false positives)
# Hermetic: drives the readers via $REPOMAN_REPOS_FILE pointing at a fixture.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../scripts/program-lib.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

FIX="$SCRIPT_DIR/fixtures/repoman-repos.json"

# --- prints owner/name per line, in file order ---
got=$(REPOMAN_REPOS_FILE="$FIX" repoman_get_repos)
want=$'rossoctl/automation\nrossoctl/cortex\nalice/cortex'
[ "$got" = "$want" ] || { echo "FAIL repoman_get_repos order: got [$got]"; fail=1; }

# --- fail loud: missing file ---
if REPOMAN_REPOS_FILE="$TEST_TMPDIR/nope.json" repoman_get_repos >/dev/null 2>&1; then
  echo "FAIL should error on missing repos file"; fail=1
fi

# --- fail loud: empty array ---
echo '[]' > "$TEST_TMPDIR/empty.json"
if REPOMAN_REPOS_FILE="$TEST_TMPDIR/empty.json" repoman_get_repos >/dev/null 2>&1; then
  echo "FAIL should error on empty repos array"; fail=1
fi

# --- fail loud: entry missing name ---
echo '[{"owner": "rossoctl"}]' > "$TEST_TMPDIR/malformed.json"
if REPOMAN_REPOS_FILE="$TEST_TMPDIR/malformed.json" repoman_get_repos >/dev/null 2>&1; then
  echo "FAIL should error on entry missing name"; fail=1
fi

# --- is_enrolled: exact whole-line match ---
REPOMAN_REPOS_FILE="$FIX" is_enrolled "rossoctl/cortex" \
  || { echo "FAIL is_enrolled: rossoctl/cortex should be enrolled"; fail=1; }
REPOMAN_REPOS_FILE="$FIX" is_enrolled "alice/cortex" \
  || { echo "FAIL is_enrolled: alice/cortex should be enrolled (same name, diff owner)"; fail=1; }
if REPOMAN_REPOS_FILE="$FIX" is_enrolled "rossoctl/nope"; then
  echo "FAIL is_enrolled: rossoctl/nope should NOT match"; fail=1
fi
# Guard against substring false positives.
if REPOMAN_REPOS_FILE="$FIX" is_enrolled "rossoctl/cort"; then
  echo "FAIL is_enrolled: partial 'cort' must not match 'cortex'"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS: repoman_get_repos + is_enrolled (order, fail-loud, exact match)" || exit 1
