#!/usr/bin/env bash
set -euo pipefail

# Verifies scripts/weekly-report.sh builds the generator invocation from the
# RepoMan enrolled set. Hermetic: a fixture enrolled set via $REPOMAN_REPOS_FILE
# and a stub report.py via $REPORT_PY, so no gh / network / real config is
# touched. The enrolled set can span owners, so each repo is passed
# owner-qualified and there is no --org.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../scripts/weekly-report.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

fail=0

# Fixture enrolled set spanning two owners.
cat > "$TEST_TMPDIR/repos.json" <<'EOF'
[
  {"owner": "rossoctl", "name": "alpha"},
  {"owner": "alice", "name": "beta"}
]
EOF

# Stub generator: echo the args it was called with.
cat > "$TEST_TMPDIR/report.py" <<'PY'
import sys
print(" ".join(sys.argv[1:]))
PY

# Owner-qualified --repos, no --org.
got=$(REPOMAN_REPOS_FILE="$TEST_TMPDIR/repos.json" \
      REPORT_PY="$TEST_TMPDIR/report.py" \
      bash "$WRAPPER" --output /tmp/ignored.md)
want="--repos rossoctl/alpha alice/beta --output /tmp/ignored.md"
[ "$got" = "$want" ] || { echo "FAIL wrapper args: got [$got] want [$want]"; fail=1; }

# --since / --until pass through.
got2=$(REPOMAN_REPOS_FILE="$TEST_TMPDIR/repos.json" \
       REPORT_PY="$TEST_TMPDIR/report.py" \
       bash "$WRAPPER" --since 2026-08-10 --until 2026-08-17)
want2="--repos rossoctl/alpha alice/beta --since 2026-08-10 --until 2026-08-17"
[ "$got2" = "$want2" ] || { echo "FAIL wrapper window args: got [$got2] want [$want2]"; fail=1; }

# Missing generator fails loud.
if REPOMAN_REPOS_FILE="$TEST_TMPDIR/repos.json" \
   REPORT_PY="$TEST_TMPDIR/does-not-exist.py" \
   bash "$WRAPPER" >/dev/null 2>&1; then
  echo "FAIL wrapper should error on missing REPORT_PY"; fail=1
fi

# Empty enrolled set fails loud (never produces a zero-repo report).
echo '[]' > "$TEST_TMPDIR/empty.json"
if REPOMAN_REPOS_FILE="$TEST_TMPDIR/empty.json" \
   REPORT_PY="$TEST_TMPDIR/report.py" \
   bash "$WRAPPER" >/dev/null 2>&1; then
  echo "FAIL wrapper should error on empty enrolled set"; fail=1
fi

if [ "$fail" -eq 0 ]; then echo "PASS test-weekly-report.sh"; fi
exit "$fail"
