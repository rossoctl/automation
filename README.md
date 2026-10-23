# rossoctl/automation

Version-controlled home for rossoctl org automation programs (scanner/fixer pattern).

## Structure

```
scripts/           Program scripts (scanner + fixer per program) + the RepoMan engine
standing-orders/   Standing order definitions per program
automation-health/ Automation-health dashboard assets
snapshot/          Host snapshot/restore toolkit
docs/              Program authoring + self-hosting guides
tests/             Shell test suite (run in CI)
tools/             Local-only dev tooling (gitignored dogfood, etc.)
reports/           (gitignored) Runtime data stays on remote host only
```

> **Repo vs. deployment.** This repo tracks the RepoMan `~/.repoman/` model: the enrolled
> repo set lives in `repos.json` (not a committed `config/core-repos.txt` allowlist), and
> programs run through `repoman-run.sh`. The live production deployment has **not** been
> migrated yet — it still runs the earlier config-era setup (`config/core-repos.txt` +
> `config/org.env`, consumed via `get_core_repos()`), which is why the Org profile and
> Deploy sections below describe that model. Tracking the migration:
> [#119](https://github.com/rossoctl/automation/issues/119).

## Programs

| Program | Scanner | Fixer | Notes |
|---------|---------|-------|-------|
| Link Health | `scripts/link-health-scanner.sh` | `scripts/link-health-fixer.sh` | Detects broken links, files issues, and opens fix PRs. Epic [#1178](https://github.com/rossoctl/rossoctl/issues/1178) |
| PR Review | `scripts/pr-review-scanner.sh` | `scripts/pr-review-fixer.sh` | Scanner finds PRs labeled for review; fixer performs the AI review (posts review + inline comments, advances the review-state label). `scripts/pr-review-impact.sh` measures time-to-merge impact |
| Dependency Bump | `scripts/dep-bump-scanner.sh` | `scripts/dep-bump-fixer.sh` | Tracks and triages Dependabot PRs across repos (comments, closes stale, audits coverage) |
| Health Dashboard | `scripts/automation-health-dashboard.sh` | — | Aggregates program run health into a dashboard |

Shared helpers live in `scripts/program-lib.sh`, a thin aggregator that sources four focused library modules (see [Library structure & portability](#library-structure--portability)). Repo coverage comes from the `config/core-repos.txt` allowlist via `get_core_repos()` (one **bare repo name** per line -- the owner is prepended from the active org; `#` comments and blank lines allowed) -- edit that file to change which repos are scanned.

### Running a program (RepoMan run path)

Under RepoMan, programs are run through the **orchestrator** rather than by invoking a scanner directly:

```bash
# Run a program across all enrolled repos
bash scripts/repoman-run.sh <program>

# Run across a named subset (e.g. re-run one repo after a transient failure)
bash scripts/repoman-run.sh <program> owner/name [owner/name ...]

# Preview a program: no issues/PRs filed or closed, no clones or reports written
# (weekly-report has no --dry-run but is read-only, so it previews the same way)
bash scripts/repoman-run.sh <program> --dry-run
```

`<program>` is one of `link-health`, `dep-bump`, `pr-review`, `weekly-report`, `automation-health`, `repo-sync` (the full set is whatever `repoman-run.sh --help` lists). The orchestrator resolves the repo set, runs the capability check and clone refresh the program needs, execs it, and writes its `_index.json` entry — it is the **sole writer of `_index.json`**, so a program run directly (the commands in the table above) no longer updates the registry the dashboard reads. `repoman run <program>` is the blessed path for an indexed run.

There is no `repoman` executable in this repo yet; `repoman run <program>` maps to `bash scripts/repoman-run.sh <program>`. In a RepoMan deployment the `/repoman` skill (in `rossoctl/agent-skills`) performs that mapping from a Claude Code / OpenClaw agent; scheduled DAM/OpenClaw jobs invoke the same command string. As of v0.1.0 that skill ships as a **self-contained plugin** that bundles this engine (the `scripts/` here are vendored into it), so the skill no longer assumes a checkout of this repo is present. Standing-orders that still call scanners directly are tracked for migration in [#118](https://github.com/rossoctl/automation/issues/118). See the run-path design in `docs/specs/` and the epic [#72](https://github.com/rossoctl/automation/issues/72).

## Library structure & portability

Shared shell helpers live in four flat modules under `scripts/`, sourced through the `program-lib.sh` aggregator so program scripts can `source "$SCRIPT_DIR/program-lib.sh"` unchanged:

| Module | Responsibility |
|--------|----------------|
| `core.sh` | Workspace/temp management, portable date math, JSON-schema validation, scan diffing, report file I/O |
| `github-api.sh` | Rate-limit-aware `gh` wrapper, issue read/close/PR-check helpers |
| `fork.sh` | Fork/PR creation, issue-field validation, link-fix candidate scoring |
| `org.sh` | Org-profile loading, core-repo allowlist reads, canonical-name remap, repos-dir validation |

Each module has a load-once guard, so it is safe to source more than once (and a subset can be vendored on its own).

**Portability contract:** the suite targets **bash 3.2+** (macOS's default) through modern bash. Do not introduce associative arrays (`declare -A`), `mapfile`/`readarray`, or GNU-only `sed`/`grep`/`date` flags without a BSD-compatible fallback. CI (`.github/workflows/tests.yml`) runs the test suite on both Linux and macOS and shellchecks the library modules, so the macOS leg catches bash-4-isms automatically.

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

- Reports: `~/reports/<program>/` (remote host only) -- one directory per program, siblings of the shared `~/reports/_index.json`.
- Cron jobs managed via OpenClaw gateway (`~/.openclaw/cron/jobs.json`).
- Bot account: [clawgenti](https://github.com/clawgenti).

See `docs/running-without-openclaw.md` to run the programs outside OpenClaw, and `docs/program-template.md` to author a new program.
