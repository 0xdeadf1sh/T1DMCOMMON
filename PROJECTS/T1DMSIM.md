# T1DMSIM — working knowledge

Seed-driven generator of synthetic Type 1 Diabetes glucose traces. Unlike the
UVA/Padova family it models patient *behaviour* as the primary driver —
carbohydrate intake, insulin action and insulin sensitivity are generated as
factor curves, and blood glucose emerges from their interaction. Python. MIT.

Passive tooling. It produces the corpus `T1DMAI` pretrains on, builds the blosc2
cache, and emits the normalization statistics that pipeline consumes.
`../SPEC/cache.md` is that cache's contract: row geometry, the four
counterfactual tails, the arrays and the meta keys. `cache_simulator.py` builds
it — the 2016-step context, the four behaviour-off tails, the `tail_` and
`tail_dose_` arrays, `skills.npy`, the geometry meta keys and `cache_format`
`blosc2-ndarray-v3`. `cache_simulator.py`, `CLAUDE.md`, `README.md`,
`docs/math.md` and both cache tests name `cache.md` by path, so an agent entering
by the repository's own files reaches the contract.

Patients here never exercise: no constant, patient field, event channel, step key
or normalized channel for it. `../SPEC/invariants.md` §3 and §5 keep the unit and
the curve for `T1DMDROID` alone.

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

Boluses follow meals: each is dosed from the logged carb count over the patient's
ICR, skipped below the patient's hypo threshold and cut within
`BOLUS_REDUCE_MARGIN` above it. Corrections fire above a skill-lowered
`BG_HIGH_THRESHOLD` once the patience window has run.

`main-old`, and `origin/main` until it is force-pushed, carry another policy: bolus
count, time and dose drawn independent of meals, and a correction bolus gated on
`HYPER_CORRECTION_PROBABILITY`. A claim about dosing names its branch.

Insulin is not the only thing that brings BG down: the insulin-independent
glucose-effectiveness pull toward the equilibrium runs at every step and
dominates below `RENAL_THRESHOLD`. Above that threshold `RENAL_CLEARANCE_RATE`
excretes glucose on top, at a damping tune carrying a `[DAMP]` tag, not the
UVA/Padova value. An unbolused meal stays high for hours. Seeds 1000–1011 over
168 h each, after a 48 h warm-up, put `bg_observed` at a 142.5 mg/dL mean, SD 57.1,
6.8% below 70 mg/dL, 71.9% in 70–180 and 0.07% at the 400 ceiling. True BG is
clamped to [`BG_CLAMP_MIN`, `BG_CLAMP_MAX`] = [1, 400] mg/dL.

An undosed tail can fall to that floor: behaviour is off, so no rescue fires, and
the glucose-effectiveness pull at `GE_RATE` 0.015 does not stop it.
`test_no_tail_is_ever_rejected` fails on it, 105 → 1.5 mg/dL inside 2 h. The two
`TestSevereHypoRefractory` tests fail as well; they assume the phone-record refit.

## The exported record is the patient's log

What leaves the simulator is what the patient believes: `total_carb` and the
`carb_g` / `carb_gi` events carry guessed grams and a guessed GI at the true onset
step, and `total_insulin` / `basal_insulin` / `bolus_insulin` and the dose events
carry the intended dose, before the injection-site factor. A meal logs the carb
count its bolus is dosed from. Blood glucose runs on the `*_true` keys, which the
cache does not store. `../SPEC/cache.md` §4 is the rule.

`main` has both splits. `main-old` predates both and exports true carbohydrate and
true insulin under those names. `old-sim` has the carbohydrate split and not the
insulin one, so its `total_insulin` is the delivered dose. Nothing about a row's
shape says which branch built it.

## Stale artefacts on disk

`diff/README.md`, `diff/stats.json` and the `uva_padova/` reports describe a
different simulator. Regenerating them
needs the three real datasets and simglucose, neither of which is on this machine.
The comparison mechanism stays and still reads `diff/stats.json`.
Its `datasets.Sim` mean of 162.9 mg/dL is an older simulator's, so the gap
`DATASET.md` reports is measured against that.
`tests/test_hypo_oversample.py` pins no number against that baseline: it asserts
the section renders when a baseline is present, is omitted when it is not, and
that an oversampled pool shifts against an unbiased one built in the same run.

`main` does not carry the refit onto the one real CGM record; it lives on `omar`
alone (`2f6c966`). A figure quoted from those reports describes neither branch.

Analysis code deserves the same scrutiny as the thing it analyses: an audit of
the comparison tooling once fixed fifteen defects in it.

## Working in this project

**Be aggressive when tuning numerical constants.** Prefer moves of 30–100% over
10–20%; six cautious rounds barely moved the metrics.

**Regenerate reports after changing the scripts that build them**, and commit the
refreshed outputs alongside.
