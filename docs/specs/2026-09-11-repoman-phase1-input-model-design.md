# RepoMan Phase 1 — Per-Repo Input Model (Design)

**Date:** 2026-09-11
**Status:** Design (awaiting review)
**Epic:** [#72](https://github.com/rossoctl/automation/issues/72) · **Sub-issue:** [#78](https://github.com/rossoctl/automation/issues/78)
**Architecture spec:** `docs/specs/2026-08-27-repoman-architecture.md`
**Builds on:** merged PR [#83](https://github.com/rossoctl/automation/pull/83) (removed hardcoded org from the read path)

## Summary

Phase 1 replaces the single-global `$ORG` plus flat `$REPOS_DIR` identity model with
per-repo `{owner, name}` tuples drawn from a user-managed `~/.repoman/repos.json`. Clone
directories become owner-namespaced (`<repos_dir>/<owner>/<name>/`), so the same repo name
under two different owners no longer collides. This is the core input model that every later
RepoMan phase builds on.

## Scope decision: no backward compatibility

The architecture spec and the original handoff assumed an additive change with a fallback to
`$ORG` plus `core-repos.txt`, so that an existing deployer would see no change. This design
drops that constraint. RepoMan is deployed independently, and the existing consumers of the old
model are flag-enabled cron jobs on OpenClaw and DAM that are turned off once their RepoMan
replacements go live. There is therefore no in-repo dual-path to maintain.

Consequences of dropping backward compatibility:

- `repoman_get_repos()` replaces `get_core_repos()` outright rather than wrapping it.
- The single-global scaffolding is deleted, not preserved behind a conditional.
- Tests are replaced to assert the new model, not extended to assert both models.
- `canonical_repo_for_dir()` and `REMAP`, which existed only as rename glue, are deleted.

The old scripts do not break in production because they are not scheduled under RepoMan. Each
of the four remaining consumers listed under "Consumer disposition" is either ported to the new
model in a later phase or left disabled.

## The input model

### repos.json — the enrolled set

`~/.repoman/repos.json` is a JSON array of objects, each with `owner` and `name`. This is the
authoritative list of repos RepoMan acts on. The user manages it (directly in Phase 1, through
the setup flow in Phase 2).

```json
[
  {"owner": "rossoctl", "name": "automation"},
  {"owner": "rossoctl", "name": "agent-skills"},
  {"owner": "alice",    "name": "tool"}
]
```

### config.json — deployment constants

`~/.repoman/config.json` holds only the values that are genuinely deployment-wide, at the same
tier as the clone-cache root. It does **not** absorb everything that used to derive from `$ORG`.

```json
{
  "repos_dir": "~/repoman/repos",
  "fork_owner": "clawgenti"
}
```

- `repos_dir` — root of the owner-namespaced clone cache (already in the Phase 0 spec).
- `fork_owner` — the account fork PRs are pushed to (was `FORK_OWNER`). Deployment-wide: every
  program that opens a PR pushes to the same fork account, and `gh repo fork <owner>/<name> --org
  <fork_owner>` works cross-owner. Adding it here is a small extension of the Phase 0 `{repos_dir}`
  schema, at the same global tier.

**What deliberately does not go here.** `source_repo` (a program's standing-orders / attribution
repo) and `report_target_repo` (where a program posts its report PR or files issues) are
**per-program**, not global. Link-health and dep-bump are different programs with different
targets, and RepoMan activates programs gradually — a deployment may have `repos_dir` and enrolled
repos set with **no program active yet**. Putting a report target in the global config would place
program-specific state in a file that must be meaningful before any program is chosen. The Phase 0
spec already defines the right home for these: `~/.repoman/programs/<name>.json`, resolved when
that program is activated.

**Phase 1 handling of the per-program values.** The per-program config file and its loader are
Phase 2/3 work (setup and capability check). To avoid inventing that schema prematurely here, in
Phase 1 `report_target_repo` and `source_repo` remain per-script constants (or a minimal env
override), each tagged in-code with a `# TODO(RepoMan Phase 2): move to programs/<name>.json`
marker. This keeps the global `config.json` clean and defers the per-program schema to the phase
that owns it. `MAIN_REPO`'s single live use (the issue-search convenience URL) folds into the
script's `report_target_repo` constant.

### Clone layout

```
<repos_dir>/
  rossoctl/
    automation/
    agent-skills/
  alice/
    tool/
```

Owner-namespaced, so `rossoctl/cortex` and `alice/cortex` coexist without collision. This is the
same repo running under two owners at once, which is the case the flat layout could not express.

## Library changes (scripts/org.sh)

`org.sh` stops being an "org identity" module and becomes a "repo set" module.

### Added

- `repoman_config()` — reads `~/.repoman/config.json`, resolves `repos_dir` and `fork_owner`, and
  exports them (or fails loud if the file or a required key is missing). Replaces the resolution
  half of `load_org_profile`. Path overridable with `$REPOMAN_CONFIG_FILE` for tests. It does
  **not** resolve report/source targets; those are per-program (see config.json section).
- `repoman_get_repos()` — reads `~/.repoman/repos.json` and emits one `owner/name` per line, in
  file order. Fails loud on a missing or empty file, or a malformed entry (missing `owner`/
  `name`). Path overridable with `$REPOMAN_REPOS_FILE` for tests.
- `is_enrolled()` — returns 0 if a given `owner/name` is present in `repos.json`, else 1. Exact
  whole-line match. Replaces `is_core_repo()`.

### Deleted

- `get_core_repos()`, `core_repo_names()`, `is_core_repo()`, `canonical_repo_for_dir()`.
- `load_org_profile()` in its current form, and all `$ORG` / `MAIN_REPO` / `REMAP` resolution.
- `config/core-repos.txt` and the `config/org*.env` profile files.
- `validate_repos_dir()` is kept (it validates `repos_dir`, still needed) but its caller shifts
  from `load_org_profile` to `repoman_config`.

`FORK_OWNER` continues to exist as an exported value, now sourced from `config.json` via
`repoman_config` rather than derived from `$ORG`. `SOURCE_REPO` and the report-target repo are no
longer exported from `org.sh`; they become per-script constants (see config.json section) pending
their Phase 2 move to per-program config.

## Script changes (the four scanners/fixers)

All four share one idiom today: glob `"$REPOS_DIR"/*/`, map the basename through
`canonical_repo_for_dir`, filter with `is_core_repo "$canon"`, dedup with `SEEN_CANON`. Under the
new model each such loop is **driven from the enrolled set**, not from a filesystem glob: the
`enrolled_clone_dirs` helper emits each enrolled `owner/name` whose clone exists under
`$REPOS_DIR`, and the loop iterates those:

```bash
ENROLLED=$(repoman_load_enrolled) || exit 1
CLONES=$(enrolled_clone_dirs "$ENROLLED")
while IFS= read -r full_repo; do
  [ -n "$full_repo" ] || continue
  owner="${full_repo%%/*}"
  name="${full_repo#*/}"
  repo_dir="$REPOS_DIR/$full_repo"
  ...
done <<< "$CLONES"
```

Notable simplifications:

- `canonical_repo_for_dir` and the `SEEN_CANON` dedup are gone. The owner namespace guarantees
  each enrolled repo maps to exactly one directory, so there is nothing to canonicalize or
  de-duplicate.
- Every `$ORG/<name>` reconstruction becomes `$owner/$name`, where `owner` comes from the enrolled
  entry rather than assumed. The full owner/name reference is carried through, not rebuilt from a
  global.
- Path joins `"$REPOS_DIR/$name"` become `"$REPOS_DIR/$owner/$name"`.
- The `.github` special-case in the glob is dropped, and it is safe to drop **only because the loop
  no longer globs**. `.github` is enrolled as `<owner>/.github` like any other repo, and driving
  from the enrolled set picks it up. A `"$REPOS_DIR"/*/` glob would NOT: bash excludes
  leading-dot entries unless `dotglob` is set, so a glob-and-filter loop silently drops `.github`.
  Driving from enrollment makes the enrolled set authoritative and removes that whole
  glob-vs-enrollment mismatch class.

Per-script loop counts to convert: link-health-scanner (1), link-health-fixer (1),
dep-bump-scanner (1), dep-bump-fixer (3). The dep-bump pair stores canonical names in
intermediate JSONL today; those `.repo` fields become full `owner/name` values, which the
downstream GitHub calls already expect.

The link-health scanner's report-target block and the dashboard's report-target block stop
building `$ORG/automation` and instead read a per-script `report_target_repo` constant (tagged
`# TODO(RepoMan Phase 2): move to programs/<name>.json`). Same for `source_repo` in the
attribution-link paths.

## Consumer disposition

Nine call sites in four other scripts use the deleted functions. None are migrated in Phase 1;
all are cron-toggled off under RepoMan until their replacements are live.

| Consumer | Uses | Phase 1 action |
|---|---|---|
| pr-review-scanner.sh | get_core_repos, load_org_profile | left disabled (cron off) |
| pr-review-impact.sh | get_core_repos, load_org_profile | left disabled (cron off) |
| weekly-report.sh | get_core_repos, load_org_profile | left disabled (cron off) |
| automation-health-dashboard.sh | load_org_profile, report target | ported (it is a RepoMan report consumer) |

The dashboard is ported in Phase 1 because it already sits in the reports path this phase
touches; the other three are deferred to their own phases. This disposition is asserted in the
plan, not left implicit.

## Companion: agent-skills report.py

The `github-weekly-report/scripts/report.py` change (drop `normalize_repo_args()` cross-owner
rejection, carry `{owner, name}` as a pair) is tracked as agent-skills [#37](https://github.com/rossoctl/agent-skills/issues/37)
and implemented in that repo alongside this phase. It is out of scope for this automation-repo
design but noted here for traceability.

## Testing

The test surface is replaced, not extended.

- `tests/test-core-repos.sh` → rewritten as `tests/test-repoman-repos.sh`: asserts
  `repoman_get_repos` emits `owner/name` in file order from a `$REPOMAN_REPOS_FILE` fixture,
  fails loud on missing/empty/malformed; `is_enrolled` exact whole-line match (positive,
  negative, substring guard). No `$ORG` prepend, no REMAP block.
- `tests/test-org-profile.sh` → rewritten as `tests/test-repoman-config.sh`: asserts
  `repoman_config` resolves `repos_dir` and `fork_owner` from a `$REPOMAN_CONFIG_FILE` fixture,
  fails loud on missing file or missing required key.
- `tests/test-lib-inventory.sh`: the enforced function list is updated — remove
  `get_core_repos`, `core_repo_names`, `is_core_repo`, `canonical_repo_for_dir`,
  `load_org_profile`; add `repoman_get_repos`, `is_enrolled`, `repoman_config`. The count
  changes from 23 accordingly. The guard's purpose (no accidental loss/rename) is preserved.
- `tests/test-lib-modules.sh`: the org.sh name-binding list is updated to the new surface.
- New fixtures under `tests/fixtures/`: `repoman-repos.json`, `repoman-config.json`.
- Existing snapshot, parse-diff-map, extract-broken-links, pr-review-impact tests are
  unaffected and must still pass.

## Sequencing

The work is built as **two self-contained commits** with clean boundaries. Whether they ship as
one PR or two is decided at the end, once the real diff size and coupling are visible — not
estimated upfront. The commit split is the unit of planning; the PR split is a packaging call
made against the actual diff.

- **Commit 1 — library seam.** Add `repoman_config`, `repoman_get_repos`, `is_enrolled` to
  org.sh; delete the old functions, `core-repos.txt`, and the org profiles; rewrite the affected
  tests and fixtures. No scanner/fixer behavior change yet. Because the scripts are not run under
  RepoMan, a state where org.sh has the new surface and the scripts have not yet adopted it is
  coherent and reviewable on its own.
- **Commit 2 — script adoption.** Convert the loops across the four scripts to the two-level
  glob plus `is_enrolled`, build owner-namespaced paths, and switch the report/source targets to
  per-script constants.

**PR packaging (decided at the end):** if the combined diff is small and tightly coupled, one PR
carrying both commits. If it is large or the two concerns read as independent reviews, two PRs
(commit 1 first). The default lean is two, per the repo's scope-discipline rule, but the diff
gets the final vote. Whatever ships targets `rossoctl/automation:main` from the fork, labeled
`ready-for-ai-review`.

## Out of scope (later phases)

- `~/.repoman/config.json` setup flow and the org-enrollment helper (Phase 2).
- Moving `report_target_repo` / `source_repo` from per-script constants into
  `~/.repoman/programs/<name>.json` (Phase 2, when per-program config lands).
- Per-program capability check (Phase 3).
- repo-sync clone/refresh program (Phase 4).
- `_index.json` and dashboard dynamic discovery (Phase 5).
- Porting pr-review and weekly-report consumers (their own phases).
