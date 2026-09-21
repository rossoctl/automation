# RepoMan Phase 3 — Per-Program Capability Check

**Date:** 2026-09-21
**Status:** Design (awaiting review)
**Epic:** [#72](https://github.com/rossoctl/automation/issues/72) (Phase 3)
**Issue:** [#74](https://github.com/rossoctl/automation/issues/74)
**Parent spec:** [2026-08-27-repoman-architecture.md](2026-08-27-repoman-architecture.md)
**Builds on:** [Phase 1 input model](2026-09-11-repoman-phase1-input-model-design.md), [Phase 2 config setup](2026-09-16-repoman-phase2-config-setup-design.md)
**Also addresses:** the **checks** half of repo-onboarding [#39](https://github.com/rossoctl/automation/issues/39)

## Summary

Phase 3 adds a per-program, per-repo capability check that runs at program
invocation. It answers one question for the user, who cannot be expected to
know what each program needs: does this program have the PAT scopes and repo
labels it requires to be *useful*, and if not, exactly how does the user close
the gap?

The check is grounded in a data flow already reserved by Phases 1 and 2. Each
skill declares its needs in a machine-readable `## Requirements` block in its
`SKILL.md` (authored in `rossoctl/agent-skills`). That block is read **once at
setup** and merged into the program's config file (`programs/<name>.json`,
written by the Phase 2 pure writer). The checker reads that config file plus
`repos.json` (via the Phase 1 reader) at **every invocation**. The checker
never parses `SKILL.md` at runtime.

## Relationship to Phases 1 and 2 (data flow)

```
rossoctl/agent-skills  SKILL.md  (## Requirements block — authoring source)
   │
   │  read ONCE at setup, when the user picks programs
   │  (parsed by repoman_parse_requirements; values passed to the writer)
   ▼
~/.repoman/programs/<name>.json   (Phase 2 writes {enabled, output_repo};
   │                               Phase 3 MERGES in {pat_scopes, labels_*})
   │  read at EVERY invocation
   ▼
capability check (Phase 3)  reads programs/<name>.json + repos.json
   │                        (Phase 1 repoman_get_repos), checks gh scopes
   │                        + labels per repo, aggregates gaps
   ▼
program runs (scopes ok) / hard-fails (missing scope) / warns+instructs (labels)
```

This is the same reader/writer split the earlier phases established: Phase 1
readers consume `config.json`/`repos.json`; Phase 2's pure writer produces
`programs/<name>.json` and reserved a JSON-**merge** seam precisely so Phase 3
could add `pat_scopes`/`labels_*` without clobbering the setup-collected fields
(Phase 2 spec, "enable-program and set-output perform a JSON merge, not an
overwrite").

## Deliverables

| # | Deliverable | Repo |
|---|---|---|
| A | `## Requirements` block folded into `## Prerequisites` in each program's `SKILL.md` | `rossoctl/agent-skills` |
| B | `repoman_parse_requirements` (lib) + `repoman-setup.sh set-requirements` subcommand (pure writer) | `rossoctl/automation` |
| C | `scripts/repoman-check.sh` invocation-time checker + `gh_with_backoff` ported into `github-api.sh` | `rossoctl/automation` |

Phase 3 is a full vertical slice: it delivers the authoring grammar, the
setup-time reader/writer, and the invocation checker end to end. It is
cross-repo by design — every RepoMan phase from 3 onward has an
agent-skills-resident deliverable (verified against the #74/#75/#76/#77 issue
bodies), so the cross-repo workflow is established here at the smallest phase
and reused later.

## Deliverable A — the `## Requirements` grammar

Authored in each program's `SKILL.md`, **folded into the existing
`## Prerequisites` section** (a machine-readable block alongside the human
prose, not a separate top-level heading). Format is the explicit dash-prefixed
key/list grammar from the architecture spec, extended to split labels by role:

```markdown
## Prerequisites

- `bash` 4+ (macOS ships 3.2; use `brew install bash` for 4+)
- `gh` (GitHub CLI, authenticated with org access)
- `jq` (JSON processor)

### Requirements (machine-readable)

- pat_scopes: [repo]
- labels_required: [ready-for-ai-review]
- labels_applied: [needs-changes, approved]
- programs: [scanner]
```

Keys:

- **`pat_scopes`** — OAuth scopes the program's `gh` operations require. Drives
  the scope check (hard gate).
- **`labels_required`** — labels the program *consumes to be useful*. Without
  them the program may not error, but it is inert (e.g. the PR-review scanner
  is useless if `ready-for-ai-review` never exists for a human/agent to apply).
  Drives the label check (warn + instruct, see Deliverable C).
- **`labels_applied`** — labels the program *writes as output*
  (e.g. `broken-link/internal`). Informational only; not checked. Documents
  what the program produces.
- **`programs`** — the sub-program(s) this skill ships. In `agent-skills`
  scanner and fixer are separate skills with separate `SKILL.md` files, so this
  is per-skill (e.g. `[scanner]` on a scanner skill). Downstream-informational
  (feeds the Phase 5 `_index.json` registry); not part of the pass/fail check.

The `required`/`applied` split is a deliberate deviation from the parent spec's
single `labels:` key. Its motivation is concrete and present today, not
speculative: at least one existing program (PR-review scanner) has a
load-bearing label that a static grep of the scripts cannot distinguish from a
cosmetic output label. The distinction must therefore be *declared*, not
inferred. See "Parent-spec amendments."

Per-skill `pat_scopes`/`labels_*` values are derived during implementation from
each script's actual `gh` calls and label usage, not guessed.

## Deliverable B — parser (lib) + writer (subcommand)

### Single point of parsing

The `## Requirements` block is parsed in exactly one place. Everything
downstream consumes already-resolved values. This keeps the Phase 2 pure-writer
contract intact and prevents two parsers drifting.

**`repoman_parse_requirements <skill-md-path>`** — new lib module
`scripts/repoman-requirements.sh`, sourced via `program-lib.sh` (kept out of
`org.sh`, whose responsibility is repo/config reading).

- Locates the machine-readable block within `## Prerequisites`, reads the
  `- key: [list]` lines, ignores surrounding prose.
- Bash 3.2-safe (no associative arrays, no `mapfile`), matching the macOS floor
  the other scripts hold.
- Emits normalized JSON via `jq -n` (safe construction):
  `{ "pat_scopes": [...], "labels_required": [...], "labels_applied": [...], "programs": [...] }`.
- Fails loudly with a specific message on a malformed block (unbracketed value,
  unknown key), consistent with Phase 2's loud-failure discipline.

### Writer stays a strict pure writer

**`repoman-setup.sh set-requirements --program <name> --pat-scopes <csv> --labels-required <csv> --labels-applied <csv>`**

- Takes **already-resolved values** as explicit flags. It never reads
  `SKILL.md`. This preserves Phase 2's contract ("receives already-resolved
  inputs and writes JSON") so a `set-requirements` failure can only concern the
  values passed to it — never an upstream artifact (a malformed `SKILL.md`)
  beyond its control, which is far easier to troubleshoot.
- JSON-**merges** `pat_scopes`/`labels_required`/`labels_applied` into
  `programs/<name>.json`, preserving `enabled`/`output_repo` (the reserved
  Phase 2 merge seam).
- Follows every Phase 2 convention: pure writer (no `gh`, no prompt, no clone),
  arity guard (`[ $# -ge 2 ]`) before every `shift 2`, atomic
  temp-then-`mv`, `--help`, and the known-program allowlist.

### Call chain at setup

The caller (the setup skill/agent) chains parser → writer:

```bash
reqs=$(repoman_parse_requirements "$skill_md")
repoman-setup.sh set-requirements --program link-health \
  --pat-scopes      "$(printf '%s' "$reqs" | jq -r '.pat_scopes      | join(",")')" \
  --labels-required "$(printf '%s' "$reqs" | jq -r '.labels_required | join(",")')" \
  --labels-applied  "$(printf '%s' "$reqs" | jq -r '.labels_applied  | join(",")')"
```

## Deliverable C — the invocation-time checker

`scripts/repoman-check.sh --program <name> [--create-missing-labels]`

Reads `programs/<name>.json` (`REPOMAN_PROGRAMS_DIR`) and iterates repos via the
Phase 1 reader `repoman_get_repos` (from `repos.json`). **Aggregates all gaps
across all repos** before exiting — it does not fail-fast on the first gap, so a
setup-heavy multi-repo run surfaces everything at once. Every `gh` call is
routed through `gh_with_backoff` (see Rate-limiting).

### PAT-scope check (hard gate)

- `gh api -i user` → parse the `X-OAuth-Scopes` response header (authoritative;
  e.g. `gist, read:org, repo`). Every scope in `pat_scopes` must be present.
- A missing scope is a **hard fail**: exit non-zero with a message naming the
  missing scope. A program genuinely cannot act without its required token
  scope.
- A fine-grained token returns an **empty** `X-OAuth-Scopes` header. This is not
  a pass — the checker cannot verify scopes, so it hard-fails with a message
  saying scopes cannot be verified for fine-grained tokens and how to proceed.

### Label check (warn + instruct; conditional mutation)

Only `labels_required` participates. Per repo:

- **Present** → ok.
- **Missing** → determine whether the current PAT can create the label, then:
  - **PAT can create, `--create-missing-labels` set** → create via
    `gh label create` and report that it was created and how to use it.
  - **PAT can create, no flag** → default (read-only): instruct the user with
    the exact `gh label create ...` command to run.
  - **PAT cannot create** → surface that the program *can be launched but may
    not be useful* without the label, and give specific remediation: (a) supply
    a PAT with the required scope, **or** (b) create the labels through the
    GitHub **web UI** (repo Settings → Labels). Note (b) explicitly: the
    remediation must **not** hand the user a `gh label create` command here,
    because that call authenticates with the same under-scoped PAT the checker
    just found insufficient and would fail identically. The web UI uses the
    user's browser/session auth, which is a different credential from the PAT
    under inspection — that is why it is a valid path while the CLI is not.

  This asymmetry is deliberate: the checker only ever emits a `gh label create`
  instruction when it has *confirmed the current PAT can run it*
  (the "PAT can create, no flag" case). It never instructs the user to run a
  command with a credential it already determined lacks the scope.

The checker is **read-only by default**; it mutates the repo (creates labels)
only behind the explicit `--create-missing-labels` flag. The calling program,
not the end user, controls whether that flag is passed.

`labels_applied` is never checked.

### Determining create-capability — authoritative, not a static table

Whether the PAT can create a label is answered by **GitHub itself**, not by a
baked-in scope table (an earlier static guess — "`repo`, or `public_repo` for
public repos" — was both incomplete and repo-visibility-dependent, and notably
`read:org` does **not** authorize label creation). GitHub returns, on the
labels endpoint, the header `X-Accepted-OAuth-Scopes: repo` (verified live).
The checker reads that per-endpoint accepted-scope set and compares it against
the token's `X-OAuth-Scopes`. This handles public vs private repos
automatically and self-adjusts if GitHub changes the requirement.

### Scalability (a core RepoMan consideration)

Because enrolling a whole org can mean many repos, API cost and GitHub
rate-limiting were an explicit design consideration here, not an afterthought,
and were checked against the live API rather than assumed:

- The accepted-scope set (`X-Accepted-OAuth-Scopes`) is a property of the
  **endpoint and repo visibility**, not of individual repo data, so it is
  constant across all repos of the same visibility. The checker therefore
  probes it **at most twice total** (one private-repo sample, one public-repo
  sample) and caches by visibility — **O(1)** in the number of repos.
- The unavoidable per-repo cost is the `gh label list` call — **O(#repos)**.
- The scope check itself is a single `gh api user` call — **O(1)**, independent
  of repo count.
- Every `gh` call is wrapped by `gh_with_backoff`, so transient 403/429/
  secondary-rate responses are retried with exponential backoff rather than
  failing the run.

Net cost: **O(1)** scope + accepted-scope probes and **O(#repos)** label-list
calls, all backoff-protected. (This note is expected to evolve as the grammar
amendment lands per "Parent-spec amendments"; it is recorded so reviewers see
scalability was verified, not presumed.)

### `gh_with_backoff` port

The rate-limit-aware `gh` wrapper (`gh_with_backoff`: up to 3 retries,
exponential backoff on 403/429/rate-limit/secondary-rate, hard stop after max
attempts) currently lives only in the **stale monolithic** `program-lib.sh` in
`agent-skills` — not in automation's modular lib. Phase 3 ports it into
automation's `scripts/github-api.sh` (where `gh` wrappers belong), with its own
unit test. The checker is its first consumer; all future automation `gh` calls
should use it. This is folded into Phase 3 rather than a separate prerequisite
PR because the checker is the reason it is needed.

### Additive

A program that never invokes the checker behaves exactly as it does today. The
checker is opt-in per program invocation, not a universal gate at repo-add time.

## Testing (TDD)

- **`repoman_parse_requirements`** (`tests/test-repoman-requirements.sh`):
  fixture `SKILL.md` → expected normalized JSON; malformed-block loud failure
  with **message assertion** (not just non-zero exit).
- **`set-requirements` writer** (extend `tests/test-repoman-setup.sh`): merge
  preserves `enabled`/`output_repo`; arity guards before `shift 2`; trailing
  no-value flags rejected with their specific message; unknown program rejected.
  Message assertions throughout.
- **`gh_with_backoff` port** (unit test): stubbed `gh` returning 429 then
  success → asserts retry occurred and the backoff WARN message was emitted;
  persistent 429 → asserts the hard-stop error after max attempts.
- **`repoman-check.sh`** (`tests/test-repoman-check.sh`): stubbed `gh` (function
  shadow) covering scope present/absent, fine-grained empty-scope, label
  present/absent, create-capable vs not, `--create-missing-labels` on/off, and
  **multi-repo aggregation** (all gaps reported, not fail-fast). Assert the
  specific messages, including the scope hard-fail and the three label
  outcomes.
- **CI** (`.github/workflows/tests.yml`): add `repoman-requirements.sh` and
  `repoman-check.sh` to the shellcheck list and the test-run list;
  `github-api.sh` is already covered.

## Parent-spec amendments (part of Phase 3)

The architecture spec ([2026-08-27](2026-08-27-repoman-architecture.md)) is a
living document; Phase 3 updates it in the same change:

1. `## Requirements` is folded **into** `## Prerequisites` in `SKILL.md` rather
   than a sibling top-level heading (spec §Skill layer showed it as a separate
   heading).
2. The `labels:` key is split into `labels_required` / `labels_applied`
   (the spec's `## Requirements` example block under §Skill layer has a single
   `labels:`). Update that example block to the split grammar, and the
   capability-check narrative (spec
   §"Program invocation flow", the `{ pat_scopes, labels }` read) to reference
   the split keys.
3. Record the scalability finding (O(1) accepted-scope probes via
   visibility-caching + O(#repos) label-list calls) as a short note where the
   check is described.

Additionally, the **Phase 2 spec** ([2026-09-16](2026-09-16-repoman-phase2-config-setup-design.md))
carries a forward-reference describing Phase 3's fields as "`pat_scopes` /
`labels` in `programs/<name>.json`" (single `labels`). Update that reference to
the split `labels_required` / `labels_applied` keys so the two specs agree.

## Out of scope

- **Bulk PAT-scope check at org-enrollment** (parent spec §Setup flow, step 2):
  the whole-org scope pre-check at enrollment belongs to the onboarding/Phase 2
  path (#39 config half), not the per-invocation per-program check that #74
  titles. Deferred.
- **`_index.json` program registry / dashboard wiring** — Phase 5 (#76). The
  `programs` key is authored here but consumed there.
- **`_meta.json` / pinned-SHA attribution** — Phase 6 (#77).
- **Deploying the modular lib to the OpenClaw host** — RepoMan v0.1 is tested
  wholesale (cron off, dry-run) rather than by per-phase host sync; no host
  deploy step is part of Phase 3.
