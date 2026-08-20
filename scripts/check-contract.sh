#!/usr/bin/env bash
# Hold this repository's own contract statements against the checkouts that implement them.
#
# `check-no-copies.sh` scans the four siblings and never reads this repository, so nothing was
# watching the two facts that live HERE and are asserted THERE: the contract version, and the fact
# that the prediction REST routes were withdrawn. Both were correct on the day 0.5.0 landed. That is
# exactly the condition under which a fact stops being watched and starts drifting.
#
# Usage:  scripts/check-contract.sh [sibling-root]     (default: the parent directory)
# Exit:   0 clean, 1 a claim is false, 2 could not run.

set -uo pipefail

ROOT="${1:-..}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
PROJECTS=(T1DMSIM T1DMAI T1DMDROID T1DMSERVER)
fail=0

say()  { printf '  %-46s %s\n' "$1" "$2"; }
bad()  { say "$1" "FAIL — $2"; fail=1; }
ok()   { say "$1" "ok"; }

# ── 1. the version file is one well-formed semver line ────────────────────────
VER_FILE="$HERE/CONTRACT_VERSION"
[ -r "$VER_FILE" ] || { echo "no CONTRACT_VERSION at $VER_FILE" >&2; exit 2; }
VERSION="$(tr -d '[:space:]' <"$VER_FILE")"
if printf '%s' "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  ok "CONTRACT_VERSION is semver ($VERSION)"
else
  bad "CONTRACT_VERSION is semver" "read '$VERSION'"
fi

# ── 2. the contract names that version as the one it describes ────────────────
if grep -qF "$VERSION" "$HERE/SPEC/http-api.md"; then
  ok "SPEC/http-api.md names $VERSION"
else
  bad "SPEC/http-api.md names $VERSION" "the document never mentions it"
fi

# ── 3. no sibling treats a prediction REST route as live ──────────────────────
#
# A forecast is a stream frame at 0.5.0. The server's own suite asserts the withdrawn paths answer
# 404, and a test that names them is the point — so tests are excluded and sources are not.
live=0
for p in "${PROJECTS[@]}"; do
  d="$ROOT/$p"
  [ -d "$d" ] || continue
  hits=$(grep -rlF "/v1/predictions" \
      --include='*.rs' --include='*.kt' --include='*.py' \
      --exclude-dir=.git --exclude-dir=target --exclude-dir=build \
      --exclude-dir=.gradle --exclude-dir=.kotlin --exclude-dir=node_modules \
      --exclude-dir='.venv*' --exclude-dir=site-packages --exclude-dir=__pycache__ \
      "$d" 2>/dev/null | grep -viE '(^|/)(test|tests)[^/]*\.(rs|kt|py)$|/(test|androidTest|tests)/' || true)
  if [ -n "$hits" ]; then
    live=1
    printf '    %s\n' $hits
  fi
done
if [ "$live" -eq 0 ]; then
  ok "no sibling source names a prediction REST route"
else
  bad "no sibling source names a prediction REST route" "listed above"
fi

printf '\n'
if [ $fail -ne 0 ]; then
  cat <<'MSG'
A claim this repository makes is not true of the suite. Fix the claim or fix the code — and if the
wire moved, read skills/shared-contract-change before either.
MSG
  exit 1
fi
echo "Every contract claim this repository makes still holds."
