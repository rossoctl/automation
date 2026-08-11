#!/usr/bin/env bash
# GitHub API helpers: rate-limit-aware gh wrapper and issue read/close/PR-check
# operations.
#
# ## Portability
# Targets bash 3.2+ (macOS default) through modern bash.
#
# No intra-library deps: functions invoke gh/jq directly, so this module sources
# no sibling module. Self-contained for vendoring.
[ -n "${_GITHUB_API_SH_LOADED:-}" ] && return
_GITHUB_API_SH_LOADED=1

# =============================================================================
# GITHUB API
# =============================================================================

# Rate-limit-aware wrapper around the gh CLI.
# Retries up to 3 times with exponential backoff on 403/429/rate-limit errors.
#
# Usage:
#   gh_with_backoff issue list --repo kagenti/adk --state open --json number
#
# Global: increments RATE_LIMIT_BACKOFF counter (initialize to 0 before use)
RATE_LIMIT_BACKOFF=${RATE_LIMIT_BACKOFF:-0}

gh_with_backoff() {
  local attempt=0
  local max_attempts=3
  local wait=5
  while [ $attempt -lt $max_attempts ]; do
    if output=$(gh "$@" 2>&1); then
      RATE_LIMIT_BACKOFF=0
      printf '%s' "$output"
      return 0
    fi
    if echo "$output" | grep -qiE 'rate limit|403|429|secondary rate'; then
      attempt=$((attempt + 1))
      RATE_LIMIT_BACKOFF=$((RATE_LIMIT_BACKOFF + 1))
      if [ $attempt -lt $max_attempts ]; then
        echo "  WARN: Rate limited, backing off ${wait}s (attempt $attempt/$max_attempts)" >&2
        sleep $wait
        wait=$((wait * 2))
      fi
    else
      printf '%s' "$output" >&2
      return 1
    fi
  done
  echo "  ERROR: Rate limit persisted after $max_attempts attempts, stopping" >&2
  return 1
}

# =============================================================================
# GITHUB ISSUES
# =============================================================================

# Check if an open issue already exists that matches a search query.
# Used for deduplication before creating new issues.
#
# Usage:
#   if existing=$(gh_issue_exists "kagenti/adk" "Broken link in README.md"); then
#     echo "Issue #$existing already open"
#   fi
#
# Args:
#   $1 - full repo name (e.g., "kagenti/adk")
#   $2 - search string (matched against issue title/body by GitHub)
# Returns: 0 if found (prints issue number), 1 if not found
gh_issue_exists() {
  local repo="$1"
  local search="$2"
  local result

  result=$(gh issue list \
    --repo "$repo" \
    --search "$search" \
    --state open \
    --json number \
    --jq '.[0].number' \
    2>/dev/null || echo "")

  if [ -n "$result" ] && [ "$result" != "null" ]; then
    echo "$result"
    return 0
  fi

  return 1
}

# Close an issue with a comment. Checks the exit code of `gh issue close`
# before reporting success -- this prevents the "close-before-verify" bug
# where we'd claim an issue was closed when the API call actually failed.
#
# Usage:
#   if close_issue_if_valid "kagenti/adk" "123" "Fixed in scan 2026-05-21-001."; then
#     echo "Closed"
#   fi
#
# Args:
#   $1 - full repo name
#   $2 - issue number
#   $3 - comment to add when closing
# Returns: 0 on success, 1 on failure (prints warning to stderr)
close_issue_if_valid() {
  local repo="$1"
  local number="$2"
  local comment="$3"

  if gh issue close "$number" --repo "$repo" --comment "$comment" 2>/dev/null; then
    return 0
  fi

  echo "  WARN: Failed to close issue #$number in $repo" >&2
  return 1
}

# Returns 0 if any open PR in $repo plausibly covers $issue_number.
# Prints the covering PR number on stdout when found (for logging).
#
# Uses a three-layer detection strategy:
#   Layer 1: GraphQL closingIssuesReferences (keyword-agnostic, author-agnostic)
#   Layer 2: Keyword text search across all authors (close/fix/resolve variants)
#   Layer 3: File + URL overlap in PR diffs (catches unlisted but covered issues)
#
# Args:
#   $1 - full repo name (e.g., "kagenti/adk")
#   $2 - issue number
#   $3 - (optional) source file path from the issue body
#   $4 - (optional) broken URL from the issue body
# Returns: 0 if covered, 1 otherwise
issue_has_open_pr() {
  local repo="$1"
  local issue_number="$2"
  local source_file="${3:-}"
  local broken_url="${4:-}"
  local owner="${repo%/*}"
  local repo_name="${repo#*/}"
  local pr_number

  # Layer 1: GraphQL closingIssuesReferences (cheapest, most authoritative)
  pr_number=$(gh api graphql -f query='
    query($owner:String!, $repo:String!, $num:Int!) {
      repository(owner:$owner, name:$repo) {
        issue(number:$num) {
          closedByPullRequestsReferences(first:5, includeClosedPrs:false) {
            nodes { number state }
          }
        }
      }
    }' \
    -F owner="$owner" -F repo="$repo_name" -F num="$issue_number" \
    --jq '.data.repository.issue.closedByPullRequestsReferences.nodes[] | select(.state == "OPEN") | .number' \
    2>/dev/null | head -1)

  if [ -n "$pr_number" ]; then
    echo "$pr_number"
    return 0
  fi

  # Layer 2: Keyword search fallback (broader text match, all authors)
  pr_number=$(gh pr list --repo "$repo" --state open \
    --search "#$issue_number" \
    --json number,body \
    --jq ".[] | select(.body | test(\"(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)\\\\s+#$issue_number\")) | .number" \
    2>/dev/null | head -1)

  if [ -n "$pr_number" ]; then
    echo "$pr_number"
    return 0
  fi

  # Layer 3: File + URL overlap (only when source_file and broken_url provided)
  if [ -n "$source_file" ] && [ -n "$broken_url" ]; then
    local pr_numbers
    pr_numbers=$(gh pr list --repo "$repo" --state open \
      --json number,files \
      --jq ".[] | select(.files[]?.path == \"$source_file\") | .number" \
      2>/dev/null)

    local candidate_pr
    local escaped_url
    escaped_url=$(printf '%s' "$broken_url" | sed -E 's/[.[\*^$()+?{|]/\\&/g')

    while IFS= read -r candidate_pr; do
      [ -z "$candidate_pr" ] && continue
      if gh pr diff "$candidate_pr" --repo "$repo" 2>/dev/null \
        | grep -q "^-.*$escaped_url"; then
        echo "$candidate_pr"
        return 0
      fi
    done <<< "$pr_numbers"
  fi

  return 1
}
