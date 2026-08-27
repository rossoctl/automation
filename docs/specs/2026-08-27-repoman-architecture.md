# RepoMan Architecture — Multi-Owner Automation Interface

**Date:** 2026-08-27
**Status:** Design (awaiting review)
**Related:** discussion [#62](https://github.com/rossoctl/automation/discussions/62) (owner-model portability), issue [#65](https://github.com/rossoctl/automation/issues/65) (skill drift), issue [#39](https://github.com/rossoctl/automation/issues/39) (repo-onboarding capability check)

## Summary

RepoMan wraps the existing scanner/fixer programs behind a discovery and configuration
interface. It replaces the current single-`$ORG` plus flat `$REPOS_DIR` identity model with
per-repo `{owner, name}` tuples drawn from a user-managed list, so any combination of org and
user repos can be covered in one deployment. A user can ask what programs are available, add
repos by URL or slug, configure output destinations per program, and register durable
schedules, all without editing config files. The system is designed to run on both DAM
(pod-based, persistent `$HOME`) and OpenClaw (VM-based) with identical program logic and a thin
deployment adapter layer.

This document is the architecture spec only. The phased implementation plan and issue breakdown
are tracked separately in the epic.

## Overview

```
  User (natural language or CLI)
   │
   │  "what can you do?"
   │  "add github.com/alice/tool"
   │  "run link-health on those repos weekly"
   ▼
┌────────────────────────────────────────────────────┐
│                REPOMAN INTERFACE                   │
│                                                    │
│  discover ──► onboard ──► configure ──► schedule  │
│                  │                                 │
│          capability check                         │
│          (per program, per repo, at invocation)   │
└──────────────────┬─────────────────────────────────┘
                   │  explicit {owner, name} tuples
       ┌───────────┼──────────────┬────────────────┐
       ▼           ▼              ▼                ▼
  link-health   dep-bump      pr-review       automation-
  scanner/      scanner/      scanner/        health-
  fixer         fixer         fixer           dashboard
       │           │              │                │
       └───────────┴──────────────┘                │
                   │ writes                        │ reads
                   ▼                               │
           ~/reports/<program>/     ◄──────────────┘
             latest.json              via _index.json
             history.json             (program registry)
             state.json
```

## Setup flow

On first run RepoMan walks five questions. Mid-to-low tier models (for example Gemini Flash,
GLM) receive explicit option lists rather than open-ended prompts. All answers are persisted
immediately so a pod restart mid-setup can resume.

```
1. "Where should I clone repos for scanning?"
   Default: ~/repoman/repos   (say 'yes' to accept, or provide a path)
   Saved to: ~/.repoman/config.json { "repos_dir": "..." }

2. "Add repos to cover:"
   Option A: enter owner/repo slugs or URLs one by one
   Option B: "enroll an entire org" -- runs:
     gh repo list <org> --json nameWithOwner,isArchived
     filters archived, bulk PAT scope check against org
     (per-program capability checks still happen at invocation, not here)
   Saved to: ~/.repoman/repos.json

3. "Which programs do you want to run?"
   Presents list with one-line descriptions from each skill's SKILL.md.
   Saved to: ~/.repoman/programs/<name>.json (created per selected program)

4. "Would you like to set up nightly repo sync?"
   Recommended. Keeps clones fresh for scanners.
   If yes: registers repo-sync program (see Repo sync program).
   Deferred: user can add this later with `repoman setup sync`.

5. Output destination is NOT asked at setup. It is asked the first time each
   program is invoked (see Program invocation flow).
```

## Program invocation flow

```
repoman run link-health-scanner
  │
  ├─► first invocation only:
  │     "Where should issues be posted?"
  │       [a] Same repo as the finding (default, recommended)
  │       [b] One central repo for all: ________
  │     Saved to ~/.repoman/programs/link-health.json
  │     Not asked again unless user resets config.
  │
  ├─► capability check (every invocation, fast):
  │     reads ~/.repoman/programs/link-health.json { pat_scopes, labels }
  │     checks each repo in repos.json
  │     if gaps: "alice/tool is missing broken-link labels.
  │               Fix now / skip this repo / disable program?"
  │
  ├─► refresh clones:
  │     pull if present, clone if missing
  │     target: <repos_dir>/<owner>/<name>/   (owner-namespaced)
  │
  ├─► exec link-health-scanner.sh
  │     --repos rossoctl/automation alice/tool ...
  │     --output-repo <from programs/link-health.json>
  │
  └─► write ~/reports/link-health/latest.json
            ~/reports/link-health/history.json
            ~/reports/link-health/state.json
            ~/reports/_index.json  (updated)
```

## Input model — replacing $ORG

```
TODAY                              REPOMAN
──────────────────────────────────────────────────────────────
$ORG = "rossoctl"                  ~/.repoman/repos.json:
core-repos.txt:                    [
  automation              →          {"owner": "rossoctl", "name": "automation"},
  agent-skills                       {"owner": "rossoctl", "name": "agent-skills"},
  cortex                             {"owner": "alice",    "name": "tool"}
                                   ]

get_core_repos()                   repoman_get_repos()
  prepends $ORG to every name        owner is per-entry, not global

$REPOS_DIR = ~/rossoctl/           <repos_dir> from config.json:
  automation/             →          rossoctl/
  agent-skills/                        automation/
  cortex/                              agent-skills/
                                     alice/
                                       tool/
                                         (owner-namespaced; no collisions)
```

`FORK_OWNER` (`clawgenti`) stays a single global. `gh repo fork alice/tool --org clawgenti`
already works cross-org.

## Repo sync program

Repo sync keeps clones fresh. It must become a first-class skill (currently only a standing
order in `standing-orders/repo-sync.md`). Creating the skill is a prerequisite for the OpenClaw
skill-install path (see Skill layer).

```
repo-sync skill (to be created in rossoctl/agent-skills)
  input:  repos.json  ──► [{owner, name}, ...]
          + ~/agent-skills/ (clone of agent-skills, also refreshed by this job)
  action: clone if missing, git pull if present per repo
          git pull in ~/agent-skills/ to refresh skills
  target: <repos_dir>/<owner>/<name>/
  output: sync-report (failed repos logged, not fatal; nothing posted to GitHub)
  writes: nothing to GitHub (read-only)

Schedule: nightly, offset before scanners run
```

## State and persistence

```
DURABLE (GitHub)                PERSISTENT ($HOME)              EPHEMERAL
────────────────────────────────────────────────────────────────────────────
GitHub Issues                   ~/.repoman/                     in-memory
  scanner → fixer handoff         config.json                   only
  survives anything               repos.json
                                  programs/<name>.json
GitHub review body
  <!-- reviewed: SHA -->        ~/reports/
  NOTE: SHA = the PR commit       _index.json  ◄── program registry
  being reviewed, NOT the           {
  skill version. Re-review            "link-health": {
  triggers on new PR commit,            "skill": "link-health-scanner",
  not on skill update. Skill            "version": "85449beb",
  version is attribution only.          "last_run": "2026-08-27T...",
                                         "report_path": "~/reports/link-health"
                                       }
                                    }

                                  link-health/
                                    latest.json
                                    history.json
                                    state.json
                                  dep-bump/
                                    latest.json
                                    history.json
                                    state.json
                                    fixer-latest.json
                                    fixer-history.json
                                  automation-health/
                                    latest.json

                                <repos_dir>/
                                  <owner>/<name>/   (clone cache)

Loss consequence:
  unrecoverable                 recoverable on next run         no impact
  (GitHub Issues are the        (may re-open already-open
  source of truth for            issues; dedup catches them)
  open work)
```

## Skill layer

Skills are stateless. All config flows in as runtime parameters. No org names or paths are
embedded in skill files. This closes issue [#65](https://github.com/rossoctl/automation/issues/65)
structurally, because there are no local copies to drift.

```
rossoctl/agent-skills (canonical)
  skills/link-health-scanner/
    SKILL.md          ◄── includes ## Requirements block (machine-readable)
    scripts/
    reference/
         │
         │  DAM: install_skill MCP or UI
         │  OpenClaw: repo-sync clones ~/agent-skills/,
         │            agent loads skill from there at runtime
         ▼
  ~/skills/link-health-scanner/     (DAM)
  ~/agent-skills/skills/...         (OpenClaw, refreshed nightly by repo-sync)
    SKILL.md
    _meta.json:
      {
        "version": "85449beb",
        "source":  "rossoctl/agent-skills",
        "installed_at": "2026-08-27"
      }
```

The `## Requirements` block in each SKILL.md declares what the skill needs. This is the source
RepoMan's capability check reads. It must be parseable by mid-to-low tier models without
inference, so it uses an explicit key-value format rather than prose.

```markdown
## Requirements
- pat_scopes: [repo, read:org]
- labels: [broken-link/internal, broken-link/external]
- programs: [scanner, fixer]
```

PR and issue body attribution uses the pinned SHA.

```
Generated by link-health-scanner@85449beb
https://github.com/rossoctl/agent-skills/blob/85449beb/skills/link-health-scanner/SKILL.md
```

On OpenClaw, when repo-sync pulls a new SHA for agent-skills, the user is prompted.

```
"link-health-scanner was updated (85449beb → f4ae90e).
 Run sync now to pick it up, or wait for tonight's scheduled sync?"
```

## Automation health dashboard

The dashboard is a consumer of the other programs' reports, not a scanner itself. Today it has
hardcoded paths to `link-scan/latest.json` and `dep-bump/latest.json`. Under RepoMan it reads
`~/reports/_index.json` to discover active programs dynamically. Adding a new program means it
appears in `_index.json` and the dashboard picks it up on the next run, with no hardcoded path
changes needed.

## Deployment

```
           PROGRAM (scanner.sh / fixer.sh)
           identical invocation everywhere
                         │
         ┌───────────────┴─────────────────┐
         ▼                                 ▼
   DAM POD                           OPENCLAW VM
   ──────────────────────────        ──────────────────────────
   state root: $HOME                 state root: $HOME
     (persistent volume)               (VM disk)

   skill source: install_skill        skill source: ~/agent-skills/
     MCP or UI; _meta.json              clone, refreshed nightly
     written at install time            by repo-sync; _meta.json
                                        written by repo-sync on pull

   schedule: platform MCP             schedule: jobs.json
     create_schedule(                   (gateway restart needed
       rrule, timezone,                  for changes; user prompted
       task="repoman run ..."            "apply now or wait?")
     )

   skill updates: install_skill       skill updates: repo-sync
     user prompted on new SHA           pulls agent-skills nightly;
                                        user prompted to sync now
                                        or wait for next cycle
```

## GitHub Actions (out of scope, noted for future)

`github-pr-review` and `github-weekly-report` are good candidates for a pure Actions port since
they need no local clones. The scanning programs (link-health, dep-bump) need persistent clone
state and `state.json`, so the natural fit is either a self-hosted runner or storing state as a
committed branch. See `skillberry-ai/skillberry-common/.github/workflows` as a reference harness
pattern. Design tracked separately, and it does not block the core implementation.
