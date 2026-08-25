---
name: shared-contract-change
description: >-
  MANDATORY before changing anything the T1DM sister repositories share — the HTTP/WebSocket contract
  between T1DMDROID and T1DMSERVER, the five-minute grid, tz_offset, physiologic units or scales,
  either Kovatchev risk space, the curve mathematics, the quantile/circadian forecast layout, the
  statistics definitions, or the model descriptor format. These concepts exist in more than one
  repository, in more than one language, and drift between them is silent — both sides keep working
  and one of them is wrong. Triggers: editing a wire DTO or handler, a serde or kotlinx annotation on
  a wire type, curve.rs, units.rs, stats.rs, KovatchevRisk.kt, GridStamper.kt, the sync module, an
  exporter, or any constant this document names.
---

# Changing something the suite shares

A change is a **shared-contract change** if a second repository would have to
change too for the suite to stay coherent. Those fail differently: nothing
errors, both sides keep transacting, and a number quietly means something else.

Work in order. Do not edit until step 2.

## 1. Establish what is actually changing

Read `SPEC/invariants.md` for the concept, then find **every** implementation of
it. Do not assume there are two — the Kovatchev transform was found in six
places across three repositories and three languages.

Search all four sibling checkouts:

```
rg -n '<the constant, field name, or formula>' ../T1DMSIM ../T1DMAI ../T1DMDROID ../T1DMSERVER
```

List what was found before proceeding. A surprising count is itself the finding;
report it.

## 2. Change the specification first

If `SPEC/` states the rule, amend it there before touching any implementation.
If `SPEC/` does not state it yet, add it. An implementation change that leaves
the spec stale has moved the drift rather than fixed it.

`invariants.md`, `http-api.md` and `inference.md` are **single-copy**. Amend the
original; never bring a copy back into a project, and never paste a changed
section into a consumer's documentation. A project's `docs/` entry is a stub
naming the specification and carrying only what is local to that project.
`scripts/check-no-copies.sh` enforces this.

A change to the wire contract between `T1DMDROID` and `T1DMSERVER` bumps
`CONTRACT_VERSION` in the same commit and says what changed.

Sweep the rest of `T1DMCOMMON` in the same pass: a `PROJECTS/` entry the change
outdates, a known deviation it resolves, an open question it answers. Resolved
entries are **deleted**, not annotated. See *Keeping this repository true* in
`CLAUDE.md`.

## 3. Change the implementations you were asked to change

Write only to the repository you were asked to work in. For every other
repository needing a corresponding change, **report it — do not reach in**.

Consistency within one repository is not optional: applying a unit or scale
change at one call site and not the others is worse than not applying it, because
the two halves then disagree inside a single program.

## 4. Prove it

A test that pins a **number** is worth more than one that pins a shape. If a
convention changed, add a case that fails against the old behaviour, and run it
against the unmodified code to confirm it does.

Where both sides ship golden vectors for one concept, compare them directly. Two
files named `curve_golden.json` in two repositories are either identical in the
scenarios they share or they are evidence of drift.

Then:

```
scripts/check-no-copies.sh
scripts/check-contract.sh
```

## 5. Report the seams you could not close

End with an explicit list: which repositories still need the corresponding
change, which call sites were unreachable, which open questions the change
depends on, and anything in `T1DMCOMMON` left stale — named by file and by claim.

## What does not need this skill

Local refactors, UI text, logging, comments, build configuration, and anything
whose effect stops at the edge of one repository. When in doubt, ask whether a
second repository would have to change too.

One thing still applies: a purely local change that falsifies something written
in `T1DMCOMMON` — a project's gates, its module map, which backends it runs —
owes that correction regardless.
