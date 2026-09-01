# OpenClaw Snapshot Toolkit

Capture an OpenClaw automation host into a small, portable snapshot and restore it
on a fresh VM so cron jobs and automation "simply work." See the design spec at
`docs/specs/2026-08-10-openclaw-snapshot-redeploy-design.md`.

The snapshot is **not** a disk image. It is three artifacts plus a generated runbook,
produced into one dated directory:

```
openclaw-snapshot-YYYY-MM-DD/
├── <ISO8601>-openclaw-backup.tar.gz  # openclaw backup create --verify output
├── state-backup.json                 # the backup's machine-readable result
├── secrets.age                       # age-encrypted host-level secrets (never plaintext on disk)
├── manifest.json                     # versions, service unit, gateway port, per-core-repo git state
├── RUNBOOK.md                        # ordered restore steps, generated from the manifest
└── age                               # static binary copied in, so restore can decrypt unaided
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
age-keygen -o ~/.openclaw-snapshot.key
# Prints the PUBLIC key (age1...) to stdout; record it. The file holds the PRIVATE key.

# Capture time (host holds only the public key — encrypt-only capability):
age -r age1<PUBLIC> < plaintext > secrets.age     # snapshot-secrets.sh does this via a tar pipe

# Restore time (operator supplies the private key):
age -d -i ~/.openclaw-snapshot.key < secrets.age > plaintext
```

The private key is saved as a **dotfile** (`~/.openclaw-snapshot.key`), which keeps it out
of casual directory listings and reduces the chance another agent on the machine reads it.
It is never copied to a VM, committed to this repo, or passed through any tooling.

`age` is not assumed present on any host, and the static binary is **not committed** to this
repo (to keep the tree binary-free). Fetch it once and drop it at `snapshot/bin/age`; the
capture driver copies that binary into each snapshot directory so restore can decrypt unaided.

---

## Operator guide

### 1. Generate the keypair (one-time, off-host)

```sh
age-keygen -o ~/.openclaw-snapshot.key      # PRIVATE key — never leaves this machine
# stdout prints:  Public key: age1<PUBLIC>  — record this; it is all the host needs.
```

If `age-keygen` is missing locally, install `age` (`brew install age`, `apt-get install age`,
or the release below) — it provides both `age` and `age-keygen`.

### 2. Provision the `age` binary at `snapshot/bin/age`

The host (`x86_64` Linux) has no `age`. Fetch the static release binary, verify its
checksum, and place it — no `sudo` needed:

```sh
# Pick the asset matching the host arch (linux-amd64 for the current host).
ver=v1.3.2
curl -fsSLO "https://github.com/FiloSottile/age/releases/download/${ver}/age-${ver}-linux-amd64.tar.gz"
# Record the SHA-256 of what you downloaded, and pin it in your ops notes so a
# future re-fetch can be checked against it:
sha256sum "age-${ver}-linux-amd64.tar.gz"
# Verified 2026-08-31 for v1.3.2 linux-amd64:
#   cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10
tar -xzf "age-${ver}-linux-amd64.tar.gz"
install -m 0755 age/age snapshot/bin/age
snapshot/bin/age --version                  # sanity check
```

> The `age` releases publish a per-asset `.proof` (Sigsum transparency proof) rather than a
> combined checksums file; upstream verification instructions are in the release notes. Pin
> the exact release tag and the SHA-256 you recorded above in your ops notes, and re-pin when
> upgrading `age`. The binary is intentionally not tracked in git.

### 3. Capture on the host

```sh
AGE_BIN=snapshot/bin/age \
  bash snapshot/snapshot.sh --output ~/snapshots --pubkey age1<PUBLIC>
```

This creates `~/snapshots/openclaw-snapshot-<DATE>/` (refusing to overwrite an existing one),
runs the manifest, state, and secrets captures into it, and copies the `age` binary alongside.
The `openclaw` binary lives at `~/.npm-global/bin/openclaw`; set `OPENCLAW_BIN` if it is not on
`PATH` for the invoking shell.

### 4. Confirm no plaintext leaked into `secrets.age`

`strings` may be absent on a minimal host. Check the encrypted blob directly for a known
secret substring using `grep -a` (treat the binary as text). A real `age` blob is encrypted,
so nothing should match:

```sh
snap=$(ls -d ~/snapshots/openclaw-snapshot-*/ | tail -1)
# The blob must start with the age header and contain none of your secrets:
head -c 64 "$snap/secrets.age"; echo
grep -a -c -i -e 'authToken' -e 'BEGIN .*PRIVATE KEY' "$snap/secrets.age"   # expect: 0
```

### 5. Verify the state archive

```sh
~/.npm-global/bin/openclaw backup verify "$snap"/*openclaw-backup.tar.gz
```

### 6. Dry-run the restore (no mutations)

```sh
bash snapshot/restore.sh --from "$snap" --dry-run
```

Eyeball the plan: the captured OpenClaw version, each core repo cloned from its **recorded
origin** (origins span multiple owners — e.g. `kagenti/*` and `rossoctl/*` — so the recorded
origin, not a single org, is authoritative) at its recorded branch, the service unit, and an
`openclaw backup verify` step. The dry-run creates nothing.
