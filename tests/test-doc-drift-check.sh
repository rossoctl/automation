#!/usr/bin/env bash
# Fixture tests for scripts/doc-drift-check.py (deterministic doc-drift checker).
# Part of RepoMan doc-drift v1 (rossoctl/repoman#8).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/../scripts/doc-drift-check.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail=0

pass() { echo "PASS: $1"; }
fail_msg() { echo "FAIL: $1"; fail=1; }

# ---------------------------------------------------------------------------
# Build a fixture clone that reproduces the five b3f128c shapes.
# ---------------------------------------------------------------------------
FIX="$TMP/fixture"
mkdir -p "$FIX/skills/repoman/scripts" \
         "$FIX/skills/repo-sync" \
         "$FIX/scripts" \
         "$FIX/.repoman" \
         "$FIX/.claude-plugin"

# Code: KNOWN_PROGRAMS includes weekly-report (enum source of truth)
cat > "$FIX/skills/repoman/scripts/repoman-setup.sh" <<'EOF'
#!/usr/bin/env bash
# Subcommands: init-config, add-repo, enable-program, set-output.
KNOWN_PROGRAMS="link-health dep-bump pr-review automation-health repo-sync weekly-report"

case "$1" in
  init-config) ;;
  add-repo) ;;
  enable-program) ;;
  set-output) ;;
  set-requirements) ;;
  *) exit 1 ;;
esac
EOF

# Script that exists but docs claim is not implemented
cat > "$FIX/skills/repoman/scripts/repoman-run.sh" <<'EOF'
#!/usr/bin/env bash
echo "run path is implemented"
EOF

# repo-sync.sh bundled here (docs claim it lives only in automation)
cat > "$FIX/scripts/repo-sync.sh" <<'EOF'
#!/usr/bin/env bash
echo "repo-sync"
EOF

# Retired branding
cat > "$FIX/skills/repoman/scripts/dep-bump-fixer.sh" <<'EOF'
#!/usr/bin/env bash
FIXER_SIGNATURE="Automated analysis by Kagenti Dep Bump Fixer"
EOF

# Docs: program list omits weekly-report (friendly-name table style)
cat > "$FIX/skills/repoman/SKILL.md" <<'EOF'
# RepoMan

Canonical allowlist names remain the `KNOWN_PROGRAMS` allowlist in
`repoman-setup.sh` (`link-health`, `dep-bump`, `pr-review`,
`automation-health`, `repo-sync`).

The **run path** is **not implemented in this skill**. Until it lands,
report the resolved set — do not attempt to exec `repoman-run.sh` yourself.

| Friendly name | Canonical token |
|---------------|-----------------|
| Link-Health-Manager | `link-health` |
| Dep-Bump-Manager | `dep-bump` |
| PR-Review-Manager | `pr-review` |
| Automation-Health-Manager | `automation-health` |
| Repo-Sync-Manager | `repo-sync` |
EOF

cat > "$FIX/skills/repo-sync/SKILL.md" <<'EOF'
# Repo Sync

**Run scripts with `--help` first.** The script lives in the automation repo,
not in this repo, so run `repo-sync.sh` from an automation checkout.
EOF

cat > "$FIX/README.md" <<'EOF'
# Fixture

Version in docs: 0.1.0
EOF

cat > "$FIX/.claude-plugin/marketplace.json" <<'EOF'
{
  "name": "fixture",
  "metadata": { "version": "0.1.0" }
}
EOF

cat > "$FIX/CHANGELOG.md" <<'EOF'
# Changelog

## [0.1.0] - 2026-10-23

### Added

- First release (#1).
EOF

cat > "$FIX/.repoman/doc-drift.yaml" <<'EOF'
boundary: main
stable_tag_pattern: '^v\d+\.\d+\.\d+$'
ignore_paths: [CHANGELOG.md, docs/history/**]
sources_of_truth:
  - name: programs
    code: { file: skills/repoman/scripts/repoman-setup.sh, pattern: 'KNOWN_PROGRAMS="([^"]+)"' }
    docs: [skills/repoman/SKILL.md]
retired_names:
  - { name: kagenti, replace_with: "" }
release:
  changelog: CHANGELOG.md
EOF

git -C "$FIX" init -q
git -C "$FIX" -c user.email=t@t -c user.name=t add -A
git -C "$FIX" -c user.email=t@t -c user.name=t commit -qm "fixture"
REF=$(git -C "$FIX" rev-parse HEAD)

# Dirty worktree must not change results
echo "DIRTY" >> "$FIX/skills/repoman/SKILL.md"

OUT1="$TMP/out1.json"
python3 "$CHECK" --clone "$FIX" --repo "fixture/repo" --ref "$REF" \
  --releases '[]' --prs '[]' > "$OUT1"

# --- Five b3f128c shapes ---
has_check() {
  local check="$1" claim_substr="$2"
  jq -e --arg c "$check" --arg s "$claim_substr" \
    '[.findings[] | select(.check == $c and (.claim | test($s; "i")))] | length > 0' \
    "$OUT1" >/dev/null
}

if has_check enumerations 'weekly-report'; then
  pass "enum: weekly-report missing from docs"
else
  fail_msg "enum: weekly-report missing from docs"
  jq '[.findings[] | select(.check=="enumerations")]' "$OUT1" || true
fi

if has_check absence 'not implemented'; then
  pass "absence: repoman-run not-implemented claim"
else
  fail_msg "absence: repoman-run not-implemented claim"
  jq '[.findings[] | select(.check=="absence")]' "$OUT1" || true
fi

if has_check absence 'automation repo'; then
  pass "absence: repo-sync lives in automation claim"
else
  fail_msg "absence: repo-sync lives in automation claim"
fi

if has_check flags 'set-requirements'; then
  pass "flags: set-requirements addition or doc mismatch"
else
  fail_msg "flags: set-requirements not reported"
  jq '[.findings[] | select(.check=="flags")]' "$OUT1" || true
fi

if has_check retired_names 'kagenti'; then
  pass "retired_names: kagenti"
else
  fail_msg "retired_names: kagenti"
fi

# Both-sides cites
if jq -e '[.findings[] | select(.doc_line < 1 or .code_line < 1)] | length == 0' "$OUT1" >/dev/null; then
  pass "every finding has doc_line and code_line >= 1"
else
  fail_msg "finding missing line cites"
fi

# Dirty worktree invariance
OUT2="$TMP/out2.json"
python3 "$CHECK" --clone "$FIX" --repo "fixture/repo" --ref "$REF" \
  --releases '[]' --prs '[]' > "$OUT2"
if diff -q <(jq -S '.findings' "$OUT1") <(jq -S '.findings' "$OUT2") >/dev/null; then
  pass "dirty worktree does not change findings"
else
  fail_msg "dirty worktree changed findings"
fi

# Idempotent keys across a second logical run
KEYS1=$(jq -r '[.findings[].key] | sort | .[]' "$OUT1")
KEYS2=$(jq -r '[.findings[].key] | sort | .[]' "$OUT2")
if [ "$KEYS1" = "$KEYS2" ]; then
  pass "second run at same ref yields identical keys"
else
  fail_msg "keys drifted across runs"
fi

# ---------------------------------------------------------------------------
# Release assist fixtures (fed as JSON; no gh)
# ---------------------------------------------------------------------------
REL_JSON="$TMP/releases.json"
PR_JSON="$TMP/prs.json"
cat > "$REL_JSON" <<'EOF'
[
  {
    "tagName": "v0.1.0",
    "publishedAt": "2026-10-27T19:09:44Z",
    "createdAt": "2026-10-27T19:04:04Z",
    "name": "v0.1.0",
    "body": "## [0.1.0] - 2026-10-23\n\nFirst release.\n"
  }
]
EOF
cat > "$PR_JSON" <<'EOF'
[
  {
    "number": 10,
    "title": "feat: add doc-drift program",
    "url": "https://github.com/fixture/repo/pull/10",
    "labels": [],
    "unreleased": true
  },
  {
    "number": 11,
    "title": "fix: correct changelog date helper",
    "url": "https://github.com/fixture/repo/pull/11",
    "labels": [],
    "unreleased": true
  },
  {
    "number": 12,
    "title": "chore: ignore me",
    "url": "https://github.com/fixture/repo/pull/12",
    "labels": [],
    "unreleased": true
  },
  {
    "number": 13,
    "title": "Improve something without prefix",
    "url": "https://github.com/fixture/repo/pull/13",
    "labels": [],
    "unreleased": true
  }
]
EOF

OUTR="$TMP/outr.json"
python3 "$CHECK" --clone "$FIX" --repo "fixture/repo" --ref "$REF" \
  --releases-json "$REL_JSON" --prs-json "$PR_JSON" > "$OUTR"

if jq -e '[.findings[] | select(.check=="release_date" and (.claim|test("2026-10-27")))] | length == 1' "$OUTR" >/dev/null; then
  pass "release_date: 2026-10-23 vs 2026-10-27"
else
  fail_msg "release_date: expected one date correction"
  jq '[.findings[] | select(.check=="release_date")]' "$OUTR" || true
fi

# Draft release (null publishedAt) → no date finding for that release
cat > "$REL_JSON" <<'EOF'
[{ "tagName": "v0.1.0", "publishedAt": null, "body": "" }]
EOF
OUTD="$TMP/outd.json"
python3 "$CHECK" --clone "$FIX" --repo "fixture/repo" --ref "$REF" \
  --releases-json "$REL_JSON" --prs '[]' > "$OUTD"
if jq -e '[.findings[] | select(.check=="release_date")] | length == 0' "$OUTD" >/dev/null; then
  pass "release_date: null publishedAt skipped"
else
  fail_msg "release_date: draft should be skipped"
fi

# Restore published release for draft checks
cat > "$REL_JSON" <<'EOF'
[
  {
    "tagName": "v0.1.0",
    "publishedAt": "2026-10-27T19:09:44Z",
    "body": "## [0.1.0] - 2026-10-23\n"
  }
]
EOF
python3 "$CHECK" --clone "$FIX" --repo "fixture/repo" --ref "$REF" \
  --releases-json "$REL_JSON" --prs-json "$PR_JSON" > "$OUTR"

if jq -e '[.findings[] | select(.check=="release_draft")] | length == 1' "$OUTR" >/dev/null; then
  pass "release_draft: Unreleased section addition"
else
  fail_msg "release_draft: expected Unreleased addition"
fi

DRAFT=$(jq -r '.findings[] | select(.check=="release_draft") | .draft' "$OUTR")
echo "$DRAFT" | grep -q '### Added' && echo "$DRAFT" | grep -q '#10' || {
  fail_msg "release_draft: missing Added/#10"
}
echo "$DRAFT" | grep -q '### Fixed' && echo "$DRAFT" | grep -q '#11' || {
  fail_msg "release_draft: missing Fixed/#11"
}
echo "$DRAFT" | grep -q 'chore' && fail_msg "release_draft: chore should be omitted" || pass "release_draft: chore omitted"
echo "$DRAFT" | grep -q '### Uncategorized' && echo "$DRAFT" | grep -q '#13' \
  && pass "release_draft: uncategorized #13" \
  || fail_msg "release_draft: expected Uncategorized #13"

# Already-cited PR → no finding for that number
# Put #10 into Unreleased in changelog and rebuild
cat > "$FIX/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

- add doc-drift program (#10).

## [0.1.0] - 2026-10-23

### Added

- First release (#1).
EOF
git -C "$FIX" -c user.email=t@t -c user.name=t add -A
git -C "$FIX" -c user.email=t@t -c user.name=t commit -qm "cite #10"
REF2=$(git -C "$FIX" rev-parse HEAD)
# Only PR 10 unreleased
cat > "$PR_JSON" <<'EOF'
[
  {
    "number": 10,
    "title": "feat: add doc-drift program",
    "url": "https://github.com/fixture/repo/pull/10",
    "labels": [],
    "unreleased": true
  }
]
EOF
OUTC="$TMP/outc.json"
python3 "$CHECK" --clone "$FIX" --repo "fixture/repo" --ref "$REF2" \
  --releases-json "$REL_JSON" --prs-json "$PR_JSON" > "$OUTC"
if jq -e '[.findings[] | select(.check=="release_draft")] | length == 0' "$OUTC" >/dev/null; then
  pass "release_draft: already-cited PR produces no draft"
else
  fail_msg "release_draft: cited PR should not draft"
  jq '[.findings[] | select(.check|startswith("release"))]' "$OUTC" || true
fi

if [ "$fail" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS"
exit 0
