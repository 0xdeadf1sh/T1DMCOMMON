# T1DMAI — working knowledge

The training and export pipeline: trains the forecasting transformer on
`T1DMSIM`'s synthetic traces and exports the ExecuTorch artifact plus the
descriptor that `T1DMDROID` loads. Python. MIT.

Passive tooling — run by hand when a new model is wanted, not part of any running
system.

## The risk-v4 redesign

What the current architecture (`ARCH_VERSION = 'risk-v4'`) carries that matters
across the suite:

**No input or target smoothing.** The causal Savitzky-Golay smoother was deleted
outright. Inputs, the forecast target, and the anchor are the raw post-noise
simulator signals, with glucose clamped to `[10, 400]` and carbohydrate/insulin
floored at zero. `scipy` is no longer a dependency.

**Kovatchev re-anchored to `[40, 400]`** — see `../SPEC/invariants.md` §4 for the
constants, the two-space rule, and why the anchors are not the clamp. The
euglycaemic zero-risk centre moved from about 112.5 to about 128 mg/dL as a
result.

**Position comes from RoPE alone.** ALiBi is gone: no additive per-head distance
bias on the logits and no `alibi_slopes` tensor. QK-norm on Q and K stays.

**Exercise is an input feature** — a carbohydrate-equivalent glucose-disposal
curve in g/step, encoded log1p + z like carbohydrate, never risk-transformed and
never rescaled. The simulator is the only source that fills it. The wire's
`exercise` carries the same quantity, in grams of carbohydrate equivalent per
bucket — `T1DMDROID` writes it from the patient's logged sessions against their
own `carb_equiv_per_min`. Units and curve in `../SPEC/invariants.md` §3 and §5.

**The forecast is one case of a masked-BG objective.** A masked span at the right
edge of the window is a forecast, one at the left edge a backcast, anything else
infill. A `bg_masked` bit announces the masked set rather than leaving it
inferable from position, and each masked patch carries its own one-sided,
left-preferring anchor in place of one broadcast `last_bg`.
`../SPEC/inference.md` holds the feature map, the patch geometry, the forward
signature and the head's slot layout.

**The configured capacity is medium** — `D_MODEL` 128, `N_LAYERS` 8, `N_HEADS` 8,
set through `resize_model.py`. The context window is `[168, 336]` patches
(84–168 h); see `../SPEC/inference.md`.

The clinical LBGI/HBGI indices in `T1DMSIM` deliberately stay on the published
constants so they remain comparable to the diabetes literature. **A cross-repo
reviewer will flag the duplication as drift — it is not.** That was an explicit
decision: model risk space only.

## Cache and statistics seam

T1DMAI's own cache builder was deleted; it relies on `../T1DMSIM/cache_simulator.py`
(symlinked as `T1DMSIM/`) to build the blosc2 cache, which also emits
`normalization_stats.json` beside `meta.json`.

**Regenerate normalization statistics from the actual training cache**, not from
a re-simulation — the re-simulate path is slightly off-distribution against the
rail-filtered cache.

`normalization_stats.json` is gitignored, so a fresh clone does not have one.
Every checkpoint embeds its own copy, which is the authoritative z-space for
those weights; the loose file is only what an untrained run needs.

## Checkpoints and metrics provenance

A checkpoint is self-contained: it embeds the training configuration and
normalization statistics. Inference merges the EMA state dict over the plain one.
Architecture is read from `config.py` globals rather than constructor arguments —
which is why re-evaluating an archived checkpoint is a multi-step ritual: resize
the config to that architecture, copy the checkpoint into place, rebuild metrics
from the repository root, then copy the results back into the archive. Snapshot
and restore both `config.py` and the live checkpoint around it.

**The archived checkpoints and exports are retired, not regenerated.** They sit
with their manifest under `scratch/retired-alibi-risk-v3/`, which is gitignored
and was never tracked. All twenty checkpoints carry an `alibi_slopes` tensor per
layer and load through none of the strict load sites; every exported descriptor
beside them stamps `arch_version risk-v3` with a `BG_CLAMP_MIN` of 40. No
checkpoint and no export in the tree loads or decodes against the current
architecture.

## Where the documentation splits

`ARCHITECTURE.md` is the **producer** side: dimensions, blocks, heads, the loss
algebra, the optimiser, and what the validation table measures. It states its
formulas symbolically so a `resize_model.py` resize does not falsify it.

The **consumer** side — the three spaces, the Kovatchev constants, the
quantile-assembly algebra, the decode recipe — is `../SPEC/inference.md`, and
`ARCHITECTURE.md` defers to it by name rather than restating it. When the two
appear to touch, the spec wins. `docs/INFERENCE.md` is the stub that routes
there and lists where each concern is implemented in the repository.

One part of the validation table is no longer T1DMAI's alone. The four metric
levels, the band projection, and the CG-EGA anchoring and window are shared with
`T1DMDROID`, which scores its own forecasts against them, so they are defined in
`../SPEC/invariants.md` §6.1–6.3. `config.py` holds the implementation; a document
here that states what those levels are, rather than which name to import, is a
second copy.

The README is the front door; it is the only one of the three written for someone
who has not read the code. It carries no results tables — accuracy figures are
deliberately absent, since the repository publishes no checkpoint to re-derive
them from.

## Publishing decisions

Public at <https://github.com/0xdeadf1sh/T1DMAI>, single branch `main`. History
begins at the initial import — there is nothing before it, so a file overwritten
prior to that commit is unrecoverable.

- **Weights are never in the git tree.** All `.pt`/`.pth` are gitignored and
  shipped out of band. The inference documentation describes the checkpoint
  *format*, not a bundled file.
- **Distribution archives are gitignored** (`*.tar.gz`). `T1DMAI_models.tar.gz`
  is ~1.9 GB and sits in the repository root; the README links it rather than
  committing it.
- **Generated figures and reports are gitignored wholesale** — on the order of a
  gigabyte of regenerable PNGs under `figures/`, `new_models/*/` and
  `metrics/**/figures/`. The source scripts stay. The one exception is
  `screenshots/`, which is committed: `make_readme_figures.py` writes the six
  light/dark PNGs the README embeds, and those must survive a fresh clone or the
  README renders broken. Keep it to figures the README actually references.
- **The JSON summaries are gitignored too** — `metrics/*.json` and
  `models/comparison/data/`. Nothing in the README quotes them, so no published
  number is left without an in-tree source.
- `T1DMSIM` ships as a documented external clone; the local symlink is
  gitignored.
- MIT, with a prominent research-only, not-a-medical-device banner atop the
  README.

## The CG-EGA columns in every training record are void

`train.py` writes nine `cgega_*` keys into each checkpoint's `val_history` and
into `logs/validation_log.csv` at validation time, and its call site passes
reference then prediction. Every such column already on disk is nonetheless the
transposed statistic — reference and prediction reversed — and none of it can be
recomputed, each being the record of a training run that no longer exists to be
re-scored. Only a retrain replaces those numbers.

One flag decides whether those columns are published. `make_figures.py` declares
`CGEGA_COLUMNS_TRUSTWORTHY`, `make_card.py` imports it rather than declaring a
second, and while it is false the CG-EGA panel drops out of `fig05_clinical`,
`fig13_cgega_regions` is not written at all, the three `cgega_ap_*` keys leave
`summary.json`, and the card's six CG-EGA rows are omitted with the card's height
scaled so the remaining table keeps its pitch. It binds by value at import, so
monkeypatching one module at runtime does not reach the other.

The flag tracks the logs, not the source. Set it true only for a tree whose
`logs/validation_log.csv` a retrain has regenerated; a run that merely re-renders
existing logs must leave it false.

The report path is unaffected: `metrics/core/suite.py` recomputes CG-EGA from
stored forecasts, so `metrics/**/stats.json` and the READMEs built from them hold
the correct statistic. Treat the training-log columns as void rather than patching
them, and never compare a card figure against a report figure.

Whether a tree's region partition is anchored on truth is checkable without
rerunning anything. The region is decided by the reference trajectory alone, so
the CG-EGA per-region share must be identical across every capacity and must track
the evaluation set's own hypoglycaemia prevalence, not the model's predicted rate.

## Working in this project

**Never wrap a test run in `timeout`.** Some tests run long simulator warm-ups or
training-step smoke checks, and a hard timeout turns a genuine convergence or
throughput regression into a spurious failure that looks unrelated to the real
bug. If a test appears to hang, investigate it rather than killing it. Where a
wall-clock cap is genuinely needed on a non-test command, use the tool's own
timeout parameter rather than the shell utility.
