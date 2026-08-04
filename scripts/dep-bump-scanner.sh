#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Dependency Bump Scanner
# Monitors Dependabot PRs, classifies by severity, flags SLA breaches,
# creates/closes GitHub issues, writes reports.
#
# Usage:
#   bash dep-bump-scanner.sh --help
#   bash dep-bump-scanner.sh --dry-run
#   bash dep-bump-scanner.sh --dry-run --org rossoctl
#   bash dep-bump-scanner.sh --issue-limit 3
# =============================================================================

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"

# --- CLI args ---
DRY_RUN=false
ISSUE_LIMIT=0  # 0 = unlimited
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --issue-limit) ISSUE_LIMIT="$2"; shift 2 ;;
    --profile) PROFILE_FLAG="$2"; shift 2 ;;
    --org) ORG_FLAG="$2"; shift 2 ;;
    --help|-h) SHOW_HELP=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  cat << 'USAGE'
dep-bump-scanner -- Monitor Dependabot PRs for SLA breaches

USAGE:
  dep-bump-scanner.sh [OPTIONS]

OPTIONS:
  --dry-run         Scan and report only; do not create/close issues
  --issue-limit N   Create at most N issues per run (0 = unlimited)
  --profile NAME    Org profile to load (config/org.<name>.env; default org.env)
  --org NAME        GitHub org to scan (default: from profile, config/org.env)
  --help, -h        Show this help

ENVIRONMENT:
  REPOS_DIR         (required) Directory containing cloned org repos
  REPORTS_DIR       (optional) Where to write reports (default: ./reports/dep-bump)

PREREQUISITES:
  bash 4+, gh (authenticated), jq

SEVERITY SLAs:
  Critical (CVSS 9.0+)   3 days
  High (CVSS 7.0-8.9)    7 days
  Medium (CVSS 4.0-6.9)  30 days
  Major version bump      30 days
  Routine (no CVE)        14 days
USAGE
  exit 0
fi

# Resolve org identity (--org > env > profile > default). Sets ORG, FORK_OWNER,
# MAIN_REPO, REPOS_DIR, REMAP. Repo reads use canonical $ORG/<name>.
load_org_profile

# --- Configuration ---
validate_repos_dir "${REPOS_DIR:-}"

REPORTS_DIR="${REPORTS_DIR:-./reports/dep-bump}"
SCAN_DATE=$(date -u +"%Y-%m-%d")
SCAN_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MAX_HISTORY_ROWS=500
ESCALATION_THRESHOLD=5

# SLA thresholds (days)
SLA_CRITICAL=3
SLA_HIGH=7
SLA_MEDIUM=30
SLA_ROUTINE=14
SLA_MAJOR=30

# --- Workspace setup ---
setup_workspace "dep-bump"
TMPDIR="$PROGRAM_TMPDIR"
mkdir -p "$REPORTS_DIR"

# --- Scan ID ---
SCAN_ID=$(generate_scan_id "$REPORTS_DIR" "$SCAN_DATE")

echo "=== Dep Bump Scan $SCAN_ID ==="
echo "Org: $ORG"
echo "Repos dir: $REPOS_DIR"
echo "Reports dir: $REPORTS_DIR"
if [ "$DRY_RUN" = true ]; then echo "Mode: DRY RUN (no issues)"; fi
if [ "$ISSUE_LIMIT" -gt 0 ]; then echo "Issue limit: $ISSUE_LIMIT"; fi

# --- Step 1: Ecosystem detection ---
echo ""
echo "--- Detecting ecosystems ---"

: > "$TMPDIR/ecosystems.jsonl"
REPOS_SCANNED=0

SEEN_CANON=""
for repo_dir in "$REPOS_DIR"/*/ "$REPOS_DIR"/.github/; do
  [ -d "$repo_dir" ] || continue
  repo_name=$(basename "$repo_dir")

  # Skip hidden dirs (except .github) and non-git dirs
  if [[ "$repo_name" == .* && "$repo_name" != ".github" ]] || [ ! -d "$repo_dir/.git" ]; then
    continue
  fi

  # Restrict to core repos (allowlist) via the canonical name; dedup duplicate
  # clone dirs so each canonical repo is processed once.
  canon=$(canonical_repo_for_dir "$repo_name")
  if ! is_core_repo "$canon"; then
    continue
  fi
  case " $SEEN_CANON " in
    *" $canon "*) continue ;;
  esac
  SEEN_CANON="$SEEN_CANON $canon"

  REPOS_SCANNED=$((REPOS_SCANNED + 1))
  ecosystems=""

  # Detect Python
  if [ -f "$repo_dir/pyproject.toml" ] || [ -f "$repo_dir/setup.py" ] || [ -f "$repo_dir/requirements.txt" ]; then
    ecosystems="${ecosystems}pip,"
  fi

  # Detect Node
  if [ -f "$repo_dir/package.json" ]; then
    ecosystems="${ecosystems}npm,"
  fi

  # Detect Go
  if [ -f "$repo_dir/go.mod" ]; then
    ecosystems="${ecosystems}gomod,"
  fi

  # Detect Rust
  if [ -f "$repo_dir/Cargo.toml" ]; then
    ecosystems="${ecosystems}cargo,"
  fi

  # Detect Docker (check recursively for Dockerfiles)
  if find "$repo_dir" -maxdepth 3 -name "Dockerfile" -print -quit 2>/dev/null | grep -q .; then
    ecosystems="${ecosystems}docker,"
  fi

  # Detect GitHub Actions
  if find "$repo_dir/.github/workflows" -maxdepth 1 -name "*.yml" -print -quit 2>/dev/null | grep -q .; then
    ecosystems="${ecosystems}github-actions,"
  fi

  # Strip trailing comma
  ecosystems="${ecosystems%,}"

  # Store the canonical repo name so Step 2 builds correct $ORG/<name> refs.
  jq -nc --arg repo "$canon" --arg eco "$ecosystems" \
    '{repo: $repo, ecosystems: ($eco | split(",") | map(select(. != "")))}' \
    >> "$TMPDIR/ecosystems.jsonl"
done

echo "Detected ecosystems for $REPOS_SCANNED repos"

# --- Step 2: List Dependabot PRs and classify ---
echo ""
echo "--- Listing Dependabot PRs ---"

: > "$TMPDIR/all_prs.jsonl"
REPOS_WITH_DEPENDABOT=0
TOTAL_OPEN_PRS=0

while IFS= read -r eco_record; do
  repo_name=$(echo "$eco_record" | jq -r '.repo')   # canonical name from Step 1
  full_repo="$ORG/$repo_name"

  echo "  Checking $repo_name..."

  # List open Dependabot PRs. Query the canonical repo directly -- gh pr list
  # with --author silently returns empty across a rename redirect, which is why
  # the pre-rename names reported zero Dependabot PRs.
  prs_json=$(gh pr list --repo "$full_repo" \
    --author "app/dependabot" \
    --state open \
    --json number,title,createdAt,labels,body,statusCheckRollup \
    --limit 100 2>/dev/null || echo "[]")

  pr_count=$(echo "$prs_json" | jq 'length')
  if [ "$pr_count" -eq 0 ]; then
    continue
  fi

  REPOS_WITH_DEPENDABOT=$((REPOS_WITH_DEPENDABOT + 1))
  TOTAL_OPEN_PRS=$((TOTAL_OPEN_PRS + pr_count))

  # Try to get dependabot alerts for severity lookup (graceful failure)
  alerts_json="[]"
  if alerts_raw=$(gh api "/repos/$full_repo/dependabot/alerts" 2>/dev/null); then
    alerts_json=$(echo "$alerts_raw" | jq -c \
      '[.[] | select(.state == "open") | {package: .dependency.package.name, severity: .security_advisory.severity}]' \
      2>/dev/null || echo "[]")
  fi

  # Process each PR: classify severity, compute age, determine staleness
  echo "$prs_json" | jq -c --arg repo "$repo_name" --arg org "$ORG" \
    --arg scan_date "$SCAN_DATE" \
    --argjson sla_critical "$SLA_CRITICAL" \
    --argjson sla_high "$SLA_HIGH" \
    --argjson sla_medium "$SLA_MEDIUM" \
    --argjson sla_routine "$SLA_ROUTINE" \
    --argjson sla_major "$SLA_MAJOR" \
    --argjson alerts "$alerts_json" '
    .[] |

    # Parse title for package and versions
    # Handles: "Bump X from A to B", "chore(deps): bump X from A to B in /dir", grouped updates
    (.title | capture("[Bb]ump (?<pkg>[^ ]+) from (?<from>[^ ]+) to (?<to>[^ ]+)") // null) as $single |
    (.title | capture("[Bb]ump the (?<grp>[^ ]+) group") // null) as $group |
    (if $single != null then $single.pkg
     elif $group != null then ($group.grp + " group")
     else (.title | sub("^[^:]+:\\s*"; ""))
     end) as $package |
    (if $single != null then $single.from else "" end) as $from_ver |
    (if $single != null then $single.to else "" end) as $to_ver |

    # Detect major version bump
    (if ($from_ver != "" and $to_ver != "") then
      (($from_ver | split(".") | .[0] | tonumber) // -1) as $major_from |
      (($to_ver | split(".") | .[0] | tonumber) // -1) as $major_to |
      ($major_to > $major_from and $major_from >= 0)
    else false end) as $is_major |

    # Security signals
    ((.labels // []) | map(.name) | any(. == "security" or . == "Security")) as $has_security_label |
    ((.body // "") | test("CVE-|GHSA-")) as $has_cve |

    # Check dependabot alerts for this package
    ($alerts | map(select(.package == $package)) | .[0].severity // null) as $alert_severity |

    # Classify severity (priority order)
    (if $alert_severity == "critical" then "critical"
     elif $alert_severity == "high" then "high"
     elif ($has_security_label or $has_cve) then "high"
     elif $alert_severity == "medium" then "medium"
     elif $is_major then "major"
     else "routine"
     end) as $severity |

    # SLA lookup
    (if $severity == "critical" then $sla_critical
     elif $severity == "high" then $sla_high
     elif $severity == "medium" then $sla_medium
     elif $severity == "major" then $sla_major
     else $sla_routine end) as $sla |

    # Compute age in days
    ((.createdAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $created_epoch |
     ($scan_date + "T00:00:00Z" | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $today_epoch |
     (($today_epoch - $created_epoch) / 86400 | floor)
    ) as $age |

    # CI status
    ((.statusCheckRollup // []) |
     if length == 0 then "pending"
     elif all(.conclusion == "SUCCESS") then "passing"
     else "failing"
     end) as $ci_status |

    # Category for issue body
    (if ($has_security_label or $has_cve or $alert_severity != null) then "security"
     elif $is_major then "major"
     else "routine"
     end) as $category |

    # Ecosystem detection from title/files heuristic
    (if (.title | test("(?i)docker|container|image")) then "docker"
     elif (.title | test("(?i)actions/|github-actions")) then "github-actions"
     elif (.title | test("(?i)\\.js|npm|node|typescript")) then "npm"
     elif (.title | test("(?i)go\\.|golang")) then "gomod"
     elif (.title | test("(?i)cargo|crate")) then "cargo"
     else "pip"
     end) as $ecosystem |

    {
      repo: $repo,
      pr_number: .number,
      title: .title,
      package: $package,
      from_version: $from_ver,
      to_version: $to_ver,
      ecosystem: $ecosystem,
      severity: $severity,
      sla_days: $sla,
      age_days: $age,
      is_stale: ($age > $sla),
      has_cve: $has_cve,
      ci_status: $ci_status,
      category: $category,
      created_at: .createdAt
    }
  ' >> "$TMPDIR/all_prs.jsonl" 2>/dev/null || true

  sleep 0.5
done < "$TMPDIR/ecosystems.jsonl"

echo "Repos with Dependabot PRs: $REPOS_WITH_DEPENDABOT"
echo "Total open PRs: $TOTAL_OPEN_PRS"

# --- Step 3: Coverage audit ---
echo ""
echo "--- Dependabot coverage audit ---"

: > "$TMPDIR/coverage_gaps.jsonl"

while IFS= read -r eco_record; do
  repo_name=$(echo "$eco_record" | jq -r '.repo')
  detected=$(echo "$eco_record" | jq -r '.ecosystems | join(",")')

  dependabot_yml="$REPOS_DIR/$repo_name/.github/dependabot.yml"
  dependabot_yaml="$REPOS_DIR/$repo_name/.github/dependabot.yaml"

  config_file=""
  if [ -f "$dependabot_yml" ]; then
    config_file="$dependabot_yml"
  elif [ -f "$dependabot_yaml" ]; then
    config_file="$dependabot_yaml"
  fi

  if [ -z "$config_file" ]; then
    # No dependabot config at all
    if [ -n "$detected" ]; then
      echo "$eco_record" | jq -c '. + {has_config: false, configured: [], gaps: .ecosystems}' \
        >> "$TMPDIR/coverage_gaps.jsonl"
    fi
    continue
  fi

  # Extract configured ecosystems from dependabot.yml
  # Map dependabot ecosystem names to our canonical names
  configured=""
  while IFS= read -r line; do
    eco_raw=$(echo "$line" | sed -nE 's/.*package-ecosystem:[[:space:]]*"?([^"]*)"?.*/\1/p' | sed 's/[[:space:]]//g')
    case "$eco_raw" in
      pip) configured="${configured}pip," ;;
      npm) configured="${configured}npm," ;;
      gomod) configured="${configured}gomod," ;;
      cargo) configured="${configured}cargo," ;;
      docker) configured="${configured}docker," ;;
      github-actions) configured="${configured}github-actions," ;;
    esac
  done < <(grep -E 'package-ecosystem:' "$config_file" 2>/dev/null || true)
  configured="${configured%,}"

  # Find gaps: ecosystems detected but not configured
  if [ -n "$detected" ]; then
    gaps=""
    IFS=',' read -ra detected_arr <<< "$detected"
    for eco in "${detected_arr[@]}"; do
      if ! echo ",$configured," | grep -qF ",$eco,"; then
        gaps="${gaps}${eco},"
      fi
    done
    gaps="${gaps%,}"

    if [ -n "$gaps" ]; then
      jq -nc --arg repo "$repo_name" --arg detected "$detected" \
        --arg configured "$configured" --arg gaps "$gaps" \
        '{repo: $repo, has_config: true,
          detected: ($detected | split(",")),
          configured: ($configured | split(",") | map(select(. != ""))),
          gaps: ($gaps | split(",") | map(select(. != "")))}' \
        >> "$TMPDIR/coverage_gaps.jsonl"
    fi
  fi
done < "$TMPDIR/ecosystems.jsonl"

COVERAGE_GAPS=$(wc -l < "$TMPDIR/coverage_gaps.jsonl" | tr -d ' ')
echo "Repos with coverage gaps: $COVERAGE_GAPS"

# --- Step 4: Filter stale PRs ---
jq -c 'select(.is_stale == true)' "$TMPDIR/all_prs.jsonl" > "$TMPDIR/stale_prs.jsonl" 2>/dev/null || true

STALE_COUNT=$(wc -l < "$TMPDIR/stale_prs.jsonl" | tr -d ' ')
echo ""
echo "--- Stale PRs: $STALE_COUNT ---"

# --- Step 5: Diff against previous scan ---
PREV_STALE="$TMPDIR/prev_stale.jsonl"
if [ -f "$REPORTS_DIR/latest.json" ]; then
  jq -c '.stale_prs[]?' "$REPORTS_DIR/latest.json" > "$PREV_STALE" 2>/dev/null || true
else
  : > "$PREV_STALE"
fi

DIFF_KEY='[.repo, (.pr_number | tostring)] | join("|")'
read -r NEW_STALE FIXED_STALE RECURRING_STALE < <(
  diff_against_previous "$TMPDIR/stale_prs.jsonl" "$PREV_STALE" "$DIFF_KEY"
)

echo "Delta: +$NEW_STALE new, -$FIXED_STALE fixed, $RECURRING_STALE recurring"

# --- Step 6: Create issues for NEW stale PRs ---
ISSUES_CREATED=0

while IFS='|' read -r issue_repo issue_pr_number; do
  [ -z "$issue_repo" ] && continue

  # Check issue limit
  if [ "$ISSUE_LIMIT" -gt 0 ] && [ "$ISSUES_CREATED" -ge "$ISSUE_LIMIT" ]; then
    echo "  SKIP (issue limit $ISSUE_LIMIT reached)"
    break
  fi

  # Get full record
  record=$(jq -c "select(.repo == \"$issue_repo\" and .pr_number == ($issue_pr_number | tonumber))" \
    "$TMPDIR/stale_prs.jsonl" | head -1)
  [ -z "$record" ] && continue

  # Extract fields
  package=$(echo "$record" | jq -r '.package')
  severity=$(echo "$record" | jq -r '.severity')
  sla_days=$(echo "$record" | jq -r '.sla_days')
  age_days=$(echo "$record" | jq -r '.age_days')
  from_version=$(echo "$record" | jq -r '.from_version')
  to_version=$(echo "$record" | jq -r '.to_version')
  ecosystem=$(echo "$record" | jq -r '.ecosystem')
  ci_status=$(echo "$record" | jq -r '.ci_status')
  category=$(echo "$record" | jq -r '.category')
  overdue=$((age_days - sla_days))

  # Record repos are canonical names (see Step 1); build canonical refs.
  full_repo="$ORG/$issue_repo"

  # Deduplication
  search_term="[dep-bump] Stale $severity bump: $package in $issue_repo"
  existing=$(gh_issue_exists "$full_repo" "$search_term" || true)

  if [ -n "$existing" ]; then
    echo "  Issue #$existing already exists for $package in $issue_repo"
    continue
  fi

  # Build issue title (truncate if needed)
  issue_title="[dep-bump] Stale $severity bump: $package in $issue_repo"
  if [ ${#issue_title} -gt 250 ]; then
    issue_title="${issue_title:0:247}..."
  fi

  # Build version string
  version_str=""
  if [ -n "$from_version" ] && [ -n "$to_version" ]; then
    version_str="$from_version -> $to_version"
  else
    version_str="(grouped update)"
  fi

  # Build issue body
  issue_body="## Describe the bug

Stale Dependabot PR detected by automated dependency bump scan.

**Repo:** $full_repo
**PR:** #$issue_pr_number
**Package:** $package
**Version:** $version_str
**Ecosystem:** $ecosystem
**Severity:** $severity
**SLA:** $sla_days days
**Age:** $age_days days (overdue by $overdue days)
**CI Status:** $ci_status
**First detected:** $SCAN_DATE
**Scan ID:** $SCAN_ID

## Steps To Reproduce

1. View PR: https://github.com/$full_repo/pull/$issue_pr_number
2. Note PR age ($age_days days) exceeds SLA threshold ($sla_days days)

## Expected Behavior

Dependabot PRs should be reviewed and merged within the SLA window.

## Additional Context

Category: $category
Detected by: OpenClaw Dep Bump Scanner (scan $SCAN_ID)"

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would create issue: $issue_title"
    ISSUES_CREATED=$((ISSUES_CREATED + 1))
  elif gh issue create --repo "$full_repo" \
    --title "$issue_title" \
    --body "$issue_body" 2>/dev/null; then
    ISSUES_CREATED=$((ISSUES_CREATED + 1))
    echo "  Created issue for $package in $issue_repo"
  else
    echo "  WARN: Failed to create issue for $package in $issue_repo"
  fi

  sleep 1
done < "$TMPDIR/new_keys.txt"

echo "Issues created: $ISSUES_CREATED"

# --- Step 7: Close issues for FIXED (merged/closed PRs) ---
ISSUES_CLOSED=0

while IFS='|' read -r fix_repo fix_pr_number; do
  [ -z "$fix_repo" ] && continue

  full_repo="$ORG/$fix_repo"

  # Find matching open issue by searching for the PR number in title/body
  issue_number=$(gh issue list --repo "$full_repo" \
    --search "[dep-bump] in:title #$fix_pr_number in:body" \
    --state open --json number --jq '.[0].number' 2>/dev/null || echo "")

  if [ -z "$issue_number" ] || [ "$issue_number" = "null" ]; then
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would close issue #$issue_number (PR #$fix_pr_number merged/closed)"
    ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
  elif close_issue_if_valid "$full_repo" "$issue_number" \
    "Dependabot PR #$fix_pr_number has been merged/closed. Resolved in scan $SCAN_ID ($SCAN_DATE). Auto-closing."; then
    ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
    echo "  Closed issue #$issue_number for PR #$fix_pr_number"
  fi
done < "$TMPDIR/fixed_keys.txt"

echo "Issues closed: $ISSUES_CLOSED"

# --- Step 8: Write reports ---
STALE_ARRAY=$(jq -s '.' "$TMPDIR/stale_prs.jsonl" 2>/dev/null || echo "[]")
COVERAGE_ARRAY=$(jq -s '.' "$TMPDIR/coverage_gaps.jsonl" 2>/dev/null || echo "[]")
ECO_SUMMARY=$(jq -s 'group_by(.ecosystem) | map({key: .[0].ecosystem, value: length}) | from_entries' \
  "$TMPDIR/all_prs.jsonl" 2>/dev/null || echo "{}")

LATEST_JSON=$(jq -nc \
  --arg scan_id "$SCAN_ID" \
  --arg date "$SCAN_TIME" \
  --argjson duration "$SECONDS" \
  --arg org "$ORG" \
  --argjson repos_scanned "$REPOS_SCANNED" \
  --argjson repos_with_dependabot "$REPOS_WITH_DEPENDABOT" \
  --argjson total_open_prs "$TOTAL_OPEN_PRS" \
  --argjson stale_prs "$STALE_ARRAY" \
  --argjson coverage_gaps "$COVERAGE_ARRAY" \
  --argjson ecosystem_summary "$ECO_SUMMARY" \
  --argjson new_count "$NEW_STALE" \
  --argjson fixed_count "$FIXED_STALE" \
  --argjson recurring_count "$RECURRING_STALE" \
  '{scan_id: $scan_id, date: $date, duration_seconds: $duration, org: $org,
    repos_scanned: $repos_scanned, repos_with_dependabot: $repos_with_dependabot,
    total_open_prs: $total_open_prs, stale_prs: $stale_prs,
    coverage_gaps: $coverage_gaps, ecosystem_summary: $ecosystem_summary,
    delta: {new: $new_count, fixed: $fixed_count, recurring: $recurring_count}}')

write_report_latest "$REPORTS_DIR" "$LATEST_JSON"
echo "Wrote $REPORTS_DIR/latest.json"

# --- History row ---
STALE_SECURITY=$(jq -s '[.[] | select(.category == "security")] | length' "$TMPDIR/stale_prs.jsonl" 2>/dev/null || echo 0)
STALE_MAJOR=$(jq -s '[.[] | select(.category == "major")] | length' "$TMPDIR/stale_prs.jsonl" 2>/dev/null || echo 0)
STALE_ROUTINE=$(jq -s '[.[] | select(.category == "routine")] | length' "$TMPDIR/stale_prs.jsonl" 2>/dev/null || echo 0)

HISTORY_ROW=$(jq -nc \
  --arg scan_id "$SCAN_ID" \
  --arg date "$SCAN_TIME" \
  --arg org "$ORG" \
  --argjson repos_scanned "$REPOS_SCANNED" \
  --argjson total_open_prs "$TOTAL_OPEN_PRS" \
  --argjson stale_security "$STALE_SECURITY" \
  --argjson stale_major "$STALE_MAJOR" \
  --argjson stale_routine "$STALE_ROUTINE" \
  --argjson new_count "$NEW_STALE" \
  --argjson fixed_count "$FIXED_STALE" \
  --argjson issues_created "$ISSUES_CREATED" \
  --argjson issues_closed "$ISSUES_CLOSED" \
  '{scan_id: $scan_id, date: $date, org: $org,
    repos_scanned: $repos_scanned, total_open_prs: $total_open_prs,
    stale_security: $stale_security, stale_major: $stale_major,
    stale_routine: $stale_routine,
    new: $new_count, fixed: $fixed_count,
    issues_created: $issues_created, issues_closed: $issues_closed}')

append_history_row "$REPORTS_DIR" "$HISTORY_ROW" "$MAX_HISTORY_ROWS"
echo "Appended to $REPORTS_DIR/history.json"

# --- Escalation check ---
if [ "$NEW_STALE" -gt "$ESCALATION_THRESHOLD" ]; then
  echo ""
  echo "ALERT: Dep bump scan found $NEW_STALE new stale PRs (threshold: $ESCALATION_THRESHOLD)."
  echo "This may indicate a Dependabot wave or security advisory affecting many packages."
  echo "Review PRs at https://github.com/orgs/$ORG/dependabot"
fi

# --- Summary ---
echo ""
echo "=== Scan $SCAN_ID Summary ==="
echo "Org: $ORG"
echo "Repos: $REPOS_SCANNED scanned, $REPOS_WITH_DEPENDABOT with Dependabot PRs"
echo "PRs: $TOTAL_OPEN_PRS open, $STALE_COUNT stale ($STALE_SECURITY security, $STALE_MAJOR major, $STALE_ROUTINE routine)"
echo "Delta: +$NEW_STALE new, -$FIXED_STALE fixed, $RECURRING_STALE recurring"
echo "Coverage gaps: $COVERAGE_GAPS repos"
echo "Issues: $ISSUES_CREATED created, $ISSUES_CLOSED closed"
echo "Duration: ${SECONDS}s"
