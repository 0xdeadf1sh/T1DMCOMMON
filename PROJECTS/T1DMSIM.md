# T1DMSIM — working knowledge

Seed-driven generator of synthetic Type 1 Diabetes glucose traces. Unlike the
UVA/Padova family it models patient *behaviour* as the primary driver —
carbohydrate intake, insulin action, insulin sensitivity and exercise are
generated as factor curves, and blood glucose emerges from their interaction.
Python. MIT.

Passive tooling. It produces the corpus `T1DMAI` pretrains on, builds the blosc2
cache, and emits the normalization statistics that pipeline consumes.

## Reading the comparison artefacts

The simulator is deterministic — repeated runs are bitwise equal — so a committed
artefact that will not reproduce from a clean checkout is environmental, not a
code regression. The discriminator: only the simulator column drifts while the
real cohorts stay bit-identical, and the cache metadata records a source path on
another machine.

Magnitudes differ by artefact. The primary comparison barely moves and prose
claims survive at their stated precision; the cross-simulator comparison moves
qualitatively — a mean-BG gap collapsed by an order of magnitude — because both
engines replay the same event stream and shift together.

Speed figures are machine-dependent, and a ratio can improve because the
*baseline* got slower.

## The known realism weakness

Two gap-score metrics sit outside the envelope the three cohorts span: hypo
episodes per day (z = +1.46, 1.18/day against 0.64–1.02) and TBR1 (z = +1.06).
The simulator runs mild lows more often than any real cohort. The other eighteen
metrics are inside it.

On the cadence-fair fifteen-minute grid Δ-BG SD is 12.14 against 10.65–14.55
across the cohorts (z = −0.47); at raw five-minute cadence it is still about 10%
low, 5.38 against Ohio 5.89 and AZT1D 6.02.

The simulator sits closer to two cohorts than those cohorts sit to each other:
W₁ 5.9 to Ohio and 5.3 to Shanghai, against a real-vs-real floor of 10.1. That is
a tuning signature. Realism claims lean on AZT1D, at 22.8.

An audit of the comparison tooling fixed fifteen defects in the testing code —
entropy measures inflated across gaps, a subject silently dropped, NaN-inflated
episode denominators. Analysis code deserves the same scrutiny as the thing it
analyses.

## Working in this project

**Be aggressive when tuning numerical constants.** Prefer moves of 30–100% over
10–20%; six cautious rounds barely moved the metrics.

**Regenerate reports after changing the scripts that build them**, and commit the
refreshed outputs alongside.
