## Program: Doc Drift

**Authority:** Read enrolled repos at a pinned git ref, file one rollup issue per
repo for doc drift, and open a fork PR only for a line-scoped mechanical edit.
**Trigger:** Not scheduled in this repo yet. Manual run:
`bash scripts/repoman-run.sh doc-drift` (add `--dry-run` to preview).
**Approval gate:** None for the rollup issue. A mechanical PR is opened on the
fork and left for a human to merge.
**Escalation:**
  - Checker fails on a repo: keep the previous findings, do not close the rollup issue
  - GitHub API rate limit: stop issue updates, report partial results

### Scope
- The enrolled repo set in `~/.repoman/repos.json`, read at a pinned ref
  (`boundary: main` resolves `HEAD` of the local clone; `boundary: tags`
  resolves the newest tag matching `stable_tag_pattern`).
- Documentation files (`.md`, `.rst`, `.txt`) plus shell and Python for the
  flag and subcommand checks.
- Per-repo behavior comes from `.repoman/doc-drift.yaml`. When that file is
  absent, `sources_of_truth` and `retired_names` are empty (those checks are
  off) and `ignore_paths` defaults to CHANGELOG.md and docs/history/**.
  The schema is in `docs/specs/2026-11-02-doc-drift-design.md`.

### What NOT to Do
- Do not edit a file outside the flagged line. Version and retired-name
  replacements are line-scoped; a repo-wide replace is not allowed.
- Do not treat a path or enumeration correction with an empty replacement as
  mechanical. Those stay on the rollup issue.
- Do not close the rollup issue when the checker fails. Carry the previous
  findings forward.
- Do not publish GitHub Releases. Release-draft findings are text for a human.

### Operational Notes
- Reports: `~/reports/doc-drift/latest.json` and `history.json`.
- Precheck: `scripts/doc-drift-precheck.sh` exits 0 when a repo has findings
  (so a model turn is warranted) and 1 when the worklist is empty.
- Manual run: `bash scripts/repoman-run.sh doc-drift`.
- Issue: rossoctl/repoman#8.
