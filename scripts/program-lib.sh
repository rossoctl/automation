#!/usr/bin/env bash
# Shared infrastructure for kagenti automation programs (scanner/fixer pattern).
#
# Source this file at the top of program scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/program-lib.sh"
#
# Prerequisites: jq, gh (GitHub CLI), coreutils (comm, sort, wc, mktemp)

# =============================================================================
# WORKSPACE MANAGEMENT
# =============================================================================

# Create a temp directory and register automatic cleanup on script exit.
# After calling this, use $PROGRAM_TMPDIR for all temp files.
#
# Usage: setup_workspace "link-fixer"
# Args:
#   $1 - prefix for the temp directory name (default: "program")
setup_workspace() {
  local prefix="${1:-program}"

  PROGRAM_TMPDIR=$(mktemp -d "/tmp/${prefix}-XXXXXX")
  # Automatic cleanup: remove the temp dir when the script exits
  trap 'rm -rf "$PROGRAM_TMPDIR"' EXIT
}

# Generate a unique scan ID for today in the format YYYY-MM-DD-NNN.
# The sequence number (NNN) increments based on how many scans already
# ran today (read from history.json). This prevents ID collisions when
# a scanner is triggered multiple times in one day.
#
# Usage: SCAN_ID=$(generate_scan_id "$REPORTS_DIR" "2026-05-21")
# Args:
#   $1 - path to the reports directory (must contain history.json)
#   $2 - today's date in YYYY-MM-DD format
# Prints: the scan ID (e.g., "2026-05-21-002")
generate_scan_id() {
  local reports_dir="$1"
  local scan_date="$2"
  local last_seq=0

  # Count how many scans already happened today
  if [ -f "$reports_dir/history.json" ]; then
    last_seq=$(jq -r \
      --arg date "$scan_date" \
      '[.[] | select(.scan_id | startswith($date))] | length' \
      "$reports_dir/history.json")
  fi

  # Zero-padded sequence number
  printf "%s-%03d" "$scan_date" $((last_seq + 1))
}

# =============================================================================
# PORTABLE DATE UTILITIES
# =============================================================================

# Convert an ISO 8601 timestamp (YYYY-MM-DDTHH:MM:SSZ) to Unix epoch seconds.
# Works on both macOS (BSD date) and Linux (GNU date), with a pure-awk fallback
# that requires no external language runtime. Returns 0 on parse failure.
#
# Usage: epoch=$(iso_to_epoch "2026-06-12T14:00:00Z")
# Args:
#   $1 - ISO 8601 timestamp string (must end in Z for UTC)
# Prints: Unix epoch seconds (integer)
iso_to_epoch() {
  local timestamp="$1"

  if [ -z "$timestamp" ]; then
    echo "0"
    return
  fi

  # Try GNU date first (Linux)
  local epoch
  epoch=$(date -d "$timestamp" +%s 2>/dev/null) && { echo "$epoch"; return; }

  # Try BSD date (macOS) — TZ=UTC ensures the Z suffix is honored
  epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null) && { echo "$epoch"; return; }

  # Fallback: pure awk (no external dependencies beyond POSIX)
  # Parses YYYY-MM-DDTHH:MM:SSZ and computes epoch via day-counting arithmetic.
  epoch=$(echo "$timestamp" | awk -F'[-T:Z]' '{
    if (NF < 6) { print 0; exit }
    y = $1 + 0; m = $2 + 0; d = $3 + 0
    H = $4 + 0; M = $5 + 0; S = $6 + 0

    # Days in each month (non-leap)
    split("31,28,31,30,31,30,31,31,30,31,30,31", mdays, ",")

    # Count days from 1970-01-01
    days = 0
    for (yr = 1970; yr < y; yr++) {
      days += 365
      if (yr % 4 == 0 && (yr % 100 != 0 || yr % 400 == 0)) days++
    }
    for (mo = 1; mo < m; mo++) {
      days += mdays[mo] + 0
      if (mo == 2 && y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) days++
    }
    days += d - 1

    print (days * 86400) + (H * 3600) + (M * 60) + S
  }' 2>/dev/null) && { echo "$epoch"; return; }

  echo "0"
}

# Write a file atomically using a temp file and mv.
# Unlike write_report_latest, this takes a source file path (not content string),
# avoiding argument-length limits for large files.
#
# Usage: atomic_write_file "$TMPDIR/state.json" "$REPORTS_DIR/state.json"
# Args:
#   $1 - source file path (contents to write)
#   $2 - destination file path
atomic_write_file() {
  local src="$1"
  local dst="$2"
  local tmp="${dst}.tmp.$$"

  cp "$src" "$tmp"
  mv "$tmp" "$dst"
}

# =============================================================================
# JSON SCHEMA VALIDATION
# =============================================================================

# Validate that a JSON file matches an expected structure.
# Uses jq to check that required top-level keys exist and are arrays.
# On failure, prints a warning and resets the file to the provided default.
#
# Usage:
#   validate_json_schema "$STATE_FILE" \
#     '(.in_progress | type) == "array" and (.reviewed | type) == "array"' \
#     '{"in_progress": [], "reviewed": []}'
#
# Args:
#   $1 - path to the JSON file
#   $2 - jq boolean expression that must return true for valid files
#   $3 - default JSON content to write if validation fails
# Returns: 0 if valid (or reset succeeded), 1 if file cannot be written
validate_json_schema() {
  local file="$1"
  local check_expr="$2"
  local default_content="$3"

  # File does not exist: write default
  if [ ! -f "$file" ]; then
    printf '%s\n' "$default_content" > "$file"
    return 0
  fi

  # File is not valid JSON: reset
  if ! jq empty "$file" 2>/dev/null; then
    echo "WARN: $file is not valid JSON, resetting to default." >&2
    printf '%s\n' "$default_content" > "$file"
    return 0
  fi

  # File does not pass schema check: reset
  local valid
  valid=$(jq -r "$check_expr" "$file" 2>/dev/null || echo "false")
  if [ "$valid" != "true" ]; then
    echo "WARN: $file failed schema validation, resetting to default." >&2
    printf '%s\n' "$default_content" > "$file"
    return 0
  fi

  return 0
}

# =============================================================================
# PATH VALIDATION
# =============================================================================

# Validate that REPOS_DIR is set and not pointing to a dangerous path.
# Rejects root filesystem paths, system directories, and $HOME itself
# (without a subdirectory). Intended to prevent accidental scanning or
# modification of system files.
#
# Usage: validate_repos_dir "$REPOS_DIR"
# Args:
#   $1 - the repos directory path to validate
# Returns: 0 if valid, exits with error message if invalid
validate_repos_dir() {
  local path="$1"

  if [ -z "$path" ]; then
    echo "ERROR: REPOS_DIR is not set." >&2
    echo "Export it to the directory containing your org's cloned repos:" >&2
    echo "  export REPOS_DIR=~/my-org" >&2
    exit 1
  fi

  # Resolve to absolute path for comparison
  local resolved
  resolved=$(cd "$path" 2>/dev/null && pwd) || resolved="$path"

  # Reject obviously dangerous paths
  local dangerous_paths=("/" "/etc" "/usr" "/var" "/sys" "/proc" "/bin" "/sbin" "/lib" "/tmp")
  for dangerous in "${dangerous_paths[@]}"; do
    if [ "$resolved" = "$dangerous" ]; then
      echo "ERROR: REPOS_DIR cannot be '$resolved' -- this is a system directory." >&2
      exit 1
    fi
  done

  # Reject $HOME itself (must be a subdirectory)
  if [ "$resolved" = "$HOME" ]; then
    echo "ERROR: REPOS_DIR cannot be your home directory itself." >&2
    echo "Use a subdirectory, e.g.: export REPOS_DIR=~/my-org" >&2
    exit 1
  fi

  # Check the directory exists
  if [ ! -d "$path" ]; then
    echo "ERROR: REPOS_DIR '$path' does not exist." >&2
    echo "Create it and clone your org's repos there, or set REPOS_DIR to an existing directory." >&2
    exit 1
  fi

  return 0
}

# =============================================================================
# ISSUE BODY VALIDATION
# =============================================================================

# Validate fields extracted from a scanner-created issue body.
# Returns 0 if all fields pass validation, 1 if any field is malformed.
# This prevents injection via crafted issue bodies.
#
# Usage:
#   if ! validate_issue_fields "$issue_repo" "$issue_file" "$broken_url" "$http_status" "$category"; then
#     echo "WARN: Skipping issue with malformed fields"
#     continue
#   fi
#
# Args:
#   $1 - repo field (expected: org/repo format)
#   $2 - file field (expected: relative path, no ..)
#   $3 - url field (expected: http:// or https://)
#   $4 - status field (expected: numeric or known text)
#   $5 - category field (expected: internal, external, or relative)
# Returns: 0 if valid, 1 if any field fails (prints warning to stderr)
validate_issue_fields() {
  local repo="$1"
  local file="$2"
  local url="$3"
  local status="$4"
  local category="$5"

  # Repo must match org/repo pattern
  if ! echo "$repo" | grep -qE '^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$'; then
    echo "  WARN: Invalid repo field: '$repo'" >&2
    return 1
  fi

  # File must not contain path traversal or shell metacharacters
  if echo "$file" | grep -qE '(\.\./|[;$`|&<>])'; then
    echo "  WARN: Invalid file field (contains unsafe characters): '$file'" >&2
    return 1
  fi

  # URL must start with http:// or https://
  if ! echo "$url" | grep -qE '^https?://'; then
    echo "  WARN: Invalid URL field (not http/https): '$url'" >&2
    return 1
  fi

  # Status must be numeric or a known enum token
  if ! echo "$status" | grep -qE '^([0-9]{3}|unknown|timeout|dns|unreachable|error)$'; then
    echo "  WARN: Invalid status field: '$status'" >&2
    return 1
  fi

  # Category must be a known value
  if ! echo "$category" | grep -qE '^(internal|external|relative)$'; then
    echo "  WARN: Invalid category field: '$category'" >&2
    return 1
  fi

  return 0
}

# =============================================================================
# PATH-SUFFIX SCORING
# =============================================================================

# Score a candidate path against a broken path by counting shared leading
# path segments (case-insensitive prefix match). This prioritizes candidates
# that share the most directory context with the broken URL, which best
# identifies where a renamed/moved file ended up.
#
# Example:
#   score_path_suffix "authbridge/cmd/authbridge/README.md" "authbridge/cmd/README.md"
#   # prints: 2 (shared prefix: authbridge/cmd)
#
# Args:
#   $1 - broken path (the original path from the URL)
#   $2 - candidate path (a found file)
# Prints: integer score (number of shared leading segments, 0 if none match)
score_path_suffix() {
  local broken_path="$1"
  local candidate_path="$2"

  # Lowercase both for case-insensitive comparison
  local broken_lower candidate_lower
  broken_lower=$(printf '%s' "$broken_path" | tr '[:upper:]' '[:lower:]')
  candidate_lower=$(printf '%s' "$candidate_path" | tr '[:upper:]' '[:lower:]')

  # Split paths into arrays by "/"
  IFS='/' read -ra broken_parts <<< "$broken_lower"
  IFS='/' read -ra candidate_parts <<< "$candidate_lower"

  local broken_len=${#broken_parts[@]}
  local candidate_len=${#candidate_parts[@]}
  local max_compare=$((broken_len < candidate_len ? broken_len : candidate_len))
  local score=0

  # Count shared leading segments
  local i
  for ((i = 0; i < max_compare; i++)); do
    if [ "${broken_parts[$i]}" = "${candidate_parts[$i]}" ]; then
      score=$((score + 1))
    else
      break
    fi
  done

  echo "$score"
}

# Given a broken path and a newline-separated list of candidates, find the
# best match by path-prefix score. Prints the winning candidate if there's
# a unique top scorer with score >= min_score; prints nothing otherwise.
#
# Usage:
#   winner=$(pick_best_candidate "$target_path" "$candidates" 1)
#
# Args:
#   $1 - broken path (from URL)
#   $2 - newline-separated candidate paths
#   $3 - minimum score threshold (default: 1)
# Prints: best candidate path if unique winner, empty if tied or below threshold
# Returns: 0 if unique winner found, 1 otherwise
pick_best_candidate() {
  local broken_path="$1"
  local candidates="$2"
  local min_score="${3:-1}"

  local best_score=0
  local best_candidate=""
  local tied=false

  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    local score
    score=$(score_path_suffix "$broken_path" "$candidate")

    if [ "$score" -gt "$best_score" ]; then
      best_score=$score
      best_candidate="$candidate"
      tied=false
    elif [ "$score" -eq "$best_score" ] && [ "$score" -gt 0 ]; then
      tied=true
    fi
  done <<< "$candidates"

  if [ "$best_score" -ge "$min_score" ] && [ "$tied" = false ] && [ -n "$best_candidate" ]; then
    echo "$best_candidate"
    return 0
  fi

  return 1
}

# =============================================================================
# DIFF LOGIC
# =============================================================================

# Compare current findings against a previous scan to determine what's new,
# what's fixed, and what's recurring. Uses set operations (comm) on sorted keys.
#
# After calling, three files are available in $PROGRAM_TMPDIR:
#   new_keys.txt       - items in current but not previous (just appeared)
#   fixed_keys.txt     - items in previous but not current (resolved)
#   recurring_keys.txt - items in both (still broken)
#
# Usage:
#   read -r new fixed recurring < <(diff_against_previous \
#     "$TMPDIR/current.jsonl" "$TMPDIR/prev.jsonl" '[.repo, .file, .url] | join("|")')
#
# Args:
#   $1 - path to current findings file (JSONL, one JSON object per line)
#   $2 - path to previous findings file (JSONL)
#   $3 - jq expression that extracts the comparison key from each object
#         (must produce a single string per line)
# Prints: three space-separated counts: "NEW FIXED RECURRING"
diff_against_previous() {
  local current_file="$1"
  local prev_file="$2"
  local key_expr="$3"

  # Extract and sort keys from both files
  jq -r "$key_expr" "$current_file" | sort > "$PROGRAM_TMPDIR/current_keys.txt"
  jq -r "$key_expr" "$prev_file"    | sort > "$PROGRAM_TMPDIR/prev_keys.txt"

  # Set operations using comm:
  #   comm -23 = lines only in file 1 (new items)
  #   comm -13 = lines only in file 2 (fixed items)
  #   comm -12 = lines in both files (recurring)
  comm -23 "$PROGRAM_TMPDIR/current_keys.txt" "$PROGRAM_TMPDIR/prev_keys.txt" \
    > "$PROGRAM_TMPDIR/new_keys.txt"

  comm -13 "$PROGRAM_TMPDIR/current_keys.txt" "$PROGRAM_TMPDIR/prev_keys.txt" \
    > "$PROGRAM_TMPDIR/fixed_keys.txt"

  comm -12 "$PROGRAM_TMPDIR/current_keys.txt" "$PROGRAM_TMPDIR/prev_keys.txt" \
    > "$PROGRAM_TMPDIR/recurring_keys.txt"

  # Count each set
  local new_count
  local fixed_count
  local recurring_count
  new_count=$(wc -l < "$PROGRAM_TMPDIR/new_keys.txt" | tr -d ' ')
  fixed_count=$(wc -l < "$PROGRAM_TMPDIR/fixed_keys.txt" | tr -d ' ')
  recurring_count=$(wc -l < "$PROGRAM_TMPDIR/recurring_keys.txt" | tr -d ' ')

  echo "$new_count $fixed_count $recurring_count"
}

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

# =============================================================================
# REPORTS
# =============================================================================

# Overwrite latest.json with the provided JSON content.
# Creates the reports directory if it doesn't exist.
#
# Usage:
#   write_report_latest "$REPORTS_DIR" "$json_string"
#
# Args:
#   $1 - path to the reports directory
#   $2 - JSON content to write (as a string)
#   $3 - (optional) filename (default: "latest.json")
write_report_latest() {
  local reports_dir="$1"
  local content="$2"
  local filename="${3:-latest.json}"

  mkdir -p "$reports_dir"
  printf '%s\n' "$content" > "$reports_dir/$filename.tmp" && mv "$reports_dir/$filename.tmp" "$reports_dir/$filename"
}

# Append a row to history.json, keeping the file under a maximum row count.
# If history.json doesn't exist or is empty, initializes it as a JSON array.
# Oldest entries are trimmed when the cap is exceeded.
#
# Usage:
#   append_history_row "$REPORTS_DIR" "$history_row_json" 500
#   append_history_row "$REPORTS_DIR" "$row" 500 "fixer-history.json"
#
# Args:
#   $1 - path to the reports directory
#   $2 - JSON object to append (as a string, e.g., '{"scan_id":"...","date":"..."}')
#   $3 - maximum number of rows to keep (default: 500)
#   $4 - (optional) filename (default: "history.json")
append_history_row() {
  local reports_dir="$1"
  local row="$2"
  local max_rows="${3:-500}"
  local filename="${4:-history.json}"

  mkdir -p "$reports_dir"

  local history_file="$reports_dir/$filename"

  # If history file exists and is non-empty, append and trim
  if [ -f "$history_file" ] && [ -s "$history_file" ]; then
    local tmp_file="$PROGRAM_TMPDIR/history_new.json"

    jq \
      --argjson row "$row" \
      --argjson cap "$max_rows" \
      '. + [$row] | if length > $cap then .[-$cap:] else . end' \
      "$history_file" > "$tmp_file"

    mv "$tmp_file" "$history_file"
  else
    # Initialize as a single-element array
    echo "[$row]" > "$history_file"
  fi
}

# =============================================================================
# FORK / PR MANAGEMENT
# =============================================================================

# Ensure a fork of the target repo exists under the fork owner's account.
# If the fork doesn't exist, creates it and waits briefly for GitHub to
# propagate it (forks are not instantly available for push).
#
# Usage:
#   ensure_fork "kagenti" "adk" "clawgenti"
#
# Args:
#   $1 - org name (e.g., "kagenti")
#   $2 - repo name (e.g., "adk")
#   $3 - fork owner account (e.g., "clawgenti")
ensure_fork() {
  local org="$1"
  local repo_name="$2"
  local fork_owner="$3"

  # Check if fork already exists
  if gh repo view "$fork_owner/$repo_name" &>/dev/null 2>&1; then
    return 0
  fi

  # Create the fork
  gh repo fork "$org/$repo_name" --org "$fork_owner" --clone=false 2>/dev/null || true

  # Wait for GitHub to make the fork available for push
  sleep 5
}

# Create a cross-fork PR from a fix branch. This function handles:
#   1. Adding the fork as a git remote (idempotent)
#   2. Committing staged changes with DCO sign-off
#   3. Pushing the branch to the fork
#   4. Creating the PR against upstream main
#
# Prerequisites: caller must have already cd'd into the repo directory,
# created the branch, and staged the changes (git add).
#
# Usage:
#   pr_url=$(create_fork_pr "kagenti" "adk" "clawgenti" \
#     "fix/broken-links-2026-05-21" \
#     "docs: Fix broken link in README.md" \
#     "docs: Fix 1 broken internal link(s) in adk" \
#     "Automated fix by Kagenti Link Health Fixer.")
#
# Args:
#   $1 - org name
#   $2 - repo name
#   $3 - fork owner
#   $4 - branch name
#   $5 - commit message
#   $6 - PR title
#   $7 - PR body
# Prints: the PR URL on success
# Returns: 0 on success, 1 on failure
create_fork_pr() {
  local org="$1"
  local repo_name="$2"
  local fork_owner="$3"
  local branch="$4"
  local commit_msg="$5"
  local pr_title="$6"
  local pr_body="$7"

  local fork_remote="${fork_owner}-fork"

  # Add fork remote (idempotent -- silently skips if already exists)
  if ! git remote get-url "$fork_remote" &>/dev/null 2>&1; then
    git remote add "$fork_remote" \
      "https://github.com/$fork_owner/$repo_name.git" 2>/dev/null || true
  fi

  # Commit with DCO sign-off (-s adds Signed-off-by trailer)
  git commit -s -m "$commit_msg"

  # Push branch to the fork
  if ! git push "$fork_remote" "$branch" --force-with-lease 2>/dev/null; then
    echo "  WARN: Failed to push branch $branch to $fork_owner/$repo_name" >&2
    return 1
  fi

  # Create cross-fork PR against upstream main
  local pr_url
  pr_url=$(gh pr create \
    --repo "$org/$repo_name" \
    --head "$fork_owner:$branch" \
    --base main \
    --title "$pr_title" \
    --body "$pr_body" \
    2>/dev/null)

  if [ -z "$pr_url" ]; then
    echo "  WARN: Failed to create PR for $org/$repo_name" >&2
    return 1
  fi

  echo "$pr_url"
}

# =============================================================================
# REPO SELECTION
# =============================================================================
#
# Single source of truth for which repos the programs act on. All programs
# derive their repo set from config/core-repos.txt via get_core_repos(), so
# coverage is defined in one place rather than hardcoded per script.
#
# The on-disk clone directories still carry pre-rename names (e.g. "kagenti",
# "kagenti-extensions"), so scripts that iterate clones must map a directory
# basename to its canonical repo via canonical_repo_for_dir() before building
# an API reference. Never rely on the rename redirect for filtered `gh pr list`
# queries (--label/--author silently return empty across a redirect).

# Load org identity from a profile file and resolve each fact by precedence:
#   --flag > env var > profile value > built-in default.
#
# The profile file assigns ONLY PROFILE_-prefixed names (PROFILE_ORG, ...),
# so sourcing it can never clobber an env-provided ORG before resolution.
#
# Profile selection: $ORG_PROFILE_FILE (absolute path, used by tests) wins;
# else --profile/$ORG_PROFILE names config/org.<name>.env; else config/org.env.
#
# Callers may pre-set *_FLAG vars from their own arg parsing (ORG_FLAG,
# FORK_OWNER_FLAG, MAIN_REPO_FLAG, REPOS_DIR_FLAG) and env vars (ORG, ...).
#
# Sets (caller should treat as exported): ORG FORK_OWNER MAIN_REPO REPOS_DIR REMAP.
# The first four honor the full flag > env > profile > default precedence; REMAP
# is profile-only (see note at its assignment below).
# Fails loud: missing profile file -> return 1; unresolvable ORG -> hard error.
#
# Only ORG has no built-in default (it must be resolved from flag/env/profile).
# The other facts fall back to sensible defaults derived from ORG, except
# FORK_OWNER, whose built-in fallback "clawgenti" is the rossoctl deployment's
# fork account. Any other org should set PROFILE_FORK_OWNER in its profile
# (config/org.env sets it explicitly) rather than rely on that fallback.
load_org_profile() {
  local lib_dir profile_file name
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  if [ -n "${ORG_PROFILE_FILE:-}" ]; then
    profile_file="$ORG_PROFILE_FILE"
  else
    name="${PROFILE_FLAG:-${ORG_PROFILE:-}}"
    if [ -n "$name" ]; then
      profile_file="$lib_dir/../config/org.$name.env"
    else
      profile_file="$lib_dir/../config/org.env"
    fi
  fi

  if [ ! -f "$profile_file" ]; then
    echo "ERROR: org profile not found: $profile_file" >&2
    return 1
  fi

  # Safe to source: file sets only PROFILE_* names.
  # shellcheck source=/dev/null
  . "$profile_file"

  ORG="${ORG_FLAG:-${ORG:-${PROFILE_ORG:-}}}"
  if [ -z "$ORG" ]; then
    echo "ERROR: ORG could not be resolved (flag/env/profile all empty)" >&2
    return 1
  fi
  FORK_OWNER="${FORK_OWNER_FLAG:-${FORK_OWNER:-${PROFILE_FORK_OWNER:-clawgenti}}}"
  MAIN_REPO="${MAIN_REPO_FLAG:-${MAIN_REPO:-${PROFILE_MAIN_REPO:-$ORG/$ORG}}}"
  REPOS_DIR="${REPOS_DIR_FLAG:-${REPOS_DIR:-${PROFILE_REPOS_DIR:-$HOME/$ORG}}}"
  # SOURCE_REPO: the owner/name of the repo where this suite (scripts, skills,
  # standing orders) is version-controlled. Used to link report PRs back to the
  # invoking program's standing order for auditability. Defaults to the
  # automation repo under the active org; a fork can override to its own.
  SOURCE_REPO="${SOURCE_REPO_FLAG:-${SOURCE_REPO:-${PROFILE_SOURCE_REPO:-$ORG/automation}}}"
  # REMAP is profile-only by design (no flag/env tier): it is a transitional
  # field that self-retires once clone dirs are renamed (rossoctl/automation#37),
  # so it never earns a durable --flag/env knob. An exported REMAP is ignored.
  REMAP="${PROFILE_REMAP:-}"

  export ORG FORK_OWNER MAIN_REPO REPOS_DIR SOURCE_REPO REMAP
}

# Print the core repo allowlist, one "owner/name" per line.
#
# Reads config/core-repos.txt, which holds BARE repo names (comments starting
# with "#" and blank lines are stripped). The owner is derived by prepending
# the loaded $ORG, so the same list works for any org the suite targets. Call
# load_org_profile (or otherwise set ORG) before this function.
#
# The file path is resolved relative to THIS library's location, not the
# caller's, so it works no matter which script sources program-lib.sh.
# Override with $CORE_REPOS_FILE (used by tests).
#
# Fails loud: if ORG is unset, or the file is missing or yields zero repos,
# prints an error to stderr and returns 1 -- callers must never silently scan
# an empty repo set or emit ownerless refs.
#
# Usage (portable; mapfile is bash 4+ and absent on macOS bash 3.2):
#   REPOS=(); while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done \
#     < <(get_core_repos)
get_core_repos() {
  if [ -z "${ORG:-}" ]; then
    echo "ERROR: ORG is unset; call load_org_profile before get_core_repos" >&2
    return 1
  fi

  local lib_dir
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local repos_file="${CORE_REPOS_FILE:-$lib_dir/../config/core-repos.txt}"

  if [ ! -f "$repos_file" ]; then
    echo "ERROR: core repos file not found: $repos_file" >&2
    return 1
  fi

  # Strip comments (full-line and trailing), trim whitespace, drop blanks.
  local repos
  repos=$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' \
    "$repos_file" | grep -v '^$' || true)

  if [ -z "$repos" ]; then
    echo "ERROR: core repos file is empty: $repos_file" >&2
    return 1
  fi

  # Prepend the loaded org to each bare name.
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && printf '%s/%s\n' "$ORG" "$line"
  done <<EOF
$repos
EOF
}

# Print just the bare repo names (owner stripped) from the core allowlist.
# Useful for membership tests against local clone directory names.
#
# Usage (portable): NAMES=(); while IFS= read -r n; do NAMES+=("$n"); done \
#   < <(core_repo_names)
core_repo_names() {
  get_core_repos | sed 's|^[^/]*/||'
}

# Return 0 if the given bare repo name is in the core allowlist, else 1.
#
# Intended for filtering local clone iteration: pass the canonical name
# (see canonical_repo_for_dir) so pre-rename clone dirs are matched correctly.
# Uses an exact, whole-line match (grep -Fx) to avoid substring false positives.
#
# Usage:
#   canon=$(canonical_repo_for_dir "$repo_name")
#   is_core_repo "$canon" || continue
# Args:
#   $1 - bare repo name (no owner prefix)
is_core_repo() {
  local name="$1"
  core_repo_names | grep -qxF "$name"
}

# Map a local clone directory basename to its canonical bare repo name.
#
# Clone dirs may still use pre-rename names; the remap table lives in the org
# profile's $REMAP (format: space-separated "basename:canonical" pairs, set by
# load_org_profile), so every script agrees and the mapping is data, not code.
# An empty $REMAP makes this pure identity; unknown names pass through
# unchanged (identity), so non-remapped repos need no special handling.
#
# TRANSITIONAL: $REMAP is a temporary bridge for the kagenti->rossoctl rename
# while stale-named clone dirs still exist on disk. Once clone dirs are renamed
# to canonical names, the PROFILE_REMAP line is deleted and this becomes pure
# identity. See rossoctl/automation#37. It is a lookup table, not a rename
# detector -- do not treat it as protection against future renames.
#
# A malformed entry (no colon) is skipped with a warning, non-fatal.
#
# Returns: the bare repo name only (e.g. "rossoctl"), NOT an owner/name pair.
#          Prepend the owner to build a full API reference, e.g. "$ORG/$canon".
#
# Usage: canon=$(canonical_repo_for_dir "$repo_dir_basename")
# Args:
#   $1 - clone directory basename (e.g. "kagenti", "cortex")
canonical_repo_for_dir() {
  local dir_name="$1"
  local pair basename_part canon_part
  # shellcheck disable=SC2086 -- intentional word-split on space-separated pairs
  for pair in ${REMAP:-}; do
    basename_part="${pair%%:*}"
    canon_part="${pair#*:}"
    if [ -z "$basename_part" ] || [ "$basename_part" = "$pair" ]; then
      # Malformed entry (no colon) -- skip with a warning, non-fatal.
      echo "WARN: ignoring malformed REMAP entry: $pair" >&2
      continue
    fi
    if [ "$dir_name" = "$basename_part" ]; then
      echo "$canon_part"
      return 0
    fi
  done
  # No match (or empty REMAP): identity.
  echo "$dir_name"
}
