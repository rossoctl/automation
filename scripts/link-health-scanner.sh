#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Link Health Scanner
# Scans all repos for broken links, creates/closes GitHub issues, writes reports.
#
# Usage:
#   bash link-health-scanner.sh                  # full run
#   bash link-health-scanner.sh --dry-run        # scan + report, no issues/PRs
#   bash link-health-scanner.sh --issue-limit 3  # create at most 3 issues
#   bash link-health-scanner.sh --dry-run --issue-limit 3  # combined
# =============================================================================

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"

# --- CLI args ---
DRY_RUN=false
ISSUE_LIMIT=0  # 0 = unlimited

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --issue-limit) ISSUE_LIMIT="$2"; shift 2 ;;
    --profile) PROFILE_FLAG="$2"; shift 2 ;;
    --org) ORG_FLAG="$2"; shift 2 ;;
    --fork-owner) FORK_OWNER_FLAG="$2"; shift 2 ;;
    --repos-dir) REPOS_DIR_FLAG="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Resolve org identity (--flag > env > profile > default). Sets ORG, FORK_OWNER,
# MAIN_REPO, REPOS_DIR, REMAP. Issue reads use canonical $ORG/<name>; $MAIN_REPO
# backs the related-issue refs and the escalation URL. The report PR itself
# targets $REPORT_TARGET_REPO (see the report-destination block below).
load_org_profile

# --- Configuration ---
REPORTS_DIR="${REPORTS_DIR:-$HOME/workspaces/clawgenti/reports/link-scan}"

# Report-PR destination. The org main repo's docs/ folder feeds the docs site
# (rossoctl.dev) and cannot host machine-generated reports, so the standing
# report PR lands under automation-health/ in the automation repo. A single
# file, overwritten in place each run: trend tooling reconstructs history by
# replaying git commit parents, so we store state (not dated snapshots) and
# avoid the files-vs-diffs-on-Git anti-pattern (rossoctl/automation#44).
REPORT_TARGET_REPO="$ORG/automation"
REPORT_TARGET_NAME="${REPORT_TARGET_REPO##*/}"
REPORT_TARGET_PATH="automation-health/link-health.md"

# Clone dir for the report target: honor an explicit MAIN_REPO_DIR override,
# else derive from REPOS_DIR.
REPORT_TARGET_DIR="${MAIN_REPO_DIR:-$REPOS_DIR/$REPORT_TARGET_NAME}"

# Fork remote name for the report-target push. Derived from the profile so it
# carries no org literal; a stale remote of this name is corrected below.
FORK_REMOTE="$FORK_OWNER-automation-fork"
SCAN_DATE=$(date -u +"%Y-%m-%d")
SCAN_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MAX_HISTORY_ROWS=500
ESCALATION_THRESHOLD=20

# --- Workspace setup ---
setup_workspace "link-scanner"
TMPDIR="$PROGRAM_TMPDIR"
mkdir -p "$REPORTS_DIR"

# --- Scan ID ---
SCAN_ID=$(generate_scan_id "$REPORTS_DIR" "$SCAN_DATE")

echo "=== Link Health Scan $SCAN_ID ==="
echo "Repos dir: $REPOS_DIR"
echo "Reports dir: $REPORTS_DIR"
if [ "$DRY_RUN" = true ]; then echo "Mode: DRY RUN (no issues, no PRs)"; fi
if [ "$ISSUE_LIMIT" -gt 0 ]; then echo "Issue limit: $ISSUE_LIMIT"; fi

# --- Scan all repos ---
TOTAL_LINKS=0
TOTAL_ERRORS=0
REPOS_SCANNED=0
REPOS_FAILED=0

# Collect all broken links into a single JSONL file
: > "$TMPDIR/broken.jsonl"

# Track canonical repos already scanned this run, so duplicate clone dirs
# (e.g. a stale "kagenti" alongside "rossoctl") are not scanned twice.
SEEN_CANON=""

for repo_dir in "$REPOS_DIR"/*/ "$REPOS_DIR"/.github/; do
  [ -d "$repo_dir" ] || continue
  repo_name=$(basename "$repo_dir")

  # Skip hidden dirs (except .github) and non-git dirs
  if [[ "$repo_name" == .* && "$repo_name" != ".github" ]] || [ ! -d "$repo_dir/.git" ]; then
    continue
  fi

  # Restrict to core repos (allowlist), mapping pre-rename dir names to their
  # canonical repo first. Non-core / archived clones are skipped.
  canon=$(canonical_repo_for_dir "$repo_name")
  if ! is_core_repo "$canon"; then
    continue
  fi

  # Dedup: skip if another clone dir already covered this canonical repo.
  case " $SEEN_CANON " in
    *" $canon "*) echo "Skipping $repo_name (already scanned as $canon)"; continue ;;
  esac
  SEEN_CANON="$SEEN_CANON $canon"

  echo "Scanning $repo_name (as rossoctl/$canon)..."

  LYCHEE_OUTPUT="$TMPDIR/lychee_${repo_name}.json"

  # Run lychee -- scanner-level args applied to all repos
  LYCHEE_SCANNER_ARGS=(
    --format json
    --scheme http --scheme https
    --exclude 'localhost' --exclude '127\.0\.0\.1' --exclude 'localtest\.me'
    --exclude 'example\.com' --exclude 'example\.org'
    --exclude-all-private
    --exclude-path 'node_modules' --exclude-path 'vendor' --exclude-path '\.claude'
    --accept '200,204,206,403,429,502,503'
    --exclude 'console\.cloud\.google\.com'
    --timeout 10
    --max-retries 2
    --max-concurrency 8
  )

  if [ -f "$repo_dir/.lychee.toml" ]; then
    lychee "${LYCHEE_SCANNER_ARGS[@]}" --config "$repo_dir/.lychee.toml" "$repo_dir" > "$LYCHEE_OUTPUT" 2>/dev/null || true
  else
    lychee "${LYCHEE_SCANNER_ARGS[@]}" "$repo_dir" > "$LYCHEE_OUTPUT" 2>/dev/null || true
  fi

  if [ ! -s "$LYCHEE_OUTPUT" ]; then
    echo "  WARN: lychee produced no output for $repo_name"
    REPOS_FAILED=$((REPOS_FAILED + 1))
    continue
  fi

  # Parse results
  repo_total=$(jq '.total // 0' "$LYCHEE_OUTPUT")
  repo_errors=$(jq '.errors // 0' "$LYCHEE_OUTPUT")
  TOTAL_LINKS=$((TOTAL_LINKS + repo_total))
  TOTAL_ERRORS=$((TOTAL_ERRORS + repo_errors))
  REPOS_SCANNED=$((REPOS_SCANNED + 1))

  # Extract broken links from the lychee report. The parsing/suppression/status
  # normalization logic lives in extract-broken-links.sh so it can be unit-tested
  # (see tests/test-extract-broken-links.sh).
  "$SCRIPT_DIR/extract-broken-links.sh" \
    "$LYCHEE_OUTPUT" "rossoctl/$canon" "$REPOS_DIR/$repo_name/" \
    >> "$TMPDIR/broken.jsonl" 2>/dev/null || true

  echo "  Links: $repo_total, Errors: $repo_errors"
done

echo ""
echo "=== Scan complete ==="
echo "Repos scanned: $REPOS_SCANNED (failed: $REPOS_FAILED)"
echo "Total links: $TOTAL_LINKS, Total errors: $TOTAL_ERRORS"

# --- Load previous scan for diffing ---
PREV_BROKEN="$TMPDIR/prev_broken.jsonl"
if [ -f "$REPORTS_DIR/latest.json" ]; then
  jq -c '.broken[]?' "$REPORTS_DIR/latest.json" > "$PREV_BROKEN" 2>/dev/null || true
else
  : > "$PREV_BROKEN"
fi

# --- Compute diff using shared library ---
DIFF_KEY='[.repo, .file, .url] | join("|")'
read -r NEW_LINKS FIXED_LINKS RECURRING_LINKS < <(
  diff_against_previous "$TMPDIR/broken.jsonl" "$PREV_BROKEN" "$DIFF_KEY"
)

echo "Delta: +$NEW_LINKS new, -$FIXED_LINKS fixed, $RECURRING_LINKS recurring"

# --- Count by category ---
BROKEN_INTERNAL=$(jq -s '[.[] | select(.category == "internal")] | length' "$TMPDIR/broken.jsonl" 2>/dev/null || echo 0)
BROKEN_EXTERNAL=$(jq -s '[.[] | select(.category == "external")] | length' "$TMPDIR/broken.jsonl" 2>/dev/null || echo 0)

# --- Create GitHub issues for NEW broken links ---
ISSUES_CREATED=0

# new_keys.txt was already written by diff_against_previous

while IFS='|' read -r issue_repo issue_file issue_url; do
  [ -z "$issue_repo" ] && continue

  # Check issue limit
  if [ "$ISSUE_LIMIT" -gt 0 ] && [ "$ISSUES_CREATED" -ge "$ISSUE_LIMIT" ]; then
    echo "  SKIP (issue limit $ISSUE_LIMIT reached): $issue_file:$issue_url"
    continue
  fi

  # Get the full broken link record
  link_record=$(jq -c "select(.repo == \"$issue_repo\" and .file == \"$issue_file\" and .url == \"$issue_url\")" "$TMPDIR/broken.jsonl" | head -1)
  [ -z "$link_record" ] && continue

  link_status=$(echo "$link_record" | jq -r '.status')
  link_category=$(echo "$link_record" | jq -r '.category')
  if [ "$link_category" = "internal" ]; then
    category_label="broken-link/internal"
  else
    category_label="broken-link/external"
  fi

  # Deduplication: skip if an open issue already exists for this link
  existing=$(gh_issue_exists "$issue_repo" "Broken link in $issue_file: $issue_url" || true)

  if [ -n "$existing" ]; then
    echo "  Issue #$existing already exists for $issue_file:$issue_url"
    continue
  fi

  # Create issue
  issue_title=":bug: Broken link in $issue_file: $issue_url"
  # Truncate title if too long (GitHub limit is 256)
  if [ ${#issue_title} -gt 250 ]; then
    issue_title="${issue_title:0:247}..."
  fi

  # Build verification note for ambiguous status codes
  verify_note=""
  case "$link_status" in
    *403*) verify_note="
> **Note:** This URL returned 403 (Forbidden). Some sites block automated scanners. The link may be valid when accessed from a browser. Please verify manually before fixing." ;;
    *503*) verify_note="
> **Note:** This URL returned 503 (Service Unavailable), which may indicate a temporarily unavailable service rather than a permanently broken link. Please verify manually before fixing." ;;
    *429*) verify_note="
> **Note:** This URL returned 429 (Too Many Requests). The link may be valid but rate-limited. Please verify manually before fixing." ;;
  esac

  issue_body="## Describe the bug

Broken link detected by automated link health scan.

**Repo:** $issue_repo
**File:** $issue_file
**Broken URL:** $issue_url
**HTTP Status:** $link_status
**First detected:** $SCAN_DATE
**Scan ID:** $SCAN_ID
$verify_note
## Steps To Reproduce

1. Open https://github.com/$issue_repo/blob/main/$issue_file
2. Click or follow the link to \`$issue_url\`
3. Observe $link_status error

## Expected Behavior

The link should resolve to valid documentation.

## Additional Context

Category: $link_category
Detected by: OpenClaw Link Health Scanner (cron: link-health-scanner)"

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would create issue on $issue_repo: $issue_file:$issue_url ($link_category)"
    ISSUES_CREATED=$((ISSUES_CREATED + 1))
  elif gh issue create --repo "$issue_repo" \
    --title "$issue_title" \
    --label "kind/bug,$category_label" \
    --body "$issue_body" 2>/dev/null; then
    ISSUES_CREATED=$((ISSUES_CREATED + 1))
    echo "  Created issue for $issue_file:$issue_url"
  else
    echo "  WARN: Failed to create issue for $issue_file:$issue_url"
  fi

  # Rate limit: small delay between issue creations
  sleep 1
done < "$TMPDIR/new_keys.txt"

echo "Issues created: $ISSUES_CREATED"

# --- Close issues for FIXED links ---
ISSUES_CLOSED=0

comm -13 "$TMPDIR/current_keys.txt" "$TMPDIR/prev_keys.txt" > "$TMPDIR/fixed_keys.txt"

while IFS='|' read -r fix_repo fix_file fix_url; do
  [ -z "$fix_repo" ] && continue

  # Get the category from the previous scan
  link_record=$(jq -c "select(.repo == \"$fix_repo\" and .file == \"$fix_file\" and .url == \"$fix_url\")" "$PREV_BROKEN" | head -1)
  link_category=$(echo "$link_record" | jq -r '.category // "internal"')

  if [ "$link_category" = "internal" ]; then
    category_label="broken-link/internal"
  else
    category_label="broken-link/external"
  fi

  # Find the open issue for this link (empty string if none exists)
  issue_number=$(gh_issue_exists "$fix_repo" "Broken link in $fix_file: $fix_url" || true)

  # Skip if no matching issue was found
  if [ -z "$issue_number" ]; then
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would close issue #$issue_number for $fix_file:$fix_url"
    ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
  elif close_issue_if_valid "$fix_repo" "$issue_number" \
    "Link verified as fixed in scan $SCAN_ID ($SCAN_DATE). Auto-closing."; then
    ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
    echo "  Closed issue #$issue_number for $fix_file:$fix_url"
  fi
done < "$TMPDIR/fixed_keys.txt"

echo "Issues closed: $ISSUES_CLOSED"

# --- Write latest.json ---
BROKEN_ARRAY=$(jq -s '
  [.[] | . + {
    issue_number: null,
    first_detected: "'"$SCAN_DATE"'",
    context: ""
  }]
' "$TMPDIR/broken.jsonl" 2>/dev/null || echo "[]")

LATEST_JSON=$(cat << LATEST_EOF
{
  "scan_id": "$SCAN_ID",
  "date": "$SCAN_TIME",
  "duration_seconds": $SECONDS,
  "model": "script",
  "repos_scanned": $REPOS_SCANNED,
  "repos_failed": $REPOS_FAILED,
  "total_links_checked": $TOTAL_LINKS,
  "broken": $BROKEN_ARRAY,
  "delta": {
    "new": $NEW_LINKS,
    "fixed": $FIXED_LINKS,
    "recurring": $RECURRING_LINKS
  }
}
LATEST_EOF
)

write_report_latest "$REPORTS_DIR" "$LATEST_JSON"
echo "Wrote latest.json"

# --- Append to history.json ---
HISTORY_ROW=$(cat << HIST_EOF
{
  "scan_id": "$SCAN_ID",
  "date": "$SCAN_TIME",
  "repos_scanned": $REPOS_SCANNED,
  "total_links_checked": $TOTAL_LINKS,
  "broken_internal": $BROKEN_INTERNAL,
  "broken_external": $BROKEN_EXTERNAL,
  "new": $NEW_LINKS,
  "fixed": $FIXED_LINKS,
  "issues_created": $ISSUES_CREATED,
  "issues_closed": $ISSUES_CLOSED
}
HIST_EOF
)

append_history_row "$REPORTS_DIR" "$HISTORY_ROW" "$MAX_HISTORY_ROWS"
echo "Appended to history.json"

# --- Update docs/link-health.md ---
# Build trend table from last 10 history entries (deduplicate same-day rows)
TREND_TABLE=$(jq -r '
  [group_by(.date | split("T")[0]) | .[] | last] | .[-10:] | reverse | .[] |
  "| \(.date | split("T")[0] | split("-")[1:] | join("-")) | \(.broken_internal) | \(.broken_external) | \(if .new > .fixed then "+\(.new - .fixed)" elif .new < .fixed then "\(.new - .fixed)" else "0" end) |"
' "$REPORTS_DIR/history.json" 2>/dev/null || echo "| - | - | - | - |")

# Build per-repo breakdown with issue counts
# Single org-wide query for all open scanner issues, then count client-side
issue_search=$(gh_with_backoff search issues "org:rossoctl in:title \"Broken link in\" state:open" --json repository --jq '.[].repository.nameWithOwner' 2>/dev/null || true)
declare -A ISSUE_COUNTS
if [ -n "$issue_search" ]; then
  while IFS= read -r r; do
    ISSUE_COUNTS["$r"]=$(( ${ISSUE_COUNTS["$r"]:-0} + 1 ))
  done <<< "$issue_search"
fi

# Single jq pass for per-repo internal/external counts
REPO_TABLE=""
repo_breakdown=$(jq -rs '
  group_by(.repo) | .[] |
  { repo: .[0].repo,
    internal: [.[] | select(.category == "internal")] | length,
    external: [.[] | select(.category == "external")] | length }
' "$TMPDIR/broken.jsonl" 2>/dev/null || true)
if [ -n "$repo_breakdown" ]; then
  while IFS= read -r row; do
    repo=$(echo "$row" | jq -r '.repo')
    short=$(echo "$repo" | cut -d/ -f2)
    int_count=$(echo "$row" | jq -r '.internal')
    ext_count=$(echo "$row" | jq -r '.external')
    issue_count=${ISSUE_COUNTS["$repo"]:-0}
    REPO_TABLE="${REPO_TABLE}| ${short} | ${int_count} | ${ext_count} | ${issue_count} |
"
  done < <(echo "$repo_breakdown" | jq -c '.')
else
  REPO_TABLE="| - | - | - | - |"
fi

SCAN_TIME_ET=$(TZ="America/New_York" date +"%Y-%m-%d %H:%M ET")

cat > "$TMPDIR/link-health.md" << DASHBOARD_EOF
# Link Health Report

> Last scan: $SCAN_TIME_ET | Scan ID: $SCAN_ID

## Summary

| Metric | Value |
|--------|-------|
| Repos scanned | $REPOS_SCANNED |
| Total links checked | $TOTAL_LINKS |
| Broken (internal) | $BROKEN_INTERNAL |
| Broken (external) | $BROKEN_EXTERNAL |
| New since last scan | +$NEW_LINKS |
| Fixed since last scan | -$FIXED_LINKS |

## Trend (last 10 scans)

| Date | Internal | External | Delta |
|------|----------|----------|-------|
$TREND_TABLE

## Broken Links by Repo

| Repo | Internal | External | Issues |
|------|----------|----------|--------|
$REPO_TABLE

*Issues counts open GitHub issues filed by the scanner; a broken link may not yet have an issue (due to per-run limits) or may share an issue with another link in the same file.*

---
*Generated by OpenClaw Link Health Scanner. Do not edit manually.*
DASHBOARD_EOF

# Commit and push dashboard
if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would push $REPORT_TARGET_PATH to fork and create/update cross-fork PR against $REPORT_TARGET_REPO"
  echo "[DRY RUN] Dashboard preview:"
  cat "$TMPDIR/link-health.md"
else
  if [ ! -d "$REPORT_TARGET_DIR/.git" ]; then
    echo "ERROR: $REPORT_TARGET_DIR does not appear to be a git repository."
    echo "Export MAIN_REPO_DIR or set REPOS_DIR so $REPORT_TARGET_REPO can be found:"
    echo "  export MAIN_REPO_DIR=$REPOS_DIR/$REPORT_TARGET_NAME"
    exit 1
  fi

  cd "$REPORT_TARGET_DIR"

  # Ensure the fork remote exists AND points at the current target. set-url
  # corrects a stale remote (e.g. one left by a prior deployment pointing at the
  # old report repo); the || add branch handles the not-yet-registered case.
  fork_url="https://github.com/$FORK_OWNER/${REPORT_TARGET_NAME}.git"
  git remote set-url "$FORK_REMOTE" "$fork_url" 2>/dev/null \
    || git remote add "$FORK_REMOTE" "$fork_url"

  # Fetch fork's branch if it exists, otherwise create from main
  if git fetch "$FORK_REMOTE" link-health/reports 2>/dev/null; then
    git checkout -B link-health/reports "$FORK_REMOTE/link-health/reports"
  else
    git fetch "$FORK_REMOTE" main 2>/dev/null || true
    git checkout -B link-health/reports "$FORK_REMOTE/main" 2>/dev/null \
      || git checkout -B link-health/reports
  fi

  mkdir -p "$(dirname "$REPORT_TARGET_PATH")"
  cp "$TMPDIR/link-health.md" "$REPORT_TARGET_PATH"
  git add "$REPORT_TARGET_PATH"
  git commit -s -m "docs: Update link health dashboard ($SCAN_ID)" 2>/dev/null || echo "No changes to commit"
  git push "$FORK_REMOTE" link-health/reports 2>/dev/null || echo "WARN: Failed to push dashboard to fork"

  # Create or update standing cross-fork PR
  existing_pr=$(gh api "repos/$REPORT_TARGET_REPO/pulls?head=$FORK_OWNER:link-health/reports&state=open" \
    --jq '.[0].number' 2>/dev/null || echo "")

  pr_body="## Summary

Auto-updated by Rossoctl Link Health Scanner. This PR is continuously updated with each scan. Merge when convenient.

| Metric | Value |
|--------|-------|
| Repos scanned | $REPOS_SCANNED |
| Broken (internal) | $BROKEN_INTERNAL |
| Broken (external) | $BROKEN_EXTERNAL |
| New since last scan | +$NEW_LINKS |
| Fixed since last scan | -$FIXED_LINKS |

## Related issue(s)

- $MAIN_REPO#1178

## Automation program

Generated by the [Rossoctl Link Health Scanner](https://github.com/$SOURCE_REPO/blob/main/standing-orders/link-health.md)."

  if [ -z "$existing_pr" ] || [ "$existing_pr" = "null" ]; then
    gh pr create --repo "$REPORT_TARGET_REPO" \
      --head "$FORK_OWNER:link-health/reports" --base main \
      --title "docs: Link health report (auto-updated)" \
      --body "$pr_body" 2>/dev/null || echo "WARN: Failed to create dashboard PR"
  else
    gh pr edit "$existing_pr" --repo "$REPORT_TARGET_REPO" --body "$pr_body" 2>/dev/null || true
  fi
fi

echo "Dashboard updated"

# --- Escalation check ---
if [ "$NEW_LINKS" -gt "$ESCALATION_THRESHOLD" ]; then
  echo ""
  echo "ALERT: Link health scan found $NEW_LINKS new broken links (threshold: $ESCALATION_THRESHOLD)."
  echo "This may indicate a bulk documentation change or a widespread external service outage."
  echo "Review issues at https://github.com/$MAIN_REPO/issues?q=label:broken-link"
fi

# --- Summary ---
echo ""
echo "=== Scan $SCAN_ID Summary ==="
echo "Repos: $REPOS_SCANNED scanned, $REPOS_FAILED failed"
echo "Links: $TOTAL_LINKS checked, $((BROKEN_INTERNAL + BROKEN_EXTERNAL)) broken ($BROKEN_INTERNAL internal, $BROKEN_EXTERNAL external)"
echo "Delta: +$NEW_LINKS new, -$FIXED_LINKS fixed, $RECURRING_LINKS recurring"
echo "Issues: $ISSUES_CREATED created, $ISSUES_CLOSED closed"
echo "Duration: ${SECONDS}s"
