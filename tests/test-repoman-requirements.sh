#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../scripts/program-lib.sh"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

# --- happy path: full block round-trips to normalized JSON ---
SK="$TEST_TMPDIR/full.md"
cat > "$SK" <<'EOF'
## Prerequisites

- `gh` (GitHub CLI)
- `jq`

### Requirements (machine-readable)

- pat_scopes: [repo]
- labels_required: [ready-for-ai-review]
- labels_applied: [needs-changes, approved]
- programs: [scanner]
EOF
got=$(repoman_parse_requirements "$SK")
want='{"pat_scopes":["repo"],"labels_required":["ready-for-ai-review"],"labels_applied":["needs-changes","approved"],"programs":["scanner"]}'
[ "$(printf '%s' "$got" | jq -cS .)" = "$(printf '%s' "$want" | jq -cS .)" ] \
  || { echo "FAIL full block: got [$got]"; fail=1; }

# --- missing keys default to empty arrays ---
SK2="$TEST_TMPDIR/partial.md"
cat > "$SK2" <<'EOF'
## Prerequisites

### Requirements (machine-readable)

- pat_scopes: [repo, read:org]
EOF
got=$(repoman_parse_requirements "$SK2")
[ "$(printf '%s' "$got" | jq -cS '.labels_required')" = '[]' ] \
  && [ "$(printf '%s' "$got" | jq -cS '.pat_scopes')" = '["repo","read:org"]' ] \
  || { echo "FAIL partial block defaults: got [$got]"; fail=1; }

# --- empty list is valid ---
SK3="$TEST_TMPDIR/empty.md"
cat > "$SK3" <<'EOF'
### Requirements (machine-readable)

- pat_scopes: [repo]
- labels_required: []
EOF
got=$(repoman_parse_requirements "$SK3")
[ "$(printf '%s' "$got" | jq -cS '.labels_required')" = '[]' ] \
  || { echo "FAIL empty list: got [$got]"; fail=1; }

# --- malformed: recognized key with unbracketed value fails LOUDLY ---
SK4="$TEST_TMPDIR/bad.md"
cat > "$SK4" <<'EOF'
### Requirements (machine-readable)

- pat_scopes: repo
EOF
err=$(repoman_parse_requirements "$SK4" 2>&1) \
  && { echo "FAIL unbracketed value should fail"; fail=1; }
case "$err" in
  *"pat_scopes"*|*"bracket"*) ;;
  *) echo "FAIL unbracketed value should name the offending key/shape, got: [$err]"; fail=1 ;;
esac

# --- malformed: unknown key inside the block fails LOUDLY ---
SK5="$TEST_TMPDIR/unknown.md"
cat > "$SK5" <<'EOF'
### Requirements (machine-readable)

- pat_scopes: [repo]
- bogus_key: [x]
EOF
err=$(repoman_parse_requirements "$SK5" 2>&1) \
  && { echo "FAIL unknown key should fail"; fail=1; }
case "$err" in
  *"bogus_key"*|*"unknown"*) ;;
  *) echo "FAIL unknown key should name it, got: [$err]"; fail=1 ;;
esac

# --- prose bullets outside the block are ignored (no false key match) ---
# (covered by the happy-path file above, which has prose bullets before the block)

[ "$fail" -eq 0 ] \
  && echo "PASS: repoman_parse_requirements" \
  || exit 1
