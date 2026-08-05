## Program: Dep Bump

**Authority:** Scan repos for stale Dependabot PRs, create/close GitHub issues, write reports
**Trigger:** Scanner Tue/Thu 7am ET (enforced via cron job `dep-bump-scanner`)
**Approval gate:** None for issues or report updates.
**Escalation:**
  - More than 5 new stale PRs in a single scan: alert owner
  - Critical severity (CVSS 9.0+) SLA breach: immediate alert
  - GitHub API rate limit hit: stop issue creation, report partial results

### Scope
- The core repositories under the active org (see `config/core-repos.txt`), cloned locally
- Only open Dependabot PRs (state=open, author=app/dependabot)
- Coverage audit of .github/dependabot.yml vs detected ecosystems

### What NOT to Do
- Do not merge or close Dependabot PRs
- Do not modify dependabot.yml files
- Do not create duplicate issues (check for existing issue with same repo + package)
- Do not create issues for PRs within their SLA window

### Operational Notes — Scanner
- Cron job: `dep-bump-scanner` (Tue/Thu 10am ET / 14:00 UTC, isolated)
- Reports: `reports/dep-bump/latest.json` and `reports/dep-bump/history.json`
- Issue prefix: `[dep-bump]` (used for discovery; no labels required)
- Manual run: `openclaw cron run dep-bump-scanner`

### Operational Notes — Fixer
- Cron job: `dep-bump-fixer` (Tue/Thu 12pm ET / 16:00 UTC, isolated — 2h after scanner)
- Reports: `reports/dep-bump/fixer-latest.json`, `reports/dep-bump/fixer-history.json`, `reports/dep-bump/baseline.json`
- Fixer signature: `_Automated analysis by Rossoctl Dep Bump Fixer_`
- Manual run: `openclaw cron run dep-bump-fixer`
- The fixer does NOT merge PRs — it comments with analysis to accelerate human decisions
- Duplicate prevention: checks for existing fixer signature before posting

### Schedule Coordination
All cron jobs maintain 1h+ separation to avoid crowding Discord:
- Link-health scanner: Mon/Wed/Fri 11:00 UTC (7am ET)
- Link-health fixer: Tue/Thu 12:00 UTC (8am ET)
- Dep-bump scanner: Tue/Thu 14:00 UTC (10am ET)
- Dep-bump fixer: Tue/Thu 16:00 UTC (12pm ET)
- Health dashboard: Daily 17:00 UTC (1pm ET)

### Epic
- rossoctl/rossoctl#1260
