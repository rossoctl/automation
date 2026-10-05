---
name: dep_bump_fixer
description: Analyze stale Dependabot PRs and post severity-appropriate analysis comments to accelerate human review decisions.
metadata: {"openclaw": {"requires": {"bins": ["gh", "jq"]}}}
---

# Dependency Bump Fixer

Respond to scanner-created issues (`[dep-bump]` title prefix) with severity-appropriate analysis comments on the Dependabot PRs. Does NOT auto-merge — provides actionable commentary to accelerate human decisions.

**Run scripts with `--help` first** to see full usage and options.

## Repo Location

All kagenti repos are already cloned at `~/kagenti/` and updated nightly by the `kagenti-repo-update` cron job. Do NOT clone repos yourself.

## Running the Fixer

### Verify prerequisites

```bash
gh auth status
jq --version
```

### Always dry-run first

```bash
REPOS_DIR=~/kagenti REPORTS_DIR=~/reports/dep-bump \
  bash ~/workspaces/clawgenti/scripts/dep-bump-fixer.sh --dry-run
```

### Live run (posts comments on PRs)

```bash
REPOS_DIR=~/kagenti REPORTS_DIR=~/reports/dep-bump \
  bash ~/workspaces/clawgenti/scripts/dep-bump-fixer.sh --live --issue-limit 3
```

## What it Does

1. **Captures baseline** (first run only) — snapshots org state before fixer starts
2. **Discovers scanner issues** — searches for `[dep-bump] in:title` across all repos
3. **Parses issue bodies** — extracts severity, package, PR number, ecosystem
4. **Checks PR state** — skips merged/closed PRs (closes the scanner issue), skips already-commented PRs
5. **Generates analysis** — severity-appropriate comment with changelog, CVE refs, risk assessment
6. **Posts comments** (live mode) — on the Dependabot PR and the scanner issue
7. **Handles missing configs** — creates fork-based PRs for repos missing `dependabot.yml`
8. **Computes metrics** — median time-to-merge, stale count, delta from baseline

## Analysis Tiers

| Category | Comment Style |
|----------|--------------|
| Security (critical/high) | Escalation: CVE refs, advisory context, SLA breach notice |
| Routine (minor/patch) | Update analysis: changelog summary, risk assessment, merge recommendation |
| Major (breaking) | Migration notes: breaking changes, bundling suggestions, deferral guidance |

## Duplicate Prevention

Comments include a fixer signature: `_Automated analysis by Kagenti Dep Bump Fixer_`. The script checks for this signature before posting and skips PRs that already have a fixer comment.

## Reports

- `reports/dep-bump/baseline.json` — org state snapshot (written once on first run)
- `reports/dep-bump/fixer-latest.json` — full run results (overwritten each run)
- `reports/dep-bump/fixer-history.json` — append-only trend data

## Metrics

Each run computes and reports:
- Issues processed (by tier)
- Comments posted
- Issues closed (PR merged since scanner created issue)
- Median time-to-merge (last 30 days)
- Stale count and delta from previous run
- Comparison to baseline

## Safety

- Always run with `--dry-run` first unless explicitly told to post comments
- Use `--issue-limit` to cap processing, especially on first runs
- The fixer does NOT merge or close Dependabot PRs
- The fixer does NOT approve PRs
- Comments are informational only — human action required
