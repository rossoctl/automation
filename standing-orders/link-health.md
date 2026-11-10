## Program: Link Health

**Authority:** Scan repos for broken links, create/update GitHub issues, write reports, update the link-health report
**Trigger:** Scanner Mon/Wed/Fri 6am ET (enforced via cron job `link-health-scanner`)
**Approval gate:** None for issues or report updates.
**Escalation:**
  - More than 20 new broken links in a single scan: alert owner
  - Link checker fails on a repo (crash, bad output): count it as failed, carry its prior findings forward (never auto-close), continue with remaining repos
  - GitHub API rate limit hit: stop issue creation, report partial results

### Link checker
- Default: `LINK_CHECKER=python` — the stdlib `scripts/link-check.py` (Python 3.8+, no extra install; the program runs on a basic agent image).
- Opt-in fallback: `LINK_CHECKER=lychee` (lychee >= 0.23.0 must be on PATH).
- Egress-proxy refusals are reported as `unchecked` (not broken): no issue is opened or auto-closed for them; the run summary and dashboard show the unchecked count and top hosts. Widen the egress allowlist to convert them into real results.
- Shadow mode: set `LINK_HEALTH_SHADOW_OUT=<path>` to run a checker side-by-side and write only a side report — it forces dry-run, so the production baseline and issues are never touched.

### Scope
- The core repositories under the active org (see `config/core-repos.txt`), cloned locally
- Only documentation files: markdown (.md), HTML, and config files with URLs
- Uses existing .lychee.toml in each repo when present; the subset honored by the
  python checker is `exclude`, `exclude_path`, and `accept` (including ranges like
  `"200..=204"`); other keys are warned about and ignored

### What NOT to Do
- Do not modify source code files
- Do not close issues without evidence the link is fixed (re-scan confirmation)
- Do not create duplicate issues (check for existing issue with same repo + file + URL)
- Do not scan non-default branches

### Operational Notes
- Cron job: `link-health-scanner` (Mon/Wed/Fri 6am ET, isolated)
- Reports: `reports/link-health/latest.json` and `reports/link-health/history.json`
- Report PR: `automation-health/link-health.md` in `rossoctl/automation` (via the
  `link-health/reports` branch, standing fork PR). Single file, overwritten in
  place each run; history lives in git commit history (rossoctl/automation#44).
- Labels: `broken-link/internal`, `broken-link/external`, `broken-link/unfixable`
- Manual run: `openclaw cron run link-health-scanner`
- Epic: rossoctl/rossoctl#1178
