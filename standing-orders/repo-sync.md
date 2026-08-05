## Program: Repo Sync

**Authority:** Keep the local repository clones current so the scanner/fixer
programs operate on up-to-date working copies.
**Trigger:** Daily (enforced via cron job `repo-sync`).
**Approval gate:** None (read-only clone/pull; no writes to GitHub).
**Escalation:** None. A repo that fails to clone or pull is logged; the sync
continues with the rest.

### Scope
- The repositories under the active org (`ORG`). Enumerate the current set with
  `gh repo list <org> --limit 100 --json nameWithOwner --jq '.[].nameWithOwner'`.
- Clones into the local clones directory (`REPOS_DIR`) any repo not already
  present; then runs `git pull` in each existing clone to bring it current.

### What NOT to Do
- Do not push, open PRs, or otherwise write to any GitHub repo.
- Do not delete or reset local clones with uncommitted state — pull only.
- Do not clone outside the active org.

### Operational Notes
- Cron job: `repo-sync` (daily, isolated).
- The clone-dir basenames may lag behind canonical repo names during an org
  rename; the scanner/fixer programs reconcile this via the transitional
  `REMAP` in the org profile (`config/org.env`) and `canonical_repo_for_dir()`.
  The remap self-retires once clone dirs are renamed (rossoctl/automation#37).
- Org selection follows the same profile as the rest of the suite: the sync
  should target the same `ORG` the scanners use, so coverage stays consistent.
