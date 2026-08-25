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

You are in `T1DMCOMMON`. The code is one directory up. Finish this ritual before
editing: the projects carry mandatory gates, cheaper to read now than to
discover after a mistake.

## 1. Identify the project and confirm the path

Map the request to exactly one of `../T1DMSIM`, `../T1DMAI`, `../T1DMDROID`,
`../T1DMSERVER`. A request spanning two is a cross-repository change: read
`shared-contract-change` as well, and still write to only one.

`../T1DMDROID-vk-build` is a build variant sitting beside the real checkout, not
the project.

## 2. Read the project in

In order:

- `../<PROJECT>/README.md` — what it is, how it builds, how it runs
- `../<PROJECT>/CLAUDE.md` — local rules
- `../<PROJECT>/.claude/skills/*/SKILL.md` — at minimum every description
- `../<PROJECT>/docs/` — the interface documentation relevant to the task

All four projects carry a `CLAUDE.md`, and it holds the local rules this
repository deliberately does not: `T1DMDROID`'s two-branch and build-both
discipline, `T1DMSERVER`'s manual gate. Skills bind separately; a project with
none is still bound by `../CLAUDE.md` and `SPEC/`.

## 3. Note the local gates

Current at the time of writing — verify against the project:

- **`T1DMDROID` / `publish-audit`** — mandatory before anything leaves that
  repository. It has a public branch and a local-only `private` branch carrying
  reverse-engineered sensor protocol and real patient data, and it has twice had
  to be deleted after that content reached GitHub. Never push, add a remote, or
  create a repository there without running it.
- **`T1DMDROID` / `terse-ui-text`** — read before writing any user-facing string.
- **`T1DMDROID` / `android-device-testing`** — the build/deploy/screenshot loop.
- **`T1DMDROID` CI** — `build.yml`, `rail-invariants.yml` (blocking safety gate
  on the dose calculator), `rust-golden.yml` (bit-for-bit core vectors). Its
  `CLAUDE.md` adds a standing rule: build **both** branches, and install the
  release build on the phone when one is attached.
- **`T1DMSERVER`** — no CI. Its gate is manual and stated in its own
  `CLAUDE.md`. Run it before claiming a change works.

## 4. Check whether the task is shared

If the concept is listed in `../CLAUDE.md` under *Concepts governed by SPEC/*,
read `shared-contract-change`: the change needs a specification amendment first,
and probably a counterpart change in another repository to report rather than
make.

## 5. Establish the baseline

Run the project's own test or build gate **before** changing anything, and
record the numbers. A pre-existing failure attributed to a change wastes a review
cycle; a regression indistinguishable from a pre-existing failure wastes more.

## 6. Report against the suite

State which sibling projects the change implies work in, and which of
`SPEC/invariants.md`'s open questions or known deviations it touched.
