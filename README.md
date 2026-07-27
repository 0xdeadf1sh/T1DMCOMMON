# T1DMCOMMON

Shared specifications and working rules for the T1DM suite — four repositories
that between them implement one physiology and one wire contract.

| Repository | Role |
| --- | --- |
| [T1DMSIM](https://github.com/0xdeadf1sh/T1DMSIM) | Behavioural simulator; generates the synthetic traces the model pretrains on |
| [T1DMAI](https://github.com/0xdeadf1sh/T1DMAI) | Training and ExecuTorch export; produces the model artifact and its descriptor |
| [T1DMDROID](https://github.com/0xdeadf1sh/T1DMDROID) | The Android app; reads the CGM, runs inference on device, owns the patient's data |
| [T1DMSERVER](https://github.com/0xdeadf1sh/T1DMSERVER) | The sync backend; stores what the app sends, holds sessions, fans out notifications |

> [!CAUTION]
> **Research and educational use only.** The T1DM projects are personal research
> artifacts, not medical devices, and are not clinically validated. Nothing here
> may be used to make medical, diagnostic, or treatment decisions, to calculate
> or adjust insulin doses, or to guide diabetes management in any way. For
> medical advice, consult a qualified healthcare professional.

## Why this exists

The same facts live in more than one repository: the five-minute grid, the
physiologic units, the Kovatchev risk transform, the curve mathematics, the
forecast layout, and the contract the app and the server speak.

Duplicated facts drift. Both copies are correct the day they are written and
disagree later, silently — the software keeps working and one side is wrong.
This repository holds one copy of each such fact, so the others can reference it
instead of restating it.

A single copy helps only while it is true, so the obligation runs both ways: a
change in one of the four projects that contradicts something written here is
also a change to this repository. Everything here is written in the present tense
and describes the suite as it stands, not the path it took to get there.

## Contents

```
CLAUDE.md          working rules and the suite map
CONTRACT_VERSION   version of the app↔server wire contract
SPEC/
  invariants.md    the grid, units, risk spaces, curve semantics, forecast layout
PROJECTS/
  T1DMSIM.md       per-project working knowledge: constraints, traps, gates,
  T1DMAI.md        and the conventions each project's author has settled on
  T1DMDROID.md
  T1DMSERVER.md
skills/
  enter-project/            orientation ritual before working on a sister project
  shared-contract-change/   protocol for changing anything shared
  common-boundary/          what may and may not be published here
```

## Use

The four projects are sibling checkouts of this one:

```
├── T1DMCOMMON     <- you are here
├── T1DMSIM
├── T1DMAI
├── T1DMDROID
└── T1DMSERVER
```

Work begins here rather than in a project, so the shared rules are in hand
before any code is: `CLAUDE.md` maps the suite and names each project's local
rules and gates, and `skills/enter-project` is the ritual for picking one up.

`SPEC/invariants.md` closes with two lists — **known deviations**, where an
implementation is known to disagree with the specification, and **open
questions**, where the specification is not yet decisive. Both are tracked in
the open rather than resolved silently.

## License

MIT.
