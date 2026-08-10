## Program: Automation Health Dashboard

**Authority:** Generate executive-facing dashboard combining all automation program metrics
**Trigger:** Daily 1pm ET (enforced via cron job `health-dashboard`)
**Approval gate:** None for dashboard updates.
**Escalation:** None (read-only aggregator)

### Scope
- Reads reports from all automation programs (link-health, dep-bump)
- Generates `automation-health/automation-health.md` in `rossoctl/automation`
- Pushes via standing fork-based PR (branch: `automation/health-dashboard`)

### What NOT to Do
- Do not modify any program's report files
- Do not create issues or PRs beyond the standing dashboard PR
- Do not run scanners or fixers — dashboard is read-only

### Operational Notes
- Cron job: `health-dashboard` (daily 1pm ET / 17:00 UTC, isolated)
- Output: `automation-health/automation-health.md` in the standing PR (single file,
  overwritten in place; history in git commit history — rossoctl/automation#44)
- Fork branch: `automation/health-dashboard`
- Report-target clone: pass `--main-repo-dir` (the local `automation` clone) so the
  dashboard finds the repo it commits into
- Manual run: `openclaw cron run health-dashboard`

### Schedule Coordination
See [dep-bump.md](dep-bump.md#schedule-coordination) for the full cron schedule grid.

### Epic
- rossoctl/rossoctl#1260
