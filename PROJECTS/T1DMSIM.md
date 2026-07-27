# T1DMSIM — working knowledge

The behavioural simulator: a seed-driven generator of synthetic Type 1 Diabetes
glucose traces. Unlike glucose-insulin simulators of the UVA/Padova family, it
models patient *behaviour* as the primary driver — carbohydrate intake, insulin
action, insulin sensitivity, and exercise are generated as factor curves, and
blood glucose emerges from their interaction. Python. MIT.

Passive tooling. It produces the corpus `T1DMAI` pretrains on, and it also builds
the blosc2 cache and emits the normalization statistics that pipeline consumes.

## Published datasets are immutable

`cache_balanced/DATASET.md` and `cache_hypo/DATASET.md` **must not be edited or
regenerated.** They describe the *pregenerated, published* datasets people
actually download, not any current run.

The corollary the author stated explicitly: the site's corpus and distribution
figures must be sourced from `cache_balanced`, not from a freshly regenerated
benchmark. Quoting numbers from a new run would describe a corpus nobody has.

Simulator-*validation* numbers — distances to the real cohorts, gap score, speed
benchmarks — have no cache counterpart and legitimately track the regenerated
reports. So when report numbers change, update the comparison directories, the
paper, and the site's validation figures, but leave both cache reports and the
site's corpus figures alone.

Known and accepted: `cache_*/meta.json` records a baseline snapshot, so
regenerating that baseline makes the cache reports' delta column compare against
a superseded reference. That drift is accepted, not fixed.

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

The simulator matches the real cohorts across the aggregate gap-score metrics,
within the envelope spanned by the three cohorts, with one clear exception:
**high-frequency variability**. Step-to-step glucose variation is roughly 7–9%
low at five-minute cadence, and worse on a common fifteen-minute grid.

This is the clearest remaining weakness and an ongoing tuning target — likely the
equilibrium of the stochastic glucose-effectiveness term or the sensor-noise
model under-producing jitter. It had previously been masked by a regrid bug that
interpolated linearly where it should have taken the nearest sample.

The simulator is also anchored on one cohort: its distance to that cohort sits
below the floor that the real cohorts show against *each other*, which is a
tuning signature. Realism claims should lean on the other two cohorts, whose
distances sit at a comparable level.

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
