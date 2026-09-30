# RepoMan Phase 5 — `_index.json` registry + dashboard discovery design

**Date:** 2026-09-30
**Status:** Approved (2026-09-30)
**Epic:** [#72](https://github.com/rossoctl/automation/issues/72) (Phase 5 = [#76](https://github.com/rossoctl/automation/issues/76))
**Milestone:** RepoMan v0.1.0
**Parent spec:** `docs/specs/2026-08-27-repoman-architecture.md` (§Program invocation flow, §State and persistence, §Automation health dashboard)

## Summary

Give RepoMan a program registry. Each scanner, after it writes its reports,
records a small entry in `~/reports/_index.json` naming itself and where its
reports live. The automation-health dashboard stops hardcoding which programs
exist and where their report directories are; instead it reads `_index.json`,
discovers the active programs, and renders one section per registered program.
Adding a program to a deployment becomes a matter of that program appearing in
the index, not editing the dashboard.

Phase 5 delivers three things:

1. **`scripts/repoman-index.sh`** — a standalone, RepoMan-agnostic writer that
   upserts one program's entry into an `_index.json` whose path is passed in.
2. **Wiring** — the `link-health` and `dep-bump` repo scanners call the writer
   after they write their reports, so the write path is exercised end-to-end in
   tests and dog-food, not just described.
3. **Dashboard discovery** — `scripts/automation-health-dashboard.sh` reads
   `_index.json` (path passed in) to discover programs and drive section
   headings from registry data, falling back to disk-derived discovery when the
   index is absent.

The companion `skills/automation-health-dashboard/SKILL.md` in agent-skills
gets prose-only updates to match the new discovery behavior.

## Scope and non-scope

**In scope:**
- `scripts/repoman-index.sh` — the registry writer (new).
- `tests/test-repoman-index.sh` — hermetic tests for the writer (new).
- Wire the writer into `scripts/link-health-scanner.sh` and
  `scripts/dep-bump-scanner.sh` after their report writes.
- Rename the link-health report directory default `link-scan` → `link-health`
  in `scripts/link-health-scanner.sh` and in the dashboard's dir constant. The
  parent spec (§Automation health dashboard) mandates this rename and flags the
  current `link-scan` name as the thing to migrate.
- Rework `scripts/automation-health-dashboard.sh` to discover programs from
  `_index.json` (path passed in), with disk-derived fallback when absent.
- `tests/test-automation-health-dashboard.sh` — a new hermetic dashboard test
  (none exists today).
- Prose-only alignment of `skills/automation-health-dashboard/SKILL.md` in
  agent-skills.

**Explicitly NOT in scope (owned elsewhere, do not implement here):**
- **No `skill` or `version` field in `_index.json`.** The parent spec's
  §State-and-persistence diagram shows a `version` (skill SHA) in the entry, but
  its own adjacent note says that SHA is attribution-only, and no scanner today
  carries any skill-SHA/version/`_meta` handle to source it from. Skill-version
  provenance is Phase 6 ([#77](https://github.com/rossoctl/automation/issues/77),
  `_meta.json` written by each skill's entry point). Phase 5 writes only fields
  it can source truthfully; a later phase enriches the same entries.
- **No `~/.repoman` reads in the new surface.** The writer takes the index path
  and report path as arguments; the dashboard takes the index path as a
  parameter. Neither new code path reads `config.json` or `~/.repoman`. This
  keeps the new surface RepoMan-agnostic, per the parent spec's Skill-layer
  principle ("Skills are stateless. All config flows in as runtime parameters").
- **No decoupling of the pre-existing `repoman_config` calls.** `link-health`,
  `dep-bump`, both fixers, and the dashboard already call `repoman_config`
  today. Phase 5 does not deepen that coupling and does not fix it — peeling it
  back is a separate cross-cutting refactor, filed as a follow-up (see
  Follow-ups). Existing `repoman_config` calls are left untouched.
- **No `pr-review` dashboard section — but this is a planned upgrade, not a
  permanent exclusion.** The authoritative dashboard renders link-health and
  dep-bump only today (verified: PR [#95](https://github.com/rossoctl/automation/pull/95)'s
  generated output reports "Programs active | 2", and the script has no
  pr-review code). A pr-review section — reviewed-PR counts and the
  before/after review-merge-delta impact metrics — was always intended (it is
  the dashboard half of the impact-metrics + blog effort) and simply has not
  been built. Phase 5 does not build it, because Phase 5 is scoped to the
  registry-and-discovery *mechanism*, not to authoring a new program section.
  Instead, Phase 5's discovery layer is built so that the moment a `pr-review`
  entry appears in `_index.json`, the dashboard will attempt to render it, and
  the missing pr-review section is filed as a follow-up upgrade (see Follow-ups)
  rather than silently dropped.
- **No `repoman run` orchestrator.** The parent spec's invocation flow lists the
  index write as the final stage of `repoman run`, but that orchestrator does
  not exist yet and its assembly is deferred to the epic. Phase 5 exercises the
  write path by wiring it directly into the scanners, not through `repoman run`.
- **No deploy-copy touch.** All edits are to the repo source-of-truth scripts
  (`automation/scripts/*.sh`), exercised in tests and dog-food. The bot's
  hand-assembled deploy copy (`~/workspaces/clawgenti/scripts/` on the VM) is
  updated only at a future deploy step, not by this change.

## Global constraints

- `bash` 3.2 compatible (macOS default): no `mapfile`, no associative arrays
  unless guarded. Follow the `while IFS= read -r` idiom used elsewhere.
- `set -uo pipefail`, **not** `-e`. Match the sibling scripts.
- **Surface every failure to the caller.** Every command's return code and
  every command-substitution output matters unless a swallow is explicitly
  stated. Under `set -uo pipefail` an unguarded `$(cmd)` captures empty on
  failure and the caller proceeds as if it got a valid answer — the
  silent-failure class flagged in the Phase 3 review. Check each `jq` and file
  operation's exit code directly; never capture a fallible call's output in a
  way that discards its rc.
- **`jq`-only JSON.** Never hand-splice JSON with `echo`/`printf`. The writer
  builds and mutates the index exclusively through `jq` (`jq -n` for a fresh
  index, `jq --arg`/`--argjson` for the upsert) so values are always correctly
  escaped.
- **Atomic write.** The index is rewritten by writing to a temp file in the same
  directory and `mv`-ing it into place, never edited in place. A crash mid-write
  never leaves a truncated `_index.json`.
- The new writer reads no `config.json` and no `~/.repoman`; all inputs are
  arguments or (for `last_run`) the writer's own clock.
- DCO `-s` sign-off; `Assisted-By`, never `Co-Authored-By`; PR title starts with
  a capitalized prefix.

## The `_index.json` contract

`_index.json` is a JSON object keyed by program id. Each value is a program
entry. Phase 5 defines exactly three fields:

```json
{
  "link-health": {
    "display_name": "Link Health",
    "report_path": "/home/bot/reports/link-health",
    "last_run": "2026-09-30T14:22:07Z"
  },
  "dep-bump": {
    "display_name": "Dependency Bumps",
    "report_path": "/home/bot/reports/dep-bump",
    "last_run": "2026-09-30T14:25:11Z"
  }
}
```

| Field | Source | Meaning |
|---|---|---|
| key (program id) | writer `--program` arg | stable machine id; selects the dashboard's per-program field-extraction block |
| `display_name` | writer `--display-name` arg | human section heading; makes headings data-driven, not hardcoded string literals |
| `report_path` | writer `--report-path` arg | absolute dir holding that program's `latest.json` / `history.json` |
| `last_run` | writer's own clock (`date -u +%Y-%m-%dT%H:%M:%SZ`) | when this entry was last upserted |

The program id is authoritative for behavior; `display_name` is authoritative
for presentation. This is the "Light" self-describing registry: the heading text
is data, but the dashboard still keeps a per-program-id block that knows which
`jq` fields to pull (`.broken[]` for link-health, `.stale_prs` for dep-bump).
A fully generic field-descriptor renderer is a deliberate future upgrade, not
Phase 5.

`skill` / `version` are intentionally absent in Phase 5 and added by Phase 6.
A dashboard reading the index must tolerate extra unknown fields (forward
compatibility) and must not require `skill`/`version`.

## Component 1 — `scripts/repoman-index.sh` (writer)

A standalone script that upserts exactly one program entry into an
`_index.json`. It is the only writer of `_index.json`.

### Interface

```
repoman-index.sh --index <path> --program <id> --display-name <name> \
                 --report-path <path> [--dry-run] [--help]
```

| Flag | Required | Meaning |
|---|---|---|
| `--index PATH` | yes | path to the `_index.json` to create/update |
| `--program ID` | yes | program id (the object key), e.g. `link-health` |
| `--display-name NAME` | yes | human heading, e.g. `Link Health` |
| `--report-path PATH` | yes | absolute report dir for this program |
| `--dry-run` | no | print the resulting index to stdout, write nothing |
| `--help` | no | usage to stdout, exit 0 |

`last_run` is not an argument — the writer stamps it from its own clock at
upsert time (`date -u`). This keeps the writer self-contained and means a
scanner does not have to thread its scan timestamp through.

### Behavior

- If `--index`'s file does not exist, start from an empty object (`jq -n '{}'`).
  If it exists, load it. If it exists but is not valid JSON → fail loud
  (non-zero exit, message names the file). A corrupt index is an error, never
  silently overwritten.
- Upsert: set `.[$program]` to an object with `display_name`, `report_path`, and
  a freshly stamped `last_run`, via `jq --arg`. An existing entry for the same
  program id is replaced; other programs' entries are preserved untouched.
- Write atomically: `jq` output to a temp file in the index's directory, then
  `mv` into place. Create the index's parent directory if missing.
- `--dry-run`: compute the new index and print it to stdout; make no filesystem
  change (no temp file, no `mv`, no mkdir).
- Every fallible step (`jq` parse, temp write, `mv`) has its rc checked; a
  failure is loud and non-zero.

### Error model

| Condition | Behavior |
|---|---|
| a required flag missing | fail loud, exit non-zero, usage to stderr |
| `--index` file exists but is invalid JSON | fail loud, exit non-zero, names the file |
| temp-write or `mv` fails | fail loud, exit non-zero, surfaces the error |
| `--dry-run` | prints resulting index, writes nothing, exit 0 |
| `--help` | usage to stdout, exit 0 |

## Component 2 — scanner wiring

After each scanner finishes writing its reports (`write_report_latest` +
`append_history_row`), it calls `repoman-index.sh` once to register itself.

- `scripts/link-health-scanner.sh`: after its report writes, invoke
  `repoman-index.sh --index "<index path>" --program link-health
  --display-name "Link Health" --report-path "$REPORTS_DIR"`.
- `scripts/dep-bump-scanner.sh`: same shape with `--program dep-bump
  --display-name "Dependency Bumps" --report-path "$REPORTS_DIR"`.

Index-path resolution in the scanner: the index lives alongside the program
report dirs, i.e. the parent of `REPORTS_DIR` (`<reports-base>/_index.json`),
overridable by an env var (`REPOMAN_INDEX_FILE`) so tests and dog-food can point
it at a scratch path. The scanner does not read `~/.repoman` to find the index;
it derives the path from the report dir it already knows, matching the agnostic
principle. A failed index write is surfaced (logged, rc checked) but is **not**
fatal to the scan — the scan's own reports are already written and are the
primary product; a registry-write failure must not fail an otherwise-successful
scan. It is logged loudly so it is never silent.

**Rename:** `scripts/link-health-scanner.sh`'s `REPORTS_DIR` default changes its
trailing path segment from `link-scan` to `link-health`. The dashboard's
corresponding dir constant is renamed in lockstep (Component 3). No historical
data migration is specified here — a deployment with existing `link-scan/`
reports is handled at deploy time, out of scope for the repo change.

## Component 3 — dashboard discovery

`scripts/automation-health-dashboard.sh` today hardcodes two dir constants
(`LINK_SCAN_DIR="$REPORTS_DIR/link-scan"`, `DEP_BUMP_DIR="$REPORTS_DIR/dep-bump"`),
two `HAS_*` presence flags, and two section-heading string literals
(`## Link Health`, `## Dependency Bumps`). Phase 5 replaces the discovery layer
while keeping the per-program rendering.

### Index-driven discovery

- New parameter: `--index PATH` (and matching `REPOMAN_INDEX_FILE` env), the
  `_index.json` to read. Default: `<reports-dir>/_index.json` derived from the
  existing `--reports-dir`, consistent with the writer's placement. No
  `~/.repoman` read is added.
- When the index exists and is valid: read its entries. For each known program
  id, take `report_path` and `display_name` from the entry (heading text is now
  data, not a literal), confirm the report files exist, and render that
  program's section using the per-program-id extraction block.
- The per-program-id extraction blocks (which `jq` fields each program's section
  pulls) stay as they are — this is the "Light" boundary. An index entry for a
  program id the dashboard has no extraction block for is skipped with a logged
  note (forward compatibility: a newly enrolled program appears in the index
  before the dashboard learns to render it).

### Absent-index fallback (disk-derived)

When `_index.json` is absent, the dashboard derives the active program set from
disk exactly as today (a report dir with `latest.json` + `history.json` present
means that program is active), but the section heading still comes from a
program-id → display-name lookup rather than a hardcoded heading literal in the
heredoc. This removes the last hardcoded section-name string while preserving
the current no-index behavior. The disk layout it probes uses the post-rename
`link-health` dir name.

The program-id → display-name lookup is a single small table in the dashboard
(the same names the writer would stamp). It is the one place the dashboard
knows program display names, used by both the index path (as a fallback if an
entry somehow lacks `display_name`) and the disk-derived path.

### Cross-cutting sections

`## Cross-Program Coverage`, `## Cron Health`, and `## Executive Summary` are not
per-program sections; they aggregate across whatever programs were discovered.
They continue to work off the discovered set (index-driven or disk-derived)
rather than hardcoded program constants.

## Testing

### `tests/test-repoman-index.sh` (new, hermetic)

No network. `--index` and `--report-path` point at temp paths. Cases:

1. Fresh index (file absent) → entry created; index is valid JSON with exactly
   the one program; `last_run` present and ISO-8601 `Z` form.
2. Upsert into existing index with a different program → both entries present,
   the pre-existing one byte-for-byte preserved.
3. Upsert same program id twice → single entry, second call's `report_path`
   wins, `last_run` refreshed.
4. `--index` points at an invalid-JSON file → fail loud, exit non-zero, message
   names the file, original file left unchanged.
5. Missing required flag → fail loud, exit non-zero, usage to stderr.
6. `--dry-run` → resulting index printed to stdout, no file created/modified.
7. `--help` → usage, exit 0.
8. Atomicity: value containing shell/JSON metacharacters in `--display-name`
   round-trips correctly (proves `jq` escaping, no `echo`-splice).

Each negative test captures and greps stderr (assert the message, not just a
non-zero exit) so "fails cleanly" cannot mean "fails silently".

### `tests/test-automation-health-dashboard.sh` (new, hermetic)

No network; `git`/`gh` stubbed as needed; `--reports-dir` and `--index` point at
fixtures; runs `--dry-run` so nothing is posted. Cases:

1. Index present with link-health + dep-bump entries → both sections rendered,
   headings taken from `display_name`.
2. Index present with only link-health → only that section; no dep-bump section.
3. Index present with an unknown program id (no extraction block) → known
   sections render, unknown id skipped with a logged note, exit 0.
4. Index absent, both report dirs present on disk (post-rename `link-health/`)
   → disk-derived discovery renders both sections with correct headings.
5. Index absent, no report dirs → existing "no reports found" error path,
   unchanged.
6. Index present but invalid JSON → fail loud, exit non-zero, names the file
   (mirrors the writer's corrupt-index stance).

### Scanner wiring tests

Extend `tests/test-link-health-scanner.sh` / `tests/test-dep-bump-scanner.sh`
(or the nearest existing scanner test) with one case each: after a stubbed scan,
`_index.json` at the resolved path contains that program's entry with the
expected id, `display_name`, and `report_path`; and a case where the index write
fails (writer stubbed non-zero) leaves the scan's own exit status successful but
logs the index-write failure.

## Companion — agent-skills SKILL.md

`skills/automation-health-dashboard/SKILL.md` in rossoctl/agent-skills gets
prose-only updates: describe that the dashboard discovers programs from
`_index.json` (path via `--index` / `REPOMAN_INDEX_FILE`), that it falls back to
disk-derived discovery when the index is absent, and that section headings come
from the registry's `display_name`. No behavioral skill logic changes. (The
agent-skills dashboard *script* copy is separately stale versus automation and
its resync is a follow-up, not this phase.)

## Dog-fooding

Dog-fooding the full writer → index → dashboard chain against real (stub-fed)
I/O is a **required gate**, not optional: the hermetic unit tests prove each
component in isolation, but only an end-to-end run confirms the scanner resolves
the index path correctly, the writer's output is what the dashboard actually
reads back, and the two agree on the post-rename `link-health` dir. The local
dog-food workflow drives a scanner step to write reports into a scratch reports
dir, confirms `_index.json` appears there naming the program, then runs the
dashboard against that scratch dir with `--dry-run` and confirms the section
renders — all without touching any core repo or the deploy copy.

This is a local development-and-testing activity. The dog-food harness itself is
not a deliverable of this phase and is not committed by it (it is a local
working tool, tracked separately). The committed gates are the hermetic tests
above; the dog-food run is a required step the implementer performs locally
before the phase is considered done.

## Follow-ups (file as issues, do not implement here)

1. **Decouple skills from `repoman_config`.** ([#99](https://github.com/rossoctl/automation/issues/99))
   link-health, dep-bump, both
   fixers, and the dashboard read `~/.repoman/config.json` via `repoman_config`
   today; the architecture spec's Skill-layer principle wants config passed as
   parameters (as `pr-review-scanner.sh` already does with `--reports-dir` /
   `--org` / `--profile`). Cross-cutting; candidate v0.1.1.
2. **Resync the agent-skills dashboard script copy.** ([#100](https://github.com/rossoctl/automation/issues/100))
   The `skills/automation-health-dashboard/scripts/` copy in agent-skills is ~2
   months stale (still `ORG="kagenti"`, pre-rossoctl-rename, carries the old
   monolithic program-lib) versus the authoritative automation copy. Port the
   current automation dashboard into agent-skills. Cross-repo; its own unit.
3. **Add a pr-review dashboard section.** ([#101](https://github.com/rossoctl/automation/issues/101))
   The dashboard has no pr-review
   section today, but one was always intended: reviewed-PR counts and the
   before/after review-merge-delta impact metrics (the dashboard half of the
   impact-metrics + blog effort). This follow-up wires pr-review into
   `_index.json` (its scanner registers an entry) and adds the per-program-id
   extraction block + section the discovery layer already leaves room for. Once
   done, no dashboard-discovery change is needed — the entry simply starts
   rendering. Depends on Phase 5's discovery layer landing first.

## Commit shape

Small commits, TDD order:
1. failing test for `repoman-index.sh` fresh-index create; minimal writer.
2. failing tests for upsert/preserve, invalid-JSON, dry-run; complete writer.
3. link-health scanner wiring + rename `link-scan`→`link-health`; its test.
4. dep-bump scanner wiring; its test.
5. dashboard index-driven discovery + disk-derived fallback + heading table;
   `tests/test-automation-health-dashboard.sh`.

After the committed work, run the local end-to-end dog-food (see Dog-fooding)
as the final gate before the phase is done. The dog-food harness is a local
tool and is not part of these commits.

Landed on `feat/repoman-phase5-index-dashboard` in this worktree (based off the
Phase 4 tip). The agent-skills SKILL.md prose change is its own agent-skills PR.
