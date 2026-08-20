#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Weekly Report (core-scoped)
# Resolves the org and the curated core-repo allowlist via the shared library,
# then invokes the Python report generator scoped to exactly those repos.
#
# Usage:
#   bash weekly-report.sh --help
#   bash weekly-report.sh --output /tmp/report.md --json-output /tmp/report-data.json
#   bash weekly-report.sh --org rossoctl --since 2026-08-10 --until 2026-08-17
# =============================================================================

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"

# --- CLI args ---
SINCE=""
UNTIL=""
OUTPUT=""
JSON_OUTPUT=""
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --since) SINCE="$2"; shift 2 ;;
    --until) UNTIL="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --json-output) JSON_OUTPUT="$2"; shift 2 ;;
    --profile) PROFILE_FLAG="$2"; shift 2 ;;
    --org) ORG_FLAG="$2"; shift 2 ;;
    --help|-h) SHOW_HELP=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  cat << 'USAGE'
weekly-report -- Generate the weekly org report scoped to the core repos

USAGE:
  weekly-report.sh [OPTIONS]

OPTIONS:
  --since DATE       Start of reporting window (YYYY-MM-DD; default: 7 days ago)
  --until DATE       End of reporting window (YYYY-MM-DD; default: today)
  --output FILE      Write the Markdown report to FILE (default: stdout)
  --json-output FILE Write structured JSON for AI synthesis to FILE
  --profile NAME     Org profile to load (config/org.<name>.env; default org.env)
  --org NAME         GitHub org (default: from profile, config/org.env)
  --help, -h         Show this help

ENVIRONMENT:
  REPORT_PY          Path to report.py (default: the deployed report generator)

PREREQUISITES:
  python3, gh (authenticated). The core-repo list comes from config/core-repos.txt
  via the shared library (get_core_repos).
USAGE
  exit 0
fi

# Resolve org identity (sets ORG, honoring --org/--profile/env/profile precedence).
load_org_profile

# The curated allowlist, owner-qualified (e.g. rossoctl/operator), one per line.
repos="$(get_core_repos)"
if [ -z "$repos" ]; then
  echo "Error: get_core_repos returned no repos" >&2
  exit 1
fi

# Locate the generator. Default points at the deployed github-weekly-report skill
# (the upstream skill name in agent-skills); override with REPORT_PY in dev.
REPORT_PY="${REPORT_PY:-$HOME/workspaces/shared/skills/github-weekly-report/scripts/report.py}"
if [ ! -f "$REPORT_PY" ]; then
  echo "Error: report generator not found at: $REPORT_PY" >&2
  echo "Set REPORT_PY to the path of report.py." >&2
  exit 1
fi

# Build args. $repos is intentionally unquoted so each line becomes a separate
# --repos value; core repo names never contain whitespace.
# shellcheck disable=SC2086
set -- --org "$ORG" --repos $repos
[ -n "$SINCE" ] && set -- "$@" --since "$SINCE"
[ -n "$UNTIL" ] && set -- "$@" --until "$UNTIL"
[ -n "$OUTPUT" ] && set -- "$@" --output "$OUTPUT"
[ -n "$JSON_OUTPUT" ] && set -- "$@" --json-output "$JSON_OUTPUT"

exec python3 "$REPORT_PY" "$@"
