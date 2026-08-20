#!/usr/bin/env bash
set -euo pipefail

# Verifies scripts/weekly-report.sh builds the generator invocation from the
# core-repo allowlist. Hermetic: a fixture allowlist via $CORE_REPOS_FILE and a
# stub report.py via $REPORT_PY, so no gh / network / real config is touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../scripts/weekly-report.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

fail=0

# Fixture allowlist (bare names; owner is derived from ORG).
cat > "$TEST_TMPDIR/repos.txt" <<'EOF'
# comment
alpha
beta
EOF

# Stub generator: echo the args it was called with.
cat > "$TEST_TMPDIR/report.py" <<'PY'
import sys
print(" ".join(sys.argv[1:]))
PY

got=$(ORG=rossoctl \
      CORE_REPOS_FILE="$TEST_TMPDIR/repos.txt" \
      REPORT_PY="$TEST_TMPDIR/report.py" \
      bash "$WRAPPER" --output /tmp/ignored.md)
want="--org rossoctl --repos rossoctl/alpha rossoctl/beta --output /tmp/ignored.md"
[ "$got" = "$want" ] || { echo "FAIL wrapper args: got [$got] want [$want]"; fail=1; }

# --since / --until pass through.
got2=$(ORG=rossoctl \
       CORE_REPOS_FILE="$TEST_TMPDIR/repos.txt" \
       REPORT_PY="$TEST_TMPDIR/report.py" \
       bash "$WRAPPER" --since 2026-08-10 --until 2026-08-17)
want2="--org rossoctl --repos rossoctl/alpha rossoctl/beta --since 2026-08-10 --until 2026-08-17"
[ "$got2" = "$want2" ] || { echo "FAIL wrapper window args: got [$got2] want [$want2]"; fail=1; }

# Missing generator fails loud.
if ORG=rossoctl CORE_REPOS_FILE="$TEST_TMPDIR/repos.txt" \
   REPORT_PY="$TEST_TMPDIR/does-not-exist.py" \
   bash "$WRAPPER" >/dev/null 2>&1; then
  echo "FAIL wrapper should error on missing REPORT_PY"; fail=1
fi

if [ "$fail" -eq 0 ]; then echo "PASS test-weekly-report.sh"; fi
exit "$fail"
