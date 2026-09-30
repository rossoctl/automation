#!/usr/bin/env bash
# repoman-index.sh — upsert one program entry into an _index.json program
# registry. RepoMan-agnostic: all inputs are args; last_run is stamped from the
# writer's own clock. jq-only, atomic (temp-then-mv). Reads no ~/.repoman.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: repoman-index.sh --index <path> --program <id> --display-name <name> \
                        --report-path <path> [--dry-run] [--help]

Upserts one program's entry into an _index.json program registry.

Options:
  --index PATH          the _index.json to create/update (required)
  --program ID          program id / object key, e.g. link-health (required)
  --display-name NAME   human section heading, e.g. "Link Health" (required)
  --report-path PATH    report dir for this program (required)
  --dry-run             print the resulting index to stdout, write nothing
  --help                print this help and exit 0

last_run is stamped internally (date -u); it is not an argument.
EOF
}

INDEX="" PROGRAM="" DISPLAY_NAME="" REPORT_PATH="" DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --index)        [ $# -ge 2 ] || { echo "ERROR: --index needs a value" >&2; exit 2; }; INDEX="$2"; shift 2 ;;
    --program)      [ $# -ge 2 ] || { echo "ERROR: --program needs a value" >&2; exit 2; }; PROGRAM="$2"; shift 2 ;;
    --display-name) [ $# -ge 2 ] || { echo "ERROR: --display-name needs a value" >&2; exit 2; }; DISPLAY_NAME="$2"; shift 2 ;;
    --report-path)  [ $# -ge 2 ] || { echo "ERROR: --report-path needs a value" >&2; exit 2; }; REPORT_PATH="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --help)         usage; exit 0 ;;
    *)              echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for pair in "index:$INDEX" "program:$PROGRAM" "display-name:$DISPLAY_NAME" "report-path:$REPORT_PATH"; do
  name="${pair%%:*}"; val="${pair#*:}"
  if [ -z "$val" ]; then echo "ERROR: --$name is required" >&2; usage >&2; exit 2; fi
done

LAST_RUN=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Load the current index (empty object if absent); a present-but-invalid index
# is a hard error, never silently overwritten.
if [ -f "$INDEX" ]; then
  if ! current=$(jq -c . "$INDEX" 2>/dev/null); then
    echo "ERROR: existing index is not valid JSON: $INDEX" >&2
    exit 1
  fi
else
  current='{}'
fi

# Upsert the entry via jq (correct escaping; no echo-splice).
if ! new_index=$(printf '%s' "$current" | jq \
      --arg p "$PROGRAM" --arg dn "$DISPLAY_NAME" \
      --arg rp "$REPORT_PATH" --arg lr "$LAST_RUN" \
      '.[$p] = {display_name: $dn, report_path: $rp, last_run: $lr}'); then
  echo "ERROR: failed to compute updated index for program $PROGRAM" >&2
  exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$new_index"
  exit 0
fi

# Atomic write: temp in the index's dir, then mv.
index_dir=$(dirname "$INDEX")
if ! mkdir -p "$index_dir"; then
  echo "ERROR: cannot create index directory: $index_dir" >&2
  exit 1
fi
tmp="$INDEX.tmp.$$"
if ! printf '%s\n' "$new_index" > "$tmp"; then
  echo "ERROR: failed to write temp index: $tmp" >&2
  exit 1
fi
if ! mv "$tmp" "$INDEX"; then
  echo "ERROR: failed to move temp index into place: $INDEX" >&2
  rm -f "$tmp"
  exit 1
fi
