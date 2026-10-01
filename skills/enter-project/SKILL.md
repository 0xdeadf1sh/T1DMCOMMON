---
name: enter-project
description: >-
  Run this FIRST, before any work on a T1DM sister project. The harness starts in T1DMCOMMON, which
  holds the suite's shared rules but none of its code — the projects are sibling checkouts at
  ../T1DMSIM, ../T1DMAI, ../T1DMDROID, ../T1DMKDE and ../T1DMAUTO. This skill is the orientation ritual: which
  files to read before touching a project, in what order, and what each project's local gates are.
  Triggers: any request naming a sister project, "work on the app", "retrain",
  "the simulator", or any task whose files are not in T1DMCOMMON itself.
---

# Entering a project

You are in `T1DMCOMMON`. The code is one directory up. Finish this ritual before
editing: the projects carry mandatory gates, cheaper to read now than to
discover after a mistake.

## 1. Identify the project and confirm the path

Map the request to exactly one of `../T1DMSIM`, `../T1DMAI`, `../T1DMDROID`,
`../T1DMKDE`, `../T1DMAUTO`. A
request spanning two is a cross-repository change: read
`shared-contract-change` as well, and still write to only one.

`../T1DMDROID-vk-build` is a build variant sitting beside the real checkout, not
the project.

## 2. Read the project in

In order:

- `../<PROJECT>/README.md` — what it is, how it builds, how it runs
- `../<PROJECT>/CLAUDE.md` — local rules
- `../<PROJECT>/.claude/skills/*/SKILL.md` — at minimum every description
- `../<PROJECT>/docs/` — the interface documentation relevant to the task

All five projects carry a `CLAUDE.md`, and it holds the local rules this
repository deliberately does not: `T1DMDROID`'s two-branch and build-both
discipline, for one. Skills bind separately; a project with
none is still bound by `../CLAUDE.md` and `SPEC/`.

## 3. Note the local gates

Current at the time of writing — verify against the project:

- **`T1DMDROID` / `publish-audit`** — mandatory before anything leaves that
  repository. `main` is published; `private` is local-only and carries the
  protocol document, the sensor reset and real patient data. The repository has
  twice had to be deleted after private content reached GitHub. Never push, add a
  remote, or create a repository there without running it.
- **`T1DMDROID` / `terse-ui-text`** — read before writing any user-facing string.
- **`T1DMDROID` / `android-device-testing`** — the build/deploy/screenshot loop.
- **`T1DMDROID` gates, local only** — `:calc:testDebugUnitTest` (rail invariants
  on the dose calculator) and `cargo test -p t1dm-core` (bit-for-bit core
  vectors); no CI fires. Its `CLAUDE.md` adds a standing rule: build **both**
  branches, and install the release build on the phone when one is attached.
- **`T1DMKDE`** — builds against `../T1DMDROID/crates/t1dm-watch`; after any QML
  change, the offscreen render check in its `CLAUDE.md`. Never commit a snapshot
  or a render made from real data.
- **`T1DMAUTO`** — builds against `../T1DMDROID/crates/t1dm-watch`; after any
  drawing change, `tools/render.sh` on the phone, sample mode only. Live mode
  renames the device's Bluetooth adapter, so it runs only on the head unit.

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
