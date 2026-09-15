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

# --- repoman_load_enrolled: yields the same set as repoman_get_repos ---
# Callers load the enrolled set ONCE into a variable before a clone loop, then
# check membership in-memory (is_enrolled_in) instead of re-parsing repos.json
# on every iteration.
loaded=$(REPOMAN_REPOS_FILE="$FIX" repoman_load_enrolled)
[ "$loaded" = "$want" ] \
  || { echo "FAIL repoman_load_enrolled: got [$loaded] want [$want]"; fail=1; }

# --- repoman_load_enrolled: fails loud like repoman_get_repos ---
if REPOMAN_REPOS_FILE="$TEST_TMPDIR/empty.json" repoman_load_enrolled >/dev/null 2>&1; then
  echo "FAIL repoman_load_enrolled should error on empty repos array"; fail=1
fi

# --- is_enrolled_in: exact whole-line match against a preloaded set string ---
is_enrolled_in "rossoctl/cortex" "$loaded" \
  || { echo "FAIL is_enrolled_in: rossoctl/cortex should be enrolled"; fail=1; }
is_enrolled_in "alice/cortex" "$loaded" \
  || { echo "FAIL is_enrolled_in: alice/cortex should be enrolled (same name, diff owner)"; fail=1; }
if is_enrolled_in "rossoctl/nope" "$loaded"; then
  echo "FAIL is_enrolled_in: rossoctl/nope should NOT match"; fail=1
fi
# Guard against substring false positives.
if is_enrolled_in "rossoctl/cort" "$loaded"; then
  echo "FAIL is_enrolled_in: partial 'cort' must not match 'cortex'"; fail=1
fi
# Empty set string matches nothing (never a silent all-pass).
if is_enrolled_in "rossoctl/cortex" ""; then
  echo "FAIL is_enrolled_in: empty set must match nothing"; fail=1
fi

# --- enrolled_clone_dirs: enrollment-driven, owner-namespaced, .github-safe ---
# The scanners/fixers no longer glob "$REPOS_DIR"/*/ and filter (that silently
# dropped ".github", which bash excludes from a "*/" glob without dotglob).
# enrolled_clone_dirs drives the loop from the enrolled set instead: for each
# "owner/name" in the set, it emits that line iff "$REPOS_DIR/owner/name/.git"
# exists. Enrollment is authoritative; a leading-dot repo name is just a string.
CLONE_ROOT=$(mktemp -d)
# Enrolled AND cloned -- including a ".github" repo, the regression this guards.
mkdir -p "$CLONE_ROOT/rossoctl/automation/.git"
mkdir -p "$CLONE_ROOT/rossoctl/.github/.git"
mkdir -p "$CLONE_ROOT/alice/cortex/.git"
# Enrolled but NOT cloned (no .git): must be skipped, not emitted.
mkdir -p "$CLONE_ROOT/rossoctl/cortex"
# Cloned but NOT enrolled: must be skipped.
mkdir -p "$CLONE_ROOT/bob/tool/.git"

CLONE_ENROLLED=$'rossoctl/automation\nrossoctl/.github\nrossoctl/cortex\nalice/cortex'

clones=$(REPOS_DIR="$CLONE_ROOT" enrolled_clone_dirs "$CLONE_ENROLLED")
clone_want=$'rossoctl/automation\nrossoctl/.github\nalice/cortex'
[ "$clones" = "$clone_want" ] \
  || { echo "FAIL enrolled_clone_dirs: got [$clones] want [$clone_want]"; fail=1; }

# Explicit .github guard: it must appear (the whole point of the blocking fix).
printf '%s\n' "$clones" | grep -qxF "rossoctl/.github" \
  || { echo "FAIL enrolled_clone_dirs: rossoctl/.github must be emitted"; fail=1; }

# A non-enrolled clone must never leak in.
if printf '%s\n' "$clones" | grep -qxF "bob/tool"; then
  echo "FAIL enrolled_clone_dirs: non-enrolled bob/tool must be skipped"; fail=1
fi

rm -rf "$CLONE_ROOT"

[ "$fail" -eq 0 ] && echo "PASS: repoman_get_repos + is_enrolled + load_enrolled/is_enrolled_in + enrolled_clone_dirs (order, fail-loud, exact match, .github-safe)" || exit 1
