#!/usr/bin/env bash
set -euo pipefail

# PR Review Impact — computes clawgenti review impact on time-to-merge.
#
# A clawgenti review is a REVIEW SUBMISSION (GET /pulls/N/reviews), not the PR
# description. Its body carries the marker "<!-- reviewed: SHA -->" and a real
# submitted_at. clawgenti ALSO comments on Dependabot PRs as the dep-bump fixer,
# so detection uses a two-layer filter: (1) a reviewed-by:clawgenti search
# prefilter (drops comment-only/dep-bump PRs at the search stage), and (2) a
# required marked review on each candidate.
#
# Per repo, activation = earliest marked-review submitted_at. Merged PRs are
# segmented reviewed/unreviewed and before/after that repo's own activation
# (split on createdAt). Buckets aggregate across repos. Read-only against
# GitHub; writes only to the reports dir.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"

# --- Configuration ---
BOT_USER="clawgenti"
REVIEW_MARKER="<!-- reviewed:"
LOOKBACK_LIMIT=200

# get_repos -- emit the repos to measure, one "owner/name" per line.
#
# Delegates to get_core_repos() (program-lib.sh), which reads the shared
# allowlist at config/core-repos.txt, so PR-review coverage is defined in one
# place shared with the scanner rather than hardcoded here.
# FUTURE SEAM (rossoctl/rossoctl#1811 repository-tiers): once the org-level
# `tier` Custom Property is stamped, the allowlist file can be replaced with the
# Core-tier query below. The property is currently unstamped (returns empty) and
# the token lacks the required scope, so the allowlist stays until #1811 lands:
#
#   gh_with_backoff api "orgs/rossoctl/properties/values" \
#     --jq '.[] | select(.properties[]? | .property_name=="tier" and .value=="core") | .repository_full_name'
#
get_repos() {
  get_core_repos
}

# --- CLI args ---
VERBOSE=false
DRY_RUN=false
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --verbose) VERBOSE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --reports-dir) REPORTS_DIR="$2"; shift 2 ;;
    --help|-h) SHOW_HELP=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  cat << 'USAGE'
pr-review-impact -- Compute clawgenti review impact on time-to-merge

Detects reviews via GET /pulls/N/reviews (a reviewed-by:clawgenti search
prefilter + a required "<!-- reviewed:" marker on each candidate review).
Per repo, activation = earliest marked-review submitted_at. Merged PRs are
segmented reviewed/unreviewed and before/after that repo's activation
(split on createdAt); buckets aggregate across repos. No hardcoded date.

Usage:
  bash pr-review-impact.sh [OPTIONS]

Options:
  --verbose           Print diagnostics to stderr
  --dry-run           Compute and print impact.json to stdout; do not write
  --reports-dir DIR   Where to write impact.json (default: ./reports/pr-review,
                      or $REPORTS_DIR if set in the environment)
  --help, -h          Show this help

NOTES:
  Each repo's merged-PR baseline is capped at the most recent 200 PRs
  (LOOKBACK_LIMIT); repos with more merged PRs are truncated to that window.

REPORTS:
  impact.json   Reviewed/unreviewed and before/after-activation median TTM,
                plus per-repo activation dates (overwritten each run)

REQUIRES:
  gh (authenticated), jq
USAGE
  exit 0
fi

# Resolve org identity (env > profile > default) before reading the allowlist;
# get_core_repos() prepends $ORG and fails loud if it is unset.
load_org_profile

# --- Workspace and reports setup ---
setup_workspace "pr-review-impact"
WORK_DIR="$PROGRAM_TMPDIR"
REPORTS_DIR="${REPORTS_DIR:-./reports/pr-review}"
mkdir -p "$REPORTS_DIR"

SCAN_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

ALL_FILE="$WORK_DIR/all.jsonl"                  # every merged PR, tagged reviewed + after_activation
ACTIVATIONS_FILE="$WORK_DIR/activations.jsonl"  # one {repo, activation} per repo with marked reviews
: > "$ALL_FILE"
: > "$ACTIVATIONS_FILE"

# Resolve the repo set once, up front, so a broken or empty allowlist fails loud
# rather than producing a zero-repo report with exit 0. Portable while-read build
# (mapfile is bash 4+, unavailable on macOS's bash 3.2), mirroring pr-review-scanner.
REPOS=()
while IFS= read -r repo_line; do
  [ -n "$repo_line" ] && REPOS+=("$repo_line")
done < <(get_repos)

if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "ERROR: core repos allowlist is empty or could not be loaded" >&2
  exit 1
fi

# --- Step 1: Per repo — find marked-reviewed PRs, derive activation, tag merged PRs ---
for repo in "${REPOS[@]}"; do
  [ "$VERBOSE" = true ] && echo "Processing $repo..." >&2

  # 1a. Prefilter: PRs clawgenti REVIEWED (not merely commented on). This drops
  #     comment-only / dep-bump PRs at the search stage.
  candidates=$(gh_with_backoff api -X GET search/issues \
    --raw-field q="repo:$repo reviewed-by:$BOT_USER type:pr" \
    --jq '.items[].number' 2>/dev/null || true)

  # 1b. Confirm each candidate has a MARKED clawgenti review; collect its
  #     earliest submitted_at. Build the marked-number set and per-repo activation.
  marked_file="$WORK_DIR/marked_${repo//\//_}.txt"
  : > "$marked_file"
  activation=""
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    sub=$(gh_with_backoff api "repos/$repo/pulls/$n/reviews" \
      --jq "[.[] | select(.user.login==\"$BOT_USER\") | select((.body//\"\")|test(\"$REVIEW_MARKER\")) | .submitted_at] | sort | first // empty" \
      2>/dev/null || true)
    [ -z "$sub" ] && continue
    echo "$n" >> "$marked_file"
    if [ -z "$activation" ] || [[ "$sub" < "$activation" ]]; then
      activation="$sub"
    fi
  done <<< "$candidates"

  if [ -n "$activation" ]; then
    jq -nc --arg repo "$repo" --arg act "$activation" \
      '{repo: $repo, activation: $act}' >> "$ACTIVATIONS_FILE"
    [ "$VERBOSE" = true ] && echo "  activation: $activation ($(grep -c . "$marked_file") marked PRs)" >&2
  else
    [ "$VERBOSE" = true ] && echo "  no marked reviews; excluded from before/after" >&2
  fi

  # 1c. Fetch merged PRs; tag reviewed (number in marked set) and after_activation
  #     (createdAt >= activation; null when no activation). The marked numbers are
  #     passed to jq as a JSON array.
  # Note: the split is on createdAt, and activation is the earliest marked-review
  #     submitted_at, so the PR that *defines* activation (created before its own
  #     review) falls in before_activation. That is intentional — these buckets
  #     measure the period, not the PR; the reviewed/unreviewed split is the per-PR view.
  marked_json=$(jq -R 'select(length>0)|tonumber' "$marked_file" 2>/dev/null | jq -s '.' || echo "[]")
  gh_with_backoff pr list --repo "$repo" \
    --state merged \
    --limit "$LOOKBACK_LIMIT" \
    --json number,createdAt,mergedAt \
    2>/dev/null \
    | jq -c --arg repo "$repo" --arg act "$activation" --argjson marked "$marked_json" \
        '.[] | {
           repo: $repo,
           number: .number,
           createdAt: .createdAt,
           mergedAt: .mergedAt,
           reviewed: (.number as $n | ($marked | index($n)) != null),
           after_activation: (if $act == "" then null else (.createdAt >= $act) end)
         }' \
    >> "$ALL_FILE" 2>/dev/null || true
done

# --- Step 2: Aggregate median TTM (HOURS, 1 decimal) per bucket across repos ---
# Hours, not floored days: PRs here merge in hours, so day-floor collapses every
# bucket to 0 (verified on real data — reviewed 18.4h vs unreviewed 9.7h are only
# distinguishable in hours). Median computed on raw hours, rounded to 1 decimal.
median_ttm() {
  jq -s '
    [.[] |
      ((.mergedAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
       (.createdAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) / 3600
    ] | sort | (if length == 0 then 0
    elif length % 2 == 1 then .[length / 2 | floor]
    else (.[length / 2 - 1] + .[length / 2]) / 2
    end) | (. * 10 | round) / 10
  ' 2>/dev/null || echo "0"
}

count_lines() { wc -l < "$1" 2>/dev/null | tr -d ' ' || echo "0"; }

jq -c 'select(.reviewed == true)'  "$ALL_FILE" > "$WORK_DIR/reviewed.jsonl"   || true
jq -c 'select(.reviewed == false)' "$ALL_FILE" > "$WORK_DIR/unreviewed.jsonl" || true
jq -c 'select(.after_activation == false)' "$ALL_FILE" > "$WORK_DIR/before.jsonl" || true
jq -c 'select(.after_activation == true)'  "$ALL_FILE" > "$WORK_DIR/after.jsonl"  || true

REVIEWED_COUNT=$(count_lines "$WORK_DIR/reviewed.jsonl")
UNREVIEWED_COUNT=$(count_lines "$WORK_DIR/unreviewed.jsonl")
BEFORE_COUNT=$(count_lines "$WORK_DIR/before.jsonl")
AFTER_COUNT=$(count_lines "$WORK_DIR/after.jsonl")

REVIEWED_TTM=$(median_ttm   < "$WORK_DIR/reviewed.jsonl")
UNREVIEWED_TTM=$(median_ttm < "$WORK_DIR/unreviewed.jsonl")
BEFORE_TTM=$(median_ttm     < "$WORK_DIR/before.jsonl")
AFTER_TTM=$(median_ttm      < "$WORK_DIR/after.jsonl")

# Per-repo activation list for transparency in the report.
ACTIVATIONS_JSON=$(jq -s '.' "$ACTIVATIONS_FILE" 2>/dev/null || echo "[]")

# --- Step 3: Assemble impact.json ---
IMPACT_JSON=$(jq -n \
  --arg date "$SCAN_TIME" \
  --argjson activations "$ACTIVATIONS_JSON" \
  --argjson rc "$REVIEWED_COUNT"   --argjson rt "$REVIEWED_TTM" \
  --argjson uc "$UNREVIEWED_COUNT" --argjson ut "$UNREVIEWED_TTM" \
  --argjson bc "$BEFORE_COUNT"     --argjson bt "$BEFORE_TTM" \
  --argjson ac "$AFTER_COUNT"      --argjson at "$AFTER_TTM" \
  '{date: $date,
    activations: $activations,
    reviewed:         {count: $rc, median_ttm_hours: $rt},
    unreviewed:       {count: $uc, median_ttm_hours: $ut},
    before_activation:{count: $bc, median_ttm_hours: $bt},
    after_activation: {count: $ac, median_ttm_hours: $at}}')

if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would write $REPORTS_DIR/impact.json" >&2
  echo "$IMPACT_JSON"
else
  write_report_latest "$REPORTS_DIR" "$IMPACT_JSON" "impact.json"
  [ "$VERBOSE" = true ] && echo "Wrote $REPORTS_DIR/impact.json" >&2
  echo "$IMPACT_JSON"
fi
