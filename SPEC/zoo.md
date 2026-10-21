# The zoo contract

*Binds: `T1DMAI` → `T1DMDROID`.*

A zoo model is a direct forecaster: raw glucose and dose windows in, a 24-slot
median out. `T1DMAI`'s `zoo/export.py` writes it; `T1DMDROID` runs it beside the
transformer of `inference.md`. Nothing of `inference.md` applies to it: no risk
space, no patches, no masked spans, no head, no circadian output.

## 1. Bundle

One zip: `<id>.descriptor.json` and the `.pte` its `artifact` names. The
`.pte` is ExecuTorch, XNNPACK CPU, fp32, one method `forward`.

## 2. Descriptor

| Key | Meaning |
| --- | --- |
| `format` | `"t1dm-zoo-1"`. Any other value is refused. |
| `id` | Model identifier, unique on the device. |
| `artifact` | `.pte` filename inside the bundle. |
| `engine` | `"executorch_xnnpack_fp32"`. |
| `model` | Zoo family name, display only. |
| `causal` | `true`: trained and scored with zero doses after the origin. |
| `ctx_steps` | Context length `C`, in five-minute slots. |
| `zone_steps` | Forecast length `Z`; `24` (5 to 120 min). |
| `gap_fill_interp_max_steps` | Longest glucose gap filled by interpolation (§3). |
| `bg_clamp_mgdl` | `[min, max]` the median and every band edge are clamped to. |
| `inputs` | The three tensors of §3, in order, with unit and shape. |
| `output` | `median`, mg/dL, shape `[1, Z]`. |
| `quantile_levels` | The levels of `invariants.md` §6, in its order. |
| `band_offsets_mgdl` | `[levels][Z]` mg/dL offsets (§4). |
| `model_card` | Display only; never decode-critical. |

## 3. Inputs

On the grid of `invariants.md` §1. The **origin** is the slot after the latest
measured reading; the context is the `C` slots ending at that reading.

| Tensor | Shape | Unit | Content |
| --- | --- | --- | --- |
| `bg` | `[1, C]` | mg/dL | Measured readings only. |
| `insulin` | `[1, C + Z]` | U per slot | Bolus plus basal delivered in the slot. |
| `carb` | `[1, C + Z]` | g per slot | Logged carbohydrate. |

`bg` is filled in two passes. A gap of at most `gap_fill_interp_max_steps` slots
between two measurements takes the straight line between them. Every slot still
empty then takes the last value before it, and leading empties the first value
after. The last slot is the measured reading itself; with none, there is no
forecast. Interpolated, reconstructed and carry-forward values never stand in
for that reading.

The last `Z` slots of `insulin` and `carb` are the forecast zone. A `causal`
model reads them as zero, whatever is logged there.

## 4. Output and band

`median[k]` is the forecast for slot `origin + k`, mg/dL. Fan level `i` at slot
`k` is `median[k] + band_offsets_mgdl[i][k]`. The median level's row is all
zero, so the fan's median is the median line. Offsets are non-decreasing across
levels at every slot. Every value is clamped to `bg_clamp_mgdl` after the offset.

The offsets are split-conformal: per slot, the empirical quantiles of
`target − median` over calibration windows disjoint from the fit's draws.

## 5. What a zoo model is not

No dose advice, no dose-response probe, no adapter, no infill or backcast, no
circadian estimate. A consumer routes a zoo model to display and backtest only.
