# RepoMan run path — design (`repoman run <program>`)

**Status:** approved for planning (2026-10-18)
**Epic:** [#72](https://github.com/rossoctl/automation/issues/72) — RepoMan multi-owner automation interface
**Issue:** [#107](https://github.com/rossoctl/automation/issues/107) — entrypoint skill + program invocation wiring (v0.1.0 completion). The setup/reconcile half of #107 shipped (automation #110, agent-skills #49); **this spec is the remaining "program invocation wiring" half.**
**Builds on:** architecture spec `docs/specs/2026-08-27-repoman-architecture.md` (§Program invocation flow, §Deployment), entrypoint-skill spec `docs/specs/2026-10-12-repoman-entrypoint-skill-design.md` (§Handoff to the run path).

## Summary

A single new orchestrator, `scripts/repoman-run.sh`, invoked as
`repoman run <program> [target...]`. It is **pure glue** over existing,
unchanged components: it turns a resolved program plus an (optional) enrolled
repo subset into an actual execution — capability check, clone refresh, scanner
exec, and `_index.json` registration — running only the steps each program needs.

No orchestrator exists today; every program is invoked standalone. This spec
defines the orchestrator, its per-program step table, and the contracts it
exposes to its callers (the `/repoman` skill, OpenClaw standing orders, DAM
schedules).

## Scope

**In scope (v0.1.0):** orchestrate the **5 non-fixer programs** —
`link-health` (scanner), `dep-bump` (scanner), `pr-review` (scanner),
`weekly-report` (scanner/wrapper), `automation-health` (index-consumer) — each
with per-program steps.

**Out of scope (deferred, tracked):**
- **Fixers** (`link-health-fixer`, `dep-bump-fixer`, `pr-review-fixer`) — they
  commit/push and hit the hardcoded commit identity (see §Commit & sign-off
  identity); deferred until the identity model settles ([#82](https://github.com/rossoctl/automation/issues/82)).
- **De-rossoctl-ing** the program scripts (hardcoded `REPORT_TARGET_REPO`,
  `SOURCE_REPO`, committer identity, personal `REPORT_PY` default) — its own
  tracked issue (see §Deferred work).
- **#99** (decouple scanners/fixers/dashboard from `repoman_config` — make them
  fully param-driven). The run path is built *param-first* so #99 later becomes
  a clean swap, but the refactor itself is v0.1.1.
- **#98** (`repoman_config` all-or-nothing key validation), **#115**
  (sourced-lib load-guard hygiene) — v0.1.1 / optional riders.
- **#76** (unify the program registry) — noted, not done here.

## The deployment contract (why non-interactivity is a hard requirement)

The architecture spec (§Deployment) states the program is invoked with an
**"identical invocation everywhere"** — both DAM pods and OpenClaw VMs run it on
a schedule as `task="repoman run ..."`. Therefore:

- **`repoman run` is the stable public contract.** Its CLI surface is what
  OpenClaw/DAM bind to. Internal mechanism choices (below) sit *below* this line
  and are swappable without a redeploy.
- **`repoman run` is fully non-interactive.** A scheduled invocation cannot
  prompt. All interactive setup (notably the first-invocation output-routing
  question) happens on the **skill/setup side** and is persisted to
  `~/.repoman/programs/<name>.json` *before* `repoman run` is ever scheduled.
- **State root is `$HOME`** on both targets (persistent volume / VM disk), with
  owner-namespaced clones under `repos_dir`. The orchestrator assumes nothing
  beyond a normal Unix `$HOME`.

## Architecture

```
repoman run <program> [target...]
  │
  ├─ 1. resolve program -> table row            (fail loud if not in table)
  ├─ 2. targets given? -> project subset:
  │        the /repoman skill has ALREADY reconciled targets to a concrete
  │        owner/name list (org-vs-repo detection, bare-name resolution, >=2-owner
  │        ambiguity) via repoman_match_name. The run path validates each is
  │        enrolled; a directly-supplied bare name is resolved and an ambiguous
  │        one (≥2 owners) fails loud. See "Subset selection" below.
  │        write a throwaway repos.json to $TMPDIR; REPOMAN_REPOS_FILE points at it
  │        [skipped entirely for the index-consumer profile]
  ├─ 3. require output_repo set                  [only rows with posts_output=yes]
  ├─ 4. capability check: repoman-check.sh --program <p>   [skip for index-consumer]
  ├─ 5. clone refresh: repo-sync.sh              [only rows with needs_clone_refresh=yes]
  ├─ 6. exec the program                         (REPOMAN_REPOS_FILE=<temp> when subset)
  └─ 7. write _index.json entry                  [only rows with writes_index=yes; sole writer]
```

### Components

**New:** `scripts/repoman-run.sh` — the orchestrator; owns the program table and
the pipeline. bash 3.2-safe, `set -uo pipefail` (aggregate-then-decide, matching
`repoman-check.sh`), sources `program-lib.sh`.

**Reused, unchanged:**
- `scripts/repoman-check.sh` — capability gate (scope hard-gate, label warn).
- `scripts/repo-sync.sh` — owner-namespaced clone refresh.
- `scripts/repoman-index.sh` — `_index.json` writer
  (`--program --display-name --report-path`).
- `scripts/org.sh` — `repoman_get_repos`, `repoman_match_name`, `is_enrolled`,
  `repoman_config`, `enrolled_clone_dirs`.
- `scripts/repoman-setup.sh` — `set-output` (invoked on the **skill** side, not
  by `repoman run`).

**Changed:**
- `scripts/link-health-scanner.sh`, `scripts/dep-bump-scanner.sh` — **remove
  their self-registration into `_index.json`**; the orchestrator becomes the
  sole index writer (see §Index-write contract).
- `tools/repoman-dogfood.sh` — drive its Phase-5 assertions **through
  `repoman run`** instead of invoking scanners directly (local-only harness;
  never committed).

## The program table (sole encoder of per-program behavior)

A declarative table at the top of `repoman-run.sh`. bash 3.2 has no associative
arrays (codebase portability constraint), so it is encoded as a line-based table
parsed per program (or an equivalent lookup function). One row per program:

| program | profile | needs_clone_refresh | posts_output | writes_index | scanner_script |
|---|---|---|---|---|---|
| `link-health` | scanner | yes | yes | yes | `link-health-scanner.sh` |
| `dep-bump` | scanner | yes | yes | yes | `dep-bump-scanner.sh` |
| `pr-review` | scanner | no | no | no | `pr-review-scanner.sh` |
| `weekly-report` | scanner | no | no | no | `weekly-report.sh` |
| `automation-health` | index-consumer | no | no | no | `automation-health-dashboard.sh` |
| `repo-sync` | sync | no | no | no | `repo-sync.sh` |

Index rows additionally carry `index_display_name` (e.g. `Link Health`) and
`report_path` (e.g. `~/reports/link-health`) — the fields `repoman-index.sh`
requires. The table must list every `KNOWN_PROGRAMS` entry (so each enrollable
program is runnable via `repoman run`); the two lists are kept in sync until
#76 unifies them.

**Rationale per non-obvious row:**
- `pr-review` posts a GitHub *review* in place, not issues to a report repo, so
  `posts_output=no` (no `output_repo` gate) and it has no report-dir/index shape
  (`writes_index=no`).
- `weekly-report` is a thin wrapper around a Python generator; it writes no
  `latest.json`/`_index.json` today, so `writes_index=no`. Giving it an index
  entry is follow-up work, not v0.1.0.
- `automation-health` *consumes* `_index.json` (it is the dashboard); the
  `index-consumer` profile skips clone-refresh, subset projection, and the
  scope gate, and simply execs the dashboard script.
- `repo-sync` *is* the clone-refresh infrastructure (clones/pulls the enrolled
  set, read-only toward GitHub); the `sync` profile likewise skips subset
  projection, the scope gate, and a separate clone-refresh step (it would be
  self-referential), and takes no `output_repo`/index. It is included so an
  enrolled program is runnable via `repoman run repo-sync` (consistency with
  `KNOWN_PROGRAMS`); subset selection, capability gate, and clone refresh apply
  to the `scanner` profile only.

**Adding a new program = adding one row.** The orchestrator reads the row's
fields to decide steps and to write the index entry; a program never
self-registers. This table is the natural future home for the unified program
registry (#76); for now it must stay consistent with the `KNOWN_PROGRAMS`
allowlist in `repoman-setup.sh`. Unifying the two lists is #76's job, not
this spec's — we deliberately avoid entrenching a conflicting third registry.

## Data flow

### Subset selection (env-scoped temp repos file)

Scanners resolve the enrolled set internally via `repoman_get_repos` and take
**no `--repos` flag** (the architecture spec's `--repos` sketch was never
implemented; link-health/dep-bump drive from `repoman_load_enrolled` +
`enrolled_clone_dirs`, pr-review/weekly go straight to GitHub). To restrict a
run to a named subset without touching any scanner:

```
~/.repoman/repos.json          (authoritative; written only at setup/enroll time
   [owner-a/repo-1, owner-b/repo-2]  via repoman-setup.sh, never during a run)
        │  run path reads the skill-reconciled target list
        ▼
   project to subset  ->  "$(mktemp -d)/repos.json"   [in $TMPDIR, NOT under ~/.repoman/]
        │                   written directly as a throwaway {owner,name} array
        ▼                   (NOT via repoman-setup.sh; allowed because it is
   REPOMAN_REPOS_FILE="$tmp" bash <scanner>.sh         outside the ~/.repoman/ guard)
        │                   scanner's own repoman_get_repos reads the override
        ▼
   trap 'rm -rf "$tmpdir"' EXIT    (fires on success/error/signal; only kill -9 leaks,
                                     and $TMPDIR is OS-reclaimed)
```

- **No targets** → no temp file; scanner reads the real `repos.json` (whole
  enrolled set). Common scheduled case.
- **Targets** → normally the list is already reconciled by the skill. The run
  path validates each is enrolled (`is_enrolled`, defensive) and fails loud
  naming any that is not. Because the CLI can also be invoked directly with a
  **bare** name (not only skill-reconciled `owner/name` slugs), it additionally
  resolves a bare name via `repoman_match_name` and **fails loud on an ambiguous
  bare name** — one enrolled under ≥2 owners — rather than silently broadening
  the run to all of them; duplicate targets are deduped. It does not perform
  org-expansion or any other reconciliation the skill owns. (Updated in
  [bb5dfb0](https://github.com/rossoctl/automation/commit/bb5dfb05f26d84cd2a633e6c74cfbbcba9fa0706);
  supersedes the earlier "trusts the list and does not re-interpret it" wording.)

**Writer invariant:** the temp file is a throwaway projection in `$TMPDIR`, so
writing it directly does **not** violate the HARD INVARIANT (which guards only
`~/.repoman/` state). The run path never writes under `~/.repoman/`.

**Race note (non-issue):** `repos.json` is written only at setup/enroll time,
never during a run, so there is no concurrent-writer race between the read and
the projection in the normal flow. (Two simultaneous sessions — one running, one
enrolling — are out of scope for v0.1.0; the read is a single atomic `jq` over a
file the setup writer writes atomically.)

### Subset-aware stateful scanners (REVISED — supersedes "scanners unchanged")

The original design asserted the env-scoped temp file needed **no scanner
changes**. Human review (PR #117) found that is wrong for the **stateful
scanners** (link-health, dep-bump, pr-review), which diff the current scan
against their previous **full-set** report:

- link-health diffs current `broken.jsonl` against `.broken[]` from the prior
  `latest.json`; dep-bump diffs against `.stale_prs[]`; the "fixed" set is
  *in-prev-not-current*.
- Under a subset run, `REPOMAN_REPOS_FILE` narrows the *current* scan to the
  subset, but the *previous* report still holds every repo. Every out-of-subset
  finding is therefore absent from the current scan, misclassified as **fixed**,
  and its **GitHub issue is closed** — then `latest.json` is overwritten with
  subset-only findings, so the next full run re-files them as new (duplicates).
  pr-review's state-eviction pass has the same shape: it drops the
  reviewed/in-progress entries of out-of-subset repos.

**Signal:** on a narrowed run the orchestrator exports
`REPOMAN_SUBSET_REPOS` (newline-delimited `owner/name`, the scanned set)
alongside the narrowed `REPOMAN_REPOS_FILE`. Its presence tells a stateful
scanner "this is a subset run — scope the diff, carry the rest forward, skip
history." Absent ⇒ whole-set run ⇒ scanners behave exactly as before. A
directly-invoked scanner (no orchestrator) never sees it, so direct runs are
unchanged.

**Contract (carry-forward):** a stateful scanner must scope its diff and its
written state to the **repos it actually scanned this run**:

1. Determine the scanned set (the enrolled set it looped over — the subset when
   `REPOMAN_REPOS_FILE` is narrowed, else the whole set).
2. **Diff only within the scanned set:** filter the previous report's findings to
   those whose `.repo` (pr-review: the PR's repo) is in the scanned set *before*
   computing fixed/new/recurring. An out-of-subset prior finding is never seen as
   "fixed," so its issue is never closed.
3. **Carry forward on write:** `latest.json` = (fresh findings for scanned repos)
   ∪ (prior findings for unscanned repos), so the baseline stays whole and the
   next full run diffs against a complete picture.
4. **Skip `history.json` on a subset run.** `history.json` is a full-set trend
   series consumed by the dashboard (aggregation) and by `generate_scan_id`
   (same-day row count; indifferent). A subset row would distort the dashboard's
   trend/impact math. **Trade-off (accepted):** subset runs are rare manual
   recoveries (e.g. re-running one repo after a transient outage); their
   issues-created/closed counts are intentionally *not* recorded to history, in
   exchange for keeping the trend series honest and the system simple.
5. **Recompute scalar totals over the merged set.** `latest.json` carries
   per-repo lists forward (step 3), so its scalar totals must match: a subset
   run must not leave whole-set lists beside subset-only counts
   (`repos_scanned`, `total_open_prs`, `repos_with_dependabot`,
   `total_links_checked`, `ecosystem_summary`, …). Otherwise the dashboard,
   which derives ratios like SLA compliance `(total_open_prs - stale)/total_open_prs`
   and coverage `repos_with_dependabot/repos_scanned`, computes nonsense (e.g. a
   negative compliance rate).

   Two mechanisms, by stakes:
   - **dep-bump** feeds the SLA/coverage **ratios**, where a subset-vs-whole-set
     mismatch goes *negative*. `total_open_prs` counts all open PRs (not just the
     stale ones in the lists), so it cannot be derived from `stale_prs`. dep-bump
     therefore stores a per-repo open-PR breakdown (`repo_pr_counts`) in
     `latest.json`; a subset run merges this run's scanned counts with the prior
     report's carried counts and **recomputes** `total_open_prs` /
     `repos_with_dependabot` from the merged breakdown — exactly consistent with
     the carried lists. The breakdown is rewritten each full run (self-pruning,
     ~tens of bytes/repo).
   - **link-health**'s `repos_scanned` / `total_links_checked` are **display
     counts only** (the dashboard never divides them), so there is no
     negative-ratio risk. A subset run keeps the prior report's whole-set scalars
     (no per-repo link-count storage needed); the broken counts come from the
     carried `broken[]` list directly. Lower stakes, simpler mechanism.

**Dry-run writes nothing to the baseline (REVISED — PR #117 round 2).** A
`--dry-run` run must **not** write `latest.json` or append `history.json` — only
preview. The scanners originally gated issue create/close and the push on
`DRY_RUN` but called `write_report_latest`/`append_history_row` unconditionally,
so a dry run silently overwrote the baseline: the next real run then saw the
dry-run's findings as *recurring* (not *new*) and skipped filing them, and saw
nothing to close. `pr-review-scanner.sh` already gates all of
`latest.json`/`state.json`/`history.json` on dry-run; link-health and dep-bump
must do the same. The orchestrator likewise does **not** write the
`_index.json` entry on a dry run — registering a program whose dry run wrote no
`latest.json` would point the dashboard at a nonexistent report. (This is why the documented "safe preview" claim must hold:
`repoman run <program> --dry-run` is side-effect-free.)

A whole-set run (no targets) is unchanged: scanned set == enrolled set, the
carry-forward merge is a no-op, totals are the whole-set counts, and history is
appended as before. All three stateful scanners (link-health, dep-bump,
pr-review) implement the full contract — steps 1-5 plus dry-run suppression.

This revises the earlier "scanners stay unchanged" boundary: the env-scoped temp
file remains the selection mechanism, but the three stateful scanners gain
subset-awareness in their diff + write + totals + history + dry-run steps.

### Output routing

`repoman run` reads `programs/<name>.json.output_repo` (shape
`{mode: "same"|"central", repo?: "owner/name"}`, written earlier by the skill
via `set-output`). For `posts_output=yes` programs, if `output_repo` is unset →
**fail loud**: "output destination not set; run `/repoman` (or
`repoman-setup.sh set-output …`)". It never prompts.

**Validate-vs-consume gap (honest, implementation-contingent).** In v0.1.0 the
scanner's report target is still the hardcoded `REPORT_TARGET_REPO`
(removal deferred to the de-rossoctl-ing issue). So the run path *validates and
requires* `output_repo` (contract-complete for callers now), while the scanner
actually *honoring* it lands with that later issue — a scanner-internal swap,
not a `repoman run` contract change. **If implementation shows this gap can
close cleanly within this work (or must change shape), update this section to
match reality rather than let the spec drift.**

## Index-write contract

**One writer: the orchestrator.** After a `writes_index=yes` program runs, the
run path writes its `_index.json` entry via `repoman-index.sh` using the row's
`index_display_name` + `report_path`. Programs never self-register.

Two accepted consequences (documented, not silent):
1. **Registry relationship (#76).** The orchestrator table is a per-program list
   alongside `KNOWN_PROGRAMS`; it must stay consistent with it. Unifying them is
   #76. We note the table as the future registry home to avoid entrenching a
   third conflicting list.
2. **Direct invocation no longer self-indexes.** Running
   `link-health-scanner.sh` directly (outside `repoman run`) will no longer
   update `_index.json`. The **blessed path for an indexed run is
   `repoman run`.** The dogfood harness (which invokes scanners directly and
   asserts index wiring) is updated to drive through the run path.

## Dry-run passthrough (added during implementation, 2026-10-18)

**Why this was added (deviation from the original spec):** the real scanners
perform **post-report push steps** — e.g. `link-health-scanner.sh` updates
`docs/*.md` and opens PRs against a report repo *after* writing `latest.json`.
Running them for real against a fresh or no-clone environment fails at that push
step, which means (a) there is no safe way to preview "what would
`repoman run <program>` do", and (b) the dogfood harness (which the spec requires
us to extend and run before the PR) cannot drive the real scanner→index chain.
The original spec was silent on dry-run; implementation showed a run
orchestrator without one is incomplete.

**Contract:** `repoman run <program> --dry-run` forwards `--dry-run` to the
program when the program's table row declares it supports it
(`supports_dry_run=yes`). The orchestrator still runs its own steps
(resolution, output gate, capability check — index write is skipped on a dry
run; see below); `--dry-run` changes only what it hands the *program*, so the
program itself suppresses its mutating tail (issue/PR creation, docs push,
report/baseline writes, and — for `repo-sync` — the clone/pull itself). All
run-path programs support `--dry-run` as side-effect-free **except
`weekly-report`** (`supports_dry_run=no`): the flag is not forwarded and it
proceeds as a normal run — which is itself read-only (it queries GitHub and
writes a report file, filing/closing/pushing nothing), so this is not a
mutating side effect. **The "side-effect-free preview" promise therefore holds
for every program; for `weekly-report` it holds because the program is read-only
by nature, not because a dry-run flag suppresses writes.** The program table has
a `supports_dry_run` column for this.

This supersedes the earlier implementation-internal reading of `--dry-run` as
"preview resolution only, skip execution": the flag now means "a real run with
the program's own dry-run engaged", which is the useful preview and what the
dogfood exercises.

### Go-live for push-by-default-off programs (REVISED — PR #117)

Forwarding `--dry-run` is not sufficient for programs whose **default is
preview** and which publish only on an explicit `--live`. `automation-health-dashboard.sh`
defaults to `DRY_RUN=true` and pushes the dashboard PR only with `--live`. The
orchestrator originally forwarded only `--dry-run`, so a scheduled
`repoman run automation-health` always previewed and **never published** — a
daily job reporting success while the standing dashboard PR never updated.

**Contract:** a program row declares whether a non-dry-run invocation must be
told to go live (`needs_live=yes`). When set, the orchestrator forwards
`--live` on a normal (non-`--dry-run`) run, and `--dry-run` on a dry run — never
both. Programs without `needs_live` (the scanners, which push by default and are
silenced by `--dry-run`) are unaffected. The program table gains a `needs_live`
column; `automation-health` is the only `needs_live=yes` row in v0.1.0.

## Error handling & exit contract

Non-interactive, fail-loud, legible to cron/standing-order wrappers.

- **Unknown program** (not in table) → non-zero; stderr lists known programs.
- **Target not enrolled** (defensive) → fail loud, name the offending
  `owner/name`.
- **`output_repo` unset** for a `posts_output` program → fail loud (above);
  never prompts.
- **Capability gate** (`repoman-check.sh`): adopt its existing contract
  unchanged — **scope gap = hard fail (abort, non-zero)**; **label gap =
  warning, continue**. The run path surfaces its stderr and propagates its code.
- **Clone refresh** (`repo-sync.sh`): existing semantics — per-repo failures
  counted/logged. **Total sync failure (all enrolled fail) = fatal** (cannot
  scan uncloned repos); **partial = logged warning, continue.**
- **Scanner exec failure** → non-zero, reason on stderr.
- **Temp dir** → `trap 'rm -rf "$tmpdir"' EXIT` fires on success/error/signal.
- **Exit codes:** `0` = program ran and succeeded; **non-zero** = gate failed OR
  exec failed OR a fatal precondition (unknown program, unset output, total sync
  failure). Partial per-repo issues follow the program's own semantics.

## Commit & sign-off identity (considered extensively; deferred)

Captured because it shapes future RepoMan work and is why fixers are out of
scope.

- **Current mechanism:** `link-health-fixer.sh` hardcodes one identity and sets
  author = committer ([the identity block](https://github.com/rossoctl/automation/blob/954096ae7adc5a1f6ca9eadc1b24b035cc252687/scripts/link-health-fixer.sh#L25-L29)),
  then [commits with `git commit -s`](https://github.com/rossoctl/automation/blob/954096ae7adc5a1f6ca9eadc1b24b035cc252687/scripts/link-health-fixer.sh#L500),
  so the DCO `Signed-off-by` trailer is derived from that committer identity.
  **Author = committer = DCO signer, all one hardcoded identity. No split exists
  today.** The same shape produces the dashboard's auto-PRs (e.g.
  [#111](https://github.com/rossoctl/automation/pull/111)). (Blob links pinned to
  `954096a`; lines drift once the file is edited.)
- **The real question (surfaced during run-path design):** when automation
  commits/opens PRs, three roles can diverge — **author** (who wrote the
  change), **committer** (what ran it; could be a bot/GitHub App), and **DCO
  signer** (a real person certifying under the DCO). DCO requires a real
  identity; a bot/App identity may not satisfy it. The hardcode is a stopgap
  that attributes automated work to a human so DCO passes.
- **Proposed future capability (NOT v0.1.0):** a setup-time question for
  commit-bearing programs — "use your detected login identity for both committer
  and sign-off, or split them (bot/App committer + human DCO signer)?" —
  persisted to `programs/<name>.json`, consumed by the fixers instead of the
  hardcode.
- **Dependency:** [#82](https://github.com/rossoctl/automation/issues/82)
  (GitHub App auth vs. clawgenti bot user) is the upstream decision this rests
  on. The identity model should be settled with #82 **before** the fixers'
  identity is parameterized. Hence v0.1.0 run path **does not touch identity**:
  scanners are read-only toward commits (they open issues via the PAT; the
  committer-identity hardcode only bites the fixers, which are out of scope),
  so there is a clean deferral boundary.

## Testing & CI

**New: `tests/test-repoman-run.sh`** — hermetic (overrides
`REPOMAN_CONFIG_FILE`/`REPOMAN_REPOS_FILE`/`REPOMAN_PROGRAMS_DIR`, stubs
`gh`/scanners/`repoman-check.sh`). Cases:
- unknown program → non-zero + known-programs list;
- no targets → scanner runs against full enrolled set, **no temp file created**;
- named subset → temp `repos.json` in `$TMPDIR` holds exactly the subset,
  scanner invoked with `REPOMAN_REPOS_FILE` pointing at it, temp dir **gone after
  exit**;
- target not enrolled → fail loud naming it;
- `output_repo` unset for a `posts_output` program → fail loud, no prompt;
- `writes_index=yes` → exactly one `_index.json` entry written **by the
  orchestrator**; `writes_index=no` → no entry;
- `index-consumer` (automation-health) → no clone-refresh, no scope gate, no
  subset projection; dashboard exec'd;
- scope-gate hard-fail (stub `repoman-check.sh` non-zero) → run aborts non-zero;
- total clone-sync failure → fatal; partial → warning + continue;
- exit codes asserted for clean / gate-fail / exec-fail.

**Modified tests:** `tests/test-link-health-index-wiring.sh` +
`tests/test-dep-bump-index-wiring.sh` — scanners no longer self-register, so
these retarget to assert the **orchestrator** writes the entry.

**CI (explicit lists, not globs — a new file silently never runs otherwise):**
add `tests/test-repoman-run.sh` to **both** the `Run test suite` loop **and** a
shellcheck group in `.github/workflows/tests.yml`. While editing that list, also
add the two currently shellcheck-only / un-run tests the run path depends on —
`tests/test-repoman-check.sh` and `tests/test-repoman-requirements.sh` — to the
run-suite loop (small adjacent hardening, directly relevant since the run path
leans on the capability gate).

## Deferred work (filed/to-file, referenced here for a clean boundary)

- **De-rossoctl-ing ([#116](https://github.com/rossoctl/automation/issues/116)):**
  remove the hardcoded org/person defaults — `REPORT_TARGET_REPO` and
  `SOURCE_REPO` in `link-health-scanner.sh` / `automation-health-dashboard.sh`,
  the committer identity in `link-health-fixer.sh`, and the personal `REPORT_PY`
  **fallback** in `weekly-report.sh` (already env-overridable). As of #127 that
  wrapper resolves `REPORT_PY` from a candidate list — the bundled plugin path
  first, the personal `$HOME/workspaces/...` path only as a fallback — so #116's
  remaining task here is dropping that fallback candidate, not the whole default.
  #116 carries the authoritative per-line locations; distinct from #99 (that is
  config *plumbing*; this is embedded org/person *defaults*).
- **#99** — scanner/fixer/dashboard param-driven decoupling (v0.1.1).
- **#82** — automation commit/sign-off identity (gates fixer orchestration).
- **#76** — unify program registry.
- **#98**, **#115** — v0.1.1 / optional riders.
