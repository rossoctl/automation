# Org Portability Design — Single Source of Org Truth

**Date:** 2026-07-29
**Status:** Design (awaiting review)
**Related:** epic `rossoctl/automation#32` (rename cleanup), `#31` (Phase 6), `#30`, `#35` (lib decomposition), `#37` (host clone-dir rename), `#39` (repo-onboarding skill)

## Problem

The scanner/fixer suite (link-health, dep-bump, pr-review, plus the health dashboard) hardcodes
org identity in scattered, inconsistent ways. After the `kagenti` → `rossoctl` org rename this left
the scripts half-migrated: `dep-bump-scanner.sh` uses `ORG="rossoctl"`, while
`dep-bump-fixer.sh`, `link-health-fixer.sh`, and `automation-health-dashboard.sh` still use
`ORG="kagenti"`; several paths bypass `$ORG` entirely with a literal `rossoctl/$canon`; and the
main-repo write targets are hardcoded `kagenti/kagenti`. The fork owner (`clawgenti`) and clone root
(`~/kagenti`) are likewise repeated per script.

The consequence is twofold:

1. **Rename is incomplete and fragile** — finishing it means editing the same write-path lines in
   many files, and the inconsistency invites silent misrouting.
2. **Not portable** — pointing the suite at a second org (an explicit near-term goal) is not
   possible without editing every script.

## Goal

Design a single source of org truth: org identity is fed in **once**, and every downstream script
derives the repo refs, fork targets, clone paths, and display strings from it. The design is built
for multi-org portability, and its **first consumer completes the rossoctl rename** (Phase 6). No
script should carry an org literal.

"Done" enables: (a) running the suite against any org by touching one file, and (b) the
repo-onboarding skill (`#39`) taking any `<org>/<repo>` with no kagenti/rosso-isms.

## The org identity model

Org identity decomposes into a small set of facts (four core identity facts plus one transitional
remap). Because the fork-repo name is derivable (decision below), there is no separate fork-repo
identity to track. `REMAP` is not a permanent identity — it exists only while on-disk clone dirs
carry pre-rename names, and self-retires (see `#37`).

| Fact | Profile var | Default | Used for |
|------|-------------|---------|----------|
| Read-owner | `ORG` | (required, fail loud if unset) | `gh` reads; `ORG/<canonical>` refs |
| Fork owner | `FORK_OWNER` | `clawgenti` | write path: `FORK_OWNER/<canonical>` |
| Main repo | `MAIN_REPO` | `$ORG/$ORG` | dashboard / report PR target (only programs that open such PRs use it) |
| Clone root | `REPOS_DIR` | `$HOME/$ORG` | local clone iteration |
| Source repo | `SOURCE_REPO` | `$ORG/automation` | standing-order link in report PRs (added during PR B; see addendum) |
| Dir remap (transitional) | `REMAP` | empty ⇒ identity | pre-rename clone dir basename → canonical name |

> **Addendum (PR B, 2026-08):** `SOURCE_REPO` was added during PR B implementation,
> beyond the original identity set above. It names the repo where the suite (scripts,
> skills, standing orders) is version-controlled, so report PRs can link back to the
> invoking program's standing order for auditability. It follows the same precedence
> as the other facts except it has no `--flag` tier (env > profile > default) — it is
> a deploy-level constant, not a per-invocation knob.

### Settled decision: fork name = canonical name (Option B)

The fork account (`clawgenti`) currently has a stale-named fork `clawgenti/kagenti` for the main
repo; forks for most core repos do not yet exist (`ensure_fork` auto-creates them). Verified fork
inventory at design time: only `clawgenti/{cortex, workload-harness, kagenti}` exist.

**Decision:** the design assumes `FORK_OWNER/<canonical>` uniformly. This requires a one-time rename
of `clawgenti/kagenti` → `clawgenti/rossoctl`, after which the fork side needs no separate mapping
and derives from the canonical repo like everything else. This is the previously-recorded Phase 6
fork decision, now firm.

## Architecture

**One committed profile file + a lib loader.**

### Files

- **`config/org.env`** — the default profile (rossoctl values). Selecting a different profile is done
  via `--profile <name>` or `$ORG_PROFILE=<name>`, which loads `config/org.<name>.env` instead.
- **`config/core-repos.txt`** — **converted to bare names** (`rossoctl`, `automation`,
  `agent-skills`, …). The owner is derived by prepending the loaded `$ORG`. Remains a single shared
  list (the core set is the same regardless of which identity loads it), preserving the current
  line-per-repo diffs and `#`-comment support.
- **`scripts/program-lib.sh`** — gains `load_org_profile()`; `canonical_repo_for_dir()` and
  `get_core_repos()` become profile-driven (data, not hardcoded logic).

### The loader

`load_org_profile()` is called once near the top of every program, after argument parsing. It
resolves each identity fact by precedence and exports it:

```sh
load_org_profile() {
  # 1. pick the profile file:
  #    --profile flag > $ORG_PROFILE > "" (default -> config/org.env)
  local name="${PROFILE_FLAG:-${ORG_PROFILE:-}}"
  local lib_dir; lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local profile_file
  if [ -n "$name" ]; then
    profile_file="$lib_dir/../config/org.$name.env"
  else
    profile_file="$lib_dir/../config/org.env"
  fi
  if [ ! -f "$profile_file" ]; then
    echo "ERROR: org profile not found: $profile_file" >&2
    return 1
  fi

  # 2. source it. The profile file defines PROFILE_-PREFIXED names ONLY
  #    (PROFILE_ORG, PROFILE_FORK_OWNER, ...), never the bare resolved names.
  #    This is what makes sourcing safe: it cannot clobber an env-provided ORG
  #    before the precedence block runs. See "Profile capture mechanism" below.
  # shellcheck source=/dev/null
  source "$profile_file"

  # 3. resolve each fact by precedence: flag > env > profile > builtin default
  ORG="${ORG_FLAG:-${ORG:-${PROFILE_ORG:-}}}"
  : "${ORG:?ERROR: ORG could not be resolved (flag/env/profile all empty)}"
  FORK_OWNER="${FORK_OWNER_FLAG:-${FORK_OWNER:-${PROFILE_FORK_OWNER:-clawgenti}}}"
  MAIN_REPO="${MAIN_REPO_FLAG:-${MAIN_REPO:-${PROFILE_MAIN_REPO:-$ORG/$ORG}}}"
  REPOS_DIR="${REPOS_DIR_FLAG:-${REPOS_DIR:-${PROFILE_REPOS_DIR:-$HOME/$ORG}}}"
  REMAP="${PROFILE_REMAP:-}"
}
```

Note: the default profile file is `config/org.env` (not `config/org.org.env`); the `.` + name suffix
is only added when a profile name is explicitly given.

### Profile capture mechanism

The precedence rule requires that an env-provided value beats the profile. If the profile file
contained a bare `ORG=rossoctl`, `source`-ing it would set `ORG` **directly** — clobbering any
env-provided `ORG` *before* the precedence block runs, silently inverting "env > profile". To make
that impossible by construction, **the profile file assigns only `PROFILE_`-prefixed names**:

```sh
# config/org.env  (default profile)
PROFILE_ORG=rossoctl
PROFILE_FORK_OWNER=clawgenti
PROFILE_MAIN_REPO=rossoctl/rossoctl      # optional; defaults to $ORG/$ORG
PROFILE_REPOS_DIR=${HOME}/rossoctl       # optional; defaults to $HOME/$ORG
PROFILE_REMAP="kagenti:rossoctl kagenti-extensions:cortex"   # transitional; see #37
```

Sourcing this file can only ever set `PROFILE_*` variables, never the resolved `ORG`/`FORK_OWNER`/…
that a flag or env var may already hold. The precedence block then reads `PROFILE_ORG` etc. as the
lowest-but-one tier. No subshell or env snapshotting is needed.

### Precedence

**First wins: explicit `--flag` > env var > profile value > built-in default.**

The profile provides defaults; existing flags and env vars still win. This is what keeps the live
host runs working unchanged during migration (the host sets `REPOS_DIR=~/kagenti` and passes flags;
both continue to take effect). A later cleanup could make the profile authoritative or remove flags,
but that is out of scope here.

**Flag-tier scope.** The full four-tier chain applies to the facts that have a CLI flag:
`ORG` (`--org`), `FORK_OWNER` (`--fork-owner`), `MAIN_REPO` (`--main-repo`), and `REPOS_DIR`
(`--repos-dir`, added by this work — a durable, real knob). `REMAP` is deliberately **profile-only**
(no env or flag tier): it is transitional, self-retires once host clone dirs are renamed (`#37`), so
a `--remap` flag would be throwaway CLI surface. Not every script defines every flag — a script only
adds the flags for facts it actually consumes (e.g. a read-only scanner needs no `--fork-owner`);
the loader resolves each fact from whichever tiers are present, and an absent `*_FLAG` simply falls
through to the env/profile/default tiers.

### Two helpers become profile-driven

- **`canonical_repo_for_dir()`** reads `REMAP` (format: `"kagenti:rossoctl kagenti-extensions:cortex"`)
  instead of a hardcoded `case`. An empty `REMAP` makes it pure identity. Unknown names pass through
  unchanged (identity), matching today's behavior.
- **`get_core_repos()`** reads the now-bare `core-repos.txt` and prepends `$ORG/` to each line.

### The `--kagenti-dir` rename

`automation-health-dashboard.sh`'s `--kagenti-dir` flag / `KAGENTI_DIR` env var is renamed to the
org-neutral `--main-repo-dir` / `MAIN_REPO_DIR`. The old `--kagenti-dir` is kept as a **deprecated
alias** (emits a warning, still works) for one release so host cron does not break mid-migration.
`KAGENTI_REPO` in `link-health-scanner.sh` is likewise renamed to derive from `$MAIN_REPO` /
`$REPOS_DIR`.

## Model diagram

```
                        ┌───────────────────────────────────────────┐
                        │              SINGLE SOURCE                  │
                        │                                             │
   selection            │   config/org.env         (default profile) │
   ┌──────────────┐     │   config/org.<name>.env  (--profile <name>)│
   │ --profile /  │────▶│   ┌─────────────────────────────────────┐  │
   │ $ORG_PROFILE │     │   │ PROFILE_ORG=rossoctl                │  │
   └──────────────┘     │   │ PROFILE_FORK_OWNER=clawgenti        │  │
                        │   │ PROFILE_MAIN_REPO=rossoctl/rossoctl │  │
                        │   │ PROFILE_REPOS_DIR=$HOME/rossoctl    │  │
                        │   │ PROFILE_REMAP="kagenti:rossoctl \   │  │
                        │   │        kagenti-extensions:cortex"   │  │ ◀── transitional,
                        │   └─────────────────────────────────────┘  │     delete post-#37
                        │                                             │
                        │   config/core-repos.txt  (bare names)      │
                        │     rossoctl / automation / agent-skills…  │
                        └───────────────────┬─────────────────────────┘
                                             │
              precedence (first wins):       │  sourced once per run
              --flag > env > profile > default
                                             ▼
                        ┌───────────────────────────────────────────┐
                        │        program-lib.sh  (the loader)         │
                        │                                             │
                        │   load_org_profile()  →  exports:           │
                        │       ORG  FORK_OWNER  MAIN_REPO  REPOS_DIR │
                        │                                             │
                        │   get_core_repos()        → $ORG/<name>     │
                        │   canonical_repo_for_dir() → reads REMAP    │
                        │   ensure_fork/create_fork_pr → FORK_OWNER   │
                        └───────────────────┬─────────────────────────┘
                                             │  every program sources lib,
                                             │  calls load_org_profile() once
                 ┌───────────────┬───────────┼───────────┬────────────────┐
                 ▼               ▼           ▼           ▼                ▼
          link-health      dep-bump     pr-review    pr-review     automation-
          scanner/fixer    scanner/     scanner/     impact        health-
                           fixer        fixer                      dashboard
                 │               │           │           │                │
        ─────────┴───────────────┴───────────┴───────────┴────────────────┴────────
         READS   :  gh ... "$ORG/$canon"          (canonical from REMAP)
         WRITES  :  fork   = "$FORK_OWNER/$canon"
                    PR      → base "$ORG/$canon"   (via create_fork_pr)
         DASH/REPORT PR →  "$MAIN_REPO"
         CLONES  :  iterate "$REPOS_DIR"/*  →  canonical_repo_for_dir → is_core_repo
```

**Reading the diagram:** the profile is written once (or selected via `--profile`); the loader
resolves the four facts by precedence and exports them; every program sources the lib and calls
`load_org_profile()` once; from then on all reads, writes, clone iteration, and dashboard PRs derive
from those vars — no script carries an org literal.

## Error handling

The design inherits and extends the existing fail-loud discipline:

- **Missing profile file** → error to stderr, exit non-zero. Never silently fall back to a default
  org — a wrong-org run could open PRs against the wrong repos.
- **`ORG` unresolved** after precedence → hard fail (`${ORG:?...}`). Every other fact has a safe
  default; `ORG` does not.
- **Empty `core-repos.txt`** → existing guard stays (fail, never scan an empty set).
- **Malformed `REMAP` entry** (no colon) → skip with a warning, non-fatal. `canonical_repo_for_dir`
  returns identity on no-match, which is safe: an un-remapped dir is either already canonical or is
  filtered out by `is_core_repo`.
- **Live write paths** (dashboard PR to `$MAIN_REPO`, cross-fork PRs) keep their existing
  `--dry-run` gates. Migration is verified in dry-run before any live run.

## Migration / rollout — Phase 6 as first consumer

The rewire touches live production write paths, so the sequence is staged to protect them.

```
Step 0   drain open fork→main report PRs, THEN rename         [one-time, gated]
   │        clawgenti/kagenti → clawgenti/rossoctl
   │
Step 1   add profile + loader, bare core-repos.txt            [seam, zero behavior change]
   │        └─ verify: dry-run parity (repo sets identical)
   │
Step 2   rewire all scripts to $ORG/$FORK_OWNER/$MAIN_REPO    ← Phase 6, Fixes #30, closes #31
   │        └─ rename --kagenti-dir → --main-repo-dir (+ deprecated alias)
   │
Step 3   dry-run parity → controlled live run → scp to host   [protect live write paths]
   │
later    #37 renames host dirs → REMAP empties → delete line  [remap self-retires]
```

- **Step 0 — fork rename (Option B prerequisite):** `gh repo rename clawgenti/kagenti` →
  `clawgenti/rossoctl`, so `FORK_OWNER/<canonical>` derivation is valid before any script relies on
  it.

  **Precondition — drain the open fork→main report PRs first.** The link-health scanner and the
  health dashboard continuously push report branches from the fork and open PRs against the main
  repo (at design time: `#2315` `clawgenti:link-health/reports` and `#2299`
  `clawgenti:automation/health-dashboard`). These survive a fork rename — GitHub rewrites the head
  reference and the branches move with the repo, so the rename is not destructive to in-flight PRs.
  Merge or let the current cycle's report PRs settle **before** renaming anyway, to eliminate the
  one race window: a report `gh pr create` issued in the same moment the rename lands could 404.

  **Ordering is the real hazard, not the open PRs.** The old fork name keeps redirecting (git-remote
  pushes to `clawgenti/kagenti.git` still land; `clawgenti` the *owner* is never renamed), so a stale
  deployed script targeting the old name keeps working after the rename. The dangerous direction is
  the reverse: if scripts are rewired to `clawgenti/rossoctl` (Step 2) **before** the fork is
  renamed, their push/PR targets a repo that does not yet exist and the auto-report PRs silently
  break. Therefore: drain the open report PRs → rename the fork → deploy the Step-2 scripts
  immediately, minimizing the window where the fork name and the scripts' expectation disagree.
- **Step 1 — add the seam (no behavior change):** introduce `config/org.env`, convert
  `core-repos.txt` to bare names, add `load_org_profile()` and the profile-driven helpers. Because
  precedence is `flag > env > profile > default` and the profile encodes today's values, a run with
  no other changes produces identical behavior.
- **Step 2 — rewire scripts (this IS Phase 6):** replace every `ORG=` literal, `kagenti/kagenti`,
  `rossoctl/$canon`, `FORK_OWNER=`, `KAGENTI_REPO`/`KAGENTI_DIR` with the loaded vars; do the
  `--kagenti-dir` rename with a deprecated alias. This single pass over the write paths carries
  `Fixes #30` and closes `#31`.
- **Step 3 — verify then deploy:** dry-run parity per program → a controlled live run (dry-run is
  insufficient for write paths) → `scp` the updated scripts and `config/org.env` to the host. The
  host keeps `REPOS_DIR=~/kagenti` (env override wins) until `#37` renames the dirs, at which point
  `REMAP` empties and the line is deleted.

This design may be split across more than one PR at planning time (the repo's `CLAUDE.md` forbids
bundling unrelated changes); Steps 1 and 2 are the natural PR boundary (seam vs. rewire).

## Testing

- **Unit** (`$CORE_REPOS_FILE` + a fixture profile via `$ORG_PROFILE`): `load_org_profile` resolves
  each fact correctly across all four precedence levels; missing-profile and unset-`ORG` fail loud;
  `get_core_repos` prepends the loaded `$ORG`; `canonical_repo_for_dir` honors `REMAP` and falls to
  identity on empty/no-match.
- **Parity test:** capture each program's `--dry-run --verbose` repo-set output *before* Step 1,
  re-run *after*, assert identical. This is the regression gate proving the seam adds no behavior
  change.
- **Portability smoke test:** a throwaway `config/org.test.env` with a different `ORG`/`FORK_OWNER`
  and a two-line `core-repos.txt` fixture; assert a dry-run emits `testorg/<name>` refs everywhere
  and never leaks `rossoctl`/`kagenti`. Proves the multi-org goal without touching a real second org.
- Existing `tests/test-pr-review-impact.sh` and `tests/test-extract-broken-links.sh` re-run green.

## Out of scope

- Making the profile authoritative over flags/env, or removing the per-script flags entirely (a
  possible later cleanup once the profile is proven).
- Decomposing `program-lib.sh` into modules (`#35`) — the loader lands in the existing lib; module
  extraction is tracked separately and may later own the org-derivation code.
- Renaming the host clone directories (`#37`) — this design makes the remap self-retiring, but the
  actual `mv` on the host is that issue's work.
- The `tier` Custom Property migration (`rossoctl/rossoctl#1811`) — the future replacement for the
  explicit allowlist, unchanged by this design.
