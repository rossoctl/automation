---
name: link_health_scanner
description: Scan kagenti org repos for broken links using lychee, create GitHub issues, and write structured reports.
metadata: {"openclaw": {"requires": {"bins": ["lychee", "gh", "jq"]}}}
---

# Link Health Scanner

Scan all kagenti GitHub org repos for broken links, create GitHub issues for new findings, close issues for fixed links, and write structured reports.

## Repo Location

All kagenti repos are already cloned at `~/kagenti/` and updated nightly by the `kagenti-repo-update` cron job. Do NOT clone repos yourself. Just use them in place.

## Running Lychee

For each repo directory in `~/kagenti/`:

```bash
cd ~/kagenti/$repo_name
if [ -f .lychee.toml ]; then
  lychee --format json --config .lychee.toml . 2>/dev/null
else
  lychee --format json --exclude-path "*.mdx" \
    --exclude localhost --exclude 127.0.0.1 --exclude example.com \
    --accept 200,204,206 \
    --timeout 30 \
    --max-retries 3 \
    --max-concurrency 8 \
    . 2>/dev/null
fi
```

Save the JSON output for each repo.

## Parsing Lychee Output

Lychee JSON output structure:

```json
{
  "total": 100,
  "successful": 95,
  "errors": 3,
  "timeouts": 1,
  "duration_secs": 5,
  "error_map": {
    "/absolute/path/to/file.md": [
      {
        "url": "https://example.com/broken",
        "status": {"code": 404, "text": "Rejected status code: 404 Not Found"}
      }
    ]
  }
}
```

For each entry in `error_map`, extract:
- `repo`: derive from the file path (strip the `~/kagenti/` prefix, take the first path segment)
- `file`: relative path within the repo
- `url`: the broken URL
- `status`: the HTTP status code from `status.code`
- `category`: `internal` if the URL is a relative path or points to `github.com/kagenti/*`, otherwise `external`

## Diffing Against Previous Scan

Read `~/workspaces/clawgenti/reports/link-scan/latest.json` if it exists. Compare current broken links against the previous scan by the tuple (repo, file, url):

- **New:** in current scan but not in previous
- **Fixed:** in previous scan but not in current
- **Recurring:** in both scans

## Creating GitHub Issues

For each **new** broken link, first check for an existing open issue:

```bash
gh issue list --repo "kagenti/$repo_name" \
  --label "kind/bug" \
  --search "Broken link in $file: $url" \
  --state open --json number --jq '.[0].number'
```

If no existing issue, create one:

```bash
gh issue create --repo "kagenti/$repo_name" \
  --title ":bug: Broken link in $file: $url" \
  --label "kind/bug,$category_label" \
  --body "## Describe the bug

Broken link detected by automated link health scan.

**Repo:** kagenti/$repo_name
**File:** $file
**Broken URL:** $url
**HTTP Status:** $status_code
**First detected:** $scan_date
**Scan ID:** $scan_id

## Steps To Reproduce

1. Open https://github.com/kagenti/$repo_name/blob/main/$file
2. Click or follow the link to \`$url\`
3. Observe $status_code error

## Expected Behavior

The link should resolve to valid documentation.

## Additional Context

Category: $category
Detected by: [Rossoctl Automation Link Health Scanner](https://github.com/rossoctl/automation/blob/main/skills/link-health/SKILL.md) (cron: link-health-scanner)"

Note that [Rossoctl Automation](https://github.com/rossoctl/automation) will auto-close this issue if fixed, but will not create a PR with fixes.
```

Where `$category_label` is:
- `broken-link/internal` for relative links and links to `github.com/kagenti/*`
- `broken-link/external` for all other URLs

## Closing Fixed Issues

For each **fixed** link (in previous scan but not current):

```bash
issue_number=$(gh issue list --repo "kagenti/$repo_name" \
  --label "$category_label" \
  --search "Broken link in $file: $url" \
  --state open --json number --jq '.[0].number')

if [ -n "$issue_number" ]; then
  gh issue close "$issue_number" --repo "kagenti/$repo_name" \
    --comment "Link verified as fixed in scan $scan_id ($scan_date). Auto-closing."
fi
```

## Writing Reports

### latest.json

Overwrite `~/workspaces/clawgenti/reports/link-scan/latest.json`:

```json
{
  "scan_id": "YYYY-MM-DD-NNN",
  "date": "ISO8601 timestamp",
  "duration_seconds": N,
  "model": "model used for this run",
  "repos_scanned": N,
  "repos_failed": 0,
  "total_links_checked": N,
  "broken": [
    {
      "repo": "kagenti/REPO",
      "file": "relative/path.md",
      "url": "the broken URL",
      "category": "internal|external",
      "status": 404,
      "context": "surrounding text",
      "issue_number": N,
      "first_detected": "YYYY-MM-DD"
    }
  ],
  "delta": {
    "new": N,
    "fixed": N,
    "recurring": N
  }
}
```

The `scan_id` format is `YYYY-MM-DD-NNN` where NNN is a zero-padded sequence number for that day. Check history.json for the last scan_id on the same date.

### history.json

Append one row to `~/workspaces/clawgenti/reports/link-scan/history.json`:

```json
{
  "scan_id": "YYYY-MM-DD-NNN",
  "date": "ISO8601 timestamp",
  "repos_scanned": N,
  "total_links_checked": N,
  "broken_internal": N,
  "broken_external": N,
  "new": N,
  "fixed": N,
  "issues_created": N,
  "issues_closed": N
}
```

If history.json exceeds 500 rows, remove the oldest to bring it back to 500.

## Updating docs/link-health.md

Update `~/kagenti/kagenti/docs/link-health.md` with dashboard content, then commit and push to a `link-health/reports` branch:

```bash
cd ~/kagenti/kagenti
git checkout -B link-health/reports origin/main
# write docs/link-health.md
git add docs/link-health.md
git commit -m "docs: Update link health dashboard ($scan_id)"
git push origin link-health/reports --force-with-lease
```

Then create or update the standing PR:

```bash
existing_pr=$(gh pr list --repo kagenti/kagenti \
  --head link-health/reports --state open --json number --jq '.[0].number')

if [ -z "$existing_pr" ]; then
  gh pr create --repo kagenti/kagenti \
    --head link-health/reports --base main \
    --title "docs: Link health dashboard (auto-updated)" \
    --body "Auto-updated by OpenClaw Link Health Scanner. This PR is continuously updated with each scan."
fi
```

Dashboard format:

```markdown
# Link Health Report

> Last scan: YYYY-MM-DD HH:MM ET | Scan ID: YYYY-MM-DD-NNN

## Summary

| Metric | Value |
|--------|-------|
| Repos scanned | N |
| Total links checked | N |
| Broken (internal) | N |
| Broken (external) | N |
| New since last scan | +N |
| Fixed since last scan | -N |

## Trend (last 10 scans)

| Date | Internal | External | Delta |
|------|----------|----------|-------|
| MM-DD | N | N | +/-N |

## Broken Links by Repo

| Repo | Internal | External | Issues |
|------|----------|----------|--------|
| repo-name | N | N | #NN, #NN |

---
*Generated by OpenClaw Link Health Scanner. Do not edit manually.*
```

## Escalation

If the scan finds more than 20 **new** broken links in a single run, report the anomaly instead of a normal summary:

"ALERT: Link health scan found {N} new broken links (threshold: 20). This may indicate a bulk documentation change or a widespread external service outage. Top affected repos: {list}. Review issues at https://github.com/kagenti/kagenti/issues?q=label:broken-link"
