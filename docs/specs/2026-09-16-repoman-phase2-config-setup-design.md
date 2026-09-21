# RepoMan Phase 2 — Config and Setup Flow

**Date:** 2026-09-16
**Status:** Design (awaiting review)
**Implements:** [#73](https://github.com/rossoctl/automation/issues/73) (Phase 2 of epic [#72](https://github.com/rossoctl/automation/issues/72))
**Parent spec:** `docs/specs/2026-08-27-repoman-architecture.md` (§Setup flow, §Program invocation flow, §Input model)
**Related:** [#39](https://github.com/rossoctl/automation/issues/39) (repo-onboarding — config/fork half), [#74](https://github.com/rossoctl/automation/issues/74) (Phase 3 capability check), [#82](https://github.com/rossoctl/automation/issues/82) (GitHub App auth spike)

> **Living document.** This spec is the source of truth for Phase 2 and is
> kept in sync with the code as it is written and revised. Any change made
> during implementation or in response to review feedback — a renamed
> subcommand, an added flag, a schema field, a changed validation rule — is
> reflected here in the same commit (or the immediately following one) that
> changes the code. If review forces a decision that contradicts a section
> below, update the section rather than letting the doc drift.

## Summary

Phase 1 (#78, merged in #87) built the **reader** side of the RepoMan input
model: `repoman_config` and `repoman_get_repos` in `scripts/org.sh` read
`~/.repoman/config.json` and `~/.repoman/repos.json`. Phase 2 builds the
**writer** side plus the setup conversation: a non-interactive pure-writer
script (`scripts/repoman-setup.sh`) that creates and validates the
`~/.repoman` files, and a conversation-driving skill (`repoman-setup`, in
`rossoctl/agent-skills`) that resolves the user's answers into concrete
values and calls the script to persist them.

The split is deliberate. The script does no `gh` calls and no prompting, so
it is fully covered by the existing bash test harness. The live parts — the
natural-language conversation and the "enroll a whole org" GitHub fetch —
live in the skill.

## Scope boundary

**In Phase 2:**
- `scripts/repoman-setup.sh` — pure writer/validator for the three
  `~/.repoman` file kinds, with per-decision subcommands.
- Bash tests for every subcommand, using `$REPOMAN_*` path overrides against
  a temp dir (same override mechanism Phase 1's reader honors).
- Paired `skills/repoman-setup/` unit in `rossoctl/agent-skills` (SKILL.md +
  bundled copy of the script), landed alongside — the same cross-repo pattern
  the scanner skills use (#37/#38 companions).

**NOT in Phase 2 (owned elsewhere, called out to prevent scope creep):**
- `pat_scopes` / `labels_required` / `labels_applied` in
  `programs/<name>.json` and the per-program capability check —
  **Phase 3 (#74)**, drawn from each skill's `### Requirements
  (machine-readable)` block, run at invocation.
- Fork creation — deferred to the fixer path (see §Fork creation below).
- Clone/refresh of repos — **Phase 4 (#75)** repo-sync.
- `_index.json` program registry and dashboard wiring — **Phase 5 (#76)**.

## The pure-writer script

`scripts/repoman-setup.sh <subcommand> [flags]` — non-interactive. Each
subcommand writes exactly one thing, validates it, and persists atomically
(write to a temp file in the target directory, then `mv` into place, so a
crash mid-write never leaves a half-written JSON file; a failed write or
rename removes the temp file rather than orphaning it). This matches the
parent spec's requirement that "all answers are persisted immediately so a
pod restart mid-setup can resume": the skill calls one subcommand per
resolved answer.

The script never calls `gh`, never prompts, never clones, never forks. It
receives already-resolved inputs and writes JSON.

Every flag that takes a value guards its arity before `shift 2`: a trailing
flag with no value (e.g. `add-repo --owner alice --name`) would otherwise make
`shift 2` fail and, under `set -e`, abort the script with exit 1 and no output
at all — the one silent failure in a script that is otherwise loud on every
mis-ordering. The guard (`[ $# -ge 2 ]`) emits a specific `<flag> requires a
value` message and returns 1 instead. This matters especially because the
skill/harness drives the script non-interactively: a silent abort would let
the caller assume success.

### Path overrides

All subcommands honor the same environment overrides Phase 1's reader uses,
so tests point them at a temp directory:
- `REPOMAN_CONFIG_FILE` (default `~/.repoman/config.json`)
- `REPOMAN_REPOS_FILE` (default `~/.repoman/repos.json`)
- `REPOMAN_PROGRAMS_DIR` (new; default `~/.repoman/programs/`)

No new flags for paths — consistent with Phase 1's variable semantics.

### Subcommands

| Subcommand | Inputs | Writes | Validation |
|---|---|---|---|
| `init-config` | `--repos-dir <path> --fork-owner <owner>` | `config.json` | Both required and non-empty. Leading `~` expanded to `$HOME` the same way `repoman_config` reads it. `repos_dir` run through `validate_repos_dir` (Phase 1), which is passed the `--repos-dir` label so its errors name the flag the user typed rather than the `REPOS_DIR` env var of the scanner/fixer flow. Idempotent overwrite. |
| `add-repo` | `--owner <o> --name <n>` (repeatable) **or** a JSON array on stdin | merges into `repos.json` | Rejects empty/missing owner or name (same guard as `repoman_get_repos`, which rejects `""`). `--owner`/`--name` must alternate: a second `--owner` before its `--name`, a `--name` with no preceding `--owner`, or a trailing `--owner` with no following `--name` is rejected loudly with a message specific to that mis-ordering, rather than silently mis-pairing (e.g. `--owner alice --owner bob --name repo` must not quietly become `bob/repo`) or falling through to the generic empty-set error. Rejects a resolved set of zero entries (`[]` on stdin) before any write, so `add-repo` never writes an empty `repos.json` that the Phase 1 reader would later reject at read time. Dedups on `owner/name`. Creates the array if the file is absent. |
| `enable-program` | `--program <name>` | `programs/<name>.json`, `{ "enabled": true }` (JSON-merge) | `<name>` checked against a known-program allowlist so a typo cannot create `programs/lnik-health.json`. Creates `programs/` dir. |
| `set-output` | `--program <name> --mode same\|central [--repo <owner/name>]` | merges `output_repo` into `programs/<name>.json` | `--repo` required iff `mode=central`, validated as exactly `owner/name` (one slash, both parts non-empty; e.g. `a/b/c` is rejected). `--mode` must be `same` or `central`. |

Every subcommand supports `--help` (the SKILL.md instructs the agent to run
it first, matching the scanner-skill convention).

`enable-program` and `set-output` perform a JSON **merge**, not an overwrite,
so Phase 3 can add `pat_scopes`/`labels_required`/`labels_applied` to the same
file without clobbering the setup-collected fields.

### Shared `validate_repos_dir` (Phase 1 `org.sh`) touch-up

`init-config` reuses Phase 1's `validate_repos_dir`, which was written for the
older env-var flow: it hard-coded `REPOS_DIR` in every error and called
`exit 1`. Two small, caller-safe changes were made at the source rather than
worked around here (a reviewer's point that the fix belongs in the broader
system, not the script under change):

- An optional second **label** argument (default `REPOS_DIR`) controls how the
  path is named in error messages. The two legacy callers
  (`dep-bump-scanner.sh`, `dep-bump-fixer.sh`) pass nothing and keep byte-for-
  byte identical messages; `init-config` passes `--repos-dir` so its errors
  name the flag the user actually typed. The "clone your org's repos there"
  advice was also made caller-neutral.
- `exit 1` → `return 1`, so the function unwinds through its caller instead of
  killing the process. Behaviour-equivalent for the two legacy callers (they
  invoke it at top level under `set -e`, where a non-zero return aborts the
  same way) and strictly better for `cmd_init_config`, which now returns
  through its own path.

## JSON schemas

The writer produces exactly the shapes Phase 1's reader consumes — no drift.

### config.json

```json
{ "repos_dir": "~/repoman/repos", "fork_owner": "clawgenti" }
```

Parent spec line 62 shows `{ "repos_dir": "..." }`; `fork_owner` is required
because `repoman_config` reads it (parent spec line 142: `FORK_OWNER` stays a
single global — hard error in the reader if the key is missing). Default
`repos_dir` is `~/repoman/repos` (parent spec line 61). `fork_owner` has no
hard-coded default; it is collected (see §The setup conversation, Q1b).

### repos.json

```json
[
  { "owner": "rossoctl", "name": "automation" },
  { "owner": "alice",    "name": "tool" }
]
```

Array of `{owner,name}` (parent spec lines 122-128). Exactly what
`repoman_get_repos` consumes.

### programs/<name>.json

```json
{ "enabled": true, "output_repo": { "mode": "same" } }
```

or, when the user chooses a central issue repo:

```json
{ "enabled": true, "output_repo": { "mode": "central", "repo": "rossoctl/triage" } }
```

Phase 2 writes only the setup-collected fields (`enabled`, `output_repo`).
The `pat_scopes`/`labels_required`/`labels_applied` the parent spec shows at
line 99 are read by the Phase 3 capability check and authored there from the
`### Requirements (machine-readable)` block — Phase 2 never writes them.

## Output destination semantics

`output_repo` governs **scanner issue destination only** (parent spec lines
92-94: "Where should issues be posted?"). It is **per-program** (read from
`programs/<name>.json`, parent spec line 110).

- `mode: same` (default, recommended) — each finding's issue is posted back
  to the repo where the finding was made.
- `mode: central` — every finding's issue, across all enrolled repos, is
  posted to the single repo named in `repo`.

`output_repo` does **not** redirect fixer PRs. A fix PR must target the repo
whose files it changes, so it always targets the finding's own repo — the
parent spec never proposes routing PRs, and `central` mode has no effect on
them. A later-phase implementer must not over-read `central` as redirecting
PRs.

## The setup conversation (skill)

The `repoman-setup` skill drives the parent spec's five setup questions.
Per the model-tier constraint (#73), every prompt presents explicit
enumerated options with a worked example — no open-ended prompts — so
mid-to-low tier models can drive it.

| Q | Question | Skill resolves | Script call |
|---|---|---|---|
| 1a | Where to clone repos? | a path (default `~/repoman/repos`) | (part of `init-config`) |
| 1b | Which account holds fork clones for fixer PRs? | an owner; default suggestion = the `gh`-authenticated login (`gh api user`), user may override | `init-config --repos-dir <p> --fork-owner <owner>` |
| 2A | Add repos by slug/URL | parse each `owner/name` or URL | `add-repo --owner <o> --name <n>` per repo |
| 2B | Enroll a whole org | `gh repo list <org> --json nameWithOwner,isArchived`, filter archived, coarse org-reachability PAT check | `add-repo` with the resolved JSON array on stdin |
| 3 | Which programs? | present one-line descriptions from each skill | `enable-program --program <name>` per selection |
| 4 | Nightly repo sync? | if yes, enable the repo-sync program | `enable-program --program repo-sync` (deferrable) |
| 5 | Output destination | NOT asked at setup — asked at first invocation | `set-output` (see below) |

Questions 1a and 1b are collected together and written by a single
`init-config` call (config.json needs both keys). `fork_owner` is not
hard-coded to any deployment's value; the skill suggests the authenticated
user's login as the default and the user may type a different owner. See
§Fork creation for how `fork_owner` relates to the auth model.

Question 5's output destination is collected at each program's first
invocation (parent spec §Program invocation flow), and the skill calls
`set-output --program <name> --mode same|central [--repo …]` then.

### Whole-org PAT check (Q2B) is coarse, not per-program

The parent spec (line 70) is explicit: the whole-org enroll does a bulk,
org-level scope check — enough to avoid enrolling repos the PAT cannot see —
and "per-program capability checks still happen at invocation, not here."
Phase 3 (#74) owns the per-program, per-repo scope/label checks. Phase 2's
Q2B check is only org-reachability (can the PAT list the org's repos). This
is a live skill step; the pure writer receives the already-filtered list.

## Fork creation

Parent spec line 142 notes `gh repo fork alice/tool --org clawgenti` "already
works," but places forking in none of the five setup questions. Issue #73
names "the fork-creation step" as the config/fork half of #39.

Resolution: enrollment writes `repos.json` only. The fork is created
**lazily** — on demand, the first time a fixer must open a PR against that
repo — not at enroll time. A scanner-only or read-only repo is never forked,
keeping the fork org uncluttered. Forking is idempotent (`gh repo fork`), so
there is no fork state to persist; the pure writer never forks.

Consequence: fork creation is therefore not a Phase 2 code deliverable — it
belongs to the fixer path under RepoMan (Phase 4 / the fixers themselves).
Phase 2 delivers the **config** half of #39 (enrollment via `add-repo`). #39
stays open until the fixer's lazy-fork path is wired; Phase 2 does not close
it.

### `fork_owner` is auth-model-specific (forward note)

`fork_owner` is a concept of the **current bot-user auth model**: the fixer
acts as a plain user account (`clawgenti`) that lacks push access to target
repos, so it forks, pushes to the fork, and opens a cross-fork PR. If the
GitHub App auth spike (#82) is adopted, the App authenticates as an
installation and pushes a branch directly on the target repo (same-repo PR,
no fork) — at which point `fork_owner` becomes meaningless and the fork step
is revisited. This is a forward note only; Phase 2 has no dependency on #82
and proceeds in the bot-user model, where `fork_owner` is real and required.

## Testing

Bash tests under `tests/`, added to the explicit CI list in
`.github/workflows/tests.yml`. Because the script is a pure writer, every
path is testable with fixtures and `$REPOMAN_*` overrides against a temp dir:

Missing-value paths are asserted on the **message**, not just the exit code:
a test that voids stderr and checks only non-zero exit would let the silent
`shift 2` abort satisfy "fails cleanly", so every trailing-flag-with-no-value
test captures stderr and greps for the specific `<flag> requires a value`
message.

- `init-config`: writes both keys; rejects empty `--repos-dir` / empty
  `--fork-owner`; rejects a trailing `--repos-dir` / `--fork-owner` with no
  value (message asserted); expands leading `~`; rejects a dangerous
  `repos_dir` via `validate_repos_dir`, asserting the error names
  `--repos-dir` (not `REPOS_DIR`); round-trips through `repoman_config`.
- `add-repo`: single repo; repeated `--owner/--name`; JSON-array-on-stdin;
  dedup of a repeat, including a single call that dedups against an
  already-existing file; rejects empty owner and empty name; rejects
  mis-ordered flags (a second `--owner` before its `--name`, a `--name`
  with no preceding `--owner`, and a trailing `--owner` with no following
  `--name` — the last with its own specific message, asserted); rejects a
  trailing `--owner` / `--name` with no value (message asserted, distinct
  from the mis-ordering cases), each leaving the file unchanged; rejects a
  resolved set of zero entries (`[]` on stdin) before any write; round-trips
  through `repoman_get_repos`; the same-name-different-owner pair
  (`rossoctl/cortex` + `alice/cortex`) both persist distinctly; a successful
  write leaves no `.repoman-setup.*` temp file behind (atomic-write cleanup
  guard).
- `enable-program`: creates the file with `enabled:true`; rejects an
  unknown program name (allowlist); rejects a trailing `--program` with no
  value (message asserted); creates `programs/` dir.
- `set-output`: `same` mode; `central` mode with `--repo`; rejects `central`
  without `--repo`; rejects an invalid mode; rejects a `--repo` that is not
  exactly `owner/name` (no slash, or more than one slash, e.g. `a/b/c`);
  rejects a trailing `--program` / `--mode` / `--repo` with no value (message
  asserted); **merges** into an existing `enabled:true` file without dropping
  `enabled`.

## Deliverables

1. `rossoctl/automation` PR (this issue #73):
   - `scripts/repoman-setup.sh`
   - `tests/test-repoman-setup.sh` (added to `.github/workflows/tests.yml`)
   - this design doc
2. `rossoctl/agent-skills` paired PR:
   - `skills/repoman-setup/SKILL.md` (conversation driver)
   - `skills/repoman-setup/scripts/repoman-setup.sh` (bundled copy)

## Open items carried forward

- #39 closes only when both the config half (this phase) and the fork half
  (fixer lazy-fork path) land.
- `programs/<name>.json` gains `pat_scopes`/`labels_required`/`labels_applied`
  in Phase 3 (#74) via JSON-merge; the schema here reserves room for them by
  never overwriting.
- `fork_owner` semantics are revisited if #82 adopts GitHub App auth.
