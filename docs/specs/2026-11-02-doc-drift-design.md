# Doc drift — design

**Status:** implemented (2026-11-02)
**Issue:** [rossoctl/repoman#8](https://github.com/rossoctl/repoman/issues/8)

## Summary

`doc-drift` checks a repo at a pinned git ref and reports places where the
docs disagree with the tree. The checker is offline: `scripts/doc-drift-check.py`
reads only `git show` / `git ls-tree`, and the shell passes release and PR JSON
in. A finding is a correction or an addition. `mechanical: true` means the
fixer has a line-scoped edit; everything else stays on one rollup issue per repo.

Programs:

| Piece | Path |
|---|---|
| Checker | `scripts/doc-drift-check.py` |
| Scanner | `scripts/doc-drift-scanner.sh` |
| Fixer | `scripts/doc-drift-fixer.sh` |
| Precheck | `scripts/doc-drift-precheck.sh` |
| Run path | `doc-drift` row in `scripts/repoman-run.sh` |
| Standing order | `standing-orders/doc-drift.md` |

`repoman-run.sh --help` lists `doc-drift` because the program table is the
source of that list.

## What is checked

| Check | Claim |
|---|---|
| `paths` | A repo-relative path written in a doc is in the tree at that ref |
| `flags` | A flag or dispatcher subcommand written next to a script is accepted by that script |
| `enumerations` | Tokens captured from a `sources_of_truth` regex appear in the named docs |
| `retired_names` | A configured retired string is gone |
| `versions` | A line that states the project version matches the declared version. Changelog history and dependency pins are not version drift |
| `absence` | A "not implemented" or "lives in the automation repo" claim is false because the file is in the tree |
| `release_date` / `release_draft` | A changelog date matches GitHub `publishedAt`, and merged PRs after the newest release are drafted under `Unreleased` |

## Precision

These rules are what keep a scan of this repo from turning into a list of
false corrections.

**Flags bind to the nearest script before them on the same line.** A line
that names two scripts and then a flag is a claim about the second script
only. A flag that appears before any script, as in a shellcheck --severity
invocation that later names a test file, is not a claim about that test.
`--help`, `--version`, and the generic word `--flag` are not claims. Two
identical lines are two findings.

**Subcommands are the dispatcher.** The header list (`Subcommands:` /
`Commands:`) is compared to the arms of `case "$1"` / `$cmd` / `$command` /
`$subcommand` only. Arms of `case "$mode"` are not subcommands. A header line
contributes command tokens until prose starts, so
`init-config, add-repo, set-output. Each writes` is three commands, and
`Each writes a report` is none.

**A script citation names one file.** A path with a directory binds that
path. A bare basename binds only when it is unique. A script that sources
`program-lib.sh` also accepts the long options of that file and of the modules
it aggregates.

**Paths are locations in this repo.** A backtick or link is a path when it has
a repo-file extension (`.sh`, `.py`, `.md`, `.rst`, `.txt`, `.yml`, `.yaml`,
`.json`, `.toml`, `.env`) or a trailing slash. `gemini-2.5-flash`,
`discord.accounts`, and `rossoctl/agent-skills` are not paths. A bare
`link-health-fixer.sh` exists when any tree path has that basename. A slash
path is a miss only when its first directory is in the tree and the rest is
not. Before that miss is reported, the same citation is also tried relative
to the document, so a bundled skill doc that says `scripts/org.sh` matches
`skills/repoman/scripts/org.sh`. Host paths, bare runtime names, and a
relative link that resolves to a real file are not misses. Extensions outside
the list above (`.csv`, `.ini`, `.cfg`, `.conf`, `.js`, `.ts`, `.jsonl`) are
not checked. Path findings are `mechanical: false` because there is no
replacement text. `ignore_paths` drops path and flag findings in those
documents, not only version and retired-name findings.

## Config schema (`.repoman/doc-drift.yaml`)

The file is optional. When it is absent the checker uses these defaults, which
turn enumeration and retired-name checks off:

```yaml
boundary: main
stable_tag_pattern: '^v\d+\.\d+\.\d+$'
ignore_paths:
  - CHANGELOG.md
  - docs/history/**
sources_of_truth: []
retired_names: []
release:
  changelog: CHANGELOG.md
```

| Key | Meaning |
|---|---|
| `boundary` | `main` (resolve `HEAD`) or `tags` (newest tag matching `stable_tag_pattern`) |
| `stable_tag_pattern` | Regex for release tags. An invalid pattern is a `config` finding, not a crash |
| `ignore_paths` | Glob-ish prefixes (a directory plus `/**`, or a trailing `*`) skipped by the version, retired-name, path, and flag checks |
| `sources_of_truth` | List of `{name, code: {file, pattern}, docs: [paths]}`. `pattern` is a regex; group 1 is the captured token list. Longer than 256 characters or an invalid regex is a `config` finding |
| `retired_names` | List of `{name, replace_with}`. `replace_with` may be empty |
| `release.changelog` | Keep-a-Changelog path, default `CHANGELOG.md` |

Example that checks the program allowlist against a doc:

```yaml
boundary: main
sources_of_truth:
  - name: programs
    code:
      file: scripts/repoman-setup.sh
      pattern: 'KNOWN_PROGRAMS="([^"]+)"'
    docs:
      - README.md
retired_names:
  - name: kagenti
    replace_with: ""
release:
  changelog: CHANGELOG.md
```

An enumeration **correction** (a doc token that is not in the code capture)
is `mechanical: false`. An enumeration **addition** (a code token missing from
the doc) carries `draft` and the fixer appends it to
`.repoman/doc-drift-additions.md` on the rolling branch.

## Fixer

`versions` and `retired_names` replace only the flagged line, with word
boundaries, so `1.2.3` does not match inside `11.2.34`. A failed scan does not
close the rollup issue: the scanner keeps the previous findings. The rolling
additions branch pushes with `--force-with-lease`.
