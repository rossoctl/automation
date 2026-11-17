# RepoMan v0.1.0 Release & Packaging Design

**Status:** approved (decisions settled 2026-10-22)
**Supersedes packaging direction in:** the "engine-release + `$REPOMAN_ENGINE_DIR` install prefix" idea (dropped).

## Goal

Ship RepoMan v0.1.0 as **one self-contained `repoman` plugin** in the existing
`rossoctl-agent-skills` marketplace, bundling the entrypoint skill + all program
skills + the engine scripts, with the engine vendored from `automation` as the
source of truth. No repo rename, no new repo/org, no engine code change.

## Context (two repos)

- **automation** — dev source of truth: engine scripts (`scripts/*.sh`), tests, CI,
  dogfood, specs.
- **agent-skills** — distribution: the `rossoctl-agent-skills` marketplace users install.

The engine is developed and tested in automation; the plugin that users run lives in
agent-skills. A release vendors the former into the latter.

## Decisions

### 1. Version
Single version **v0.1.0**. `agent-skills/.claude-plugin/marketplace.json` version (line 9)
is reconciled from the pre-release `1.0.0` to `0.1.0`.

### 2. Repo structure
Unchanged. No rename of agent-skills (it is multi-tenant: also hosts hypershift,
byo-rossoctl-cortex). Branding reaches users via the **plugin name `repoman`**.

### 3. The `repoman` plugin (edit the existing marketplace entry)
The marketplace already has a `repoman` entry with `skills: ["./skills/repoman"]`
(entrypoint only). **Edit it** to bundle the program skills:

```json
{ "name": "repoman", "source": "./", "strict": false,
  "skills": [
    "./skills/repoman",
    "./skills/link-health-scanner",   "./skills/link-health-fixer",
    "./skills/dep-bump-scanner",      "./skills/dep-bump-fixer",
    "./skills/github-pr-review",
    "./skills/repo-sync",
    "./skills/automation-health-dashboard",
    "./skills/github-weekly-report"
  ] }
```

A marketplace entry with `source: "./"` + a `skills[]` list is this repo's existing
bundle mechanism (every standalone plugin uses it). No `.claude-plugin/plugin.json`.

**Standalone plugins stay** — each program remains independently installable. The
duplication is of marketplace *entries*, not of source of truth (all vendored from
automation), so one push fans out to standalone and bundled users alike.

### 4. Engine layout — flat dir, zero engine code change
`repoman-run.sh` resolves scanners via `_bin() { echo "${REPOMAN_RUN_BIN:-$SCRIPT_DIR}/$1"; }`,
and scanners source siblings (`source "$SCRIPT_DIR/program-lib.sh"`). The engine
therefore **requires a flat directory**. The whole engine ships to one flat dir in the
plugin; the engine sets `REPOMAN_RUN_BIN` to that dir. `REPOMAN_RUN_BIN` is the existing
run-time override — not a new install mechanism.

Engine dir = `skills/repoman/scripts/` (the entrypoint skill's existing scripts dir).
Paths resolve at runtime via `${CLAUDE_PLUGIN_ROOT}`.

### 5. Vendor source & manifest
**Source: `automation/scripts/` — verified newest for every engine file** (git dates
2026-10). **SKILL.md stays agent-skills-canonical** (newest, carries the
`### Requirements` blocks). automation's own `skills/` dir is a stale stub (3 files
across 2 program dirs: `skills/dep-bump/SKILL.md`, `skills/dep-bump/FIXER-SKILL.md`,
`skills/link-health/SKILL.md`) — not a vendor source, and **deleted by this work** (see
Deliverable 5) to remove a false source of truth.

The engine is one cohesive flat set (nearly all scripts source `program-lib.sh`, which
sources `org.sh`/`core.sh`). So the manifest vendors the **entire engine** into the flat
dir — all 23 `automation/scripts/*.sh`:

```
automation-health-dashboard.sh  core.sh  dep-bump-fixer.sh  dep-bump-scanner.sh
extract-broken-links.sh  fork.sh  github-api.sh  link-health-fixer.sh
link-health-scanner.sh  org.sh  parse-diff-map.sh  pr-review-fixer.sh
pr-review-impact.sh  pr-review-lib.sh  pr-review-scanner.sh  program-lib.sh
repo-sync.sh  repoman-check.sh  repoman-index.sh  repoman-requirements.sh
repoman-run.sh  repoman-setup.sh  weekly-report.sh
```
→ all into `agent-skills/skills/repoman/scripts/`.

The vendor script is a **~30-50 line explicit copy** (`automation/scripts/<f>` →
`agent-skills/skills/repoman/scripts/<f>`), **never a glob into other skill dirs**. It
must not touch the standalone skills' own `scripts/` (see Out of Scope).

### 6. Provenance stamp
The vendor script records which automation commit it vendored, reusing the Phase 6
pinned-SHA machinery (`2026-10-05-repoman-phase6-provenance-attribution-design.md`).
Written into the repoman plugin at vendor time so a shipped bundle is traceable to its
automation source SHA.

### 7. pr-review (flagship)
One `github-pr-review` skill. Its 4 scripts (`pr-review-scanner.sh`, `pr-review-fixer.sh`,
`pr-review-lib.sh`, `pr-review-impact.sh`) live only in automation today — they land in
the flat engine dir via the manifest like every other engine script (no separate
first-class vendoring path needed). The pr-review "fixer" is a begin/finalize **state
manager**, internal to the pr-review program, not a separate user-facing skill.

Unlike the dormant standalone link-health/dep-bump skills, `github-pr-review` is actively
invoked today. Vendoring its scripts into the bundle must not alter the behavior of the
existing standalone `github-pr-review` flow.

### 8. Fixers
The run path (`repoman run`) is **scanner-only** — no fixer is in its program table.
`link-health-fixer` and `dep-bump-fixer` are true repair tools, bundled as skills and
driven by their own flow/schedule. v0.1.0 does not wire fixers into the run path.

## Out of Scope

**Standalone scanner/fixer resync (`rossoctl/agent-skills#51`).** The standalone
link-health/dep-bump skills carry a **different, monolithic** `program-lib.sh` (~662
lines, Jun) than the RepoMan 20-line aggregator, and their scanners/fixers have diverged
too. These standalone skills are not currently invoked, so the divergence is not biting;
a safe fix is a full resync onto the modular engine lib, tracked in #51. The v0.1.0
vendor manifest targets only `skills/repoman/scripts/` and must never flatten those
standalone copies.

**Committed cross-repo parity guard (`rossoctl/agent-skills#47`).** That issue asks for a
CI test that diffs agent-skills' vendored *dashboard* copies against automation's at a
pinned SHA, so they cannot silently drift. This spec adds the vendor + provenance stamp
(§5–6) but **not** a committed parity test; #47 remains the home for that guard, and its
scope naturally widens once the bundle vendors the whole engine (not just the dashboard
set). (Note: `automation#47` is an unrelated merged PR — the parity issue is the
agent-skills one.)

## Deliverables

1. Edit the `repoman` marketplace entry to the `skills[]` list in §3.
2. Reconcile `marketplace.json` version `1.0.0` → `0.1.0`.
3. A vendor script (automation → `skills/repoman/scripts/`) per the §5 manifest, with
   the §6 provenance stamp.
4. Ensure the bundled engine resolves via `REPOMAN_RUN_BIN=${CLAUDE_PLUGIN_ROOT}/skills/repoman/scripts`
   (wiring in the entrypoint skill's invocation of the engine; no change to the engine
   scripts themselves).
5. Delete automation's stale `skills/` dir (`skills/link-health/`, `skills/dep-bump/`) —
   it is not a vendor source and has already caused missteps. Do this as part of this
   work, since we are editing automation anyway.
