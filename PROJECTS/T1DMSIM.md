# T1DMSIM — working knowledge

Seed-driven generator of synthetic Type 1 Diabetes glucose traces. Unlike the
UVA/Padova family it models patient *behaviour* as the primary driver —
carbohydrate intake, insulin action and insulin sensitivity are generated as
factor curves, and blood glucose emerges from their interaction. Python. MIT.

Passive tooling. It produces the corpus `T1DMAI` pretrains on, builds the blosc2
cache, and emits the normalization statistics that pipeline consumes.
`../SPEC/cache.md` is that cache's contract: row geometry, the four
counterfactual tails, the arrays and the meta keys. `simulator.py`,
`cache_simulator.py`, `tests/test_curves.py` and `docs/math.md` cite
`../SPEC/invariants.md` §5 by path; nothing inside `T1DMSIM` names `cache.md`,
so an agent entering by that repository's own files never learns that contract
exists. A `docs/` stub naming it is the fix, and it belongs to `T1DMSIM`.

**`cache_simulator.py` builds none of that contract — a live deviation.** It
writes `cache_format` `blosc2-ndarray-v1` over 2394-step rows from
`DEFAULT_SIM_HOURS = 199.5`, against the contract's `blosc2-ndarray-v2` and its
2016-step context, and carries no boundary deep copy, no arm, no tail array and
no `skills.npy`.

**The simulator still exercises its patients, and the specification binds that
channel to `T1DMDROID` alone — a live deviation.** `simulator.py` carries
`EXERCISE_DURATION_MEAN_MIN`, `EXERCISE_CARB_EQUIV_PER_MIN`, the
`exercise_duration_mean_min` patient field, the `exercise_min` event channel, the
`total_exercise` step key and the post-exercise sensitivity reduction;
`cache_simulator.py` caches `total_exercise` and normalizes it as
`exercise_equiv`. `../SPEC/inference.md` §6 takes exercise out of the model
input, and `../SPEC/invariants.md` §3 and §5 keep the unit and the curve for
`T1DMDROID` alone. Removing all of it from here is a task of its own.

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

Scheduled bolus count, clock time and dose are drawn independent of meals, carbs
and BG, so the insulin channel carries its own effect rather than a meal's shadow.
It is a deliberate departure from every real patient; never justify it as realism.
Most boluses with no meal carbs nearby fall in a meal-free night window.
BG-reactive dosing is the pre-bolus skip below the patient's hypo threshold and a
correction bolus, taken with probability `HYPER_CORRECTION_PROBABILITY` on an
awake CGM check above `HYPER_CORRECTION_THRESHOLD`.

Insulin is not the only thing that brings BG down: the insulin-independent
glucose-effectiveness pull toward the equilibrium runs at every step and
dominates below `RENAL_THRESHOLD`, and exercise subtracts its disposal. Above
that threshold `RENAL_CLEARANCE_RATE` excretes glucose on top, at a damping tune
carrying a `[DAMP]` tag, not the UVA/Padova value. An unbolused meal stays high
for hours. The population is tuned
tight all the same: seeds 1000–1011 over 168 h each, after a 48 h warm-up, put
`bg_observed` near a 125 mg/dL mean with an SD near 40, about 5% below 70 mg/dL,
about 86% in 70–180, and no time at the 400 ceiling.
True BG has no floor and can go below zero; only the CGM reading is clipped.

## The exported record is the patient's log

What leaves the simulator is what the patient believes: `total_carb` and the
`carb_g` / `carb_gi` events carry guessed grams and a guessed GI at the true onset
step, and `total_insulin` / `basal_insulin` / `bolus_insulin` and the dose events
carry the intended dose, before the injection-site factor. A meal logs the carb
count its bolus is dosed from. Blood glucose runs on the `*_true` keys, which the
cache does not store. `../SPEC/cache.md` §4 is the rule.

`main` predates both splits and exports true carbohydrate and true insulin under
those names. `old-sim` has the carbohydrate split — `_logged_carb` and
`total_carb_true` are both there — and not the insulin one, so its
`total_insulin` is the delivered dose. Nothing about a row's shape says which
branch built it.

## Stale artefacts on disk

`diff/README.md`, `diff/stats.json` and the `uva_padova/` reports predate the
randomised dosing policy and describe a different simulator. Regenerating them
needs the three real datasets and simglucose, neither of which is on this machine.
The comparison mechanism stays and still reads `diff/stats.json`.
`tests/test_hypo_oversample.py::test_unbiased_build_sits_near_baseline` pins a
fresh unbiased pool within 12 mg/dL of that baseline's 162.9 mg/dL mean and
within 0.05 of its hypoglycaemia fraction. Its fixture errors first, on the
`exercise_equiv` std=0 cache build, so the 38 mg/dL gap to the retuned
population only surfaces once exercise is gone; the test needs decoupling from
the baseline in the same task.

The population is tuned against one real CGM record rather than the public
cohorts, so a figure quoted from those reports describes neither.

Analysis code deserves the same scrutiny as the thing it analyses: an audit of
the comparison tooling once fixed fifteen defects in it.

## Working in this project

**Be aggressive when tuning numerical constants.** Prefer moves of 30–100% over
10–20%; six cautious rounds barely moved the metrics.

**Regenerate reports after changing the scripts that build them**, and commit the
refreshed outputs alongside.
