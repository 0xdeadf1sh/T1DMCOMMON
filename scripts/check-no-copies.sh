#!/usr/bin/env bash
# Detect second copies of the specifications under SPEC/.
#
# A copy is how every divergence in this suite began: correct the day it was
# made, silently wrong later. The specifications are single-copy by design, and
# each consumer keeps a stub pointing here instead. This script looks for a
# sibling file that reproduces one of them.
#
# It works on FINGERPRINTS, not filenames: a handful of sentences distinctive
# enough that no independent document would carry several by accident. A file
# matching THRESHOLD of them is reproducing that specification, whatever it
# happens to be called. Prose is fingerprinted rather than constants, because a
# constant legitimately appears in the code implementing it — a paragraph does
# not.
#
# Usage:  scripts/check-no-copies.sh [sibling-root]     (default: the parent
#         directory, in which the four sibling checkouts are expected)
# Exit:   0 clean, 1 a copy was found, 2 could not run.

set -uo pipefail

ROOT="${1:-..}"
PROJECTS=(T1DMSIM T1DMAI T1DMDROID T1DMSERVER)
THRESHOLD=3

TARGETS=()
for p in "${PROJECTS[@]}"; do
  [ -d "$ROOT/$p" ] && TARGETS+=("$ROOT/$p")
done
[ ${#TARGETS[@]} -eq 0 ] && {
  echo "none of ${PROJECTS[*]} found under $ROOT" >&2; exit 2; }

PATDIR="$(mktemp -d)"
trap 'rm -rf "$PATDIR"' EXIT

# Each spec's fingerprints, one per line, matched as fixed strings.
cat >"$PATDIR/http" <<'EOF'
A server-to-client push stream
the constant tag `t1dm-login`
Every write fans out except the origin
is an opaque store-identity string
carries no record and has no REST counterpart
EOF
cat >"$PATDIR/inference" <<'EOF'
Every tensor lives in exactly one of three spaces
Patch flatten order is step-major
The stored slopes are trained and may be
decodes to a phantom
builds DCT-II cosine modes over the full
EOF
cat >"$PATDIR/invariants" <<'EOF'
on one side and an **amount** on the other
the zero-risk centre moves from roughly
Summing is the invariant; the shape is the meaning
A grid slot with no measurement stores
EOF

# One recursive pass per spec. --include keeps it to text the suite authors;
# --exclude-dir keeps build output, VCS metadata and artifacts out of the walk.
scan() {
  grep -rHoFf "$1" \
    --include='*.md' --include='*.txt' --include='*.rs' --include='*.kt' \
    --include='*.py' --include='*.kts' --include='*.toml' \
    --exclude-dir=.git --exclude-dir=target --exclude-dir=build \
    --exclude-dir=.gradle --exclude-dir=.kotlin --exclude-dir=node_modules \
    --exclude-dir=.venv --exclude-dir=__pycache__ --exclude-dir=data \
    "${TARGETS[@]}" 2>/dev/null | sort -u | cut -d: -f1 | uniq -c
}

fail=0
check_spec() {
  local name="$1" patfile="$2" total found=0
  total=$(wc -l <"$patfile")
  while read -r count file; do
    [ "$count" -ge "$THRESHOLD" ] || continue
    [ $found -eq 0 ] && printf '\n  %s — copies found:\n' "$name"
    printf '    %s (%s/%s fingerprints)\n' "$file" "$count" "$total"
    found=1
    fail=1
  done < <(scan "$patfile")
  [ $found -eq 0 ] && printf '  %-22s no copies\n' "$name"
}

printf 'Checking %s\n\n' "${TARGETS[*]}"
check_spec 'SPEC/http-api.md'   "$PATDIR/http"
check_spec 'SPEC/inference.md'  "$PATDIR/inference"
check_spec 'SPEC/invariants.md' "$PATDIR/invariants"

if [ $fail -ne 0 ]; then
  cat <<'EOF'

A specification has been copied into a sibling repository. Replace the copy with
a stub pointing at the T1DMCOMMON document, folding any genuinely local content
into that stub. If the copy is the newer of the two, amend the specification
here first — the correction belongs in the original, not in the copy.
EOF
  exit 1
fi

printf '\nNo copies. Each specification exists once.\n'
