# program-lib.sh Decomposition Design — Portable, Vendorable Modules

**Date:** 2026-08-09
**Status:** Design (awaiting review)
**Related:** `#35` (lib decomposition), epic `#32` (rename cleanup, now complete), `#2149` (agent-skills sync — downstream consumer of this work)

## Problem

`scripts/program-lib.sh` is a single ~985-line file holding 23 functions spanning workspace
plumbing, date/JSON utilities, GitHub API helpers, fork/PR workflow, link-fix candidate scoring,
and org-identity resolution. It is sourced by 9 program scripts.

Two forces make the monolith a liability:

1. **Reasoning/maintenance** — one 985-line file mixes unrelated concerns; a change to fork logic
   sits beside date parsing. Focused files are easier to read, edit, and review.
2. **Distribution / vendoring** — the suite is headed toward being a distributable, harness-agnostic
   template that consumers copy and extend. The `agent-skills` repo already **vendors (copies)** the
   scripts per-skill (`skills/<skill>/scripts/`), and the Agent Spec does not support referencing
   external scripts — so each skill must carry its own copy. A monolith forces every skill to vendor
   all 985 lines even when it uses a handful of functions, and a change on the automation side must
   be re-copied wholesale.

There is also one concrete portability defect: `scripts/link-health-scanner.sh` uses
`declare -A ISSUE_COUNTS` (bash 4), which fails on macOS's default bash 3.2 — the suite otherwise
deliberately avoids bash-4 features (`mapfile` is avoided throughout).

## Goal

Split `program-lib.sh` into a small set of **balanced, single-purpose, self-contained modules** that:

- keep the existing entrypoint (`source "$SCRIPT_DIR/program-lib.sh"`) working unchanged for all 9
  scripts (zero consumer edits),
- can be **vendored as a subset** into another harness without knowing a load order (each module
  pulls in its own dependencies),
- run on **bash 3.2+** (macOS-safe), enforced by CI on both Linux and macOS.

This is a **pure refactor — no behavior change.** No functional or rename work rides along.

## Non-goals

- A "sync workflow" to automate copying modules into `agent-skills` (noted as a future idea; **not**
  pursued here).
- The `agent-skills` sync itself (`#2149`) — this work only makes the modules *ready* to be synced.
- POSIX-sh portability (dash/ash). The floor is bash 3.2, not POSIX sh; the code uses `[[ ]]`,
  `local`, and indexed arrays freely.

## The module layout (data-driven)

A function-usage audit across the 9 consumers produced four natural cohesion clusters, verified to
be **balanced** (185–278 LOC each — no monolith-plus-stubs lopsidedness):

| Module (flat, in `scripts/`) | Functions | ~LOC |
|------------------------------|-----------|------|
| `core.sh` | `setup_workspace`, `generate_scan_id`, `iso_to_epoch`, `atomic_write_file`, `validate_json_schema`, `diff_against_previous`, `write_report_latest`, `append_history_row` | ~278 |
| `github-api.sh` | `gh_with_backoff`, `gh_issue_exists`, `close_issue_if_valid`, `issue_has_open_pr` | ~185 |
| `fork.sh` | `ensure_fork`, `create_fork_pr`, `validate_issue_fields`, `pick_best_candidate`, `score_path_suffix` | ~277 |
| `org.sh` | `load_org_profile`, `get_core_repos`, `core_repo_names`, `is_core_repo`, `canonical_repo_for_dir`, `validate_repos_dir` | ~226 |
| `program-lib.sh` (aggregator) | *(sources the four modules)* | ~15 |

**Flat layout** (modules beside `program-lib.sh` in `scripts/`, not a `scripts/lib/` subdir): this
matches exactly how `agent-skills` already vendors scripts — a flat `skills/<skill>/scripts/`
directory copied wholesale, with no subdirectory contract to preserve. With ~5 library files total,
the `scripts/` listing stays readable.

### Neither zero-consumer function is dead (verified)

The usage matrix showed `score_path_suffix` and `core_repo_names` with no *external* consumers, but:

- `score_path_suffix` is called **internally** by `pick_best_candidate` — co-located in `fork.sh`.
- `core_repo_names` is called **internally** by `is_core_repo` **and** covered by
  `tests/test-core-repos.sh` — stays in `org.sh`.

No functions are removed. A pure refactor preserves the public surface.

## Dependency loading: load-once guards, self-source only real dependencies

Every module opens with a **load-once guard** so repeated sourcing is a no-op:

```sh
# top of core.sh
[ -n "${_CORE_SH_LOADED:-}" ] && return
_CORE_SH_LOADED=1
```

**A module self-sources another module only if its own function bodies actually call that
module's helpers** — the load list is driven by measured call-sites, not by category. The
decomposition was verified empirically (grep each module's bodies for cross-module helper names)
rather than assumed, and the finding was that the current split has **no intra-library
dependencies**: `github-api.sh`, `fork.sh`, and `org.sh` each define functions that invoke `gh`,
`git`, `jq`, and shell builtins directly, and none of them call a `core.sh` helper (nor does
`fork.sh` call a `github-api.sh` helper). So each of the four modules is guard-only — no `source`
lines beyond the guard.

If a future change makes one module call another's helper, that module gains a self-source block
resolved relative to **its own** location (not the caller's), so it works no matter which directory
it is sourced from or vendored into:

```sh
# self-source pattern, added only when a real cross-module call is introduced
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_LIB_DIR/core.sh"
```

**Why measure rather than pre-wire (given the vendoring direction):** a consumer copying only
`fork.sh` into another harness gets a genuinely self-contained file, and no module declares a
dependency it does not use. When a real dependency does exist, the module declares it in code — not
in prose a copier must read — and the guard makes double-sourcing harmless. Runtime cost of a guard
check is a one-time variable test at startup — negligible.

### The aggregator

`program-lib.sh` becomes a thin file that sources the four modules (the guards make load order
irrelevant; the aggregator lists them in a stable, readable order):

```sh
#!/usr/bin/env bash
# Aggregator: sources the automation library modules. Kept as the stable
# entrypoint so consumers can `source "$SCRIPT_DIR/program-lib.sh"` unchanged.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_LIB_DIR/core.sh"
# shellcheck source=/dev/null
. "$_LIB_DIR/github-api.sh"
# shellcheck source=/dev/null
. "$_LIB_DIR/fork.sh"
# shellcheck source=/dev/null
. "$_LIB_DIR/org.sh"
```

The 9 consumer scripts keep their existing `source "$SCRIPT_DIR/program-lib.sh"` line verbatim —
**zero consumer edits**, and vendored `agent-skills` copies that expect `program-lib.sh` keep working.

## Portability contract

**Floor: bash 3.2+ (macOS-safe) through modern bash.** Documented in a `## Portability` section in
each module header and in the repo README. The contract forbids:

- associative arrays (`declare -A`) — bash 4+
- `mapfile` / `readarray` — bash 4+
- GNU-only flags on `sed`/`grep`/`date` without a BSD-compatible fallback (the existing
  `iso_to_epoch` already demonstrates the GNU-then-BSD-then-awk pattern).

**Known fix in scope:** `scripts/link-health-scanner.sh` `declare -A ISSUE_COUNTS` is replaced with a
bash-3.2-safe equivalent (indexed parallel arrays or a delimited accumulator string). This is the one
hard blocker; without it, macOS CI (below) would fail. It is the only consumer-script edit in this
work and is justified as part of the portability contract.

## CI

A new GitHub Actions workflow (no test CI exists today; only PR-verifier/project/self-assign
workflows are present):

- **Matrix:** `ubuntu-latest` + `macos-latest`. The macOS runner exercises BSD `date`/`sed`/`grep`
  and an older-bash environment, catching the `declare -A` class of defect automatically.
- **Steps:** run every `tests/*.sh`; run `shellcheck` over `scripts/*.sh`.

## Equivalence verification (pure refactor)

1. **Existing suite green before and after** — `test-org-profile`, `test-core-repos`,
   `test-pr-review-impact`, `test-pr-review-integration` (needs `ORG=rossoctl`),
   `test-extract-broken-links`, `test-parse-diff-map`.
2. **Function-inventory diff** — assert the set of function names defined after sourcing
   `program-lib.sh` is **identical** pre- and post-split (nothing lost, renamed, or accidentally made
   private). A small test captures `declare -F` output before/after.
3. **Per-module smoke tests** — add minimal coverage for modules whose functions lack existing tests
   (notably `github-api.sh` and `fork.sh` helpers), asserting they are defined and callable after
   sourcing the module standalone (which also proves the self-sourcing guard works).

## Rollout

Single PR: create the four modules, reduce `program-lib.sh` to the aggregator, fix the `declare -A`,
add the CI workflow and the function-inventory + smoke tests, document the portability contract. No
deployment step beyond the normal `scp` of `scripts/` to the host (the aggregator entrypoint is
unchanged, so the host and the vendored `agent-skills` copies keep working). Because `#2149` will
copy these modules into `agent-skills`, landing this first means the sync copies clean, modular,
portable files rather than the monolith.

## Risks

- **Sourcing-path resolution when vendored.** Mitigated by resolving every intra-module `source` via
  the module's own `$BASH_SOURCE` dir, and by the flat layout matching the existing vendor structure.
  The per-module smoke tests source each module standalone to prove this.
- **A missed bash-4-ism.** Mitigated by the macOS CI leg + shellcheck; the audit explicitly greps for
  `declare -A`, `mapfile`, `readarray`, and GNU-only flag patterns.
- **Accidental behavior change during extraction.** Mitigated by the function-inventory diff and the
  unchanged existing suite; extraction is mechanical (move function bodies verbatim, add guards).
