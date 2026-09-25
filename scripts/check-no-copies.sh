#!/usr/bin/env bash
# Fingerprint scan for copies of SPEC/ in the sibling checkouts. Exit 0 clean, 1 copy, 2 no run.

set -uo pipefail

ROOT="${1:-..}"
PROJECTS=(T1DMSIM T1DMAI T1DMDROID T1DMKDE)
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
cat >"$PATDIR/inference" <<'EOF'
Every tensor lives in exactly one of three spaces
Patch flatten order is step-major
Position enters through RoPE alone
the masked set is announced, never inferred
Every node sits at its patch centre
EOF
cat >"$PATDIR/invariants" <<'EOF'
on one side and an **amount** on the other
the zero-risk centre moves from roughly
Summing is the invariant; the shape is the meaning
A grid slot with no measurement stores
EOF
cat >"$PATDIR/cache" <<'EOF'
It moves the warm-up, never the simulator clock
arm 0 is bit-identical to an untouched
What the model sees is the patient's record, not the physiology
is never rejected, whatever it does
geometry is in the cache, not in a constant the reader holds
EOF
cat >"$PATDIR/watch" <<'EOF'
minted once per peripheral, stable across pairings
only after its own user confirms; the keys go live on that
that no central drives; a peripheral does not implement it
slot it covers, empty ones included
are unauthenticated, so none touches a key. The central drops the connection
EOF

# One recursive pass per spec. --include keeps it to text the suite authors;
# --exclude-dir keeps build output, VCS metadata and artifacts out of the walk.
scan() {
  grep -rHoFf "$1" \
    --include='*.md' --include='*.txt' --include='*.rs' --include='*.kt' \
    --include='*.py' --include='*.kts' --include='*.toml' --include='*.qml' \
    --exclude-dir=.git --exclude-dir=target --exclude-dir=build \
    --exclude-dir=.gradle --exclude-dir=.kotlin --exclude-dir=node_modules \
    --exclude-dir=.venv --exclude-dir=__pycache__ \
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
check_spec 'SPEC/inference.md'  "$PATDIR/inference"
check_spec 'SPEC/invariants.md' "$PATDIR/invariants"
check_spec 'SPEC/cache.md'      "$PATDIR/cache"
check_spec 'SPEC/watch.md'      "$PATDIR/watch"

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
