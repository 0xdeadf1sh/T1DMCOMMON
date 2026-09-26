# T1DMCOMMON

Shared specifications and working rules for the T1DM suite — five repositories
that between them implement one physiology, one model contract and one watch link.

| Repository | Role |
| --- | --- |
| [T1DMSIM](https://github.com/0xdeadf1sh/T1DMSIM) | Behavioural simulator; generates the synthetic traces the model pretrains on |
| [T1DMAI](https://github.com/0xdeadf1sh/T1DMAI) | Training and ExecuTorch export; produces the model artifact and its descriptor |
| [T1DMDROID](https://github.com/0xdeadf1sh/T1DMDROID) | The Android app; reads the CGM, runs inference on device, owns the patient's data |
| [T1DMKDE](https://github.com/0xdeadf1sh/T1DMKDE) | A KDE Plasma wallpaper and panel widget showing what the phone pushes over the watch link |
| T1DMAUTO | An Android app for a car head unit showing the reading, 6 h of history and the forecast the phone pushes over the watch link |

> [!CAUTION]
> **Research and educational use only.** The T1DM projects are personal research
> artifacts, not medical devices, and are not clinically validated. Nothing here
> may be used to make medical, diagnostic, or treatment decisions, to calculate
> or adjust insulin doses, or to guide diabetes management in any way. For
> medical advice, consult a qualified healthcare professional.

## Why this exists

Some facts are needed in more than one repository: the five-minute grid, the
physiologic units, the Kovatchev risk transform, the curve mathematics, the
forecast layout, the model contract the app decodes against, the shape of the
cache the model pretrains on, and the watch link the phone pushes over. Each is
written down once, here. A project that
needs one keeps a stub at the path its readers expect, pointing back.

Duplicated facts drift. Both copies are correct the day they are written and
disagree later, silently — the software keeps working and one side is wrong.

The obligation runs both ways: a change in one of the five projects that
contradicts something written here is also a change to this repository.
Everything here is present tense and describes the suite as it stands.

## Contents

```
CLAUDE.md          working rules and the suite map
SPEC/
  invariants.md    the grid, units, risk spaces, curve semantics, forecast layout
  inference.md     the model contract: checkpoint, graph, decode, constants
  cache.md         the pretraining cache: row geometry, tails, arrays, meta
  watch.md         the watch link: pairing, session crypto, record layouts
scripts/
  check-no-copies.sh   fails when a specification has been copied into a project
PROJECTS/
  T1DMSIM.md       per-project working knowledge: constraints, traps, gates,
  T1DMAI.md        and the conventions each project's author has settled on
  T1DMDROID.md
  T1DMKDE.md
  T1DMAUTO.md
skills/
  enter-project/            orientation ritual before working on a sister project
  shared-contract-change/   protocol for changing anything shared
  common-boundary/          what may and may not be published here
```

## Use

The five projects are sibling checkouts of this one:

```
├── T1DMCOMMON     <- you are here
├── T1DMSIM
├── T1DMAI
├── T1DMDROID
├── T1DMKDE
└── T1DMAUTO
```

Work begins here, so the shared rules are in hand before any code is. `CLAUDE.md`
maps the suite and names each project's local rules and gates;
`skills/enter-project` is the ritual for picking one up.

`SPEC/invariants.md` closes with three lists — **known deviations**, where an
implementation disagrees with the specification; **accepted divergences**,
differences that are deliberate; and **open questions**, where the specification
is not yet decisive.

## License

MIT.
