## Program: PR Review

**Authority:** Review PRs labeled `ready-for-ai-review`, post review comments
**Trigger:** Scanner every 15 min; fixer every 15 min (offset ~5 min)
**Model:** claude-sonnet-4-6 (fixer only; scanner is bash-only)
**Identity:** clawgenti (single identity, no switching)
**Approval gate:** None. Comments only, never blocks merge.
**Branding:** "Clawgenti Code Review"
**Tracking:** rossoctl/rossoctl#1910

### Scope
- Repositories: the core allowlist (see `config/core-repos.txt`)
- Only open PRs with the `ready-for-ai-review` label
- Uses the `github:pr-review` skill

### Architecture: Scanner/Fixer Pattern

| | Scanner | Fixer |
|---|---|---|
| **Script** | `pr-review-scanner.sh` | `pr-review-fixer.sh` |
| **Runs as** | Bash (no LLM) | Agent turn (LLM-driven) |
| **Input** | GitHub API (labels, PRs, reviews) | `reports/pr-review/latest.json` |
| **Output** | `latest.json` + `state.json` + `history.json` | PR review comment via GitHub API |
| **Idempotency** | State file prevents re-queuing | `<!-- reviewed: SHA -->` marker |

### State Machine

PRs move through internal states tracked in `reports/pr-review/state.json`:

```
[not tracked] → eligible → in_progress → reviewed
                  ↑                          |
                  └──── new commits pushed ──┘
```

- **eligible**: Scanner found the PR (has label, not draft, not approved, not self-authored, no matching SHA)
- **in_progress**: Fixer claimed it (prevents duplicate work across overlapping cycles)
- **reviewed**: Fixer posted the review (SHA recorded)
- **re-eligible**: New commits pushed (HEAD SHA no longer matches state)

### Eviction Rules

Entries are removed from state when:
- PR is merged or closed (no longer open)
- `ready-for-ai-review` label is removed (human opt-out)
- Entry exceeds 30-day TTL (safety net)
- `in_progress` entry exceeds 30 minutes (stale fixer run, recycle)

### Behavior

**Review verdicts:**
- Issues found: post review with inline findings (must-fix, suggestion, nit)
- No issues: post review with "All checks pass. Ready for human review."

**Label management:** None. Humans add/remove all labels.
- `ready-for-ai-review` — author adds when ready for AI pass; removes to opt out
- `ready-for-human-review` — human adds after reading AI verdict

**Skip logic:**
- Skip draft PRs
- Skip PRs authored by clawgenti (no self-review)
- Skip PRs already approved (reviewDecision == APPROVED)
- Skip PRs in `state.reviewed` with matching SHA
- Skip PRs in `state.in_progress` (fixer is working on them)
- Fallback: check `<!-- reviewed: SHA -->` via PR reviews API

### What NOT to Do
- Do not submit REQUEST_CHANGES or APPROVE reviews (COMMENT type only)
- Do not add or remove labels
- Do not merge or close PRs
- Do not review clawgenti's own PRs

### Components

**Scanner** (`pr-review-scanner.sh`):
- Deterministic bash; iterates repos, filters by label/author/draft/approved/SHA
- Manages state eviction (closed PRs, removed labels, TTL)
- Writes `latest.json`, `state.json`, `history.json`
- Outputs JSON queue to stdout (backward compatible)

**Fixer** (`pr-review-fixer.sh`):
- Two modes: `begin` (mark in_progress, output queue) and `finalize` (confirm reviews, update state)
- Agent reviews PRs between begin and finalize calls
- Writes `fixer-history.json`

**Cron jobs:**
- `pr-review-scanner`: bash-only, no LLM cost
- `pr-review-fixer`: agent turn using `github:pr-review` skill

### Reports

| File | Lifecycle |
|---|---|
| `latest.json` | Overwritten each scanner run |
| `history.json` | Append-only, capped at 500 rows |
| `state.json` | Managed by scanner (eviction) and fixer (transitions) |
| `fixer-history.json` | Append-only, capped at 500 rows |

### Permissions
- Repos are public; no collaborator/triage role needed
- clawgenti PAT with `repo` scope (already configured)
- Only permission exercised: posting PR review comments via API

### Security Considerations
- Skill includes supply-chain hardening: flags PRs touching `.claude/`, `.vscode/` configs
- Read-only analysis; no code from reviewed PRs is executed
- PAT never exposed in comments or logs

### Error Handling
- Zero eligible PRs: scanner reports and exits cleanly; fixer outputs NO_REPLY
- Review failure mid-queue: failed PRs stay in `in_progress`, recycled after 30 min
- Timeout: 1200s (20 min)

### Schedule
- Scanner: every 15 minutes (lightweight, no LLM)
- Fixer: every 15 minutes, offset ~5 min from scanner
- Manual run: `openclaw cron run pr-review-scanner` / `openclaw cron run pr-review-fixer`
