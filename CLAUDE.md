# T1DM suite — shared working rules

## Start here

**You are running in `T1DMCOMMON`, which is not where the work happens.** This
repository holds the specifications and rules the suite shares. The software
lives in sibling checkouts, one directory up:

```
../T1DMSIM      ../T1DMAI      ../T1DMDROID      ../T1DMSERVER
```

Before doing anything in a project, orient yourself in it. Read, in this order:

1. This file, and `SPEC/invariants.md` for any shared concept you will touch.
2. `../<PROJECT>/README.md` — what it is and how it is built and run.
3. `../<PROJECT>/CLAUDE.md` — its local rules, where one exists.
4. `../<PROJECT>/.claude/skills/` — its skills. Several are **mandatory gates**,
   not suggestions; read their descriptions before you start, not after you are
   blocked.
5. `../<PROJECT>/docs/` — its interface documentation. Several of those files are
   **stubs**: the specification they name lives in `SPEC/` here, and the stub
   carries only what is local to that project. Follow the pointer; do not
   reconstruct the specification from the stub.

What each project currently exposes:

| Project | `CLAUDE.md` | Skills | `docs/` |
| --- | --- | --- | --- |
| `../T1DMSIM` | yes | — | `math.md` |
| `../T1DMAI` | yes | — | `INFERENCE.md` → `SPEC/inference.md` |
| `../T1DMDROID` | yes | `android-device-testing`, `publish-audit`, `terse-ui-text` | `CGM.md`, `WATCH_BLE.md`; `INFERENCE.md` → `SPEC/inference.md`, `T1DMSERVER_API.md` → `SPEC/http-api.md` |
| `../T1DMSERVER` | yes | — | `API.md` → `SPEC/http-api.md` |

`CGM.md` is the one interface document that must **never** be promoted here, in
any part: see *What must never enter this repository*.

Two cautions on the layout. A `CLAUDE.md` is not the whole of a project's rules:
`T1DMDROID`'s skills are mandatory gates in their own right, and its build and
branch discipline live in its `CLAUDE.md` rather than here. And a
`../T1DMDROID-vk-build` directory exists beside the real checkout; it is a build
variant, not the project. Do not work in it.

Write only to the project you were asked to change. Read the others freely.

## Project memories — load them on demand

Each project keeps its own memory directory, outside its repository:

```
~/.claude/projects/-home-omar-Desktop-<PROJECT>/memory/
```

Starting here means **only this repository's memory is loaded automatically**.
Every sister project's memory is invisible until you go and read it, and some of
it is load-bearing — the fact that the model consumes carbohydrate as an
appearance curve rather than a delivery schedule lives in a memory, not in any
source file.

**On demand, not in bulk.** Each directory has a `MEMORY.md` index, one line per
memory. Read the index — it is cheap — and open only the entries your task
actually touches. Do not read a project's memories wholesale; there are more
than twenty for `T1DMDROID` alone, and loading them all buys noise.

Three cautions:

- **A memory records what was true when it was written.** It is not verified
  against the code and may have been overtaken. If one names a file, a constant,
  a device, or a decision, confirm it still holds before acting on it. Where a
  memory and this specification disagree, this specification wins; where a
  memory and the code disagree, the code wins and the memory is a defect.
- **Some projects have memories under an older path encoding**, left behind when
  the checkout moved. `T1DMDROID` and `T1DMSIM` both have a second directory
  under `-home-omar-<PROJECT>/`. Its contents are largely superseded and in
  places directly contradict the current set. Prefer the `-home-omar-Desktop-`
  directory and treat the other as suspect.
- **Do not write a shared fact into a memory.** A memory is local, private, and
  unversioned. If something is true for more than one project, it belongs in
  `SPEC/` where every project and every agent can see it. Project-local facts go
  in that project's memory directory — not in this one.

## The four repositories, and how they differ

Two are **active** — running software in a live client/server relationship:

| Repository | Role | Language |
| --- | --- | --- |
| `T1DMDROID` | The Android app. Reads the CGM, runs inference on device, owns the patient's data. | Kotlin + Rust |
| `T1DMSERVER` | The sync backend. Stores what the app sends, holds sessions, fans out notifications, and renders an operator console. | Rust |

Two are **passive** — offline tooling, run occasionally by hand, not part of any
running system:

| Repository | Role | Language |
| --- | --- | --- |
| `T1DMSIM` | Behavioural simulator. Generates the synthetic traces the model pretrains on. | Python |
| `T1DMAI` | Training and ExecuTorch export. Produces the model artifact and its descriptor. | Python |

This distinction governs how strongly each shared fact binds. A disagreement
between the two active repositories is a live defect: they exchange data
continuously, and a mismatch corrupts or loses a patient record. A disagreement
involving the passive repositories surfaces at the next training or export run,
where a human is present to notice.

## The rule that matters

**Never create a second copy of a shared fact.**

Every divergence this suite has suffered began as a reasonable-looking local
copy: a constant inlined "just here", a contract document duplicated into a
second repository, a numeric routine ported rather than shared. Both copies were
correct on the day they were written. They stopped agreeing later, silently,
because nothing was watching.

If a value, formula, or contract is defined under `SPEC/`, reference it. Do not
restate it, re-derive it, or re-hardcode it. If you find an existing duplicate,
report it rather than adding a third.

**Specifications are single-copy, and that is checked.** `SPEC/invariants.md`,
`SPEC/http-api.md` and `SPEC/inference.md` exist here and nowhere else. A project
that needs one keeps a **stub** at the path its readers expect — naming this
document, pointing at the sibling checkout, and carrying only what is local to
that project. Never restore a copy, however convenient: both copies of the wire
contract were correct on the day they were made, and the app's had fallen a
version behind the server's before anyone noticed.

```
scripts/check-no-copies.sh          # 0 = clean, 1 = a copy exists
```

It fingerprints each specification with a handful of its own sentences and
scans the four sibling checkouts, so it catches a copy under any filename — and
a specification pasted into a source comment as readily as into a document. Run
it before you finish anything that touched `SPEC/` or a project's `docs/`.

## Keeping this repository true

One copy of a fact is only an improvement while the copy is right. A stale
specification is worse than none: it is trusted, it is read first, and it sends
the next agent to change working code to match something no longer true.

**Drift flows back here.** A change in a sister project that falsifies anything
in this repository obliges an update to this repository, in the same task, not
in a follow-up. That includes a `SPEC/` invariant the change contradicts, a
`PROJECTS/` entry the change outdates, a deviation the change resolves, an open
question the change answers, and the `CONTRACT_VERSION` where the wire contract
moved. Finishing the code and leaving the specification behind has not fixed the
drift — it has moved it somewhere quieter, where the next reader will trust it.

If the correction is not yours to make — you were asked to work in one
repository and the truth now lives in another — say so explicitly and name the
file and the claim. An unreported staleness is indistinguishable from a fact.

**State what is true now.** Every file here describes the suite as it stands
today, in the present tense. When an implementation catches up with the
specification, **delete** the entry: do not annotate it "Resolved", do not leave
the old behaviour beside the new one, and do not narrate what changed. A defect
that no longer exists belongs to the commit that fixed it, in the repository
where it was fixed; read there it is history, read here it is a live warning
about nothing. The same holds for prose: describe the mechanism in place, not the
one it replaced — unless the superseded design is still on disk and could be
reached by mistake, in which case it is a live trap and belongs here as one.

## What T1DMSERVER is, and is not

The phone is authoritative. `T1DMDROID` authors every physiologic record and
computes every forecast and statistic. Understanding the server's remit narrowly
is the single most important thing for an agent working on it.

The server **is** responsible for:

- storing what it receives, verbatim and durably, and returning it unchanged
- resolving bearer tokens and holding read-write and read-only sessions
- fanning notifications out to every session except the one that wrote
- its own operator console

The server is **not** responsible for:

- judging whether a physiologic value is plausible, correctly scaled, or sane
- computing or recomputing any statistic or forecast
- interpreting model metadata, which is opaque to it
- re-stamping any timestamp the client authored

**The boundary.** The server may reject input only where accepting it would
corrupt its own storage or make a record unreachable — a timestamp off the grid
it keys reconstruction on, a window label no reader could ever resolve. It must
never reject input for being physiologically implausible. That is the client's
judgement to make, and the server's job is to keep whatever the client decided.

**The console is not the data path.** The server carries curve mathematics and a
risk transform solely to render its own operator TUI. Those are display
conveniences. If they drift from the phone's, the operator sees a different
picture than the patient — worth fixing, but no stored record is wrong. Never
let a display convenience write back into stored data.

## Concepts governed by SPEC/

Changing any of these in one repository obliges you to check its counterparts:

| Concept | Written in | Binds |
| --- | --- | --- |
| The HTTP/WebSocket contract | `SPEC/http-api.md` | `T1DMDROID` ↔ `T1DMSERVER` — live, strongest |
| The five-minute grid, timestamps, `tz_offset` | `SPEC/invariants.md` §1–2 | all four |
| Physiologic units, scales, sign conventions | `SPEC/invariants.md` §3 | all four |
| The two risk spaces | `SPEC/invariants.md` §4 | all four |
| Meal-appearance and insulin-action curve mathematics | `SPEC/invariants.md` §5 | all four |
| Quantile levels and order, horizon, circadian bins | `SPEC/invariants.md` §6, `SPEC/inference.md` | `T1DMAI` → `T1DMDROID`, displayed by `T1DMSERVER` |
| The metric levels, band projection, CG-EGA anchoring | `SPEC/invariants.md` §6.1–6.3 | `T1DMAI` ↔ `T1DMDROID` |
| Authority, `client_id`, `updated_at` ordering | `SPEC/invariants.md` §7 | `T1DMDROID` ↔ `T1DMSERVER` |
| Statistics definitions | `SPEC/http-api.md` (Stats) | computed by `T1DMDROID`, displayed by `T1DMSERVER` |
| The model descriptor format, graph cut, decode | `SPEC/inference.md` | `T1DMAI` → `T1DMDROID` |
| The conformal band correction — its apply AND its fit | `SPEC/inference.md` §8.4 | `T1DMAI` ↔ `T1DMDROID` |

Anything on that list is a cross-repository change. Read
`skills/shared-contract-change` before touching it.

## Safety stance

All four projects are research artifacts and advisory only. None is a medical
device; none is clinically validated. No component may actuate insulin delivery.
Every repository carries a disclaimer to this effect in its README — keep them
consistent in substance, and never weaken one.

Where a calculation could mislead if wrong, prefer failing closed — withholding
a number — over showing a value you cannot justify.

## What must never enter this repository

`T1DMCOMMON` is public. Some of its consumers are not entirely public:
`T1DMDROID` maintains a local-only branch carrying reverse-engineered CGM
sensor-control protocol, and that repository has twice had to be deleted after
such content reached GitHub.

Nothing may be promoted here that is not safe to publish. Read
`skills/common-boundary` before adding a file. Never move here:

- sensor-control protocol, activation, bonding, or session-key material
- device identifiers, serial numbers, or MAC addresses
- real patient data, screenshots of it, or anything derived from it
- credentials, tokens, keys, or private network addresses

Synthetic data and published clinical formulae are fine. When uncertain, leave it
in the repository that owns it and reference it from there.

## Working across repositories

The sister repositories are checked out beside each other. Read them freely;
write only to the one you were asked to change. A change to another repository is
a separate, explicit task — report what it needs instead of reaching into it.

### T1DMDROID has two branches, and most work belongs on both

`T1DMDROID` keeps a public `main` and a local-only `private`. Only one thing
separates them: `private` carries the reverse-engineered CGM sensor-control work
— the connected-session sources, the session crypto, the unredacted protocol
document — and `main` is the passive-advertisement reader without it.

Everything else is common ground. **Unless a change touches that
reverse-engineering seam, it lands on both branches.** A forecast fix, a UI
change, a calculator rail, a schema migration, a dependency bump, a
specification-driven correction: all of it applies to `main` as much as to
`private`, and a change that lives on only one branch is a divergence with no
reason to exist. The branches are synced by hand, so nothing will notice for you.

Two cautions. Apply the change to each branch **deliberately** — as its own
commit on each — rather than merging or cherry-picking across the seam; a
careless merge is how private content reached `main`, twice. And when you cannot
land both halves in one task, say which branch has the change and which does not.
An unmirrored commit that nobody flagged is how the branches drift apart in the
first place.
