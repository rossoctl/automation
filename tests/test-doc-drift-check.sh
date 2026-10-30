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

# mergedAt before the newest publishedAt is already released, even if the
# caller stamped unreleased:true. A later merge still drafts.
cat > "$PR_JSON" <<'EOF'
[
  {
    "number": 11,
    "title": "feat: already shipped",
    "url": "https://github.com/fixture/repo/pull/11",
    "labels": [],
    "mergedAt": "2026-10-01T00:00:00Z",
    "unreleased": true
  },
  {
    "number": 12,
    "title": "feat: after the release",
    "url": "https://github.com/fixture/repo/pull/12",
    "labels": [],
    "mergedAt": "2026-10-28T00:00:00Z",
    "unreleased": false
  }
]
EOF
OUTD="$TMP/outd.json"
python3 "$CHECK" --clone "$FIX" --repo "fixture/repo" --ref "$REF2" \
  --releases-json "$REL_JSON" --prs-json "$PR_JSON" > "$OUTD"
if jq -e '[.findings[] | select(.check=="release_draft") | .draft | contains("#11")] | any' "$OUTD" >/dev/null; then
  fail_msg "release_draft: PR merged before publishedAt should not draft"
  jq '[.findings[] | select(.check=="release_draft")]' "$OUTD" || true
else
  pass "release_draft: already-released PR is not unreleased"
fi
if jq -e '[.findings[] | select(.check=="release_draft") | .draft | contains("#12")] | any' "$OUTD" >/dev/null; then
  pass "release_draft: PR merged after publishedAt drafts"
else
  fail_msg "release_draft: PR merged after publishedAt should draft"
  jq '[.findings[] | select(.check=="release_draft")]' "$OUTD" || true
fi

# Compact YAML sequences, changelog history, and project-version lines.
python3 - "$CHECK" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("dd", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
text = """retired_names:
- old-name
ignore_paths:
- vendor/
sources_of_truth:
- name: version
  code:
    path: VERSION
"""
got = mod.parse_simple_yaml(text)
assert got["retired_names"] == ["old-name"], got
assert got["ignore_paths"] == ["vendor/"], got
assert got["sources_of_truth"][0]["code"]["path"] == "VERSION", got
assert "code" not in got, got
PY
pass "yaml: compact sequences stay lists"

VER="$TMP/versions"
mkdir -p "$VER/.claude-plugin" "$VER/.repoman"
cat > "$VER/.claude-plugin/marketplace.json" <<'EOF'
{"version": "2.0.0"}
EOF
cat > "$VER/CHANGELOG.md" <<'EOF'
# Changelog

## [1.0.0] - 2026-01-01

## [2.0.0] - 2026-02-01
EOF
cat > "$VER/requirements.txt" <<'EOF'
foo==1.2.3
EOF
cat > "$VER/README.md" <<'EOF'
# App

The plugin version is 2.0.0.

The plugin version is 9.9.9.
Also the version is 8.8.8.
EOF
cat > "$VER/.repoman/doc-drift.yaml" <<'EOF'
boundary: tags
stable_tag_pattern: '^v\d+\.\d+\.\d+$'
retired_names:
- old-name
ignore_paths:
- vendor/
sources_of_truth:
- name: version
  code:
    path: VERSION
EOF
git -C "$VER" init -q
git -C "$VER" -c user.email=t@t -c user.name=t add -A
git -C "$VER" -c user.email=t@t -c user.name=t commit -qm "ver"
git -C "$VER" tag v1.0.0
OUTV="$TMP/outv.json"
python3 "$CHECK" --clone "$VER" --repo "fixture/versions" \
  --releases '[]' --prs '[]' > "$OUTV"
if jq -e '[.findings[] | select(.check=="versions" and (.doc_path|test("CHANGELOG")))] | length == 0' "$OUTV" >/dev/null; then
  pass "versions: changelog history is not drift"
else
  fail_msg "versions: changelog history flagged"
  jq '[.findings[] | select(.check=="versions")]' "$OUTV" || true
fi
if jq -e '[.findings[] | select(.doc_path=="requirements.txt")] | length == 0' "$OUTV" >/dev/null; then
  pass "versions: dependency pins are not the project version"
else
  fail_msg "versions: requirements.txt pin flagged"
fi
vcount=$(jq '[.findings[] | select(.check=="versions" and .doc_path=="README.md" and .mechanical==true)] | length' "$OUTV")
if [ "$vcount" = "2" ]; then
  pass "versions: both project-version lines survive dedupe"
else
  fail_msg "versions: expected 2 README findings, got $vcount"
  jq '[.findings[] | select(.check=="versions")]' "$OUTV" || true
fi
if jq -e '[.findings[] | select(.check=="versions" and .mechanical==false and (.evidence|test("tag v1.0.0")))] | length == 1' "$OUTV" >/dev/null \
  && jq -e '[.findings[] | select(.check=="versions" and .mechanical==true and .replace_with=="1.0.0")] | length == 0' "$OUTV" >/dev/null; then
  pass "versions: older tag is a non-mechanical mismatch, not the canon"
else
  fail_msg "versions: tag should not override the declared version"
  jq '[.findings[] | select(.check=="versions")]' "$OUTV" || true
fi

BAD="$TMP/badre"
mkdir -p "$BAD/.repoman"
echo 'stable_tag_pattern: "("' > "$BAD/.repoman/doc-drift.yaml"
echo '{"version":"1.0.0"}' > "$BAD/package.json"
git -C "$BAD" init -q
git -C "$BAD" -c user.email=t@t -c user.name=t add -A
git -C "$BAD" -c user.email=t@t -c user.name=t commit -qm "bad"
OUTB="$TMP/outb.json"
if python3 "$CHECK" --clone "$BAD" --repo "fixture/bad" --releases '[]' --prs '[]' > "$OUTB"; then
  if jq -e '[.findings[] | select(.check=="config")] | length > 0' "$OUTB" >/dev/null; then
    pass "config: invalid stable_tag_pattern is a finding, not a crash"
  else
    fail_msg "config: invalid pattern produced no finding"
  fi
else
  fail_msg "config: invalid pattern crashed the checker"
fi

# Line-scoped replace: 1.2.3 must not match inside 11.2.30, and only line 2 changes.
EDIT="$TMP/edit.md"
printf 'keep 11.2.30 and 1.2.3\nreplace 1.2.3 here\nkeep 1.2.3\n' > "$EDIT"
# shellcheck disable=SC1090
eval "$(sed -n '/^replace_on_line() {$/,/^}$/p' "$SCRIPT_DIR/../scripts/doc-drift-fixer.sh")"
if replace_on_line "$EDIT" 2 "1.2.3" "2.0.0" \
  && [ "$(sed -n '1p' "$EDIT")" = "keep 11.2.30 and 1.2.3" ] \
  && [ "$(sed -n '2p' "$EDIT")" = "replace 2.0.0 here" ] \
  && [ "$(sed -n '3p' "$EDIT")" = "keep 1.2.3" ]; then
  pass "fixer: replace touches only the flagged line"
else
  fail_msg "fixer: line-scoped replace"
  cat "$EDIT" || true
fi

if [ "$fail" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASS"
exit 0
