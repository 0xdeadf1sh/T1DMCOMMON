---
name: enter-project
description: >-
  Run this FIRST, before any work on a T1DM sister project. The harness starts in T1DMCOMMON, which
  holds the suite's shared rules but none of its code — the projects are sibling checkouts at
  ../T1DMSIM, ../T1DMAI, ../T1DMDROID and ../T1DMSERVER. This skill is the orientation ritual: which
  files to read before touching a project, in what order, and what each project's local gates are.
  Triggers: any request naming a sister project, "work on the app", "fix the server", "retrain",
  "the simulator", or any task whose files are not in T1DMCOMMON itself.
---

# Entering a project

You are in `T1DMCOMMON`. The code is one directory up. Do not start editing
before finishing this ritual — the projects carry mandatory gates that are
cheaper to read now than to discover after a mistake.

## 1. Identify the project and confirm the path

Map the request to exactly one of `../T1DMSIM`, `../T1DMAI`, `../T1DMDROID`,
`../T1DMSERVER`. If a request spans two, it is a cross-repository change: read
`shared-contract-change` as well, and still write to only one.

Beware `../T1DMDROID-vk-build`, a build variant sitting beside the real
checkout. It is not the project.

## 2. Read the project in

In order, and actually read them:

- `../<PROJECT>/README.md` — what it is, how it builds, how it runs
- `../<PROJECT>/CLAUDE.md` — local rules, if present
- `../<PROJECT>/.claude/skills/*/SKILL.md` — at minimum every description
- `../<PROJECT>/docs/` — the interface documentation relevant to your task

All four projects carry a `CLAUDE.md`, and reading it is not optional — it holds
the local rules this repository deliberately does not: `T1DMDROID`'s two-branch
and build-both discipline, `T1DMSERVER`'s manual gate. Their skills bind
separately; a project with none is still bound by everything in `../CLAUDE.md`
and `SPEC/`.

## 3. Note the local gates before you start

Known gates, current at the time of writing — verify against the project, do not
trust this list alone:

- **`T1DMDROID` / `publish-audit`** — mandatory before anything leaves that
  repository. It has a public branch and a local-only `private` branch carrying
  reverse-engineered sensor protocol and real patient data, and it has twice had
  to be deleted after that content reached GitHub. Never push, add a remote, or
  create a repository there without running it.
- **`T1DMDROID` / `terse-ui-text`** — read before writing any user-facing string.
- **`T1DMDROID` / `android-device-testing`** — the build/deploy/screenshot loop.
- **`T1DMDROID` CI** — `build.yml`, `rail-invariants.yml` (a blocking safety
  gate on the dose calculator), `rust-golden.yml` (bit-for-bit core vectors).
  Its `CLAUDE.md` adds a standing local rule: build **both** branches, and
  install the release build on the phone when one is attached.
- **`T1DMSERVER`** — no CI at all; its gate is manual and stated in its own
  `CLAUDE.md`. Run it before claiming a change works.

## 4. Check whether the task is shared

Before editing, ask whether the concept you are about to touch is listed in
`../CLAUDE.md` under *Concepts governed by SPEC/*. If it is, stop and read
`shared-contract-change` — the change needs a specification amendment first, and
probably a counterpart change in another repository that you must report rather
than make.

## 5. Establish the baseline

Run the project's own test or build gate **before** changing anything, and
record the numbers. A pre-existing failure attributed to your change wastes a
review cycle; a regression you cannot distinguish from a pre-existing failure
wastes more.

## 6. Report against the suite, not just the file

When you finish, state which sibling projects your change implies work in, and
which of `SPEC/invariants.md`'s open questions or known deviations you touched.
That list is what stops the next divergence.
