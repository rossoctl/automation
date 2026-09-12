#!/usr/bin/env bash
set -euo pipefail

# Verifies repoman_config() in program-lib.sh:
#   - resolves repos_dir + fork_owner from config.json
#   - expands a leading ~ in repos_dir to $HOME
#   - fails loud on a missing file or a missing required key
# Hermetic: drives the reader via $REPOMAN_CONFIG_FILE pointing at a fixture.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../scripts/program-lib.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

FIX="$SCRIPT_DIR/fixtures/repoman-config.json"

# --- resolves both values (run in one subshell so the exports survive) ---
got=$(
  REPOMAN_CONFIG_FILE="$FIX"; repoman_config >/dev/null 2>&1
  echo "$REPOS_DIR|$FORK_OWNER"
)
[ "$got" = "/tmp/repoman-fixture-repos|clawgenti" ] \
  || { echo "FAIL repoman_config resolve: got [$got]"; fail=1; }

# --- leading ~ in repos_dir expands to $HOME ---
cat > "$TEST_TMPDIR/tilde.json" <<'EOF'
{"repos_dir": "~/repoman/repos", "fork_owner": "clawgenti"}
EOF
got=$(
  REPOMAN_CONFIG_FILE="$TEST_TMPDIR/tilde.json"; repoman_config >/dev/null 2>&1
  echo "$REPOS_DIR"
)
[ "$got" = "$HOME/repoman/repos" ] \
  || { echo "FAIL repoman_config tilde: got [$got]"; fail=1; }

# --- fail loud: missing file ---
if ( REPOMAN_CONFIG_FILE="$TEST_TMPDIR/nope.json"; repoman_config ) >/dev/null 2>&1; then
  echo "FAIL should error on missing config file"; fail=1
fi

# --- fail loud: missing required key (no fork_owner) ---
cat > "$TEST_TMPDIR/nofork.json" <<'EOF'
{"repos_dir": "/tmp/x"}
EOF
if ( REPOMAN_CONFIG_FILE="$TEST_TMPDIR/nofork.json"; repoman_config ) >/dev/null 2>&1; then
  echo "FAIL should error when fork_owner missing"; fail=1
fi

[ "$fail" -eq 0 ] && echo "PASS: repoman_config (resolve, tilde, fail-loud)" || exit 1
