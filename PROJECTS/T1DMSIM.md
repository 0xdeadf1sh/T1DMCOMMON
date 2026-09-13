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

## The dosing policy

Bolus count, clock time and dose are drawn independent of meals, carbs and BG,
so the insulin channel carries its own effect rather than a meal's shadow. It is a
deliberate departure from every real patient; never justify it as realism. Most
boluses with no meal carbs nearby fall in a meal-free night window. The only
BG-reactive dosing is the pre-bolus skip below the patient's hypo threshold.

Below 180 mg/dL only insulin brings BG down; above it renal clearance does, at
the UVA/Padova rate. An unbolused meal stays high for hours. With nothing but insulin to remove
glucose and insulin blind to meals, the BG distribution is wide by construction:
mean about 210 mg/dL, SD about 115, and roughly 12% of CGM time at the 400 ceiling,
which the cache's rail filter discards. True BG has no
floor and can go below zero; only the CGM reading is clipped.

## Stale artefacts on disk

`diff/README.md`, `diff/stats.json` and the `uva_padova/` reports predate the
randomised dosing policy and describe a different simulator. Regenerating them
needs the three real datasets and simglucose. Until then
`test_unbiased_build_sits_near_baseline` compares fresh caches against that stale
baseline and fails.

Analysis code deserves the same scrutiny as the thing it analyses: an audit of
the comparison tooling once fixed fifteen defects in it.

## Working in this project

**Be aggressive when tuning numerical constants.** Prefer moves of 30–100% over
10–20%; six cautious rounds barely moved the metrics.

**Regenerate reports after changing the scripts that build them**, and commit the
refreshed outputs alongside.
