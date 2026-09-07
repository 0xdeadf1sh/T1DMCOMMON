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

## What the simulator is calibrated to

The calibration target is the owner's own CGM record, read through the
hypo-onset profile `scripts/onset_profile.py` prints: share of onsets over
within 15 min, share with nadir below 55, median duration, median nadir, share
starting from at least 130 mg/dL two hours earlier, onsets per week. The
simulator's `CLAUDE.md` carries the target values and the tolerance. The public
cohorts in `diff/README.md` (OhioT1DM, ShanghaiT1DM, AZT1D) are a reference
comparison only; nothing is tuned to them, and the numbers there predate the
counter-regulation rewrite until the report is regenerated.

The remaining gap against the record is the share of onsets that begin from at
least 130 mg/dL two hours earlier: 24 % in the simulator against 43 % in the
record. Its first-of-cluster lows start from a median 112 mg/dL, the record's from
144, and the share trades against brevity along the counter-regulation threshold:
neither a two-stage response nor any dosing lever tried (over-bolus bias, shorter
meal tails, looser bolus gate, tighter basal, lower correction target) moves it
past 30 %.

An audit of the comparison tooling fixed fifteen defects in the testing code —
entropy measures inflated across gaps, a subject silently dropped, NaN-inflated
episode denominators. Analysis code deserves the same scrutiny as the thing it
analyses.

## Working in this project

**Be aggressive when tuning numerical constants.** Prefer moves of 30–100% over
10–20%; six cautious rounds barely moved the metrics.

**Regenerate reports after changing the scripts that build them**, and commit the
refreshed outputs alongside.
