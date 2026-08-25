# T1DMAI — working knowledge

Trains the forecasting transformer on `T1DMSIM`'s synthetic traces and exports
the ExecuTorch artifact plus the descriptor `T1DMDROID` loads. Python. MIT.

Passive tooling — run by hand when a new model is wanted.

## The risk-v4 architecture

What `ARCH_VERSION = 'risk-v4'` carries that matters across the suite:

**No input or target smoothing.** The causal Savitzky-Golay smoother was deleted.
Inputs, the forecast target and the anchor are the raw post-noise simulator
signals, glucose clamped to `[10, 400]` and carbohydrate/insulin floored at zero.
`scipy` is not a dependency.

**Kovatchev re-anchored to `[40, 400]`** — `../SPEC/invariants.md` §4 for the
constants, the two-space rule, and why the anchors are not the clamp. The
euglycaemic zero-risk centre sits near 128 mg/dL rather than 112.5.

**Position comes from RoPE alone.** No additive per-head distance bias and no
`alibi_slopes` tensor. QK-norm on Q and K stays.

**Exercise is an input feature** — a carbohydrate-equivalent glucose-disposal
curve in g/step, encoded log1p + z like carbohydrate, never risk-transformed and
never rescaled. The simulator is its only source. The wire's `exercise` carries
the same quantity, in grams of carbohydrate equivalent per bucket, which
`T1DMDROID` writes from the patient's logged sessions against their own
`carb_equiv_per_min`. Units and curve in `../SPEC/invariants.md` §3 and §5.

**The forecast is one case of a masked-BG objective.** A masked span at the right
edge of the window is a forecast, one at the left edge a backcast, anything else
infill. A `bg_masked` bit announces the masked set rather than leaving it
inferable from position, and each masked patch carries its own one-sided,
left-preferring anchor in place of one broadcast `last_bg`.
`../SPEC/inference.md` holds the feature map, the patch geometry, the forward
signature and the head's slot layout.

**Configured capacity is medium** — `D_MODEL` 128, `N_LAYERS` 8, `N_HEADS` 8, set
through `resize_model.py`. Context window `[168, 336]` patches (84–168 h); see
`../SPEC/inference.md`.

The clinical LBGI/HBGI indices in `T1DMSIM` stay on the published constants so
they remain comparable to the diabetes literature. **A cross-repo reviewer will
flag the duplication as drift — it is not.** Model risk space only.

## Cache and statistics seam

T1DMAI's own cache builder is gone; it relies on
`../T1DMSIM/cache_simulator.py` (symlinked as `T1DMSIM/`) to build the blosc2
cache, which also emits `normalization_stats.json` beside `meta.json`.

**Regenerate normalization statistics from the actual training cache**, not from
a re-simulation — the re-simulate path is slightly off-distribution against the
rail-filtered cache.

`normalization_stats.json` is gitignored, so a fresh clone has none. Every
checkpoint embeds its own copy, the authoritative z-space for those weights; the
loose file is only what an untrained run needs.

## Checkpoints and metrics provenance

A checkpoint is self-contained: it embeds the training configuration and
normalization statistics. Inference merges the EMA state dict over the plain one.
Architecture is read from `config.py` globals rather than constructor arguments,
which makes re-evaluating an archived checkpoint a multi-step ritual: resize the
config to that architecture, copy the checkpoint into place, rebuild metrics from
the repository root, then copy the results back into the archive. Snapshot and
restore both `config.py` and the live checkpoint around it.

**The archived checkpoints and exports are retired, not regenerated.** They sit
with their manifest under `scratch/retired-alibi-risk-v3/`, gitignored and never
tracked. All twenty carry an `alibi_slopes` tensor per layer and load through
none of the strict load sites; every exported descriptor beside them stamps
`arch_version risk-v3` with a `BG_CLAMP_MIN` of 40. No checkpoint and no export
in the tree loads or decodes against the current architecture.

## Where the documentation splits

`ARCHITECTURE.md` is the **producer** side: dimensions, blocks, heads, the loss
algebra, the optimiser, and what the validation table measures. Its formulas are
symbolic so a `resize_model.py` resize does not falsify them.

The **consumer** side — the three spaces, the Kovatchev constants, the
quantile-assembly algebra, the decode recipe — is `../SPEC/inference.md`, and
`ARCHITECTURE.md` defers to it by name. Where the two appear to touch, the spec
wins. `docs/INFERENCE.md` is the stub that routes there and lists where each
concern is implemented.

The four metric levels, the band projection, and the CG-EGA anchoring and window
are shared with `T1DMDROID`, which scores its own forecasts against them, so they
are defined in `../SPEC/invariants.md` §6.1–6.3. `config.py` holds the
implementation; a document here stating what those levels are, rather than which
name to import, is a second copy.

The README is the front door, the only one of the three written for someone who
has not read the code. It carries no results tables: the repository publishes no
checkpoint to re-derive accuracy figures from.

## Publishing decisions

Public at <https://github.com/0xdeadf1sh/T1DMAI>, single branch `main`. History
begins at the initial import, so a file overwritten before that commit is
unrecoverable.

- **Weights are never in the git tree.** All `.pt`/`.pth` are gitignored and
  shipped out of band. The inference documentation describes the checkpoint
  *format*, not a bundled file.
- **Distribution archives are gitignored** (`*.tar.gz`). `T1DMAI_models.tar.gz`
  is ~1.9 GB and sits in the repository root; the README links it.
- **Generated figures and reports are gitignored wholesale** — on the order of a
  gigabyte of regenerable PNGs under `figures/`, `models/*/` and
  `metrics/**/figures/`. The source scripts stay. The exception is
  `screenshots/`, which is committed: `make_readme_figures.py` writes the six
  light/dark PNGs the README embeds, and those must survive a fresh clone. Keep
  it to figures the README references.
- **JSON summaries are gitignored too** — `metrics/*.json` and
  `models/comparison/data/`. Nothing in the README quotes them.
- `T1DMSIM` ships as a documented external clone; the local symlink is
  gitignored.
- MIT, with a research-only, not-a-medical-device banner atop the README.

## The CG-EGA columns in every training record are void

`train.py` writes nine `cgega_*` keys into each checkpoint's `val_history` and
into `logs/validation_log.csv` at validation time, and its call site passes
reference then prediction. Every such column already on disk is the transposed
statistic — reference and prediction reversed — and none of it can be recomputed,
each being the record of a training run that no longer exists to be re-scored.
Only a retrain replaces those numbers.

One flag decides whether those columns are published. `make_figures.py` declares
`CGEGA_COLUMNS_TRUSTWORTHY` and `make_card.py` imports it rather than declaring a
second. While it is false the CG-EGA panel drops out of `fig05_clinical`,
`fig13_cgega_regions` is not written, the three `cgega_ap_*` keys leave
`summary.json`, and the card's six CG-EGA rows are omitted with the card's height
scaled so the remaining table keeps its pitch. It binds by value at import, so
monkeypatching one module at runtime does not reach the other.

The flag tracks the logs, not the source. Set it true only for a tree whose
`logs/validation_log.csv` a retrain has regenerated; a run that merely re-renders
existing logs leaves it false.

The report path is unaffected: `metrics/core/suite.py` recomputes CG-EGA from
stored forecasts, so `metrics/**/stats.json` and the READMEs built from them hold
the correct statistic. Treat the training-log columns as void rather than
patching them, and never compare a card figure against a report figure.

Whether a tree's region partition is anchored on truth is checkable without
rerunning anything. The region is decided by the reference trajectory alone, so
the CG-EGA per-region share must be identical across every capacity and must
track the evaluation set's own hypoglycaemia prevalence, not the model's
predicted rate.

## Working in this project

**Never wrap a test run in `timeout`.** Some tests run long simulator warm-ups or
training-step smoke checks, and a hard timeout turns a genuine convergence or
throughput regression into a spurious failure. Investigate an apparent hang
rather than killing it. Where a wall-clock cap is genuinely needed on a non-test
command, use the tool's own timeout parameter rather than the shell utility.
