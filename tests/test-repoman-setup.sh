#!/usr/bin/env bash
set -euo pipefail

# Verifies scripts/repoman-setup.sh, the pure-writer side of the RepoMan
# input model (Phase 2): init-config, add-repo, enable-program, set-output.
#   - non-interactive: no gh calls, no prompts, no clone, no fork
#   - atomic writes: a rejected write never touches the target file
#   - every write round-trips through the Phase 1 reader (program-lib.sh)
# Hermetic: drives the script via $REPOMAN_CONFIG_FILE / $REPOMAN_REPOS_FILE /
# $REPOMAN_PROGRAMS_DIR pointing at a temp dir.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP="$SCRIPT_DIR/../scripts/repoman-setup.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../scripts/program-lib.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

# =============================================================================
# Task 1: skeleton, --help, dispatch
# =============================================================================

out=$(bash "$SETUP" --help)
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL --help should exit 0"; fail=1; }
printf '%s\n' "$out" | grep -q "init-config" \
  || { echo "FAIL --help should mention init-config"; fail=1; }

if bash "$SETUP" bogus >/dev/null 2>&1; then
  echo "FAIL unknown subcommand 'bogus' should exit non-zero"; fail=1
fi

# =============================================================================
# Task 2: init-config
# =============================================================================

CFG="$TEST_TMPDIR/config.json"
REPOS_DIR_FIXTURE="$TEST_TMPDIR/repos"
mkdir -p "$REPOS_DIR_FIXTURE"

# --- happy path: writes both keys, round-trips through repoman_config ---
REPOMAN_CONFIG_FILE="$CFG" bash "$SETUP" init-config \
  --repos-dir "$REPOS_DIR_FIXTURE" --fork-owner alice \
  || { echo "FAIL init-config happy path should exit 0"; fail=1; }
[ -f "$CFG" ] || { echo "FAIL init-config should create $CFG"; fail=1; }

got=$(
  REPOMAN_CONFIG_FILE="$CFG"; repoman_config >/dev/null 2>&1
  echo "$REPOS_DIR|$FORK_OWNER"
)
[ "$got" = "$REPOS_DIR_FIXTURE|alice" ] \
  || { echo "FAIL init-config round-trip: got [$got]"; fail=1; }

# --- rejects empty --fork-owner, writes nothing ---
rm -f "$CFG"
if REPOMAN_CONFIG_FILE="$CFG" bash "$SETUP" init-config \
     --repos-dir "$REPOS_DIR_FIXTURE" --fork-owner "" >/dev/null 2>&1; then
  echo "FAIL init-config should reject empty --fork-owner"; fail=1
fi
[ -f "$CFG" ] && { echo "FAIL init-config empty fork-owner must write nothing"; fail=1; }

# --- rejects empty --repos-dir, writes nothing ---
rm -f "$CFG"
if REPOMAN_CONFIG_FILE="$CFG" bash "$SETUP" init-config \
     --repos-dir "" --fork-owner alice >/dev/null 2>&1; then
  echo "FAIL init-config should reject empty --repos-dir"; fail=1
fi
[ -f "$CFG" ] && { echo "FAIL init-config empty repos-dir must write nothing"; fail=1; }

# --- missing value for a trailing flag fails LOUDLY (shift-2 regression guard) ---
rm -f "$CFG"
err=$(REPOMAN_CONFIG_FILE="$CFG" bash "$SETUP" init-config --repos-dir 2>&1) \
  && { echo "FAIL init-config should reject a trailing --repos-dir with no value"; fail=1; }
case "$err" in
  *"--repos-dir requires a value"*) ;;
  *) echo "FAIL init-config trailing --repos-dir should explain itself, got: [$err]"; fail=1 ;;
esac
[ -f "$CFG" ] && { echo "FAIL init-config missing repos-dir value must write nothing"; fail=1; }

rm -f "$CFG"
err=$(REPOMAN_CONFIG_FILE="$CFG" bash "$SETUP" init-config \
       --repos-dir "$REPOS_DIR_FIXTURE" --fork-owner 2>&1) \
  && { echo "FAIL init-config should reject a trailing --fork-owner with no value"; fail=1; }
case "$err" in
  *"--fork-owner requires a value"*) ;;
  *) echo "FAIL init-config trailing --fork-owner should explain itself, got: [$err]"; fail=1 ;;
esac
[ -f "$CFG" ] && { echo "FAIL init-config missing fork-owner value must write nothing"; fail=1; }

# --- rejects a dangerous repos_dir via validate_repos_dir, writes nothing; ---
# --- the error names --repos-dir (the flag the user typed), not REPOS_DIR ---
rm -f "$CFG"
err=$(REPOMAN_CONFIG_FILE="$CFG" bash "$SETUP" init-config \
       --repos-dir "/etc" --fork-owner alice 2>&1) \
  && { echo "FAIL init-config should reject dangerous repos-dir (/etc)"; fail=1; }
case "$err" in
  *"--repos-dir cannot be"*) ;;
  *) echo "FAIL init-config dangerous repos-dir should name --repos-dir, got: [$err]"; fail=1 ;;
esac
[ -f "$CFG" ] && { echo "FAIL init-config dangerous repos-dir must write nothing"; fail=1; }

# --- leading ~ expands the same way the reader expands it ---
# Use a fake $HOME so validate_repos_dir's existence check (and the writer's
# own expansion) never touches the real machine's home directory.
rm -f "$CFG"
FAKE_HOME="$TEST_TMPDIR/fake-home"
mkdir -p "$FAKE_HOME/repoman/repos"
HOME="$FAKE_HOME" REPOMAN_CONFIG_FILE="$CFG" bash "$SETUP" init-config \
  --repos-dir '~/repoman/repos' --fork-owner alice \
  || { echo "FAIL init-config tilde path should exit 0"; fail=1; }
got=$(
  HOME="$FAKE_HOME" REPOMAN_CONFIG_FILE="$CFG" repoman_config >/dev/null 2>&1
  echo "$REPOS_DIR"
)
[ "$got" = "$FAKE_HOME/repoman/repos" ] \
  || { echo "FAIL init-config tilde expansion: got [$got]"; fail=1; }

# --- idempotent overwrite ---
REPOMAN_CONFIG_FILE="$CFG" bash "$SETUP" init-config \
  --repos-dir "$REPOS_DIR_FIXTURE" --fork-owner bob \
  || { echo "FAIL init-config overwrite should exit 0"; fail=1; }
got=$(
  REPOMAN_CONFIG_FILE="$CFG"; repoman_config >/dev/null 2>&1
  echo "$REPOS_DIR|$FORK_OWNER"
)
[ "$got" = "$REPOS_DIR_FIXTURE|bob" ] \
  || { echo "FAIL init-config overwrite: got [$got]"; fail=1; }

# =============================================================================
# Task 3: add-repo
# =============================================================================

REPOS_FILE="$TEST_TMPDIR/repos.json"

# --- single repo into an absent file ---
rm -f "$REPOS_FILE"
REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo \
  --owner rossoctl --name automation \
  || { echo "FAIL add-repo single should exit 0"; fail=1; }
got=$(REPOMAN_REPOS_FILE="$REPOS_FILE" repoman_get_repos)
[ "$got" = "rossoctl/automation" ] \
  || { echo "FAIL add-repo single round-trip: got [$got]"; fail=1; }

# --- atomic_write leaves no .repoman-setup.* temp file behind on success ---
# The write goes to a temp file in the target dir, then mv consumes it; the
# RETURN-trap cleanup must not fire early or leave litter on the happy path.
leftover=$(find "$(dirname "$REPOS_FILE")" -name '.repoman-setup.*' 2>/dev/null)
[ -z "$leftover" ] \
  || { echo "FAIL atomic_write left a temp file behind: [$leftover]"; fail=1; }

# --- repeated flags, in order ---
rm -f "$REPOS_FILE"
REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo \
  --owner a --name x --owner b --name y \
  || { echo "FAIL add-repo repeated flags should exit 0"; fail=1; }
got=$(REPOMAN_REPOS_FILE="$REPOS_FILE" repoman_get_repos)
want=$'a/x\nb/y'
[ "$got" = "$want" ] \
  || { echo "FAIL add-repo repeated flags order: got [$got] want [$want]"; fail=1; }

# --- stdin array ---
rm -f "$REPOS_FILE"
echo '[{"owner":"alice","name":"cortex"}]' \
  | REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo \
  || { echo "FAIL add-repo stdin array should exit 0"; fail=1; }
got=$(REPOMAN_REPOS_FILE="$REPOS_FILE" repoman_get_repos)
[ "$got" = "alice/cortex" ] \
  || { echo "FAIL add-repo stdin round-trip: got [$got]"; fail=1; }

# --- dedup: adding the same owner/name twice yields one entry ---
rm -f "$REPOS_FILE"
REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo --owner rossoctl --name automation
REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo --owner rossoctl --name automation
got=$(REPOMAN_REPOS_FILE="$REPOS_FILE" repoman_get_repos)
[ "$got" = "rossoctl/automation" ] \
  || { echo "FAIL add-repo dedup: got [$got]"; fail=1; }

# --- same-name-different-owner: both persist, distinct ---
rm -f "$REPOS_FILE"
REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo --owner rossoctl --name cortex
REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo --owner alice --name cortex
got=$(REPOMAN_REPOS_FILE="$REPOS_FILE" repoman_get_repos)
want=$'rossoctl/cortex\nalice/cortex'
[ "$got" = "$want" ] \
  || { echo "FAIL add-repo same-name-diff-owner: got [$got] want [$want]"; fail=1; }

# --- rejects empty owner, file unchanged ---
rm -f "$REPOS_FILE"
REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo --owner rossoctl --name automation
cp "$REPOS_FILE" "$TEST_TMPDIR/repos-before.json"
if REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo --owner "" --name x >/dev/null 2>&1; then
  echo "FAIL add-repo should reject empty owner"; fail=1
fi
diff -q "$REPOS_FILE" "$TEST_TMPDIR/repos-before.json" >/dev/null \
  || { echo "FAIL add-repo empty owner must leave file unchanged"; fail=1; }

# --- rejects empty name, file unchanged ---
if REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo --owner a --name "" >/dev/null 2>&1; then
  echo "FAIL add-repo should reject empty name"; fail=1
fi
diff -q "$REPOS_FILE" "$TEST_TMPDIR/repos-before.json" >/dev/null \
  || { echo "FAIL add-repo empty name must leave file unchanged"; fail=1; }

# --- rejects a trailing --owner with no following --name, file unchanged, ---
# --- with a message specific to the unconsumed owner (not the empty-set one) ---
err=$(REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo --owner a 2>&1) \
  && { echo "FAIL add-repo should reject a trailing --owner with no --name"; fail=1; }
case "$err" in
  *"--owner given without a following --name"*) ;;
  *) echo "FAIL add-repo trailing --owner should report the specific error, got: [$err]"; fail=1 ;;
esac
diff -q "$REPOS_FILE" "$TEST_TMPDIR/repos-before.json" >/dev/null \
  || { echo "FAIL add-repo trailing --owner must leave file unchanged"; fail=1; }

# --- rejects an empty resolved set: '[]' on stdin, file unchanged (or absent) ---
if echo '[]' | REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo >/dev/null 2>&1; then
  echo "FAIL add-repo should reject an empty JSON array on stdin"; fail=1
fi
diff -q "$REPOS_FILE" "$TEST_TMPDIR/repos-before.json" >/dev/null \
  || { echo "FAIL add-repo empty stdin array must leave file unchanged"; fail=1; }

# --- rejects an empty resolved set on an ABSENT file too (nothing gets created) ---
rm -f "$TEST_TMPDIR/absent-repos.json"
if echo '[]' | REPOMAN_REPOS_FILE="$TEST_TMPDIR/absent-repos.json" bash "$SETUP" add-repo >/dev/null 2>&1; then
  echo "FAIL add-repo should reject an empty JSON array on stdin (absent file)"; fail=1
fi
[ -f "$TEST_TMPDIR/absent-repos.json" ] \
  && { echo "FAIL add-repo empty stdin array must not create the repos file"; fail=1; }

# --- trailing --name with no value fails LOUDLY, file unchanged ---
# Regression guard: `shift 2` on a last-arg flag used to abort under set -e
# with no output at all, so a silent exit-1 satisfied "fails cleanly". Assert
# the message, not just the exit code, or a return to silence goes unnoticed.
err=$(REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo --owner a --name 2>&1) \
  && { echo "FAIL add-repo should reject a trailing --name with no value"; fail=1; }
case "$err" in
  *"--name requires a value"*) ;;
  *) echo "FAIL add-repo trailing --name should explain itself, got: [$err]"; fail=1 ;;
esac
diff -q "$REPOS_FILE" "$TEST_TMPDIR/repos-before.json" >/dev/null \
  || { echo "FAIL add-repo trailing --name with no value must leave file unchanged"; fail=1; }

# --- trailing --owner with no value fails LOUDLY (distinct from the trailing
# --- --owner-with-no-following-*--name* case, which is a mis-ordering, not a
# --- missing value): here --owner is literally the last token ---
err=$(REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo --owner rossoctl --name automation --owner 2>&1) \
  && { echo "FAIL add-repo should reject a trailing --owner with no value"; fail=1; }
case "$err" in
  *"--owner requires a value"*) ;;
  *) echo "FAIL add-repo trailing --owner (no value) should explain itself, got: [$err]"; fail=1 ;;
esac

# --- a second --owner before its --name is rejected loudly, file unchanged ---
# `--owner alice --owner bob --name repo` would otherwise silently pair bob/repo
# and drop alice; a mis-ordered flag set must fail, not guess.
if REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo \
     --owner alice --owner bob --name repo >/dev/null 2>&1; then
  echo "FAIL add-repo should reject a second --owner before its --name"; fail=1
fi
diff -q "$REPOS_FILE" "$TEST_TMPDIR/repos-before.json" >/dev/null \
  || { echo "FAIL add-repo double --owner must leave file unchanged"; fail=1; }

# --- a --name with no preceding --owner is rejected, file unchanged ---
if REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo --name repo >/dev/null 2>&1; then
  echo "FAIL add-repo should reject a --name with no preceding --owner"; fail=1
fi
diff -q "$REPOS_FILE" "$TEST_TMPDIR/repos-before.json" >/dev/null \
  || { echo "FAIL add-repo lone --name must leave file unchanged"; fail=1; }

# --- single-call dedup spans existing+new: pre-seed then add the same repo again ---
rm -f "$REPOS_FILE"
REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo --owner rossoctl --name automation
REPOMAN_REPOS_FILE="$REPOS_FILE" bash "$SETUP" add-repo --owner rossoctl --name automation \
  || { echo "FAIL add-repo single-call dedup call should exit 0"; fail=1; }
got=$(REPOMAN_REPOS_FILE="$REPOS_FILE" repoman_get_repos)
[ "$got" = "rossoctl/automation" ] \
  || { echo "FAIL add-repo single-call dedup against existing file: got [$got]"; fail=1; }

# =============================================================================
# Task 4: enable-program
# =============================================================================

PROGRAMS_DIR="$TEST_TMPDIR/programs"

# --- happy path: creates the dir + file with enabled:true ---
rm -rf "$PROGRAMS_DIR"
REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" enable-program --program link-health \
  || { echo "FAIL enable-program happy path should exit 0"; fail=1; }
[ -f "$PROGRAMS_DIR/link-health.json" ] \
  || { echo "FAIL enable-program should create link-health.json"; fail=1; }
enabled=$(jq -r '.enabled' "$PROGRAMS_DIR/link-health.json")
[ "$enabled" = "true" ] \
  || { echo "FAIL enable-program: .enabled got [$enabled]"; fail=1; }

# --- rejects unknown program name, writes nothing ---
rm -rf "$PROGRAMS_DIR"
if REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" enable-program --program lnik-health >/dev/null 2>&1; then
  echo "FAIL enable-program should reject unknown program name"; fail=1
fi
[ -f "$PROGRAMS_DIR/lnik-health.json" ] && { echo "FAIL enable-program unknown name must write nothing"; fail=1; }

# --- merge: pre-existing output_repo survives enabled:true write ---
rm -rf "$PROGRAMS_DIR"
mkdir -p "$PROGRAMS_DIR"
echo '{"output_repo":{"mode":"same"}}' > "$PROGRAMS_DIR/link-health.json"
REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" enable-program --program link-health \
  || { echo "FAIL enable-program merge call should exit 0"; fail=1; }
enabled=$(jq -r '.enabled' "$PROGRAMS_DIR/link-health.json")
mode=$(jq -r '.output_repo.mode' "$PROGRAMS_DIR/link-health.json")
[ "$enabled" = "true" ] && [ "$mode" = "same" ] \
  || { echo "FAIL enable-program merge: enabled=[$enabled] mode=[$mode]"; fail=1; }

# --- missing value for --program fails LOUDLY (shift-2 regression guard) ---
rm -rf "$PROGRAMS_DIR"
err=$(REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" enable-program --program 2>&1) \
  && { echo "FAIL enable-program should reject a trailing --program with no value"; fail=1; }
case "$err" in
  *"--program requires a value"*) ;;
  *) echo "FAIL enable-program trailing --program should explain itself, got: [$err]"; fail=1 ;;
esac

# =============================================================================
# Task 5: set-output
# =============================================================================

# --- same mode: no .repo key ---
rm -rf "$PROGRAMS_DIR"
REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-output --program link-health --mode same \
  || { echo "FAIL set-output same mode should exit 0"; fail=1; }
mode=$(jq -r '.output_repo.mode' "$PROGRAMS_DIR/link-health.json")
hasrepo=$(jq -r 'has("repo")' <<< "$(jq '.output_repo' "$PROGRAMS_DIR/link-health.json")")
[ "$mode" = "same" ] || { echo "FAIL set-output same: mode got [$mode]"; fail=1; }
[ "$hasrepo" = "false" ] || { echo "FAIL set-output same: unexpected .repo key present"; fail=1; }

# --- central mode with --repo ---
rm -rf "$PROGRAMS_DIR"
REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-output \
  --program link-health --mode central --repo rossoctl/triage \
  || { echo "FAIL set-output central mode should exit 0"; fail=1; }
got=$(jq -c '.output_repo' "$PROGRAMS_DIR/link-health.json")
want='{"mode":"central","repo":"rossoctl/triage"}'
[ "$got" = "$want" ] \
  || { echo "FAIL set-output central: got [$got] want [$want]"; fail=1; }

# --- central without --repo: rejected ---
rm -rf "$PROGRAMS_DIR"
if REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-output --program link-health --mode central >/dev/null 2>&1; then
  echo "FAIL set-output central without --repo should be rejected"; fail=1
fi
[ -f "$PROGRAMS_DIR/link-health.json" ] && { echo "FAIL set-output central-no-repo must write nothing"; fail=1; }

# --- invalid mode: rejected ---
rm -rf "$PROGRAMS_DIR"
if REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-output --program link-health --mode bogus >/dev/null 2>&1; then
  echo "FAIL set-output invalid mode should be rejected"; fail=1
fi

# --- --repo not a slug (no slash) with central: rejected ---
rm -rf "$PROGRAMS_DIR"
if REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-output \
     --program link-health --mode central --repo not-a-slug >/dev/null 2>&1; then
  echo "FAIL set-output should reject --repo without a slash"; fail=1
fi

# --- --repo with TWO slashes (not exactly owner/name) with central: rejected, nothing written ---
rm -rf "$PROGRAMS_DIR"
if REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-output \
     --program link-health --mode central --repo a/b/c >/dev/null 2>&1; then
  echo "FAIL set-output should reject --repo with more than one slash (a/b/c)"; fail=1
fi
[ -f "$PROGRAMS_DIR/link-health.json" ] \
  && { echo "FAIL set-output two-slash --repo must write nothing"; fail=1; }

# --- merge preserves enabled ---
rm -rf "$PROGRAMS_DIR"
mkdir -p "$PROGRAMS_DIR"
echo '{"enabled":true}' > "$PROGRAMS_DIR/link-health.json"
REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-output --program link-health --mode same \
  || { echo "FAIL set-output merge call should exit 0"; fail=1; }
enabled=$(jq -r '.enabled' "$PROGRAMS_DIR/link-health.json")
mode=$(jq -r '.output_repo.mode' "$PROGRAMS_DIR/link-health.json")
[ "$enabled" = "true" ] && [ "$mode" = "same" ] \
  || { echo "FAIL set-output merge: enabled=[$enabled] mode=[$mode]"; fail=1; }

# --- unknown program name: rejected (same allowlist) ---
rm -rf "$PROGRAMS_DIR"
if REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-output --program lnik-health --mode same >/dev/null 2>&1; then
  echo "FAIL set-output should reject unknown program name"; fail=1
fi

# --- missing value for a trailing flag fails LOUDLY (shift-2 regression guard) ---
rm -rf "$PROGRAMS_DIR"
err=$(REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-output --program 2>&1) \
  && { echo "FAIL set-output should reject a trailing --program with no value"; fail=1; }
case "$err" in
  *"--program requires a value"*) ;;
  *) echo "FAIL set-output trailing --program should explain itself, got: [$err]"; fail=1 ;;
esac
err=$(REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-output --program link-health --mode 2>&1) \
  && { echo "FAIL set-output should reject a trailing --mode with no value"; fail=1; }
case "$err" in
  *"--mode requires a value"*) ;;
  *) echo "FAIL set-output trailing --mode should explain itself, got: [$err]"; fail=1 ;;
esac
err=$(REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-output --program link-health --mode central --repo 2>&1) \
  && { echo "FAIL set-output should reject a trailing --repo with no value"; fail=1; }
case "$err" in
  *"--repo requires a value"*) ;;
  *) echo "FAIL set-output trailing --repo should explain itself, got: [$err]"; fail=1 ;;
esac

# =============================================================================
# Task 6 (Phase 3): set-requirements
# =============================================================================

# --- happy path: writes all three arrays, merges over enabled ---
rm -rf "$PROGRAMS_DIR"; mkdir -p "$PROGRAMS_DIR"
echo '{"enabled":true}' > "$PROGRAMS_DIR/pr-review.json"
REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-requirements \
  --program pr-review --pat-scopes repo \
  --labels-required ready-for-ai-review --labels-applied "needs-changes,approved" \
  || { echo "FAIL set-requirements happy path should exit 0"; fail=1; }
got=$(jq -c '{e:.enabled,ps:.pat_scopes,lr:.labels_required,la:.labels_applied}' "$PROGRAMS_DIR/pr-review.json")
want=$(jq -c -n '{e:true,ps:["repo"],lr:["ready-for-ai-review"],la:["needs-changes","approved"]}')
[ "$got" = "$want" ] || { echo "FAIL set-requirements merge: got [$got] want [$want]"; fail=1; }

# --- empty CSV yields [] ---
rm -rf "$PROGRAMS_DIR"
REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-requirements \
  --program link-health --pat-scopes repo --labels-required "" --labels-applied "" \
  || { echo "FAIL set-requirements empty CSV should exit 0"; fail=1; }
lr=$(jq -c '.labels_required' "$PROGRAMS_DIR/link-health.json")
[ "$lr" = '[]' ] || { echo "FAIL set-requirements empty CSV should be []: got [$lr]"; fail=1; }

# --- only --program: all arrays default to [] ---
rm -rf "$PROGRAMS_DIR"
REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-requirements --program dep-bump \
  || { echo "FAIL set-requirements program-only should exit 0"; fail=1; }
got=$(jq -cS '{ps:.pat_scopes,lr:.labels_required,la:.labels_applied}' "$PROGRAMS_DIR/dep-bump.json")
[ "$got" = '{"la":[],"lr":[],"ps":[]}' ] || { echo "FAIL set-requirements defaults: got [$got]"; fail=1; }

# --- unknown program rejected, nothing written ---
rm -rf "$PROGRAMS_DIR"
if REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-requirements --program lnik-health --pat-scopes repo >/dev/null 2>&1; then
  echo "FAIL set-requirements should reject unknown program"; fail=1
fi
[ -f "$PROGRAMS_DIR/lnik-health.json" ] && { echo "FAIL set-requirements unknown program must write nothing"; fail=1; }

# --- missing --program rejected ---
rm -rf "$PROGRAMS_DIR"
if REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-requirements --pat-scopes repo >/dev/null 2>&1; then
  echo "FAIL set-requirements should require --program"; fail=1
fi

# --- trailing flag with no value fails LOUDLY (shift-2 regression guard) ---
rm -rf "$PROGRAMS_DIR"
err=$(REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-requirements --program pr-review --pat-scopes 2>&1) \
  && { echo "FAIL set-requirements should reject a trailing --pat-scopes with no value"; fail=1; }
case "$err" in
  *"--pat-scopes requires a value"*) ;;
  *) echo "FAIL set-requirements trailing --pat-scopes should explain itself, got: [$err]"; fail=1 ;;
esac
[ -f "$PROGRAMS_DIR/pr-review.json" ] && { echo "FAIL set-requirements trailing --pat-scopes must write nothing"; fail=1; }

# --- set-requirements after enable-program + set-output preserves all prior keys ---
rm -rf "$PROGRAMS_DIR"
REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" enable-program --program pr-review
REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-output --program pr-review --mode same
REPOMAN_PROGRAMS_DIR="$PROGRAMS_DIR" bash "$SETUP" set-requirements --program pr-review --pat-scopes repo --labels-required ready-for-ai-review
got=$(jq -cS '{e:.enabled,m:.output_repo.mode,ps:.pat_scopes,lr:.labels_required}' "$PROGRAMS_DIR/pr-review.json")
want=$(jq -cS -n '{e:true,m:"same",ps:["repo"],lr:["ready-for-ai-review"]}')
[ "$got" = "$want" ] || { echo "FAIL set-requirements full-merge: got [$got] want [$want]"; fail=1; }

[ "$fail" -eq 0 ] \
  && echo "PASS: repoman-setup.sh (init-config, add-repo, enable-program, set-output, set-requirements)" \
  || exit 1
