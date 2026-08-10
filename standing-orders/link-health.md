## Program: Link Health

**Authority:** Scan repos for broken links, create/update GitHub issues, write reports, update the link-health report
**Trigger:** Scanner Mon/Wed/Fri 6am ET (enforced via cron job `link-health-scanner`)
**Approval gate:** None for issues or report updates.
**Escalation:**
  - More than 20 new broken links in a single scan: alert owner
  - Lychee fails on a repo (network, auth): log and continue with remaining repos
  - GitHub API rate limit hit: stop issue creation, report partial results

### Scope
- The core repositories under the active org (see `config/core-repos.txt`), cloned locally
- Only documentation files: markdown (.md), HTML, and config files with URLs
- Uses existing .lychee.toml in each repo when present; falls back to default config

### What NOT to Do
- Do not modify source code files
- Do not close issues without evidence the link is fixed (re-scan confirmation)
- Do not create duplicate issues (check for existing issue with same repo + file + URL)
- Do not scan non-default branches

### Operational Notes
- Cron job: `link-health-scanner` (Mon/Wed/Fri 6am ET, isolated)
- Reports: `reports/link-scan/latest.json` and `reports/link-scan/history.json`
- Report PR: `automation-health/link-health.md` in `rossoctl/automation` (via the
  `link-health/reports` branch, standing fork PR). Single file, overwritten in
  place each run; history lives in git commit history (rossoctl/automation#44).
- Labels: `broken-link/internal`, `broken-link/external`, `broken-link/unfixable`
- Manual run: `openclaw cron run link-health-scanner`
- Epic: rossoctl/rossoctl#1178
