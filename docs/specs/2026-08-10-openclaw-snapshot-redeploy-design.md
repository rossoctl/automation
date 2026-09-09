# OpenClaw Snapshot & Redeploy Design

**Date:** 2026-08-10
**Status:** Design (awaiting review)
**Related:** org-portability design (`docs/specs/2026-07-29-org-portability-design.md`), `config/core-repos.txt`, `config/org.env`

## Problem

The automation suite (scanners, fixers, standing orders, cron jobs) runs on a single
OpenClaw host. The disk holding that host's state will be migrated soon and may move to a
different virtual machine. Today there is no repeatable way to reconstruct the host: the
runtime, the OpenClaw state, the agent workspaces, the credentials, and the automation
source clones are all entangled on one disk, with no documented boundary between what is
authoritative and what is regenerable.

The goal is a **snapshot** that lets an operator redeploy on a new VM and have the crons and
automation "simply work," without hand-reconstructing the host from memory.

## Goal

Produce a small, portable snapshot plus a runbook such that, on a fresh VM, a single
`restore.sh` run reconstructs a working OpenClaw instance: config, cron jobs, credentials,
per-agent workspaces, memory, the core automation clones, and the service plumbing.

**Non-goals:** a raw disk image; preserving regenerable artifacts (`node_modules`, package
caches, downloaded runtimes); preserving runtime scratch (logs, delivery queues, session
transcripts, cron run history); reproducing non-core repo clones.

## Approach: clean rebuild + state

The snapshot is **not** a disk image. It is three artifacts plus a generated runbook:

1. **State archive** — the authoritative OpenClaw state, produced by the first-class
   `openclaw backup create` command (see OpenClaw docs `cli/backup`). This captures the
   state directory (`~/.openclaw`), the active config file, the external `credentials/`
   directory, and the configured per-agent workspaces. It automatically **excludes**
   live-mutation paths (logs, delivery queue, session `.jsonl`, `cron/runs`) and rebuildable
   runtime roots (`dev/`, `git/`, `npm/`, `tools/`, plugin `node_modules/`).

2. **Secrets bundle** — a *separately* captured, encrypted blob of the sensitive files that
   must survive migration but must never sit in the state archive (see "Secrets" below).

3. **Manifest + runbook** — a generated `manifest.json` recording the reconstruction facts
   (versions, service unit, gateway port, per-core-repo git state) and a `RUNBOOK.md` with
   the ordered restore steps derived from it.

On restore, the new VM installs OpenClaw fresh (pinned to the captured version), restores the
state archive, decrypts and places the secrets, re-clones only the core repos at their
recorded branches, installs the service unit, and starts the gateway. Regenerable material is
rebuilt by the install rather than carried in the snapshot.

### Why clean rebuild over bit-for-bit

The automation source clones under the clone root total ~900 MB on disk, of which the large
majority is `.git` history. Re-cloning from the remotes reduces that to a few KB of manifest
text and eliminates accumulated drift and stale in-state backups. The tradeoff — that
re-cloning only reproduces what is on the remote — is safe here: verification showed **no
core repo carries unpushed commits**; the only local state is checked-out branches and a few
KB of dirty diffs, which the snapshot captures explicitly as patches.

## What is authoritative vs regenerable

| Category | Examples | Snapshot treatment |
|----------|----------|--------------------|
| OpenClaw state | config, cron jobs, credentials dir, agent SQLite, memory | State archive (authoritative) |
| Agent workspaces | per-agent working dirs mapped via the config `workspace` field (memory, `AGENTS.md`, heartbeat/identity docs, dreams) | State archive via workspace discovery (authoritative — NOT re-cloned) |
| Secrets | `~/.openclaw/.env`, service env file, `~/.npmrc` token, SSH private key, PATs | Encrypted secrets bundle (out-of-band) |
| Core automation clones | the repos in `config/core-repos.txt` | Re-cloned at recorded branch + patched (manifest) |
| Runtime | OpenClaw version, node version, service unit, gateway port | Manifest facts (reinstalled) |
| Regenerable | `node_modules`, package caches, downloaded runtimes, plugin deps | Dropped; rebuilt by install |
| Runtime scratch | logs, delivery queue, session transcripts, cron run history, in-state `*.bak`/`*.clobbered` config copies | Dropped (excluded by `openclaw backup`) |
| Non-core clones | any clone not in `config/core-repos.txt` | Not reproduced; re-clone on demand later |

**Key correction from initial assumptions:** the per-agent workspace directories are
authoritative agent state (they hold memory and identity docs), captured by `openclaw backup`
via workspace discovery — they are NOT version-controlled and must NOT be treated as
re-clonable. Conversely, the automation clones ARE re-clonable and should not be archived
wholesale.

## Secrets

Secrets are captured as a **separate encrypted artifact**, never embedded in the state
archive, so the state archive can be shared for debugging without leaking credentials, and
the two can live in different storage with different retention.

### Encryption: age, keypair model

Encryption uses [`age`](https://age-encryption.org) with an asymmetric keypair:

- The operator generates a keypair once with `age-keygen`. The **private key stays off every
  VM** (operator's laptop or password manager).
- The **public key** (an encrypt-only capability) is placed on the host / in the toolkit
  config. `snapshot-secrets.sh` encrypts to it with `age -r <public-key>`.
- Decryption at restore requires the private key: either decrypt on the operator's laptop and
  push plaintext over the (already-encrypted) SSH channel, or copy the private key to the new
  VM briefly, `age -d -i <key>`, then shred it.

`age` is chosen over `gpg` for the minimal keypair workflow (three commands, no keyring/trust
model). Because `age` is not assumed present on any host, the toolkit ships a **self-contained
static `age` binary** rather than depending on a system package manager or `sudo`. The binary
rides along in the snapshot so the new VM can decrypt without a bootstrap dependency.

### Secrets in scope

The service env file, the OpenClaw env file, the npm registry token, the SSH private key, and
any stored PAT files. Channel credential/allowlist files under the state's `credentials/`
directory travel inside the state archive (they are part of OpenClaw state); the separate
secrets bundle covers host-level secrets outside the state directory.

## Repo handling (core repos only)

The set of repos to reproduce is **not hardcoded**. `restore.sh` reads `config/core-repos.txt`
(bare repo names) and the loaded org profile (`config/org.env`: `ORG`, `FORK_OWNER`,
`REPOS_DIR`), exactly as the rest of the suite does per the org-portability design. This keeps
the snapshot org-agnostic: pointing the suite at a different org reproduces that org's core
repos with no change to the toolkit.

For each core repo the manifest records `{ path, origin, branch, dirty, unpushed }`. Restore
clones the repo, checks out the recorded branch, and re-applies any captured dirty diff
(saved as a patch at capture time). Non-core clones are intentionally not reproduced.

## Components

The toolkit lives in this repo under `snapshot/`. Each script has one responsibility, a
clear interface, and is independently runnable.

- **`snapshot-state.sh`** — guarded wrapper around `openclaw backup create --verify --output
  <dir>`. Preflight: gateway healthy, sufficient disk, config valid (falls back to
  `--no-include-workspace` if the config is invalid, per the backup docs). Emits the backup
  JSON result (resolved sources, `skippedVolatileCount`). Depends on: the `openclaw` CLI.

- **`snapshot-secrets.sh`** — tars the in-scope secret files and pipes through
  `age -r <public-key>` to a single `secrets.age`. Never writes plaintext to disk. Prints a
  checklist of captured file **names** (never values). Depends on: the bundled `age` binary
  and the operator's public key.

- **`snapshot-manifest.sh`** — read-only introspection that generates `manifest.json` and
  `RUNBOOK.md`: OpenClaw version, node version, service unit contents, gateway port, and the
  per-core-repo git state. Depends on: `git`, the service manager query, the org profile +
  `core-repos.txt`.

- **`snapshot.sh`** — top-level driver. Runs the three capture scripts into one dated output
  directory. Refuses to overwrite an existing dated directory.

- **`restore.sh`** — the reverse, run on the new VM from inside the snapshot directory.
  Executes the ordered flow, fail-fast, and finishes with a verification pass.

## Artifact layout

One `snapshot.sh` run produces a single dated directory:

```
openclaw-snapshot-YYYY-MM-DD/
├── state.tar.gz     # openclaw backup create --verify output
├── secrets.age      # encrypted host-level secrets
├── manifest.json    # versions, service unit, gateway port, per-core-repo git state
├── RUNBOOK.md       # ordered restore steps, generated from the manifest
└── age              # self-contained static binary, so restore can decrypt unaided
```

The operator copies this directory to the new VM (scp/rsync over SSH) and runs `restore.sh`
from inside it. The operator carries only the private key separately.

## Restore flow

`restore.sh` runs these steps in order, stopping on the first failure. Each step is guarded so
a half-failed restore can be re-run:

1. Bootstrap `age` (from the bundled binary).
2. Install OpenClaw pinned to the manifest version, plus the recorded node version.
3. Decrypt `secrets.age` (operator provides the private key) and place the secret files.
4. Restore `state.tar.gz` (OpenClaw state, config, credentials, agent workspaces, memory).
5. Re-clone the core repos into `REPOS_DIR`, checkout each recorded branch, re-apply patches.
6. Install and enable the service unit; start the gateway.
7. Verify.

## Error handling & verification

- **Capture-time verification** — `openclaw backup create --verify` validates the state
  archive immediately after writing it, so corruption is caught while re-capture is still
  possible, not at restore.
- **Secrets checklist** — capture prints the names of files included (never contents) so the
  operator can confirm nothing is missing.
- **Drift is reported, not silently lost** — the manifest flags any core repo with dirty or
  unpushed work; captured patches carry the dirty diffs forward.
- **Restore verification** — the final step compares the live cron job count and configured
  agent list against the manifest and prints a diff. A mismatch fails the restore loudly.
- **No-overwrite guarantees** — `snapshot.sh` refuses to reuse an existing dated directory;
  `openclaw backup` refuses to overwrite an existing archive and rejects self-inclusion.

## Open questions / future work

- **Scheduling** — whether `snapshot.sh` should run on a cron for periodic backups, or only
  on-demand before a migration. The keypair model supports unattended capture (the host holds
  only the public key), so a scheduled variant is feasible later.
- **Retention & destination** — where snapshot directories are stored off-host and how long
  they are kept. Out of scope for this design.
- **Restore-time OpenClaw version drift** — if the pinned version is no longer installable,
  the runbook should document the nearest-compatible upgrade path.
```