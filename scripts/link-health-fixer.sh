#!/usr/bin/env bash
set -euo pipefail

# Link Health Fixer -- Phase 2
# Reads scanner-created issues, re-verifies broken links, attempts fixes for internal links.
# Outputs PR previews in dry-run mode; creates fork-based PRs when --live is passed.

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"

# --- Configuration ---
REPORTS_DIR="${REPORTS_DIR:-$HOME/workspaces/clawgenti/reports/link-scan}"
FIX_DATE=$(date +%Y-%m-%d)
SCAN_DATE=$(date +%Y-%m-%d)

# DCO sign-off identity for fix PRs (maintainer, not bot)
GIT_AUTHOR_NAME="Gloire Rubambiza"
GIT_AUTHOR_EMAIL="gloire@ibm.com"
export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# --- CLI args ---
DRY_RUN=true
ISSUE_LIMIT=5
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --live) DRY_RUN=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --issue-limit) ISSUE_LIMIT="$2"; shift 2 ;;
    --profile) PROFILE_FLAG="$2"; shift 2 ;;
    --org) ORG_FLAG="$2"; shift 2 ;;
    --fork-owner) FORK_OWNER_FLAG="$2"; shift 2 ;;
    --repos-dir) REPOS_DIR_FLAG="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Resolve org identity (--flag > env > profile > default). Sets ORG, FORK_OWNER,
# MAIN_REPO, REPOS_DIR, REMAP. Reads use canonical $ORG/<name>; fork-PR write
# paths derive from $ORG/$FORK_OWNER.
load_org_profile

# --- Workspace setup ---
setup_workspace "link-fixer"
TMPDIR="$PROGRAM_TMPDIR"

echo "=== Link Health Fixer $FIX_DATE ==="
echo "Repos dir: $REPOS_DIR"
if [ "$DRY_RUN" = true ]; then
  echo "Mode: DRY RUN (no PRs, re-verified issues will still be closed)"
else
  echo "Mode: LIVE (PRs will be created)"
fi
echo "Issue limit: $ISSUE_LIMIT"
echo ""

# --- Step 1: Gather open scanner issues across all repos ---
echo "=== Step 1: Gathering open scanner issues ==="

ISSUES_FILE="$TMPDIR/issues.jsonl"
: > "$ISSUES_FILE"

SEEN_CANON=""
for repo_dir in "$REPOS_DIR"/*/ "$REPOS_DIR"/.github/; do
  [ -d "$repo_dir" ] || continue
  repo_name=$(basename "$repo_dir")
  if [[ "$repo_name" == .* && "$repo_name" != ".github" ]] || [ ! -d "$repo_dir/.git" ]; then
    continue
  fi

  # Restrict to core repos (allowlist), mapping pre-rename dir names first;
  # dedup so duplicate clone dirs for the same canonical repo run once.
  canon=$(canonical_repo_for_dir "$repo_name")
  if ! is_core_repo "$canon"; then
    continue
  fi
  case " $SEEN_CANON " in
    *" $canon "*) continue ;;
  esac
  SEEN_CANON="$SEEN_CANON $canon"

  full_repo="$ORG/$canon"

  issues_json=$(gh issue list --repo "$full_repo" \
    --search "Broken link in:title" \
    --state open --limit 100 \
    --json number,title,body 2>/dev/null || echo "[]")

  # Add repository info since gh issue list doesn't include it
  echo "$issues_json" | jq -c --arg repo "$full_repo" \
    '.[] | . + {repository: {nameWithOwner: $repo}}' >> "$ISSUES_FILE" 2>/dev/null || true
done

TOTAL_ISSUES=$(wc -l < "$ISSUES_FILE" | tr -d ' ')
echo "Found $TOTAL_ISSUES open scanner issues"

if [ "$TOTAL_ISSUES" -eq 0 ]; then
  echo "No issues to process."
  echo ""
  echo "=== Fixer Run $FIX_DATE Summary ==="
  echo "Issues processed: 0"
  exit 0
fi

# --- Step 2: Parse issue fields and filter to internal links ---
echo ""
echo "=== Step 2: Parsing issues and classifying ==="

PARSED_FILE="$TMPDIR/parsed.jsonl"
EXTERNAL_FILE="$TMPDIR/external.jsonl"
: > "$PARSED_FILE"
: > "$EXTERNAL_FILE"

while IFS= read -r issue_json; do
  number=$(echo "$issue_json" | jq -r '.number')
  repo_full=$(echo "$issue_json" | jq -r '.repository.nameWithOwner // empty')
  body=$(echo "$issue_json" | jq -r '.body // ""')

  # Parse structured fields from issue body (BSD-compatible, no grep -P)
  issue_repo=$(echo "$body" | sed -nE 's/^\*\*Repo:\*\*[[:space:]]*(.*)/\1/p' | head -1 | tr -d ' ' || true)
  issue_file=$(echo "$body" | sed -nE 's/^\*\*File:\*\*[[:space:]]*(.*)/\1/p' | head -1 | tr -d ' ' || true)
  broken_url=$(echo "$body" | sed -nE 's/^\*\*Broken URL:\*\*[[:space:]]*(.*)/\1/p' | head -1 | tr -d ' ' || true)
  http_status=$(echo "$body" | sed -nE 's/^\*\*HTTP Status:\*\*[[:space:]]*(.*)/\1/p' | head -1 || true)
  category=$(echo "$body" | sed -nE 's/^Category:[[:space:]]*(.*)/\1/p' | head -1 | tr -d ' ' || true)

  # Skip issues with missing required fields
  [ -z "$issue_repo" ] && continue
  [ -z "$broken_url" ] && continue

  # Validate extracted fields to prevent injection via crafted issue bodies
  if ! validate_issue_fields "$issue_repo" "${issue_file:-unknown}" "$broken_url" "${http_status:-unknown}" "${category:-internal}"; then
    echo "  WARN: Skipping issue #$number with malformed fields"
    continue
  fi

  # Use repo from issue body if repo_full is empty
  [ -z "$repo_full" ] && repo_full="$issue_repo"

  record=$(jq -nc \
    --arg number "$number" \
    --arg repo "$repo_full" \
    --arg issue_repo "$issue_repo" \
    --arg file "$issue_file" \
    --arg url "$broken_url" \
    --arg status "$http_status" \
    --arg category "$category" \
    '{number: ($number|tonumber), repo: $repo, issue_repo: $issue_repo, file: $file, url: $url, status: $status, category: $category}')

  if [ "$category" = "internal" ]; then
    echo "$record" >> "$PARSED_FILE"
  elif [ "$category" = "external" ]; then
    echo "$record" >> "$EXTERNAL_FILE"
  else
    [ "$VERBOSE" = true ] && echo "  SKIP #$number: unknown category ($category)"
  fi
done < "$ISSUES_FILE"

INTERNAL_COUNT=$(wc -l < "$PARSED_FILE" | tr -d ' ')
EXTERNAL_COUNT=$(wc -l < "$EXTERNAL_FILE" | tr -d ' ')
echo "Internal link issues: $INTERNAL_COUNT"
echo "External link issues: $EXTERNAL_COUNT"
echo "Total: $TOTAL_ISSUES"

# --- Step 3: Re-verify broken links ---
echo ""
echo "=== Step 3: Re-verifying broken links ==="

STILL_BROKEN="$TMPDIR/still_broken.jsonl"
REVERIFIED="$TMPDIR/reverified.jsonl"
: > "$STILL_BROKEN"
: > "$REVERIFIED"

PROCESSED=0
REVERIFIED_COUNT=0

while IFS= read -r item; do
  [ "$ISSUE_LIMIT" -gt 0 ] && [ "$PROCESSED" -ge "$ISSUE_LIMIT" ] && break

  number=$(echo "$item" | jq -r '.number')
  repo=$(echo "$item" | jq -r '.repo')
  broken_url=$(echo "$item" | jq -r '.url')
  source_file=$(echo "$item" | jq -r '.file')

  # Skip issues that already have an open fix PR (don't count toward limit)
  if covering_pr=$(issue_has_open_pr "$repo" "$number" "$source_file" "$broken_url"); then
    echo "  #$number: Open PR #$covering_pr already covers, skipping"
    continue
  fi

  # Extract target org/repo/path from GitHub URL (BSD-compatible)
  if echo "$broken_url" | grep -qE 'github\.com/[^/]+/[^/]+/(blob|tree)/'; then
    target_org=$(echo "$broken_url" | sed -nE 's#.*github\.com/([^/]+)/.*#\1#p')
    target_repo=$(echo "$broken_url" | sed -nE 's#.*github\.com/[^/]+/([^/]+)/.*#\1#p')
    target_ref=$(echo "$broken_url" | sed -nE 's#.*(blob|tree)/([^/]+)/.*#\2#p')
    target_path=$(echo "$broken_url" | sed -E 's#.*/((blob|tree))/[^/]+/##')

    # Check if file exists via GitHub API
    if gh api "repos/$target_org/$target_repo/contents/$target_path?ref=$target_ref" \
      --jq '.name' >/dev/null 2>&1; then
      echo "  #$number: Link now resolves ($broken_url)"

      if close_issue_if_valid "$repo" "$number" \
        "Link now resolves as of $SCAN_DATE. Verified by Link Health Fixer. Closing."; then
        echo "  #$number: Issue closed"
      fi

      echo "$item" >> "$REVERIFIED"
      REVERIFIED_COUNT=$((REVERIFIED_COUNT + 1))
      PROCESSED=$((PROCESSED + 1))
      sleep 1
      continue
    fi
  fi

  echo "  #$number: Still broken ($broken_url)"
  echo "$item" >> "$STILL_BROKEN"
  PROCESSED=$((PROCESSED + 1))
done < "$PARSED_FILE"

BROKEN_COUNT=$(wc -l < "$STILL_BROKEN" | tr -d ' ')
echo "Re-verified (now valid): $REVERIFIED_COUNT"
echo "Still broken: $BROKEN_COUNT"

# --- Step 4: Attempt deterministic fixes ---
echo ""
echo "=== Step 4: Attempting fixes ==="

FIXES_FILE="$TMPDIR/fixes.jsonl"
AMBIGUOUS_FILE="$REPORTS_DIR/fixer-ambiguous.json"
: > "$FIXES_FILE"
echo "[]" > "$AMBIGUOUS_FILE"

FIXED_COUNT=0
UNFIXABLE_COUNT=0
AMBIGUOUS_COUNT=0

while IFS= read -r item; do
  number=$(echo "$item" | jq -r '.number')
  repo=$(echo "$item" | jq -r '.repo')
  issue_repo=$(echo "$item" | jq -r '.issue_repo')
  source_file=$(echo "$item" | jq -r '.file')
  broken_url=$(echo "$item" | jq -r '.url')

  # Skip issues that already have an open fix PR
  if covering_pr=$(issue_has_open_pr "$repo" "$number" "$source_file" "$broken_url"); then
    echo "  #$number: Open PR #$covering_pr already covers, skipping"
    continue
  fi

  # Extract target repo and path from URL
  target_repo_name=""
  target_path=""

  if echo "$broken_url" | grep -qE 'github\.com/[^/]+/[^/]+/(blob|tree)/'; then
    target_repo_name=$(echo "$broken_url" | sed -nE 's#.*github\.com/[^/]+/([^/]+)/.*#\1#p')
    target_path=$(echo "$broken_url" | sed -E 's#.*/((blob|tree))/[^/]+/##')
  else
    echo "  #$number: Unrecognized URL format, skipping"
    UNFIXABLE_COUNT=$((UNFIXABLE_COUNT + 1))
    continue
  fi

  target_repo_dir="$REPOS_DIR/$target_repo_name"
  if [ ! -d "$target_repo_dir/.git" ]; then
    echo "  #$number: Target repo $target_repo_name not cloned locally, skipping"
    UNFIXABLE_COUNT=$((UNFIXABLE_COUNT + 1))
    continue
  fi

  echo "  #$number: Searching for $target_path in $target_repo_name..."

  # Strategy 1: git log --follow for renames
  filename=$(basename "$target_path")
  new_path=""

  rename_result=$(cd "$target_repo_dir" && git log --all --follow --diff-filter=R \
    --format="%H" -- "$target_path" 2>/dev/null | head -1 || true)

  if [ -n "$rename_result" ]; then
    # Find what the file was renamed to
    new_path=$(cd "$target_repo_dir" && git diff-tree --no-commit-id -r --diff-filter=R \
      "$rename_result" 2>/dev/null | grep "$filename" | awk '{print $NF}' | head -1 || true)
    [ -n "$new_path" ] && [ -f "$target_repo_dir/$new_path" ] || new_path=""
  fi

  # Strategy 2: find by filename
  if [ -z "$new_path" ]; then
    candidates=$(cd "$target_repo_dir" && find . -name "$filename" -type f \
      ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/vendor/*' \
      2>/dev/null | sed 's|^\./||')

    candidate_count=$(echo "$candidates" | grep -c . 2>/dev/null || echo 0)

    if [ "$candidate_count" -eq 1 ] && [ -n "$candidates" ]; then
      new_path="$candidates"
    elif [ "$candidate_count" -gt 1 ]; then
      # Score candidates by path-prefix match
      best=$(pick_best_candidate "$target_path" "$candidates" 1) || true
      if [ -n "$best" ]; then
        echo "    Scored best candidate: $best"
        new_path="$best"
      else
        echo "    Multiple candidates found ($candidate_count), flagging for model"
        candidate_list=$(echo "$candidates" | jq -R . | jq -s .)
        jq --argjson new "$(jq -nc \
          --arg number "$number" \
          --arg repo "$repo" \
          --arg issue_repo "$issue_repo" \
          --arg file "$source_file" \
          --arg url "$broken_url" \
          --arg target_repo "$target_repo_name" \
          --arg target_path "$target_path" \
          --argjson candidates "$candidate_list" \
          '{issue_number: ($number|tonumber), repo: $repo, file: $file, broken_url: $url, target_repo: $target_repo, target_path: $target_path, candidates: $candidates, reason: "multiple_matches"}')" \
          '. += [$new]' "$AMBIGUOUS_FILE" > "$TMPDIR/amb_tmp.json" && mv "$TMPDIR/amb_tmp.json" "$AMBIGUOUS_FILE"
        AMBIGUOUS_COUNT=$((AMBIGUOUS_COUNT + 1))
        continue
      fi
    fi
  fi

  # Strategy 3: find by filename without extension (for .mdx -> .md or vice versa)
  if [ -z "$new_path" ]; then
    basename_no_ext="${filename%.*}"
    candidates=$(cd "$target_repo_dir" && find . -name "${basename_no_ext}.*" -type f \
      ! -path '*/node_modules/*' ! -path '*/.git/*' ! -path '*/vendor/*' \
      2>/dev/null | sed 's|^\./||')

    candidate_count=$(echo "$candidates" | grep -c . 2>/dev/null || echo 0)

    if [ "$candidate_count" -eq 1 ] && [ -n "$candidates" ]; then
      new_path="$candidates"
    elif [ "$candidate_count" -gt 1 ]; then
      # Score candidates by path-prefix match
      best=$(pick_best_candidate "$target_path" "$candidates" 1) || true
      if [ -n "$best" ]; then
        echo "    Scored best candidate: $best"
        new_path="$best"
      else
        echo "    Multiple extension variants found ($candidate_count), flagging for model"
        candidate_list=$(echo "$candidates" | jq -R . | jq -s .)
        jq --argjson new "$(jq -nc \
          --arg number "$number" \
          --arg repo "$repo" \
          --arg issue_repo "$issue_repo" \
          --arg file "$source_file" \
          --arg url "$broken_url" \
          --arg target_repo "$target_repo_name" \
          --arg target_path "$target_path" \
          --argjson candidates "$candidate_list" \
          '{issue_number: ($number|tonumber), repo: $repo, file: $file, broken_url: $url, target_repo: $target_repo, target_path: $target_path, candidates: $candidates, reason: "multiple_extension_matches"}')" \
          '. += [$new]' "$AMBIGUOUS_FILE" > "$TMPDIR/amb_tmp.json" && mv "$TMPDIR/amb_tmp.json" "$AMBIGUOUS_FILE"
        AMBIGUOUS_COUNT=$((AMBIGUOUS_COUNT + 1))
        continue
      fi
    fi
  fi

  if [ -z "$new_path" ]; then
    echo "    No candidates found, marking unfixable"
    UNFIXABLE_COUNT=$((UNFIXABLE_COUNT + 1))

    # Comment on the issue
    gh issue comment "$number" --repo "$repo" \
      --body "Unable to find an automated fix: file \`$target_path\` not found in \`$target_repo_name\` (searched for renames, filename matches, and extension variants). This may require manual investigation." \
      2>/dev/null || echo "    WARN: Failed to comment on issue #$number"
    sleep 1
    continue
  fi

  # Build new URL (BSD-compatible)
  target_ref=$(echo "$broken_url" | sed -nE 's#.*(blob|tree)/([^/]+)/.*#\2#p')
  url_type=$(echo "$broken_url" | sed -nE 's#.*(blob|tree)/.*#\1#p')
  target_org=$(echo "$broken_url" | sed -nE 's#.*github\.com/([^/]+)/.*#\1#p')
  new_url="https://github.com/$target_org/$target_repo_name/$url_type/$target_ref/$new_path"

  # Verify the new path exists
  if [ ! -f "$target_repo_dir/$new_path" ]; then
    echo "    Candidate $new_path does not exist on disk, skipping"
    UNFIXABLE_COUNT=$((UNFIXABLE_COUNT + 1))
    continue
  fi

  echo "    FIX: $target_path -> $new_path"

  # Determine which repo contains the source file that needs editing.
  # $repo is always "owner/name"; strip any owner so the bare repo name is
  # correct regardless of which org owns it (do not couple to $ORG).
  source_repo_name="${repo##*/}"

  jq -nc \
    --arg number "$number" \
    --arg repo "$repo" \
    --arg source_repo "$source_repo_name" \
    --arg source_file "$source_file" \
    --arg old_url "$broken_url" \
    --arg new_url "$new_url" \
    --arg old_path "$target_path" \
    --arg new_path "$new_path" \
    '{number: ($number|tonumber), repo: $repo, source_repo: $source_repo, source_file: $source_file, old_url: $old_url, new_url: $new_url, old_path: $old_path, new_path: $new_path}' \
    >> "$FIXES_FILE"

  FIXED_COUNT=$((FIXED_COUNT + 1))
done < "$STILL_BROKEN"

echo ""
echo "Fixes found: $FIXED_COUNT"
echo "Ambiguous (needs model): $AMBIGUOUS_COUNT"
echo "Unfixable: $UNFIXABLE_COUNT"

# --- Step 5: Apply fixes / PR preview ---
echo ""
echo "=== Step 5: Fix application ==="

if [ "$FIXED_COUNT" -eq 0 ]; then
  echo "No fixes to apply."
else
  # Group fixes by source repo
  repos_with_fixes=$(jq -r '.source_repo' "$FIXES_FILE" | sort -u)

  for fix_repo in $repos_with_fixes; do
    echo ""
    echo "--- Repo: $ORG/$fix_repo ---"

    fix_repo_dir="$REPOS_DIR/$fix_repo"
    FIX_BRANCH="fix/broken-links-${fix_repo}-${FIX_DATE}"

    # Collect fixes for this repo
    repo_fixes=$(jq -c "select(.source_repo == \"$fix_repo\")" "$FIXES_FILE")
    fix_count=$(echo "$repo_fixes" | wc -l | tr -d ' ')
    echo "Fixes: $fix_count"

    if [ "$DRY_RUN" = true ]; then
      echo ""
      echo "[DRY RUN] PR Preview for $ORG/$fix_repo:"
      echo "  Branch: $FIX_BRANCH"
      echo "  Title: docs: Fix $fix_count broken internal link(s) in $fix_repo"
      echo "  Changes:"

      echo "$repo_fixes" | while IFS= read -r fix; do
        src_file=$(echo "$fix" | jq -r '.source_file')
        old_url=$(echo "$fix" | jq -r '.old_url')
        new_url=$(echo "$fix" | jq -r '.new_url')
        echo "    $src_file:"
        echo "      - $old_url"
        echo "      + $new_url"
      done

      echo ""
      echo "  Body:"
      echo "    Automated fix by OpenClaw Link Health Fixer."
      echo "    Broken internal links updated to point to current file locations."
      echo ""
      echo "    | File | Old URL | New URL |"
      echo "    |------|---------|---------|"
      echo "$repo_fixes" | while IFS= read -r fix; do
        src_file=$(echo "$fix" | jq -r '.source_file')
        old_path=$(echo "$fix" | jq -r '.old_path')
        new_path=$(echo "$fix" | jq -r '.new_path')
        echo "    | \`$src_file\` | \`$old_path\` | \`$new_path\` |"
      done
    else
      # --- LIVE MODE ---
      cd "$fix_repo_dir"

      # Fork on demand (uses shared library)
      ensure_fork "$ORG" "$fix_repo" "$FORK_OWNER"

      # Set up remote
      FORK_REMOTE="clawgenti-${fix_repo}-fork"
      if ! git remote get-url "$FORK_REMOTE" &>/dev/null 2>&1; then
        git remote add "$FORK_REMOTE" "https://github.com/$FORK_OWNER/${fix_repo}.git"
      fi

      # Create branch from fork's main
      git fetch "$FORK_REMOTE" main 2>/dev/null || true
      git checkout -B "$FIX_BRANCH" "$FORK_REMOTE/main" 2>/dev/null || git checkout -B "$FIX_BRANCH"

      # Apply each fix
      echo "$repo_fixes" | while IFS= read -r fix; do
        src_file=$(echo "$fix" | jq -r '.source_file')
        old_url=$(echo "$fix" | jq -r '.old_url')
        new_url=$(echo "$fix" | jq -r '.new_url')

        if [ -f "$src_file" ]; then
          # Escape URLs for sed
          old_escaped=$(printf '%s\n' "$old_url" | sed 's/[&/\]/\\&/g')
          new_escaped=$(printf '%s\n' "$new_url" | sed 's/[&/\]/\\&/g')
          sed -i "s|$old_escaped|$new_escaped|g" "$src_file"
          git add "$src_file"
        else
          echo "  WARN: Source file $src_file not found"
        fi
      done

      # Commit
      git commit -s -m "docs: Fix broken internal links in $fix_repo

Automated fix by OpenClaw Link Health Fixer ($FIX_DATE)." 2>/dev/null || {
        echo "  No changes to commit"
        continue
      }

      # Push
      git push "$FORK_REMOTE" "$FIX_BRANCH" 2>/dev/null || {
        echo "  WARN: Failed to push to fork"
        continue
      }

      # Create PR
      pr_body="Automated fix by OpenClaw Link Health Fixer.
Broken internal links updated to point to current file locations.

| File | Old Path | New Path |
|------|----------|----------|"

      while IFS= read -r fix; do
        src_file=$(echo "$fix" | jq -r '.source_file')
        old_path=$(echo "$fix" | jq -r '.old_path')
        new_path=$(echo "$fix" | jq -r '.new_path')
        pr_body="$pr_body
| \`$src_file\` | \`$old_path\` | \`$new_path\` |"
      done <<< "$repo_fixes"

      pr_url=$(gh pr create --repo "$ORG/$fix_repo" \
        --head "$FORK_OWNER:$FIX_BRANCH" --base main \
        --title "docs: Fix $fix_count broken internal link(s) in $fix_repo" \
        --body "$pr_body" 2>/dev/null) || {
        echo "  WARN: Failed to create PR"
        continue
      }

      echo "  PR created: $pr_url"

      # Comment on each issue with the PR link
      echo "$repo_fixes" | while IFS= read -r fix; do
        issue_num=$(echo "$fix" | jq -r '.number')
        src_file=$(echo "$fix" | jq -r '.source_file')
        new_path=$(echo "$fix" | jq -r '.new_path')
        gh issue comment "$issue_num" --repo "$ORG/$fix_repo" \
          --body "Fix submitted: $pr_url. The broken link in \`$src_file\` has been updated to point to \`$new_path\`." \
          2>/dev/null || echo "  WARN: Failed to comment on issue #$issue_num"
        sleep 1
      done

      # Return to main
      git checkout main 2>/dev/null || true
    fi
  done
fi

# --- Step 6: Analyze external links ---
echo ""
echo "=== Step 6: Analyzing external links ==="

EXTERNAL_ANALYZED=0
EXTERNAL_REVERIFIED=0
EXTERNAL_PROCESSED=0

while IFS= read -r item; do
  [ "$ISSUE_LIMIT" -gt 0 ] && [ "$((PROCESSED + EXTERNAL_PROCESSED))" -ge "$ISSUE_LIMIT" ] && break

  number=$(echo "$item" | jq -r '.number')
  repo=$(echo "$item" | jq -r '.repo')
  broken_url=$(echo "$item" | jq -r '.url')
  source_file=$(echo "$item" | jq -r '.file')

  # Skip issues that already have an open fix PR (don't count toward limit)
  if covering_pr=$(issue_has_open_pr "$repo" "$number" "$source_file" "$broken_url"); then
    echo "  #$number: Open PR #$covering_pr already covers, skipping"
    continue
  fi

  echo "  #$number: Analyzing $broken_url"

  # Re-verify with full redirect follow
  curl_output=$(curl -sL -o /dev/null -w "%{http_code} %{url_effective}" --max-time 10 "$broken_url" 2>/dev/null || echo "000 ")
  final_status=$(echo "$curl_output" | awk '{print $1}')
  final_url=$(echo "$curl_output" | awk '{print $2}')

  if [ "$final_status" = "200" ]; then
    if [ "$final_url" = "$broken_url" ]; then
      # Link resolves at same URL -- close the issue
      echo "    Link now resolves (200 at original URL)"
      if close_issue_if_valid "$repo" "$number" \
        "Link now resolves as of $FIX_DATE. Verified by Link Health Fixer. Closing."; then
        echo "    Issue closed"
      fi
      EXTERNAL_REVERIFIED=$((EXTERNAL_REVERIFIED + 1))
      EXTERNAL_PROCESSED=$((EXTERNAL_PROCESSED + 1))
      sleep 1
      continue
    else
      # Link moved -- report replacement but don't close
      echo "    Link moved (200 at different URL): $final_url"
      redirect_finding="Redirects to: \`$final_url\`"
      suggested_replacement="\`$final_url\` -- this is where the original URL now redirects."
    fi
  else
    echo "    Still broken (HTTP $final_status)"
    redirect_finding="No redirect detected (HTTP $final_status)"
    suggested_replacement=""
  fi

  # Check Wayback Machine
  wayback_url=""
  wayback_date=""
  wayback_json=$(curl -s --max-time 10 "https://web.archive.org/wayback/available?url=$broken_url" 2>/dev/null || echo "{}")
  wayback_url=$(echo "$wayback_json" | jq -r '.archived_snapshots.closest.url // empty' 2>/dev/null || true)
  wayback_date=$(echo "$wayback_json" | jq -r '.archived_snapshots.closest.timestamp // empty' 2>/dev/null || true)

  if [ -n "$wayback_url" ]; then
    # Format timestamp (YYYYMMDDHHMMSS -> YYYY-MM-DD)
    wb_formatted="${wayback_date:0:4}-${wayback_date:4:2}-${wayback_date:6:2}"
    wayback_finding="Archived version available from $wb_formatted: $wayback_url"
    if [ -z "$suggested_replacement" ]; then
      suggested_replacement="\`$wayback_url\` -- archived version from $wb_formatted."
    fi
  else
    wayback_finding="No archived version found"
  fi

  if [ -z "$suggested_replacement" ]; then
    suggested_replacement="No automated replacement found. Manual investigation needed."
  fi

  # Build comment
  comment_body="## External Link Analysis

**URL:** \`$broken_url\`
**Current status:** HTTP $final_status
**Source file:** \`$source_file\`

### Findings
- **Redirect:** $redirect_finding
- **Wayback Machine:** $wayback_finding

### Suggested replacement
$suggested_replacement

---
*Analyzed by OpenClaw Link Health Fixer ($FIX_DATE)*"

  # Post comment
  if gh issue comment "$number" --repo "$repo" --body "$comment_body" 2>/dev/null; then
    echo "    Comment posted"
  else
    echo "    WARN: Failed to comment on issue #$number"
  fi

  # Label unfixable if no redirect and no wayback
  if [ "$final_status" != "200" ] && [ -z "$wayback_url" ]; then
    gh issue edit "$number" --repo "$repo" --add-label "broken-link/unfixable" 2>/dev/null || true
  fi

  EXTERNAL_ANALYZED=$((EXTERNAL_ANALYZED + 1))
  EXTERNAL_PROCESSED=$((EXTERNAL_PROCESSED + 1))
  sleep 1
done < "$EXTERNAL_FILE"

echo "External analyzed: $EXTERNAL_ANALYZED"
echo "External re-verified (now valid): $EXTERNAL_REVERIFIED"

# --- Step 7: Ambiguous items for model ---
AMBIG_COUNT=$(jq 'length' "$AMBIGUOUS_FILE")
if [ "$AMBIG_COUNT" -gt 0 ]; then
  echo ""
  echo "=== Ambiguous items (needs model reasoning) ==="
  echo "Written to: $AMBIGUOUS_FILE"
  jq -r '.[] | "  #\(.issue_number): \(.broken_url) (\(.reason), \(.candidates | length) candidates)"' "$AMBIGUOUS_FILE"
fi

# --- Step 8: Summary ---
echo ""
echo "=== Fixer Run $FIX_DATE Summary ==="
echo "Issues processed: $((PROCESSED + EXTERNAL_PROCESSED))"
echo ""
echo "Internal links:"
echo "  Re-verified (now valid): $REVERIFIED_COUNT"
echo "  Fixes found: $FIXED_COUNT"
echo "  Unfixable: $UNFIXABLE_COUNT"
echo "  Ambiguous (needs model): $AMBIGUOUS_COUNT"
echo ""
echo "External links:"
echo "  Analyzed (commented): $EXTERNAL_ANALYZED"
echo "  Re-verified (now valid): $EXTERNAL_REVERIFIED"
if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "Mode: DRY RUN (no PRs created)"
fi
echo "Duration: ${SECONDS}s"
