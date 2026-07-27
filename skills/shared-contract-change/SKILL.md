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
change too for the suite to stay coherent. Those changes fail differently from
ordinary ones: nothing errors, both sides keep transacting, and a number quietly
means something else.

Work the protocol below in order. Do not begin editing until step 2.

## 1. Establish what you are actually changing

Read `SPEC/invariants.md` for the concept you are touching, then find **every**
implementation of it. Do not assume there are two. The Kovatchev transform was
found in six places across three repositories and three languages.

Search all four sibling checkouts, not only the one you are working in:

```
rg -n '<the constant, field name, or formula>' ../T1DMSIM ../T1DMAI ../T1DMDROID ../T1DMSERVER
```

List what you found before proceeding. If the count surprises you, that is the
finding — report it.

## 2. Change the specification first

If `SPEC/` states the rule, amend it there before touching any implementation.
If `SPEC/` does not state it yet, add it. The spec is the artefact the next agent
will read; an implementation change that leaves it stale has moved the drift
rather than fixed it.

If the change alters the wire contract between `T1DMDROID` and `T1DMSERVER`,
bump `CONTRACT_VERSION` and say what changed.

`SPEC/` is not the only thing your change can falsify. Sweep the rest of
`T1DMCOMMON` in the same pass: a `PROJECTS/` entry your change outdates, a known
deviation it resolves, an open question it answers. Resolved entries are
**deleted**, not annotated — these files state what is true now, and the commit
that fixed a defect is where that defect's history belongs. See *Keeping this
repository true* in `CLAUDE.md`.

## 3. Change the implementations you were asked to change

Write only to the repository you were asked to work in. For every other
repository that needs a corresponding change, **report it — do not reach in**.
A cross-repository edit is a separate, explicit task.

Consistency within your own repository is not optional: applying a unit or scale
change at one call site and not the others is worse than not applying it, because
the two halves then disagree inside a single program.

## 4. Prove it, do not assert it

A test that pins a **number** is worth more than one that pins a shape. If you
changed a convention, add a case that fails against the old behaviour, and check
that it does — run it against the unmodified code before you trust it.

Where both sides ship golden vectors for the same concept, compare them directly.
Two files named `curve_golden.json` in two repositories are either identical in
the scenarios they share or they are evidence of drift.

## 5. Report the seams you could not close

End with an explicit list: which repositories still need the corresponding
change, which call sites you could not reach, which of this document's open
questions your change depends on, and anything in `T1DMCOMMON` your change has
left stale that you could not amend yourself — named by file and by claim.
Silence here is how the next divergence starts.

## What does not need this skill

Local refactors, UI text, logging, comments, build configuration, and anything
whose effect stops at the edge of one repository. When in doubt, ask whether a
second repository would have to change too. If not, proceed normally.

One thing still applies to those changes: if a purely local change happens to
falsify something written in `T1DMCOMMON` — a project's gates, its module map,
which backends it runs — that correction is owed regardless. Skipping this skill
is not a licence to leave the specification wrong.
