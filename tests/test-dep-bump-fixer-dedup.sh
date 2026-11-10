#!/usr/bin/env bash
# The dep-bump-fixer dedups its own PR comments by searching comment bodies for
# FIXER_SIGNATURE (a `jq contains`, case-sensitive). That signature MUST be a
# substring of every footer skill_attribution("dep-bump-fixer") can emit —
# resolved (pinned-SHA markdown link) and unresolved (linkless) — or the fixer
# stops recognizing its own comments and re-comments every run (automation#131
# footer-format change regressed this; caught on #136).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../scripts/program-lib.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0

# The exact signature the fixer uses for dedup (scripts/dep-bump-fixer.sh).
FIXER_SIGNATURE=$(grep -E '^FIXER_SIGNATURE=' "$SCRIPT_DIR/../scripts/dep-bump-fixer.sh" | head -1 | sed -E 's/^FIXER_SIGNATURE="(.*)"$/\1/')
[ -n "$FIXER_SIGNATURE" ] || { echo "FAIL: could not read FIXER_SIGNATURE from dep-bump-fixer.sh"; exit 1; }

# --- Resolved footer (a SHA is available) must contain the signature ---
meta_dir="$TMP/meta"; mkdir -p "$meta_dir"
FAKE_SHA="abcdef1234567890abcdef1234567890abcdef12"
printf '{"version":"%s","source":"rossoctl/repoman","installed_at":"2026-11-09"}\n' "$FAKE_SHA" \
  > "$meta_dir/_meta.dep-bump-fixer.json"
resolved=$(SCRIPT_DIR="$meta_dir" SKILL_SOURCE_REPO="rossoctl/repoman" skill_attribution "dep-bump-fixer")
case "$resolved" in
  *"$FIXER_SIGNATURE"*) echo "PASS: resolved footer contains the dedup signature" ;;
  *) echo "FAIL: resolved footer [$resolved] does not contain FIXER_SIGNATURE [$FIXER_SIGNATURE]"; fail=1 ;;
esac

# --- Unresolved (linkless) footer must also contain the signature ---
empty_dir="$TMP/empty"; mkdir -p "$empty_dir"
gh() { return 1; }   # force resolution failure -> linkless branch
unresolved=$(SCRIPT_DIR="$empty_dir" SKILL_SOURCE_REPO="rossoctl/repoman" skill_attribution "dep-bump-fixer" 2>/dev/null)
unset -f gh
case "$unresolved" in
  *"$FIXER_SIGNATURE"*) echo "PASS: linkless footer contains the dedup signature" ;;
  *) echo "FAIL: linkless footer [$unresolved] does not contain FIXER_SIGNATURE [$FIXER_SIGNATURE]"; fail=1 ;;
esac

[ "$fail" -eq 0 ] && echo "PASS: dep-bump-fixer dedup signature matches the emitted footer" || exit 1
