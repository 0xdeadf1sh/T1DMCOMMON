# T1DMSIM — working knowledge

The behavioural simulator: a seed-driven generator of synthetic Type 1 Diabetes
glucose traces. Unlike glucose-insulin simulators of the UVA/Padova family, it
models patient *behaviour* as the primary driver — carbohydrate intake, insulin
action, insulin sensitivity, and exercise are generated as factor curves, and
blood glucose emerges from their interaction. Python. MIT.

Passive tooling. It produces the corpus `T1DMAI` pretrains on, and it also builds
the blosc2 cache and emits the normalization statistics that pipeline consumes.

## Committed report artefacts did not reproduce

A genuine trap, diagnosed and resolved. Committed comparison artefacts failed to
reproduce from a clean checkout even though the simulator is deterministic —
repeated runs are bitwise equal.

The evidence that it was *environmental* rather than a code regression: only the
simulator column drifted while all three real cohorts came out bit-identical, so
the loaders were sound; and the cache metadata recorded a source path on a
different machine. No in-repository state produced the committed figure.

The magnitudes are worth remembering, because they differ by artefact: the
primary comparison barely moved and prose claims survived at their stated
precision, but the cross-simulator comparison moved *qualitatively* — a mean-BG
gap collapsed by an order of magnitude — because both engines are driven by the
same replayed event stream and shift together.

Speed figures are machine-dependent, and a ratio can improve because the
*baseline* got slower. Read them accordingly.

## The known realism weakness

Two gap-score metrics sit outside the envelope the three cohorts span: hypo
episodes per day (z = +1.46, 1.18/day against 0.64–1.02) and TBR1 (z = +1.06).
The simulator runs mild lows more often than any real cohort. The other
eighteen metrics are inside it.

High-frequency variability is no longer the exception. On the cadence-fair
fifteen-minute grid Δ-BG SD is 12.14 against 10.65–14.55 across the cohorts
(z = −0.47); at raw five-minute cadence it is still about 10% low, 5.38
against Ohio 5.89 and AZT1D 6.02.

The simulator sits closer to two cohorts than those cohorts sit to each other:
W₁ 5.9 to Ohio and 5.3 to Shanghai, against a real-vs-real floor of 10.1. That
is a tuning signature. Realism claims should lean on AZT1D, at 22.8.

An audit of the comparison tooling fixed fifteen defects in the testing code —
entropy measures inflated across gaps, a subject silently dropped, NaN-inflated
episode denominators. The lesson generalises: analysis code deserves the same
scrutiny as the thing it analyses.

## Working in this project

**Be aggressive when tuning numerical constants.** Prefer moves of 30–100% over
timid 10–20% adjustments. The author asked for this explicitly after six cautious
rounds barely moved the metrics.

**Regenerate reports after changing the scripts that build them**, and commit the
refreshed outputs alongside — a script change that leaves stale artefacts behind
is how the reproduction trap above came about.
