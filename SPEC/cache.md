# The pretraining cache contract

*Binds: `T1DMSIM` → `T1DMAI`.*

`T1DMSIM/cache_simulator.py` writes the pool `T1DMAI` pretrains on, and the
trainer memory-maps it. A training run that simulates instead of reading the pool
builds its rows through `T1DMSIM`'s own row builder: one implementation, never a
second copy in the trainer. This document fixes the row geometry, the
counterfactual tails, and what the arrays on disk mean.

**This is the only copy.** Changing anything below is a shared-contract change —
read `../skills/shared-contract-change` first. `invariants.md` defines the grid,
the units and the curves; this document says how a cached row is built from them.

---

## 1. Row geometry

One row is one patient on the five-minute grid:

```
48 h warm-up + U{0..287} extra steps    # a random start hour, drawn per row
2016 steps of context                   # 7 d = 336 patches of 6, behaviour ON
4 paired tails of 24 steps              # 2 h per arm, behaviour OFF
```

Those three numbers are not free. The context is `MAX_CONTEXT_PATCHES ×
PATCH_SIZE` and a tail is `PREDICTION_PATCHES × PATCH_SIZE`, both from
`inference.md` §11, and the offset spans one day on the grid — `288` steps. A
cache built to any other arithmetic trains a model that cannot consume it, so the
two documents move together.

The extra warm-up offset lands the boundary on a uniform hour of day.
It moves the warm-up, never the simulator clock.

The context ends **at the boundary**, so a consumer taking fewer than
`MAX_CONTEXT_PATCHES` crops from the right end of the row.

At the boundary the simulator is deep-copied once per arm, behaviour is switched
off in the copy, the arm's dose is injected at tail step 0 — the first step after
the context — and 24 steps run.

## 2. Behaviour off

A behaviour-off copy skips `_generate_day_events`, pending-event activation and
`_check_and_correct`. Everything else keeps running: `_plan_day`, the curves
already injected, basal and bolus on board, carbohydrate on board, queued
post-hypo basal stand-down windows, HGO, the glucose-effectiveness equilibrium
and its noise, the guardrails, CGM noise and lag.

Nothing is chopped. Doses from before the boundary carry through the tail, so a
tail's logged carbohydrate and insulin curves are the carried-over curve plus the
boundary dose.

The four arms stay in RNG lockstep: arm 0 is bit-identical to an untouched
behaviour-off continuation, and the arms differ only through the injected dose.

## 3. The four arms

The order is frozen — the index is the arm's identity:

| arm | name | boundary dose |
| --- | --- | --- |
| 0 | `none` | — |
| 1 | `bolus` | the row's bolus |
| 2 | `carbs` | the row's carbohydrate |
| 3 | `bolus_carbs` | both, unchanged |

A 2×2 factorial: arm 3 reuses arm 1's bolus and arm 2's carbohydrate exactly.

Doses are drawn **once per row** from a stream keyed on the row seed and
dedicated to this draw — never the simulator's own `rng`, never its `_log_rng`.
Either of those advances a stream the population depends on, and the cache stops
reproducing the one built without tails.

| draw | distribution |
| --- | --- |
| bolus | log-uniform `0.5 .. 20` U |
| bolus analogue | uniform over `BOLUS_VARIANTS` |
| carbohydrate | log-uniform `5 .. 120` g |
| glycaemic index | uniform `0 .. 100` |

The bolus PK shape comes from `bolus_pk_for_dose` on the intended dose, as a meal
bolus does; `invariants.md` §5 holds the curve.

## 4. Logged and true

What the model sees is the patient's record, not the physiology:

- **Carbohydrate** is the guessed grams and guessed GI that `_logged_carb`
  produces. The guess is drawn once per row and shared by arms 2 and 3.
- **Insulin** is the dose the patient injected, before the site-quality factor.
  Delivered is `intended · _site_quality(lifestyle_consistency)`, that factor is
  drawn once per row and shared by arms 1 and 3, and the logged curve and the
  event both carry the **intended** dose.

Both draws land on a throwaway deep copy of the boundary simulator. `_site_quality`
and `_logged_carb` spend the simulator's own `rng` and `_log_rng`, and spending them
on the boundary simulator itself would move arm 0 off the continuation §2 pins.

`total_carb`, `total_insulin`, `basal_insulin`, `bolus_insulin` and every event
channel are logged values. The `*_true` keys are what drives blood glucose, and
the cache does not store them; anything measured against physiology reads those.

## 5. Rejection

Rail rejection and hypoglycaemia oversampling read the **context** alone. A tail
is never rejected, whatever it does.

## 6. On disk

Context channels stay one `(pool_size, 2016)` `.b2nd` array per channel. Beside
them:

| path | shape | contents |
| --- | --- | --- |
| `tail_<channel>.b2nd` | `(pool_size, 4, 24)` | a per-step channel over the four arms |
| `tail_dose_<event_channel>.b2nd` | `(pool_size, 4)` | the boundary point dose, under `--events`; `0` where the arm has no such dose |
| `skills.npy` | `(pool_size, 4)` float32 | the patient skills, written like `icr.npy` |

The per-step tails cover every exported channel the model or a diagnostic reads —
at least `bg_observed`, `bg`, `total_carb`, `total_insulin`, `basal_insulin`,
`bolus_insulin`. Under `--events` the event channels are exported per-step too,
so each of them has both arrays; the `tail_dose_` prefix is what keeps the two
apart on disk, and a name is never shared between the two ranks.

`skills.npy` columns are frozen in this order: `dietary_discipline`,
`attentiveness`, `dosing_competence`, `lifestyle_consistency`.

`meta.json` carries, beside what it already holds:

| key | value |
| --- | --- |
| `cache_format` | `blosc2-ndarray-v3` |
| `n_timesteps` | `2016`, the context alone |
| `context_steps` | `2016` |
| `tail_steps` | `24` |
| `tail_arms` | `["none", "bolus", "carbs", "bolus_carbs"]` |
| `tail_channels` | the channel names behind the `tail_` arrays |

A consumer gates on these keys rather than on a simulated-hours scalar: the
geometry is in the cache, not in a constant the reader holds.

## 7. Normalisation statistics

Fitted over the context **and all four tails**, in the spaces `inference.md` §6
fixes — blood glucose in Kovatchev risk space, the sparse channels in `log1p`
space. The stats file names exactly the channels of the layout it was fitted for.
