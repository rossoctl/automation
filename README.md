# rossoctl/automation

Version-controlled home for rossoctl org automation programs (scanner/fixer pattern).

## Structure

```
scripts/           Program scripts (scanner + fixer per program)
config/            Shared configuration (e.g. core-repos.txt allowlist)
skills/            OpenClaw SKILL.md files per program
standing-orders/   Standing order definitions per program
docs/              Program authoring + self-hosting guides
reports/           (gitignored) Runtime data stays on remote host only
```

## Programs

| Program | Scanner | Fixer | Notes |
|---------|---------|-------|-------|
| Link Health | `scripts/link-health-scanner.sh` | `scripts/link-health-fixer.sh` | Detects broken links, files issues, and opens fix PRs. Epic [#1178](https://github.com/rossoctl/rossoctl/issues/1178) |
| PR Review | `scripts/pr-review-scanner.sh` | `scripts/pr-review-fixer.sh` | Scanner finds PRs labeled for review; fixer performs the AI review (posts review + inline comments, advances the review-state label). `scripts/pr-review-impact.sh` measures time-to-merge impact |
| Dependency Bump | `scripts/dep-bump-scanner.sh` | `scripts/dep-bump-fixer.sh` | Tracks and triages Dependabot PRs across repos (comments, closes stale, audits coverage) |
| Health Dashboard | `scripts/automation-health-dashboard.sh` | — | Aggregates program run health into a dashboard |

Shared helpers live in `scripts/program-lib.sh`. Repo coverage comes from the `config/core-repos.txt` allowlist via `get_core_repos()` (one **bare repo name** per line -- the owner is prepended from the active org; `#` comments and blank lines allowed) -- edit that file to change which repos are scanned.

## Org profile

Org identity (which GitHub org the programs target) lives in one committed profile file, `config/org.env`. It assigns only `PROFILE_`-prefixed keys:

```bash
PROFILE_ORG=rossoctl              # the org (required)
PROFILE_FORK_OWNER=clawgenti      # fork account for cross-fork PRs
PROFILE_MAIN_REPO=rossoctl/rossoctl
PROFILE_REPOS_DIR=/home/claw/rossoctl
PROFILE_REMAP="kagenti:rossoctl kagenti-extensions:cortex"  # transitional
```

Each program calls `load_org_profile()` (in `program-lib.sh`), which resolves the identity by precedence **`--flag` > env var > profile > built-in default**:

- `--org NAME` / `ORG` -- the org (fails loud if it cannot be resolved).
- `--fork-owner NAME` / `FORK_OWNER` -- fork account (default `clawgenti`).
- `--repos-dir DIR` / `REPOS_DIR` -- local clone root (default `$HOME/$ORG`).
- `--main-repo-dir DIR` / `MAIN_REPO_DIR` -- the main-repo clone for dashboard/report git ops.

`PROFILE_REMAP` is profile-only (transitional; maps pre-rename clone-dir names to canonical names). To target a **different org**, copy `config/org.env` to `config/org.<name>.env`, edit the `PROFILE_*` values, and run any program with `--profile <name>` (or `ORG_PROFILE=<name>`). No per-script edits are needed.

## Deploy

Scripts run on the remote host (`kagenti-bot:~/workspaces/clawgenti/scripts/`).
Deploy after merging changes:

```bash
scp scripts/<name>.sh kagenti-bot:~/workspaces/clawgenti/scripts/
```

No gateway restart needed -- scripts are read from disk on each cron trigger.

All programs resolve their org identity from `config/org.env`, and allowlist-driven scanners/fixers also read `config/core-repos.txt`. Both must be present on the host alongside the scripts:

```bash
scp config/org.env config/core-repos.txt kagenti-bot:~/workspaces/clawgenti/config/
```

## Runtime

- Reports: `~/workspaces/clawgenti/reports/<program>/` (remote host only) -- one directory per program.
- Cron jobs managed via OpenClaw gateway (`~/.openclaw/cron/jobs.json`).
- Bot account: [clawgenti](https://github.com/clawgenti).

See `docs/running-without-openclaw.md` to run the programs outside OpenClaw, and `docs/program-template.md` to author a new program.
