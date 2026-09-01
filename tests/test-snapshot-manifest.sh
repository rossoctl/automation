#!/usr/bin/env bash
set -euo pipefail

# Verifies snapshot/snapshot-manifest.sh:
#   - writes manifest.json with runtime facts (versions, gateway port, service
#     unit) and per-core-repo git state (name, origin, branch, dirty, unpushed)
#   - reads each repo's origin from the REAL `git remote get-url origin`, never
#     an $ORG-interpolated slug (discussion #62: owner may not equal org)
#   - falls back to empty origin when a clone has no origin remote
#   - generates a human RUNBOOK.md
#   - never leaks secret-shaped content into the manifest
# Hermetic: fake org profile via $ORG_PROFILE_FILE + $CORE_REPOS_FILE, real
# throwaway git clones under a temp $REPOS_DIR, fake openclaw/node on PATH.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_SH="$SCRIPT_DIR/../snapshot/snapshot-manifest.sh"

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT
fail=0

# Fake org profile: ORG=acme, fork owner acmefork.
cat > "$TEST_TMPDIR/org.env" <<'EOF'
PROFILE_ORG=acme
PROFILE_FORK_OWNER=acmefork
PROFILE_REMAP=""
EOF

# Core repo allowlist: two repos.
cat > "$TEST_TMPDIR/core.txt" <<'EOF'
tool-one
tool-two
EOF

# Repos dir with two real git clones.
REPOS_DIR="$TEST_TMPDIR/repos"
mkdir -p "$REPOS_DIR"

# Repo one: origin owned by SOMEONE ELSE (not acme), on a feature branch, dirty.
NONACME_ORIGIN="git@github.com:someone-else/tool-one.git"
git init -q "$REPOS_DIR/tool-one"
(
  cd "$REPOS_DIR/tool-one"
  git config user.email "t@example.com"
  git config user.name "t"
  git remote add origin "$NONACME_ORIGIN"
  echo "hello" > file.txt
  git add file.txt
  git commit -qm "init"
  git checkout -q -b feat/x
  # Leave a dirty working tree.
  echo "changed" >> file.txt
)

# Repo two: NO origin remote -> origin should be recorded as empty.
git init -q "$REPOS_DIR/tool-two"
(
  cd "$REPOS_DIR/tool-two"
  # Pin the branch to 'main' explicitly. A bare `git init` uses the host's
  # init.defaultBranch, which is 'master' on GitHub Actions runners -- the
  # manifest would then record 'master' and the checkout assertion below would
  # fail on CI while passing on a dev box configured for 'main'.
  git checkout -q -b main
  git config user.email "t@example.com"
  git config user.name "t"
  echo "world" > file.txt
  git add file.txt
  git commit -qm "init"
)

# Fake openclaw / node so the version readers resolve.
FAKE_BIN="$TEST_TMPDIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/openclaw" <<'EOF'
#!/usr/bin/env bash
echo "OpenClaw 2026.5.12 (f066dd2)"
EOF
cat > "$FAKE_BIN/node" <<'EOF'
#!/usr/bin/env bash
echo "v22.22.2"
EOF
chmod +x "$FAKE_BIN/openclaw" "$FAKE_BIN/node"

OUTDIR="$TEST_TMPDIR/out"

# Run the manifest generator with all seams pointed at the fixtures.
PATH="$FAKE_BIN:$PATH" \
ORG_PROFILE_FILE="$TEST_TMPDIR/org.env" \
CORE_REPOS_FILE="$TEST_TMPDIR/core.txt" \
REPOS_DIR="$REPOS_DIR" \
GATEWAY_PORT="18789" \
SERVICE_UNIT="openclaw-gateway.service" \
bash "$MANIFEST_SH" --outdir "$OUTDIR"

MANIFEST="$OUTDIR/manifest.json"

# The manifest file must exist and be valid JSON.
if [ ! -f "$MANIFEST" ]; then
  echo "FAIL manifest: $MANIFEST not created"
  fail=1
elif ! jq empty "$MANIFEST" 2>/dev/null; then
  echo "FAIL manifest: not valid JSON"
  fail=1
fi

# Runtime facts must match the fixtures.
if [ -f "$MANIFEST" ]; then
  got_ver=$(jq -r '.openclawVersion' "$MANIFEST")
  if [ "$got_ver" != "2026.5.12" ]; then
    echo "FAIL manifest: openclawVersion got [$got_ver]"
    fail=1
  fi

  got_node=$(jq -r '.nodeVersion' "$MANIFEST")
  if [ "$got_node" != "v22.22.2" ]; then
    echo "FAIL manifest: nodeVersion got [$got_node]"
    fail=1
  fi

  got_port=$(jq -r '.gatewayPort' "$MANIFEST")
  if [ "$got_port" != "18789" ]; then
    echo "FAIL manifest: gatewayPort got [$got_port]"
    fail=1
  fi

  got_unit=$(jq -r '.serviceUnit' "$MANIFEST")
  if [ "$got_unit" != "openclaw-gateway.service" ]; then
    echo "FAIL manifest: serviceUnit got [$got_unit]"
    fail=1
  fi

  # tool-one: origin must be the REAL non-acme remote, on feat/x, dirty=true.
  one_origin=$(jq -r '.repos[] | select(.name=="tool-one") | .origin' "$MANIFEST")
  if [ "$one_origin" != "$NONACME_ORIGIN" ]; then
    echo "FAIL manifest: tool-one origin got [$one_origin], want [$NONACME_ORIGIN]"
    fail=1
  fi

  one_branch=$(jq -r '.repos[] | select(.name=="tool-one") | .branch' "$MANIFEST")
  if [ "$one_branch" != "feat/x" ]; then
    echo "FAIL manifest: tool-one branch got [$one_branch]"
    fail=1
  fi

  one_dirty=$(jq -r '.repos[] | select(.name=="tool-one") | .dirty' "$MANIFEST")
  if [ "$one_dirty" != "true" ]; then
    echo "FAIL manifest: tool-one dirty got [$one_dirty], want true"
    fail=1
  fi

  # origin must never be an $ORG-interpolated slug.
  if jq -r '.repos[].origin' "$MANIFEST" | grep -Fq "acme/tool-one"; then
    echo "FAIL manifest: origin was ORG-interpolated (acme/tool-one) instead of real remote"
    fail=1
  fi

  # tool-two: no origin remote -> empty origin string.
  two_origin=$(jq -r '.repos[] | select(.name=="tool-two") | .origin' "$MANIFEST")
  if [ -n "$two_origin" ]; then
    echo "FAIL manifest: tool-two origin should be empty, got [$two_origin]"
    fail=1
  fi
fi

# RUNBOOK.md must be generated.
if [ ! -f "$OUTDIR/RUNBOOK.md" ]; then
  echo "FAIL manifest: RUNBOOK.md not created"
  fail=1
fi

# RUNBOOK content: the real-origin repo must show its remote and branch.
if [ -f "$OUTDIR/RUNBOOK.md" ]; then
  if ! grep -Fq "$NONACME_ORIGIN" "$OUTDIR/RUNBOOK.md"; then
    echo "FAIL runbook: tool-one origin not present in runbook"
    fail=1
  fi
  if ! grep -Fq 'checkout `feat/x`' "$OUTDIR/RUNBOOK.md"; then
    echo "FAIL runbook: tool-one branch not present in runbook"
    fail=1
  fi

  # The empty-origin repo must render the fallback note, NOT a shifted/garbled
  # line (guards the TSV empty-field pitfall).
  if ! grep -Fq 'no origin recorded' "$OUTDIR/RUNBOOK.md"; then
    echo "FAIL runbook: empty-origin fallback note missing for tool-two"
    fail=1
  fi
  if ! grep -Fq 'checkout `main`' "$OUTDIR/RUNBOOK.md"; then
    echo "FAIL runbook: tool-two branch garbled (expected checkout main)"
    fail=1
  fi
fi

# Guard against secret-shaped leakage into the manifest.
if [ -f "$MANIFEST" ] && grep -Eiq 'authToken|BEGIN [A-Z]* ?PRIVATE KEY|_pat|password=' "$MANIFEST"; then
  echo "FAIL manifest: secret-shaped content leaked into manifest"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: snapshot-manifest (runtime facts, real-origin per repo, runbook)"
else
  exit 1
fi
