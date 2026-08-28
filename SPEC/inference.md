# The inference contract

*Binds: `T1DMAI` → `T1DMDROID`; its forecast layout is displayed by
`T1DMSERVER`.*

A hardware- and framework-agnostic account of loading a trained T1DMAI checkpoint
and producing a blood-glucose (BG) forecast — on CPU, GPU, NPU, mobile, or a
non-PyTorch runtime. Verified against `T1DMAI`'s own source: `config.py`,
`model.py`, `utils.py`, `normalization.py`, `inference.py`.

**This is the only copy.** `T1DMAI` produces what is described here and
`T1DMDROID` consumes it; each keeps a stub pointing at this document. Changing
anything below is a shared-contract change — read
`../skills/shared-contract-change` first.

Read `invariants.md` alongside this. The two risk spaces, the quantile levels and
their order, the circadian bins and the five-minute grid are defined there; this
document says how the model uses them.

> [!CAUTION]
> **Research and educational use only.** T1DMAI is trained on synthetic
> simulator data and is **not a medical device**. Its output is a forecast of
> artificial or research signals, **not** clinical guidance. It must not be used
> to make medical, diagnostic, or treatment decisions, to calculate or adjust
> insulin doses, or to manage diabetes in any way. No regulatory clearance.

The model is plain **fp32 PyTorch** — no autocast, no custom CUDA. A non-PyTorch
runtime reimplements only the pre/post-processing: per-channel normalization, the
Kovatchev risk transform, and the quantile assembly. All are pure numeric, and
every constant they need is tabulated in [§11](#11-reference-constants). There is
**no input smoother** in the reference pipeline — the model consumes the raw
signal directly (BG only clamped to `[BG_CLAMP_MIN, BG_CLAMP_MAX]`, the other
channels floored at 0). A consumer may pre-filter its own input
([§7.1](#71-input-filtering-is-the-consumers-choice)).

## Table of contents

- [1. Mental model: three spaces](#1-mental-model-three-spaces)
- [2. Getting a checkpoint](#2-getting-a-checkpoint)
- [3. Architecture](#3-architecture)
- [4. Attention mask](#4-attention-mask)
- [5. The Kovatchev risk transform (physical ↔ risk)](#5-the-kovatchev-risk-transform-physical--risk)
- [6. Normalization (raw ↔ z-score)](#6-normalization-raw--z-score)
- [7. Input construction (the frozen index map)](#7-input-construction-the-frozen-index-map)
- [8. Forward pass and output decode](#8-forward-pass-and-output-decode)
- [9. End-to-end recipe](#9-end-to-end-recipe)
- [10. Minimal PyTorch example](#10-minimal-pytorch-example)
- [11. Reference constants](#11-reference-constants)
- [12. Porting to another runtime](#12-porting-to-another-runtime)

---

## 1. Mental model: three spaces

Every tensor lives in exactly one of three spaces, crossed by exactly two bridge
pairs. Tracking which space a value is in is the single most important thing when
reimplementing inference.

| space | representation |
|---|---|
| **(a) normalized z-space** | model **inputs**: per-channel z-scores. The BG input is `z(f(bg))` — Kovatchev risk **then** z-score. |
| **(b) mg/dL physical** | the per-slot anchor, the true forecast in mg/dL, all clinical thresholds, the GUI. |
| **(c) Kovatchev risk** | the BG input *before* its z-score (`f(bg)`), and **all model outputs** (`q_tau`, `median`). |

The two bridges:

- **(a) ↔ (b): `normalize` / `denormalize`** — [§6](#6-normalization-raw--z-score).
- **(b) ↔ (c): `f` / `f_inv`** on the descriptor's own constants — [§5](#5-the-kovatchev-risk-transform-physical--risk).

The model **never sees raw mg/dL** for BG, and it **never emits mg/dL**. Inputs
are risk-then-z; outputs are risk. Your code owns both bridges: build the input by
`f` then z; decode the output by `f_inv`.

---

## 2. Getting a checkpoint

A checkpoint is a `torch.save` pickle:

```python
import torch
ckpt = torch.load("t1dmai.pt", map_location="cpu", weights_only=False)
```

### 2.1 Checkpoint keys

| key | contents | needed for inference? |
|---|---|---|
| `arch_version` | e.g. `'risk-v5'` | provenance |
| `loss_schema` | e.g. `'kendall-pinball-dilate-v3'` | provenance |
| `step` | training step | provenance |
| `model_state_dict` | live weights | base weights |
| `model_ema_state_dict` | EMA shadow weights (same keys) | **use these** |
| `weighting_state_dict` | `{log_sigma_Q, log_sigma_D}` | no (loss only) |
| `muon_optimizer_state_dict`, `adam_optimizer_state_dict` | optimizer state | no (bloat) |
| `training_config` | dict of shape/hparam scalars | rebuild the graph |
| `normalization_stats` | `{channel: {mean, std}}` | **yes** |
| `conformal_delta`, `conformal_meta` | optional band recalibration (§8.4) | optional |
| `master_seed`, `loss_history`, `val_history`, `loss_ema`, `best_val_*` | telemetry | no |

Some checkpoints carry a leaner set and may **omit `training_config`**; recover
the architecture dimensions from the state-dict tensor shapes
([§3.1](#31-recovering-dimensions)).

### 2.2 Which weights to run

Validation and every reported metric were produced under the **EMA** weights.
Merge the EMA shadow over the live weights, then load:

```python
sd     = ckpt["model_state_dict"]
ema    = ckpt.get("model_ema_state_dict")
merged = {k: ema.get(k, v) for k, v in sd.items()} if ema else dict(sd)
model.load_state_dict(merged, strict=False)   # strict=False tolerates the aux time_head
model.eval()
```

### 2.3 Slimming a shipped checkpoint

For distribution, drop `muon_optimizer_state_dict`, `adam_optimizer_state_dict`,
`weighting_state_dict` and all telemetry; that shrinks the file to roughly the
model size. Keep the EMA weights (or a pre-merged state dict),
`normalization_stats`, and enough of `training_config` (or the shapes) to rebuild
the graph. The `time_head.*` weights are a diagnostic hour-of-day probe that never
touches the BG forecast and may be dropped.

---

## 3. Architecture

`T1DMAI` takes **no constructor arguments**; it reads every dimension from
`config.py` module globals at construction. To rebuild the graph, set those
globals from the checkpoint and instantiate.

### 3.1 Recovering dimensions

| config global | meaning | from `training_config` | from state-dict shape |
|---|---|---|---|
| `D_MODEL` | hidden width | `d_model` | `patch_embed.weight` rows |
| `N_LAYERS` | transformer blocks | `n_layers` | count of `blocks.N.*` |
| `N_HEADS` | attention heads | `n_heads` | `D_MODEL / HEAD_DIM` |
| `HEAD_DIM` | `= D_MODEL // N_HEADS` | derive | `blocks.0.attn.q_norm.weight` length |
| `FFN_DIM` | SwiGLU inner width | `ffn_dim` | `blocks.0.ffn.w1.weight` rows |
| `PATCH_SIZE` | steps per patch = 6 | `patch_size` | `patch_embed.weight` cols `/ 5` |
| `N_INPUT_FEATURES` | 5 (fixed) | — | `PATCH_DIM / PATCH_SIZE` |
| `PATCH_DIM` | `PATCH_SIZE·N_INPUT_FEATURES` = 30 | derive | `patch_embed.weight` cols |
| `PREDICTION_PATCHES` | horizon patches | `prediction_patches` | — |
| `MIN/MAX_CONTEXT_PATCHES` | 168 / 336 | `min/max_context_patches` | — |
| `MAX_MASKED_PATCHES` (M) | head slots the caller fills | `max_masked_patches` | — (sizes no weight) |
| `BG_HEAD_HIDDEN` | head MLP width | — | `bg_head.0.weight` rows |
| `N_SPREADS` | 3 | — | `bg_head.4.weight` rows `= 1 + 2·N_SPREADS` |

A few decode-critical constants are **not** stored anywhere and are fixed released
defaults — reproduce them exactly: `ROPE_BASE = 1000`, RMSNorm `eps = 1e-6`,
`QUANTILE_LEVELS = (.05, .1, .25, .5, .75, .9, .95)`,
`BG_QUANTILE_SPREAD_MIN = 1e-3`, and the Kovatchev constants (§5).

`MAX_MASKED_PATCHES` (`M`) is the head's slot count and the training sampler's cap
on the masked set. It sizes no weight — the BG head is applied per step with
shared weights — so it bounds what a consumer may ask for, not what the graph
computes. It is a training-time choice, not a released constant: read it from
`training_config['max_masked_patches']` and run each checkpoint at its own. A
checkpoint that omits `training_config` loses it, and no tensor shape recovers it.

The exported descriptor carries it as `geometry.MAX_MASKED_PATCHES`, and the
exported graph is sized by it: the masked set crosses as a `(M, T)` one-hot
`slot_sel` input, row `j` naming the patch head slot `j` reads, ascending. Surplus
rows repeat patch 0 and their outputs are discarded. A selection matmul, not a
gather — no int64 tensor crosses the runtime boundary.

The graph emits `hidden` `(B, T, D_MODEL)`, the final-normed hidden state of every
patch, and the export writes `bg_head`'s weights beside the artifact as the flat
fp32 file `head.file` names. A consumer gathers each span's nodes out of `hidden` —
the patches `slot_sel` names, plus the visible neighbour on each side under the
rule of [§8.2](#82-the-step-state-spline) — forms the step states and runs the head
file's MLP on each of them to reproduce `head_raw`. An adapter may act on the node
states, ahead of the spline; with no adapter the two paths agree, which is what a
consumer checks at load. The `head` block carries the tensor order, the shapes, a
sha256 over the exact bytes, and `decoder = "bspline-centre-nodes"` — the name of
the rule in [§8.2](#82-the-step-state-spline); a consumer rejects a value it does
not implement rather than assuming this one. A sidecar synced without the `head`
block decodes `head_raw` alone and needs no decoder name.

`geometry.MAX_CONTEXT_PATCHES` is what the artifact accepts
(`T − PREDICTION_PATCHES`), which a shorter export lowers;
`ARCH_MAX_CONTEXT_PATCHES` is the architecture's own ceiling.

### 3.2 Block structure (pre-norm, 2 residual writes per block)

```
x = patch_embed(patches)                      # Linear(PATCH_DIM -> D_MODEL), has bias
for block in blocks:
    x = x + attn(norm1(x))                    # RMSNorm -> TemporalSelfAttention
    x = x + ffn (norm2(x))                    # RMSNorm -> SwiGLU
x = final_norm(x)                             # RMSNorm
H        = step_states(x, mask_idx, attn_mask)   # (B, M, PATCH_SIZE, D_MODEL) — §8.2
head_raw = bg_head(H)                            # (B, M, PATCH_SIZE, 7)
q_tau, median = assemble_quantiles(head_raw, anchor_bg, mask_idx)   # §8
```

- `step_states` reads the masked patches **by index**, never as a trailing slice:
  the masked set may sit anywhere in the sequence (§4).
- **RMSNorm** (no mean subtraction, no bias): `x / sqrt(mean(x², dim=-1) + eps) *
  weight`, `eps = 1e-6`, learned per-channel `weight` (init 1).

### 3.3 Temporal self-attention (per block)

1. `q, k, v = w_q/w_k/w_v(x)` (no bias), reshaped to `(B, N_HEADS, T, HEAD_DIM)`.
2. **QK-norm**: per-head `RMSNorm(HEAD_DIM)` (`q_norm` / `k_norm`, eps 1e-6) on
   `q` and `k`, **before** RoPE.
3. **RoPE** on `q` and `k` (base 1000; §3.4).
   Position enters through RoPE alone: the block carries no additive distance or
   positional bias.
4. **Mask**: the boolean mask of §4 (`True = attend`), consumed as it stands. A
   `(T, T)` mask broadcasts over batch and head; a per-sample `(B, T, T)` one must
   gain the head axis — `(B, 1, T, T)` — before use, or `B` aligns onto the head
   axis and head *b* reads sample *b*'s mask.
5. `attn = softmax(QKᵀ / sqrt(HEAD_DIM) + mask) @ V`, with `-inf` at the blocked
   positions. In PyTorch this is
   `F.scaled_dot_product_attention(q, k, v, attn_mask=mask)` on the bool mask; the
   `1/sqrt(HEAD_DIM)` scaling is the only thing a reimplementation must reproduce.
6. `out = w_o(concat_heads)`.

A state dict carrying `blocks.*.attn.alibi_slopes` does not load into this graph.

### 3.4 RoPE cache (`build_rope_cache(T, HEAD_DIM, base=1000)`)

```
half     = HEAD_DIM // 2
inv_freq = 1 / (base ** (arange(0, half) / half))     # (half,)
freqs    = outer(arange(T), inv_freq)                 # (T, half)
emb      = concat([freqs, freqs], dim=-1)             # (T, HEAD_DIM)
cos, sin = emb.cos(), emb.sin()
```

Applied per head with the rotate-half convention:

```
x1, x2 = x[..., :half], x[..., half:]
x_rot  = concat([-x2, x1], dim=-1)
out    = x * cos + x_rot * sin
```

Tables depend only on `T` and `HEAD_DIM`, so they are built once per forward and
shared across layers.

### 3.5 SwiGLU FFN

`out = w2( SiLU(w1(x)) ⊙ w3(x) )`, all `bias=False`, where `SiLU(z) = z·σ(z)`.

---

## 4. Attention mask

Every patch of a `T`-patch window is **visible** (its BG is observed), **masked**
(its BG is withheld and the head predicts it) or **padding**. The boolean mask
(`True = attend`) follows that labelling, not a position rule:

```
visible row → visible col    allowed   (bidirectional among evidence)
visible row → masked  col    BLOCKED   (evidence never reads a prediction)
masked  row → any real col   allowed   (a prediction reads everything)
pad row / pad col            blocked, except the diagonal
```

Build it from a `(B, T)` visible bool and a `(B, T)` padding bool, in four lines,
all four load-bearing:

```python
vis    = visible & ~is_pad
masked = ~visible & ~is_pad
attn   = vis[:, None, :] | masked[:, :, None]
attn  &= ~is_pad[:, None, :]    # nothing reads a pad column
attn  &= ~is_pad[:, :, None]    # a pad row reads nothing but itself
attn[:, diag, diag] = True      # no all-False row, which would NaN the softmax
```

The mask goes to attention as bool (§3.3); nothing additive is materialized, and
nothing is memoized — the masked set varies per sample and no cheap key identifies
it.

A masked span ending at patch `T−1` is a **forecast**, one starting at patch 0 a
**backcast**, anything else an **infill**: one objective, not three modes. Two
spans never abut — one visible patch separates neighbours, and that separator is
what makes the anchor (§7.4), the spline's node sequence (§8.2) and the span
grouping well defined. The masked patches are decoded **jointly** in one forward pass, with no
causal triangulation among them, and future leak is prevented solely by the
blocked visible→masked direction. The model accepts any `n_ctx` in
`[MIN_CONTEXT_PATCHES, MAX_CONTEXT_PATCHES]` = `[168, 336]` patches (84–168 h).

`create_attention_mask(n_ctx, P)` is a shim for the right-edge forecast: it builds
that visible bool internally and returns the `(T, T)` mask.

---

## 5. The Kovatchev risk transform (physical ↔ risk)

The symmetrizing transform whose risk-distance equates the clinical danger of a
low and a high excursion. It is the (b) ↔ (c) bridge.

```
f(g)     = SCALE · ( ln(g)^POWER − OFFSET )               # mg/dL -> risk
f_inv(r) = exp( ( r/SCALE + OFFSET )^(1/POWER) )          # risk  -> mg/dL
```

### 5.1 Which parameterization, and where it comes from

Two Kovatchev parameterizations coexist across the suite — a **model** space and a
**clinical** space — defined once, in `invariants.md` §4. Read it before touching
either. Everything on the model path uses the model space; the clinical space
never decodes a forecast.

The model constants are **a property of the checkpoint**, not of the domain, and
travel in the exported descriptor's `kovatchev` block: `SCALE`, `POWER`, `OFFSET`,
`BG_CLAMP_MIN`, `BG_CLAMP_MAX`. Every (b)↔(c) crossing on the model path reads
them from there — the BG input transform, the masked-patch anchors, and decoding
`q_tau`/`median` back to mg/dL.

A checkpoint re-anchored to a different physical BG range ships different
constants, and decoding one against the other fails silently: the output stays
finite and plausible while being wrong by tens of mg/dL. `arch_version = risk-v5`
is anchored on `[40, 400]` — `f(40) = −√10`, `f(400) = +√10` — while its clamp
`[BG_CLAMP_MIN, BG_CLAMP_MAX]` is `[10, 400]`; the anchors are not the clamp.
Against the superseded `risk-v2` constants a true 55 mg/dL decodes as 32 and a
true 300 as 394.

A descriptor carrying no `kovatchev` block is **rejected** rather than defaulted:
there is no safe constant to fall back to.

### 5.2 Clamp guards

Reproduce these to match the model at extremes. `BG_CLAMP_MIN`/`BG_CLAMP_MAX`
below mean *the acting parameterization's* bounds.

- `f_inv`: first replace non-finite risk inputs (NaN/−inf → `f(BG_CLAMP_MIN)`,
  +inf → `f(BG_CLAMP_MAX)`), then **clamp the risk input** to
  `[f(BG_CLAMP_MIN), f(BG_CLAMP_MAX)]` (this keeps the base `r/SCALE + OFFSET ≥ 0`
  — no complex/NaN — and prevents fp32 `exp` overflow), compute `f_inv`, then
  **clamp the output** to `[BG_CLAMP_MIN, BG_CLAMP_MAX]` mg/dL.
- `f` on BG is applied inside `normalize` on physically-clamped mg/dL, so it is
  always well-defined.

The physical bounds are plain numbers travelling in the descriptor — inference
needs no simulator. They also set the rails `forecast_degeneracy_check` tests a
pinned-flat median against, which is why that check takes the descriptor: given
the wrong range it cannot fire at all.

---

## 6. Normalization (raw ↔ z-score)

Four normalized channels, fixed order — the index **is** the model input-feature
index:

```
CHANNEL_NAMES = ['bg_absolute', 'carb_intake', 'insulin_combined', 'exercise_equiv']
                #  feat 0        feat 1         feat 2              feat 3
```

Membership sets: `RISK_SPACE_CHANNELS = {'bg_absolute'}`,
`SPARSE_LOG1P_CHANNELS = {'carb_intake', 'insulin_combined', 'exercise_equiv'}`.

Input feat 4 (`bg_masked`, §7.3) is a bit, not a signal: no entry here, no
statistics, no encoding.

**Units.** BG in mg/dL; carb in **grams per 5-min step**; insulin in **units per
5-min step**, with basal and bolus already **summed** into the single channel;
exercise as a **carbohydrate-equivalent glucose disposal in grams per 5-min step**
— the trained scale, never rescaled to an intensity. One timestep = 5 min; one
patch = 6 steps = 30 min.

**normalize (raw → z):**

```
bg  (risk) :  z = ( f(clamp(x, BG_CLAMP_MIN, BG_CLAMP_MAX)) − mean_bg ) / (std_bg + 1e-8)
carb/ins   :  z = ( log1p(max(x, 0))     − mean_c  ) / (std_c  + 1e-8)
```

**denormalize (z → raw):**

```
bg  (risk) :  x = f_inv( z·(std_bg + 1e-8) + mean_bg )
carb/ins   :  x = max( expm1( z·(std_c + 1e-8) + mean_c ), 0 )
```

`log1p(x) = ln(1+x)`, `expm1(x) = eˣ − 1`. The `std + 1e-8` floor and the
`max(·, 0)` on the sparse inverse are load-bearing.

**Stats structure** (`ckpt['normalization_stats']`, mirrored on disk as
`normalization_stats.json`):

```json
{ "bg_absolute":      {"mean": <risk-space>,  "std": <risk-space>},
  "carb_intake":      {"mean": <log1p-space>, "std": <log1p-space>},
  "insulin_combined": {"mean": <log1p-space>, "std": <log1p-space>},
  "exercise_equiv":   {"mean": <log1p-space>, "std": <log1p-space>} }
```

The BG mean/std live in **risk space** (fit on `f(bg)`); the other three in log1p
space. All four keys are required, each with `std > 0`. Prefer the checkpoint's
embedded stats — they are exactly what the model was trained with.

---

## 7. Input construction (the frozen index map)

Per timestep the features are
`[bg_absolute, carbs, insulin, exercise, bg_masked]` (`N_INPUT_FEATURES = 5`):
feats 0–3 are §6's normalized channels in that order, feat 4 the per-patch mask
bit (§7.3). The output-channel → input-feature map is
`CHANNEL_TO_FEAT = {0: 1, 1: 2, 2: 3}` (carb-channel 0 → feat 1, insulin-channel 1
→ feat 2, exercise-channel 2 → feat 3). BG (feat 0) is never overrideable.

**Patch flatten order is step-major:** `(PATCH_SIZE, N_INPUT_FEATURES) →
PATCH_DIM` via a C-contiguous reshape:

```
flat_index = t · N_INPUT_FEATURES + feat        # t in [0, 6), feat in [0, 5)
PATCH_DIM  = PATCH_SIZE · N_INPUT_FEATURES = 6 · 5 = 30
```

### 7.1 Input filtering is the consumer's choice

The reference pipeline applies **no smoother**. Inputs, forecast target, loss and
metrics all live in one raw post-noise space: the same raw BG is the model input,
the forecast target and the anchor. BG is clamped to the descriptor's
`[BG_CLAMP_MIN, BG_CLAMP_MAX]`; carb, insulin and exercise are floored at `0` (the
`log1p` transform does this in `normalize`).

A consumer may denoise its own BG channel before normalization — a live CGM feed
is noisier than the simulator's — but that is an application decision outside this
contract, and one that moves the anchor with it. Any filter must be **strictly
causal**: reading `x[> t]` to estimate `x[t]` leaks the future into a forecast and
invalidates every metric measured against it. A consumer that filters documents
its own window and taps, in its own repository.

### 7.2 Building the context tensor

`context` has shape `(n_ctx, PATCH_SIZE, N_INPUT_FEATURES)`, already normalized.
From a raw history:

1. Take the trailing raw per-step series for BG (mg/dL), carb (g/step), insulin
   (U/step, basal + bolus summed) and exercise (carb-equivalent g/step), length
   `n_ctx · PATCH_SIZE`, with `n_ctx ∈ [168, 336]`.
2. Clamp BG to `[BG_CLAMP_MIN, BG_CLAMP_MAX]`; floor carb, insulin and exercise at
   0. Optionally pre-filter BG (§7.1); the reference applies no filter.
3. `normalize` each channel (BG via risk-z, the other three via log1p-z).
4. Reshape to `(n_ctx, 6, 5)`: the four normalized channels in feats 0–3, feat 4
   written by §7.3.

### 7.3 Masked patches

A masked patch withholds its BG and announces that it did:

- **feat 0 (BG): 0** — it is what the model predicts.
- **feat 4 (`bg_masked`): 1** in all `PATCH_SIZE` step-major columns of that
  patch, `0` on every visible patch. The bit is per patch, and `z = 0` in a masked
  BG slot is an ordinary reading (≈142 mg/dL on the simulator pool), not a
  sentinel — the masked set is announced, never inferred.
- **feats 1–3 (carb / insulin / exercise): the announced plan.** A masked context
  patch keeps its observed values. A future patch takes the no-event baseline
  `normalize(0)` per channel. A literal `z = 0` routes through the sparse `log1p`
  inverse and announces a phantom ≈0.47 g of carbohydrate, ≈0.15 U of insulin and
  ≈0.025 g of exercise equivalent per step — `expm1` of each channel's fitted
  mean, not the mean itself. Overwrite these slots with **announced** future doses
  or sessions (normalized) to condition the forecast; never write into them
  anything the patient did not announce.

The `P = PREDICTION_PATCHES` future patches carry no observed BG at all, so all of
them are masked. A masked set totals at most `MAX_MASKED_PATCHES` patches, and at
least one patch of the window stays visible.

### 7.4 The per-slot anchor

`model.forward` requires a `(B, M)` mg/dL anchor, one per masked patch. It is
**one-sided and left-preferring**: the last step of the span's left neighbour, or
the first step of the right neighbour when the span starts at patch 0. Every slot
of one span carries the same value, so a slot near a span's right edge anchors
past its nearest visible evidence — the geometry, not a defect. For the trailing
forecast it is the last context BG cell.

An anchor cell is always a **visible** cell, read back from the context:

```
anchor = f_inv( context[p, s, 0] · (std_bg + 1e-8) + mean_bg )  # clamp to the physical range
```

Indexing a masked cell yields a plausible anchor rather than an error, since its
feat 0 is a legal-looking `z`. The forward asserts
`anchor_bg ≥ BG_CLAMP_MIN − 1e-3` over all `M` slots (a units tripwire that
catches a z-scored value routed in by mistake) and forms the risk anchor
`f(anchor_bg)` internally. Padded slots must still carry a legal mg/dL value;
their outputs are discarded by `valid`.

---

## 8. Forward pass and output decode

**Signature** (frozen):
`forward(patches, attn_mask, anchor_bg, mask_idx, return_time=False) -> (q_tau, median)`.

- `patches`: `(B, T, PATCH_DIM)`, `T ≤ MAX_SEQ_LEN` — a batch is left-padded to
  its own longest window, so `T` varies and is never fixed at `MAX_SEQ_LEN`;
  `attn_mask`: `(T, T)` or `(B, T, T)` bool (`True = attend`); `anchor_bg`:
  `(B, M)` mg/dL (§7.4); `mask_idx`: `(B, M)` int64, the patch index each of the
  `M` head slots reads.
- `q_tau`: `(B, M, PATCH_SIZE, 7)` in **risk space**, ascending τ.
- `median`: `(B, M, PATCH_SIZE)` in risk space (`== q_tau[..., 3]`).
- `return_time=True` additionally returns the diagnostic hour-of-day probe logits,
  one per slot; they never affect `q_tau`/`median`.

A masked set smaller than `M` pads the surplus slots, which gather patch 0 and
carry a legal anchor; a `(B, M)` `valid` bool marks them and the decode drops
them, leaving `P` rows in `mask_idx` order — `P = PREDICTION_PATCHES` for the
trailing forecast. `M = MAX_MASKED_PATCHES` (§3.1) is the largest masked set the
objective admits.

`QUANTILE_LEVELS = (0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95)`, median column
index `3`.

### 8.1 `assemble_quantiles(head_raw, anchor_bg, mask_idx, valid=None, carry_spread=0.0)`

`head_raw` is `(B, M, S, 7)`: column 0 = median delta; columns 1..3 = the τ>.5
spreads (nearest→far, .75/.9/.95); columns 4..6 = the τ<.5 spreads (nearest→far,
.25/.1/.05).

The assembly is pointwise per `(slot, step)`: it groups nothing and low-passes
nothing. Spans enter the decode one stage earlier, in the step-state spline
([§8.2](#82-the-step-state-spline)).

```
anchor = f( clamp(anchor_bg, BG_CLAMP_MIN, BG_CLAMP_MAX) )  # (B, M), risk; flat over S
delta  = head_raw[..., 0]                                   # (B, M, S)

# --- median ---
m = anchor[..., None] + delta                               # (B, M, S)

# --- spreads ---
spread = softplus(head_raw[..., 1:]) + 1e-3              # strict positive floor
d_up   = spread[..., :3]                                 # .75/.9/.95
d_dn   = spread[..., 3:]                                 # .25/.1/.05
c_up   = carry_spread[..., :3]                           # .75/.9/.95
c_dn   = carry_spread[..., 3:]                           # .25/.1/.05
up = m[..., None] + hypot(c_up, cumsum(d_up, dim=-1))     # ascending
dn = m[..., None] − hypot(c_dn, cumsum(d_dn, dim=-1))     # descending in value
q_tau = concat([ flip(dn, -1), m[..., None], up ], dim=-1)   # (B, M, S, 7) ascending τ
```

The median is the slot's own anchor plus the head's per-step delta. At
initialization (`delta ≈ 0`) it is `≈ anchor`, a flat persistence forecast. Its
smoothness comes from the step states the head reads, not from this assembly
([§8.2](#82-the-step-state-spline)). The `cumsum` of strictly-positive spreads
guarantees a monotone ascending fan around the median.

`carry_spread` is **per level**, in `head_raw[..., 1:]`'s own layout —
`[.75 .9 .95 | .25 .1 .05]`, six risk-space offsets — and defaults to `0` (only
rolling inflation uses a non-zero value, §9). A scalar broadcasts to all six and is
a defect anywhere the six differ: it re-seeds every level from the outermost one's
accumulation, and the fan stops being a fan.

The carry composes with the span's own spread **in quadrature**, not by addition:
the two are increments of different rolls, and independent increments add
variances. Addition is the perfectly-correlated bound, and over four rolls it is
twice as wide as it should be. `hypot(0, x) = x`, so a zero carry is the identity
and every non-rolling caller is bit-unaffected.

### 8.2 The step-state spline

The head runs on one `D_MODEL` state per 5-minute step, interpolated from the
trunk's patch states by a uniform cubic B-spline. `step_states(x, mask_idx,
attn_mask)` returns `(B, M, S, D_MODEL)` from the final-normed `x` `(B, T, D_MODEL)`.

**Nodes.** `mask_idx` groups the `M` slots into contiguous **spans**. For a span of
`L` patches the node sequence is: the visible patch immediately left of the span
(node `0`) where it exists, the `L` masked patches (nodes `1..L`) in order, the
visible patch immediately right of the span (node `L+1`) where it exists. A
neighbour **exists** when it lies inside the window and the span's first (last)
patch may read it under the attention mask of [§4](#4-attention-mask), so a pad row
is never a node. Node `n`'s state is `x[b, patch(n)]`.
Every node sits at its patch centre.

**Coordinate.** Step `j` (`0..S-1`) of masked patch `i` (`1..L`) sits at

```
c = i + (j − (S−1)/2) / S          # node units; S = PATCH_SIZE
```

**Weights.** With `k = floor(c)` and `u = c − k`,

```
w(u) = ( (1−u)³/6, (3u³ − 6u² + 4)/6, (−3u³ + 3u² + 3u + 1)/6, u³/6 )
h(c) = Σ_{o = −1..2}  w_o(u) · N[ clamp(k + o, lo, hi) ]
```

`w` sums to 1 at every `u`.

**Ends.** `lo = 0` when node `0` exists, else `1`; `hi = L+1` when node `L+1`
exists, else `L`. The clamp repeats the end node, so a span at either edge of the
window uses the same formula as one bracketed on both sides.

**Matrix form.** The weights depend only on `(L, has_left, has_right)`, never on
the states, so they are one fixed matrix `W(L, has_left, has_right)` of shape
`(L·S) × (L + has_left + has_right)` — rows in patch-major step order
(`row = (i−1)·S + j`), columns the nodes `lo..hi` ascending — and the span's step
states are `H = W · N`. Rows sum to 1.

Nothing here is saved in the checkpoint: `W` is recomputed per
`(L, has_left, has_right)`.

### 8.3 Decoding to mg/dL

Inference owns the risk → mg/dL inverse:

```
median_bg = f_inv(median).flatten()      # (P·S,) mg/dL — the headline forecast
bands     = f_inv(q_tau)                  # (P, S, 7) mg/dL band edges
```

At the 2 h default, `P·S = 4 · 6 = 24` steps = 2 h at 5-min cadence. Both are
clamped into `[BG_CLAMP_MIN, BG_CLAMP_MAX]` by `f_inv`.

### 8.4 Conformal recalibration

A band correction `delta` is additive mg/dL per `(step, τ)`, applied downstream of
`f_inv`. It may be carried by the checkpoint (`ckpt['conformal_delta']`) or fitted
by the consumer; the same rules govern it either way.

**The apply.** `apply_quantile_conformal(bands, delta, median_idx=3)` takes one
**two-dimensional** delta, shaped like the fan's own trailing `(step, τ)` axes —
`(P·S, 7)` over a flattened horizon — adds it, and re-enforces three invariants:
the **median is held fixed** (`delta[..., 3] = 0`), the **fan stays monotone** (no
crossing), and an **all-zero delta is the identity**. The point forecast is
untouched. Skipping the apply is bit-identical to the raw bands. A delta of any
other rank is rejected, never broadcast.

**The fit.** Split conformal on a held-out calibration set of matured
`(forecast, realized)` pairs. Per `(step, τ)` the residuals are
`realized − band[step, τ]`; `delta[step, τ]` is the empirical `τ`-quantile of those
residuals, taken as the **side-aware** 1-indexed order statistic over the `n`
sorted residuals:

```
idx(n, τ) = floor((n+1)·τ)   for τ < 0.5      # a LOWER edge
            ceil((n+1)·τ)    for τ > 0.5      # an UPPER edge
```

clamped into `[1, n]`; the median column is skipped. The two sides round opposite
ways: `ceil` on a lower edge sits that edge one order statistic too high and lets
realized BG escape below it more often than the nominal rate — anti-conservative on
exactly the hypo edge, and worst at small `n`. Below the `n` at which every level
resolves without clamping (**19** for the seven levels of `invariants.md` §6) the
extreme levels' offsets are simply the minimum and the maximum of the residual
sample, and the coverage they claim is arithmetic that never ran.

**The region bins.** A fit is either **marginal** — one delta over the whole
calibration set — or **region-binned** (Mondrian): the same fit run once per bin on
that bin's own rows, stacked to `(n_bins, P·S, 7)`. The region is a property of the
whole window, read off where its forecast is heading: the mean of the median line
over the final patch of the horizon. An apply holds the median fixed, so a window's
region is the same before and after correction. The one edge is at 110 mg/dL,
inside the euglycaemic band; an edge at a clinical threshold would split the windows
that decide an alarm across two separately fitted corrections. A bin holding fewer
than **39** calibration windows — the `n` below which its own τ.05 offset is the
calibration-sample minimum — takes the marginal delta instead. A stack travels with
a meta carrying `layout`, `region_edges`, `region_variable` and the per-bin fallback
record; without them a consumer cannot reconstruct the bin.

**Applying a stack.** Group the windows by bin and call the apply once per group
with that bin's `(P·S, 7)` slice. A per-window delta is never gathered.

**One protocol per delta.** A delta is fit and applied within one masked-set
protocol. A forecast fit is the one that ships; an infill fit is stored apart under
`shipped = false` and never merged into a shipped band — its slots are bracketed by
visible evidence on both sides, so its residuals are not exchangeable with a
forecast's.

Validity rests on **exchangeability** between the calibration set and the forecasts
the delta is later applied to. Two consequences are not optional: the split is
**chronological** (older fitted on, newer held out and scored), and the held-out
τ.05–.95 coverage is **reported beside the mean band width**, per `invariants.md`
§6.2 — a band widened until it swallows every truth covers perfectly and forecasts
nothing.

**Where each fit lives.** A checkpoint-carried delta is fit on the **simulator**
distribution; for real-world CGM it must be re-fit per cohort or omitted, and the
export path ships none. Off device, `T1DMAI/conformal.py` fits and applies one
delta and `T1DMAI/mondrian.py` bins it into a stack. On device, `T1DMDROID` fits a
**marginal** per-patient delta from the patient's own matured forecasts — one
`(step, τ)` correction, no region axis — and applies it to **display only**: the raw
fan is what the alarm engine, the dose calculator, the accuracy suite, the
`prediction` table and the wire all carry. Both implementations are bound by the
order-statistic rule above, and because both publish τ.05–.95 coverage under one
name, neither may change it alone.

**Corrective versus constitutive.** The delta above *corrects* a fan the model
already emitted, which is why it is display-only. The same fit and apply also give a
band to a forecaster that has none — `T1DMDROID`'s classical baseline starts from a
degenerate fan whose seven levels are all the median, and its residual quantiles
become its interval. `invariants.md` §6.2's degenerate-band property makes that
exact: a collapsed fan projects to its own point forecast, so the apply opens it
without moving anything.

The two differ in what a consumer may do with the result. A corrective delta is
fitted after the model, stored apart from it, and skippable, so a raw and a
calibrated fan both exist and only the raw one may be classified on, stored, or
sent. A constitutive one is fitted with the model and travels inside it, so one fan
exists and it is stored and sent like any other output. Neither may move a median.

---

## 9. End-to-end recipe

**Single window** (≤ `PREDICTION_HORIZON_HOURS`, default 2 h):

1. Gather the trailing raw history: BG (mg/dL), carb (g/step), insulin (U/step,
   basal + bolus summed), exercise (carb-equivalent g/step), length `n_ctx · 6`,
   `n_ctx ∈ [168, 336]`.
2. Clamp BG to `[BG_CLAMP_MIN, BG_CLAMP_MAX]`; floor carb, insulin and exercise at
   0 (no filtering — `normalize` floors the sparse channels through `log1p`).
3. `normalize` each channel → `context (n_ctx, 6, 5)`, feat 4 written in step 4.
4. Choose the masked set — the default is the trailing `P` patches, a forecast.
   Build `patches (T, 30)`: context reshaped step-major, then `P` future patches
   with BG = 0 and carb/insulin/exercise at `normalize(0)` **or** announced. On
   every masked patch zero feat 0 and set feat 4 (§7.3).
5. Build `attn_mask` from the visible/masked labelling (§4).
6. `anchor_bg`: one mg/dL anchor per masked patch (§7.4); `mask_idx`: their patch
   indices; pad both to `M` slots.
7. `q_tau, median = model(patches[None], attn_mask, anchor_bg[None], mask_idx[None])`.
8. Drop the padded slots, then `median_bg = f_inv(median)` (mg/dL);
   `bands = f_inv(q_tau)`; optionally conformal-recalibrate `bands` — the delta is
   fit against the forecast masked set and means nothing under another (§8.4).

**Autoregressive rolling** (horizons beyond one window): repeat the window; each
roll —

1. Run steps 4–8 → a risk-space `median`.
2. Re-feed: `median → f_inv → mg/dL → normalize → BG feat-0 slot` of the new
   context patches, clearing feat 4 — those patches are visible now. Carb, insulin
   and exercise come from the caller's announced schedule for that roll, else the
   `normalize(0)` no-event baseline.
3. Slide the context forward, dropping the oldest patches once it exceeds
   `MAX_CONTEXT_PATCHES`. BG anchors at the last forecast BG carried across rolls.
4. To keep the band fan from resetting at each roll seam, carry the terminal-step
   spread forward via `assemble_quantiles`'s `carry_spread`, **per level**:

   ```
   c_up[k] = q_tau[−1, −1, 3 + 1 + k] − m[−1, −1]      k = 0,1,2 → .75/.9/.95
   c_dn[k] = m[−1, −1] − q_tau[−1, −1, 3 − 1 − k]      k = 0,1,2 → .25/.1/.05
   ```

   read off the fan the roll just produced — which already carries the incoming
   `c`, so each roll folds in the model's own terminal spread and no more. Every
   level resumes at the width it reached; the median is untouched.

The shipped `inference.predict` and `inference.predict_rolling` implement both
recipes; `predict_what_if` is `predict` with `overrides`. `predict` takes the
masked set as `mask_spans` and defaults it to the trailing forecast.

---

## 10. Minimal PyTorch example

```python
import numpy as np, torch
from model import T1DMAI
from inference import predict
from normalization import normalize, CHANNEL_NAMES
from config import MIN_CONTEXT_PATCHES, PATCH_SIZE, N_INPUT_FEATURES

# 1. Load a checkpoint and its embedded stats.
ckpt   = torch.load("t1dmai.pt", map_location="cpu", weights_only=False)
stats  = ckpt["normalization_stats"]
model  = T1DMAI()                                   # dims read from config.py
sd, ema = ckpt["model_state_dict"], ckpt.get("model_ema_state_dict")
merged = {k: ema.get(k, v) for k, v in sd.items()} if ema else dict(sd)
model.load_state_dict(merged, strict=False)
model.eval()

# 2. Build a normalized context from a raw history.
n_ctx = MIN_CONTEXT_PATCHES
n_ch  = len(CHANNEL_NAMES)                          # 4 normalized channels
raw   = np.zeros((n_ctx * PATCH_SIZE, n_ch), dtype=np.float32)
raw[:, 0] = 120.0        # BG mg/dL   (raw; clamp a real stream to the physical range)
raw[:, 1] = 0.0          # carb g/step
raw[:, 2] = 0.02         # insulin U/step (basal)
raw[:, 3] = 0.0          # exercise carb-equivalent g/step
ctx_norm = normalize(raw, stats)                    # (n_ctx*6, 4) normalized
context  = torch.zeros(n_ctx, PATCH_SIZE, N_INPUT_FEATURES)
context[..., :n_ch] = torch.from_numpy(
    ctx_norm.reshape(n_ctx, PATCH_SIZE, n_ch))      # feat 4 stays 0: predict() writes it

# 3. Forecast. predict() handles the mask, the per-slot anchors, and f_inv.
with torch.no_grad():
    out = predict(model, context, normalization_stats=stats)

median_bg = out["median_bg"]    # (P*PATCH_SIZE,) mg/dL headline, P masked patches
bands     = out["bands"]        # (P, PATCH_SIZE, 7) mg/dL fan
```

To announce future doses and sessions, pass
`overrides={0: carb_norm, 1: insulin_norm, 2: exercise_norm}` (each
`(PREDICTION_PATCHES, PATCH_SIZE)` **normalized**) to `predict`. For a backcast or
an infill pass `mask_spans=[(start_patch, length), ...]`. For horizons past 2 h use
`inference.predict_rolling(...)`.

---

## 11. Reference constants

Everything a from-scratch reimplementation needs (none require the simulator):

| constant | value |
|---|---|
| Kovatchev `SCALE / POWER / OFFSET` | **descriptor-carried** (§5.1); `risk-v5` specifies `2.2211457449985317 / 1.084 / 5.540076976170212` |
| `BG_CLAMP_MIN / MAX` | **descriptor-carried**; `10.0 / 400.0` under `risk-v5` |
| risk clamp `[f(min), f(max)]` | derived from the two bounds; `[−6.8198, +3.1623]` under `risk-v5` — asymmetric, since the transform's anchors (`f(40) = −√10`, `f(400) = +√10`) are not the clamp |
| the clinical scale | **not here** — `invariants.md` §4. It never decodes a forecast. |
| `PATCH_SIZE` | `6` (5-min steps; one patch = 30 min) |
| `N_INPUT_FEATURES` / `PATCH_DIM` | `5` / `30` |
| feature order | `[bg_absolute, carb, insulin, exercise, bg_masked]` |
| `CHANNEL_TO_FEAT` | `{0: 1, 1: 2, 2: 3}` |
| patch flatten | step-major: `flat = t·5 + feat` |
| `PREDICTION_PATCHES` / output steps | `4` / `24` (2 h) at the default horizon |
| `MIN / MAX_CONTEXT_PATCHES` | `168 / 336` (84–168 h) |
| `QUANTILE_LEVELS` | `(.05, .1, .25, .5, .75, .9, .95)`; median idx `3` |
| `N_SPREADS` / `N_QUANTILES` | `3` / `7` |
| `BG_QUANTILE_SPREAD_MIN` | `1e-3` |
| `MAX_MASKED_PATCHES` (M) | **checkpoint-carried** (§3.1); surplus slots are padded and discarded |
| `ROPE_BASE` | `1000` |
| RMSNorm `eps` | `1e-6` |
| normalize `std` floor | `1e-8` |
| input filter | none in the reference (raw signal; BG clamped to the descriptor's physical range, carb/insulin/exercise floored at 0); a consumer's own filter must be strictly causal (§7.1) |
| position encoding | RoPE only; no additive distance bias |
| SDPA scaling | `1/sqrt(HEAD_DIM)` |

The per-channel `mean` / `std` come from `ckpt['normalization_stats']` (BG in risk
space, carb/insulin/exercise in log1p space).

---

## 12. Porting to another runtime

- **The graph is plain fp32 PyTorch** — `model.eval()` + `torch.no_grad()`, no
  autocast anywhere. Once the dimensions are fixed the graph is static and
  **traceable / ONNX-exportable**.
- The only non-elementwise/matmul op is `F.scaled_dot_product_attention` with a
  bool mask. Export with a math-fallback SDPA, or hand-roll
  `softmax(QKᵀ/sqrt(HEAD_DIM) + mask) @ V` with `-inf` at the blocked positions.
  RoPE, RMSNorm and SwiGLU are all elementwise or matmul.
- **What a non-PyTorch runtime reimplements outside the exported graph** (all pure
  numeric): per-channel `normalize` / `denormalize`; `kovatchev_f` /
  `kovatchev_f_inv` with their clamp guards; the per-slot anchor; the step-major
  patch flatten; the masked-patch fill (feat 0 zeroed, feat 4 set, the maskable
  feats at `normalize(0)` or the announced plan); the bool attention mask; the
  step-state spline (§8.2) and the head MLP over its output;
  `assemble_quantiles` (softplus, cumsum); and the optional conformal apply.
- **Watch the `bg_masked` bit.** Nothing else writes feat 4, so a builder that
  forgets it announces every masked patch as an observation, with every shape still
  matching and every fan still monotone.
- **Keep the decode constants exact.** `ROPE_BASE`, the B-spline weights and the
  quantile floor are not stored in the checkpoint; a released model is locked to
  the values in §11 and the spline of §8.2.
