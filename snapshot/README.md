# OpenClaw Snapshot Toolkit

Capture an OpenClaw automation host into a small, portable snapshot and restore it
on a fresh VM so cron jobs and automation "simply work." See the design spec at
`docs/specs/2026-08-10-openclaw-snapshot-redeploy-design.md`.

The snapshot is **not** a disk image. It is three artifacts plus a generated runbook,
produced into one dated directory:

```
openclaw-snapshot-YYYY-MM-DD/
├── state.tar.gz     # openclaw backup create --verify output
├── secrets.age      # age-encrypted host-level secrets (never plaintext on disk)
├── manifest.json    # versions, service unit, gateway port, per-core-repo git state
├── RUNBOOK.md       # ordered restore steps, generated from the manifest
└── age              # self-contained static binary, so restore can decrypt unaided
```

## Contracts

These are the external contracts the toolkit depends on, pinned from the real host
(`OpenClaw 2026.5.12`) so downstream scripts reference facts rather than guesses.
Re-pin them if the OpenClaw version changes.

### `openclaw backup` subcommands

`openclaw backup` exposes exactly two subcommands:

- **`create`** — writes a backup archive (config, credentials, sessions, workspaces).
- **`verify <archive>`** — validates an archive and its embedded manifest.

There is **no `restore` subcommand.** Restore is performed by extracting the archive
tarball into place and then validating it with `openclaw backup verify`. `restore.sh`
must not invoke a nonexistent `openclaw backup restore`.

### `openclaw backup create` flags

| Flag | Meaning |
|------|---------|
| `--output <path>` | Archive path or destination directory |
| `--verify` | Verify the archive immediately after writing it |
| `--json` | Emit machine-readable JSON |
| `--dry-run` | Print the plan without writing the archive |
| `--only-config` | Back up only the active JSON config file |
| `--no-include-workspace` | Exclude agent workspace directories |

### `openclaw backup create --json` result shape

Pinned from `openclaw backup create --dry-run --json`. A non-dry-run create emits the
same top-level shape with `dryRun: false` and `verified` reflecting `--verify`. A
sanitized sample (generic paths, no host identity) lives at
`tests/fixtures/snapshot/backup-create.dryrun.json`.

Top-level fields:

| Field | Type | Notes |
|-------|------|-------|
| `createdAt` | string | ISO-8601 timestamp |
| `archiveRoot` | string | Directory name inside the tarball |
| `archivePath` | string | **Absolute path to the written `.tar.gz`** (the archive-path field) |
| `dryRun` | boolean | `true` only under `--dry-run` |
| `includeWorkspace` | boolean | `false` under `--no-include-workspace` |
| `onlyConfig` | boolean | `true` under `--only-config` |
| `verified` | boolean | `true` when `--verify` succeeded |
| `assets` | array | Included sources (see below) |
| `skipped` | array | Sources deliberately not archived |
| `skippedVolatileCount` | number | Count of volatile paths auto-excluded (logs, queues, session `.jsonl`, cron runs) |

`assets[]` element: `{ kind: "state" | "workspace", sourcePath, displayPath, archivePath }`.

`skipped[]` element: `{ kind, sourcePath, displayPath, reason, coveredBy }` — e.g. the
in-state `~/.openclaw/workspace` is skipped with `reason: "covered"`, `coveredBy: "~/.openclaw"`.

### `age` encryption (keypair model)

Secrets are encrypted with [`age`](https://age-encryption.org) using an asymmetric
keypair. The private key never touches any VM.

```sh
# One-time, on the operator's machine only. Private key stays here (or a password manager).
age-keygen -o ~/openclaw-snapshot.key
# Prints the PUBLIC key (age1...) to stdout; record it. The file holds the PRIVATE key.

# Capture time (host holds only the public key — encrypt-only capability):
age -r age1<PUBLIC> < plaintext > secrets.age     # snapshot-secrets.sh does this via a tar pipe

# Restore time (operator supplies the private key):
age -d -i ~/openclaw-snapshot.key < secrets.age > plaintext
```

`age` is not assumed present on any host, so the toolkit ships a self-contained static
`age` binary in `snapshot/bin/age` and rides a copy along in each snapshot directory.
