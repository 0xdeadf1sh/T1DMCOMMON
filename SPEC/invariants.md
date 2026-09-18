# Domain invariants

Normative definitions shared across the T1DM suite. Where a repository's code
disagrees with this document, one of the two is a defect; neither may be assumed
correct without checking the other.

Each invariant records which repositories it binds. `../CLAUDE.md` holds the
active/passive distinction that governs how strongly.

A companion specification applies these definitions to a particular seam and is
equally normative: `inference.md`, the model contract between the trainer and the
app. Both are single-copy — see `../scripts/check-no-copies.sh`.

---

## 1. The five-minute grid

*Binds: all three.*

Physiologic samples, meal events and dose events sit on a fixed five-minute grid
in epoch milliseconds:

```
ts % 300000 == 0
```

`T1DMDROID` **snaps** a timestamp to the grid before storing it. The snapping rule
is part of the contract: two implementations that floor where the other rounds
both land on the grid and both pass every validation, while filing the same
reading in different buckets.

Gaps are explicit. A grid slot with no measurement stores `NULL`; it is never
back-filled at rest. Gap-filling is a presentation step, and a filled value must
never be written back as though measured.

A slot is in one of three states: measured, empty, or tombstoned. A tombstone is
a deletion the patient authored; it hides the row, is not a gap the sensor left,
and must never be re-filled by a restore of the value it retired.

One narrow exception. A model-reconstructed value may be promoted to a stored
sample by a deliberate user action, and only while it stays permanently flagged as
reconstructed. The flag is for
life: such a value may never clear an alarm, never anchor or condition a dose
recommendation, never be a fit target or a fit window's context, never count as
measured context for a cold start or a warm-up, and never enter a statistic as a
measurement. A carry-forward or interpolated value gets no such route.

## 2. `tz_offset`

*Binds: all three.*

`tz_offset` is the client's UTC offset **in minutes, east-positive**, at the time
of the event. `UTC−5` is `-300`.

It is carried alongside the timestamp so local time can be rendered after the
fact. It never shifts the timestamp itself: `ts` is always UTC.

Anything aggregating by day states whether its day boundary is UTC or local; the
two disagree for a quarter of the world and across every DST transition.

`T1DMDROID`'s statistics state it in the day-boundary block on `advanced_stats`
in `crates/t1dm-core/src/stats.rs`: every day-keyed reduction there — the weekday
× hour grid, the AGP ribbon, the six-hour diurnal buckets, MODD, ADRR and the
day-to-day SD — is keyed on **local** time, resolved per sample from that
sample's own `tz_offset`. CONGA needs no boundary: it compares readings a fixed
lag apart, so a constant offset cancels.

## 3. Units and sign conventions

*Binds: all three.*

Storage units are fixed. Display conversion is presentation-only and never
written back.

| Quantity | Unit | Notes |
| --- | --- | --- |
| Blood glucose | mg/dL | The only BG unit stored or sent. See §4. |
| Carbohydrate | grams | |
| Insulin | units | |
| Basal slot dose | units **delivered in that slot** | Not a rate. Summing slots yields a daily total. |
| Glycaemic index | 0–100 | A GI, not a 0–1 fraction. |
| Heart rate | bpm | |
| Exercise | grams of carbohydrate equivalent | Glucose disposal, expressed as the carbohydrate it offsets. Never a duration, an intensity, or an energy. Positive-valued; the sign lives in the equation that subtracts it. See §5. |
| Duration | minutes | Everywhere `duration_min` appears. |
| Rate constants | per hour | `ka_per_hour`, `ke_per_hour`. |
| Timestamps | epoch milliseconds, UTC | |

A quantity that is a **rate** on one side and an **amount** on the other is the
most damaging error in this table, because it scales by a duration and still
looks plausible. Basal is an amount.

**Display conversion.** Blood glucose is stored and transmitted in mg/dL and
converted only for display:

```
mg/dL per mmol/L = 18.0182
```

Not 18.0. The two differ by about 0.1%, and both sides render one decimal place,
so the gap straddles the rounding boundary for roughly one integer mg/dL value in
nine: 100 mg/dL prints as `5.6` under 18.0 and `5.5` under 18.0182.

## 4. The two risk spaces

*Binds: all three. The most easily conflated pair in the suite.*

Two Kovatchev parameterizations coexist **by design**. They are numerically
similar, dimensionally incompatible, and must never be mixed.

### Clinical risk space

The published transform, anchored on the physical BG range clinicians assume when
reading a risk index. Used for **LBGI, HBGI, and anything a human reads**.

```
f(BG) = SCALE * (ln(BG)^POWER - OFFSET)
SCALE = 1.509   POWER = 1.084   OFFSET = 5.381
clinical BG domain: [20, 600] mg/dL
```

These constants are published and fixed, and may be hardcoded. Input is clamped
to `[20, 600]` before the transform, so `f` is finite and `f_inv` never takes a
negative base.

The domain is part of the definition. It is the range the transform was
constructed symmetric over: `f(20) ≈ -3.1633` and `f(600) ≈ +3.1619`, equal and
opposite to within a thousandth. A narrower clamp saturates real glucose early
and breaks that symmetry. Two implementations sharing the constants but clamping
differently return different risk for the same glucose, and neither looks wrong.

**The clamp fails closed.** An invalid, missing, or out-of-domain glucose reads as
**maximal hypo risk** — the value at the low bound — never as the risk-neutral
point. Zero on this scale is the *symmetry point*, roughly 112.5 mg/dL, which is
perfect euglycaemia; mapping a garbage reading to zero announces an ideal glucose
exactly when the input is least trustworthy. That direction is a safety property;
do not simplify it to a zero.

### Model risk space

The same family, **re-anchored for the network**. The model's input and output BG
both live here.

The current anchoring (`ARCH_VERSION = risk-v5`) is solved so that `f(40) = -√10`
and `f(400) = +√10` — risk 100 at both rails:

```
SCALE = 2.2211457449985317   POWER = 1.084   OFFSET = 5.540076976170212
```

The anchors are not the clamp. BG is clamped to `[BG_CLAMP_MIN, BG_CLAMP_MAX]`,
which the descriptor carries beside the constants and whose low rail sits below
the low anchor, so the realised risk range is asymmetric and reaches further
below `−√10` than above `+√10`. Never assume `±√10` bounds a risk value.

A consequence: the zero-risk centre moves from roughly 112.5 mg/dL in clinical
space to roughly **128 mg/dL** in model space. The two transforms disagree about
where euglycaemia sits.

These constants are **a property of a checkpoint**, not of the domain. They are
read from the model descriptor's `kovatchev` block and **must never be
hardcoded**; `inference.md` §5 gives the block and its guards. A re-anchored
checkpoint ships different constants, and decoding it against the clinical ones
misreads glucose badly and silently.

The scale triple survives in two hardcoded copies with no shared source and no
cross-repository equality test — `T1DMAI/utils.py` (`_KOVATCHEV_*`) and
`T1DMSIM/cache_simulator.py` (`NORM_BG_RISK_*`). Re-tuning the transform means
editing both.

The **bounds** are not duplicated: `T1DMAI` reaches `BG_CLAMP_MIN` /
`BG_CLAMP_MAX` in `T1DMSIM/simulator.py` through a symlinked checkout. That is
the pattern the constants themselves should follow.

`T1DMDROID` holds no copy. Its Rust core reads the block from the descriptor,
**rejects** a descriptor that omits it rather than defaulting to any scale, and
takes every model-path bound from it — the input clamp, the `f_inv` output clamp,
and the rail-pinned degeneracy test alike. A rail-pin check against a fixed
20 mg/dL is meaningless for a model whose floor is its own descriptor's
`BG_CLAMP_MIN`.

### Rules

1. Every symbol, field and function carrying a risk value **names its space**.
   `kovatchev_f` without qualification is a defect.
2. A value in one space is never compared to, stored as, or displayed as a value
   in the other.
3. **Risk space never leaves the decode.** Every BG the phone stores, draws or
   sends — samples, prediction lines, quantile fans — is mg/dL. Decoding from
   model space happens on the phone, before anything is stored.
4. Only `T1DMAI` (which trains and exports) and `T1DMDROID` (which decodes) have
   any business with model space.
5. **A descriptor and a model artifact are one unit.** They are coherent only if
   they come from the same export run, and nothing on device can check that: a
   stale descriptor beside a fresh artifact decodes finite, plausible, wrong.
   Ship them together, and never hand-edit one to match the other.

## 5. Curve semantics

*Binds: all three.*

A curve is a **per-five-minute rate series that sums to the event's total**. It is
never an amount-in-body.

What the rate *is* differs by channel:

- **Carbohydrate — appearance (Ra) rate.** Grams entering the blood per bucket: a
  gamma curve shaped by the glycaemic index, spread across the absorption window.
  Not the moment of eating.
- **Insulin — PK action rate.** Units of action per bucket across the duration of
  insulin action: a gamma curve for a rapid bolus, a Bateman curve for a
  long-acting basal. Not the injection instant, and not a delivery schedule.
- **Exercise — glucose disposal rate.** Grams of carbohydrate equivalent removed
  from the blood per bucket: a gamma curve spread across the session and the
  ninety minutes after it. Not the session's duration, intensity, or energy cost.

A gamma bucket carries the density `t^(k−1)·e^(−t/θ)` averaged over sixteen
midpoints across its five minutes, from `t = 0`; a Bateman bucket carries
`e^(−ke·t) − e^(−ka·t)` at its start, `t` in hours, with its last sixth tapered to
zero by a smootherstep. Both are then scaled to sum to the total.

A rapid bolus is a gamma curve whose `θ` and duration grow with the dose, about a
5 U reference:

```
x   = √max(dose_U, 0.5) − √5
θ   = θ₅ · (1 + 0.17 · x)
dur = clamp(dur₅ + 0.8 · x, 2, 9)      # hours
```

| class | analogues | k | θ₅ (min) | dur₅ (h) |
| --- | --- | --- | --- | --- |
| rapid | aspart, lispro | 3.0 | 45.0 | 5.6 |
| ultra-rapid | faster aspart, ultra-rapid lispro | 2.55 | 52.0 | 4.7 |

`k` and `θ` fit the clamp glucose-infusion fractions at 1 h and 2 h after 0.2 U/kg
(Heise 2015); the dose terms fit the per-dose peak and duration tables of the
Fiasp and Lyumjev labels.

A long-acting basal is a Bateman curve over its action window:

| analogue | ka (1/h) | ke (1/h) | action (h) |
| --- | --- | --- | --- |
| glargine U100 | 0.477 | 0.0499 | 73 |
| glargine U300 | 0.156 | 0.0377 | 101 |
| degludec | 0.187 | 0.0277 | 133 |

`ke` is the label half-life (13.9, 18.4, 25 h). `ka` puts the peak at 5.3 h for
U100 — U300's half-AUC falls 3 h later at steady state (Becker 2015) — and 12 h
for U300 and degludec. The window ends where 3% of the untruncated area remains.

The glycaemic index shapes the carbohydrate gamma rather than scaling it: a high
GI concentrates the appearance into an early peak, a low GI spreads it. Every
carbohydrate curve in the suite is drawn from it; `T1DMSIM` draws a GI per meal and
gives every hypoglycaemia rescue GI 100:

```
g   = clamp(GI, 0, 100) / 100
k   = 4.5 + (2.0 − 4.5) · g
θ   = 30.0 + (15.0 − 30.0) · g
dur = clamp(k · θ · 4, 120, 360)       # minutes
```

`GI 100 → (2.0, 15.0, 120 min)`; `GI 50 → (3.25, 22.5, 292.5 min)`. The duration
clamp binds below about GI 31.

The exercise gamma, for the same reason:

```
magnitude = duration_min · carb_equiv_per_min      # grams
k         = 3.0
θ         = 15.0
dur       = duration_min + 90                      # minutes
```

`carb_equiv_per_min` is per-patient. `T1DMSIM` uses a population constant of
`0.5`; `T1DMDROID` takes the patient's own value and defaults to the same `0.5`.
Magnitude scales with duration alone — every model pretrained on `T1DMSIM` learnt
it that way, so deriving it from pace, heart rate or energy puts the channel
off-distribution.

The post-exercise insulin-sensitivity boost is a **separate mechanism** and is
never carried by this curve: `T1DMSIM` raises sensitivity for six hours after the
session by `0.10 · duration_min / 75`, capped at `0.30`. Folding that tail into
the exercise channel counts it twice.

Basal is auto-extended across the whole context and forecast window rather than
treated as a discrete event, because background insulin is always present.

Both descriptions sum to the same total, so an implementation that places a whole
bolus in the bucket it was injected in still reconciles against every daily
total while being physiologically wrong at every point in between.
Summing is the invariant; the shape is the meaning.

Because a curve sums to its event total, the statistics that aggregate them —
total daily dose, mean daily carbohydrate, the bolus:basal ratio — are bucket sums
and equal the sum of the underlying events.

Amount-in-body is a **derived** quantity, not a stored one: insulin- and
carbohydrate-on-board are the remaining area under the curve from now forward.

An explicit `custom_curve` overrides the parametric form. Where present it is
authoritative and is never re-derived from the parameters beside it.

## 6. Forecast layout

*Binds: `T1DMAI` → `T1DMDROID`.*

A prediction carries a median line, a seven-level quantile fan, and a twelve-bin
circadian distribution with a confidence scalar.

```
quantile levels: 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95   (median at index 3)
circadian bins:  12
```

How the model produces this layout is `inference.md` §8.

The **order** of the fan levels is part of the contract, and consumers index it
positionally — the median is read at index 3, not searched for. A producer
emitting the levels descending would mirror every interval silently, turning the
95th percentile into the 5th while every value stays in range and every parse
succeeds.

The same applies to the phase origin of the circadian bins: which bin is midnight
must be stated, not inferred.

### 6.1 The metric levels

*Binds: `T1DMAI` ↔ `T1DMDROID`. `T1DMAI` computes these metrics; a forecast
scored on the phone keys off the same four levels, or the two accuracy figures
are not comparable.*

Two of the levels above carry four names — one pair for the level metrics, one
for the excursion detectors:

| level | value | governs |
| --- | --- | --- |
| `METRIC_BAND_TAU_LO` | `0.25` | lower edge of the band the level metrics score against (§6.2) |
| `METRIC_BAND_TAU_HI` | `0.75` | its upper edge |
| `HYPO_ALARM_QUANTILE_TAU` | `0.25` | the lower band edge whose dip below the hypo threshold raises the scored hypo alarm |
| `HYPER_ALARM_QUANTILE_TAU` | `0.75` | the upper band edge whose rise above the hyper threshold raises the scored hyper alarm |

Each is a **level resolved to a position by lookup** — the index is wherever that
value sits in the tuple above, never a literal `2` or `4`. A fan re-levelled
without its consumers being re-pointed still parses, still validates, and scores a
different quantile throughout.

The two lower entries are levels below `0.5`, the two upper above, and all four
are members of the tuple. `T1DMAI` asserts exactly that at import; a consumer
elsewhere owes the same check, because a level absent from the tuple has no
position and cannot announce its own absence.

**The two pairs are numerically equal today and separately named on purpose.**
The band a metric scores against and the envelope an alarm reads are independent
choices, and either may move without the other. Do not fold them into one
constant, and do not read today's equality as an alias.

**None of the four is descriptor-carried.** Unlike the risk constants of §4 they
are a property of the evaluation rather than of a checkpoint, so no exported
descriptor ships them. Each consumer holds its own copy, and this section fixes
the values those copies take.

The alarm reads a **band edge rather than the median** deliberately: the lower
envelope crosses a hypo threshold before the median does, and the upper crosses a
hyper threshold likewise, so an excursion is scored on its possibility rather than
its expectation. Every other metric — RMSE, MAE, MARD, Clarke, CG-EGA, skill
against persistence — scores the band projection of §6.2.

What the edge is compared *against* is the consumer's own hypo and hyper
threshold: a fixed clinical pair in `T1DMAI`'s validation table, the patient's
configurable bands on the phone.

### 6.2 The band projection

*Binds: `T1DMAI` ↔ `T1DMDROID`.*

A forecast is a fan and not a line, so the effective point forecast the level
metrics score is the band point nearest the truth:

```
pred_eff = clip(truth, q[METRIC_BAND_TAU_LO], q[METRIC_BAND_TAU_HI])
```

Three definitional properties:

- **zero error** wherever the truth lies inside the band;
- **the distance to the nearer edge** wherever it lies outside;
- a **degenerate band** (`lo == hi`) returns that common value, so the projection
  reduces to a point forecast exactly — score a collapsed fan and the median-line
  numbers come back unchanged.

The projection replaces the prediction fed to the metrics and nothing else. Every
downstream formula is untouched, which is what makes the two bases comparable.

A wider band can only lower the error, so a band-projected figure means nothing on
its own. Two numbers travel with it: the **realized coverage**, the fraction of
truth falling inside the band, whose target is
`METRIC_BAND_TAU_HI − METRIC_BAND_TAU_LO`, and the **mean edge-to-edge width** in
mg/dL. A band widened until it swallows every truth scores a flawless zero, and
those two are what expose it.

The basis is part of every figure's identity. A band-projected error and a
median-line error are different quantities measured on one forecast: report both
if you wish, never in a single column, and never against an outside number
without naming which basis yours is.

### 6.3 CG-EGA anchoring and window

*Binds: `T1DMAI` ↔ `T1DMDROID`.*

CG-EGA scores a point-error grid and a rate-of-change grid jointly, so it needs a
step *before* the forecast's first step to difference against. That step is the
**persistence value** — the measured BG at the forecast's `made_at`, the same
anchor the model's flat prior departs from — and never the first forecast step or
a zero:

```
dy[t] = (y[t] − y[t−1]) / 5          y[−1] := the persistence anchor
```

for the truth and the forecast alike, in mg/dL per minute. The `5` is §1's grid in
minutes — one forecast step, not the horizon. Every step in the window carries a
rate, the first included; a consumer that begins at `t = 1` scores one step fewer
on a different alignment, which is not this statistic. A mismatched anchor — one
lifted from another cycle — corrupts `dy` only at `t = 0`, the step at which a
fast fall is most decisive.

CG-EGA is scored over the **whole forecast window**, every step from first to
last, yielding one accurate/benign/erroneous triple per glycaemic region. The
level metrics of §6.2 are reported per horizon; this one is not. A CG-EGA computed
at a single horizon is a different statistic and must not be published under the
same name.

Both grids take the **truth** as their reference axis. A point's glycaemic region
is that of its true BG, never of its forecast, and the rate-of-change widening of
the point grid's acceptance band follows the truth's `dy`. Transposing the two
trajectories yields a well-formed table of a different statistic: points are
re-bucketed between the regions, so every denominator moves and the percentages
shift in both directions at once.

**What this suite implements is the `dotXem/CG-EGA` reimplementation's grid, not
Kovatchev's published one.** Both repositories transcribe `dotXem`, deliberately:
matching each other bit for bit is what makes the phone's panel and the trainer's
validation table one statistic.

The cost is not symmetric. On four points the grids differ, and **two of the four
under-report danger**. No figure produced here may be quoted against a published
CG-EGA value without stating them.

- **The rate widening is not directional.** The published grid widens *only the
  upper* limits of `A_P`/`B_P`/`D_P` when the reference is falling, and *only the
  lower* when it is rising; the allowance pays for interstitial lag. Both
  implementations here apply one `mod` to both bounds. **Safety-relevant:** the
  misclassified cases concentrate at a true BG at or below 70 with a rising
  reference, where the published grid calls an upper-`D` failure-to-detect and
  this suite calls it `A`.
- **The `lD` cell of the hyperglycaemia benign filter.** This suite marks it
  benign; the published grid marks it erroneous — failure to detect a rise while
  already hyperglycaemic. The paper's own totals settle it: with hyper benign at
  9 % the stated weighted `A` = 84.6 % and `B` = 9.3 % both reproduce; at 10 % the
  second becomes 9.7 %. **Safety-relevant:** it moves points from erroneous to
  benign, in hyperglycaemia.
- **The upper-`C` boundary.** Published `1.03·U + 107.9`; here `(22/17)·U +
  (180 − 70·22/17)`. Same anchor at `(70, 180)`, different slope.
- **The anchor.** The shared persistence anchor above is this suite's own choice;
  `dotXem` differences each series against itself. A forecast has no step before
  its first, so an anchor must come from somewhere, and the measured value keeps
  both rates on one origin at the cost of a transient at `t = 0`. Not a defect.

Correcting the first three would make this suite literature-comparable and would
have to move both implementations together. What is settled is that neither
repository may claim the published grid while implementing this one.

One consequence of §6.2: where the truth lies inside the band the projection
*equals* the truth, so the rate term inherits the truth's own derivative there.
The rate grid is scored only where the band actually missed.

## 7. CGM source authority

*Binds: `T1DMDROID`.*

`T1DMDROID` records several CGM sensors at once. Each is **active** — its readings
are retained and the BG panel may be switched to it. Exactly one is also
**authoritative**.

The authoritative source is the sole input to the forecast, the statistics, the
alarm engine and every outbound destination. Another active source's readings
reach nothing else.

Authority implies activity; the converse does not hold.

A sample carries `bg_source`, naming the sensor its `bg` came from. It is a label, not a key: one source is authoritative at a time, so a slot
still holds one reading. A change in it between adjacent slots is a sensor change
— except across a reconstructed slot, which carries no `bg_source` because no
sensor produced it.

---

## Known deviations

Places where an implementation is known to disagree with this document. The
document is normative; each entry is a defect awaiting a change in the named
repository. An entry is **deleted** once the implementation agrees.

1. **`T1DMDROID` clamps clinical risk to `[20, 500]`.** §4 fixes the clinical
   domain at `[20, 600]`; `CLINICAL_BG_CLAMP_MAX` in `crates/t1dm-core/src/lib.rs`
   is 500, and `KovatchevScale.kt` mirrors it for the display chrome that cannot
   reach the JNI seam. The client's golden vectors pin the current bound and need
   regenerating alongside the change.

## Accepted divergences

Differences a reviewer will read as drift. They are deliberate. **Do not "fix"
them**; unifying them would be the defect.

1. **Two Kovatchev parameterizations.** The clinical constants of §4 and the
   model-space constants beside them are both correct and serve different
   purposes. Never unify them.

## Open questions

Each is a place where two implementations could diverge without either looking
wrong.

1. **Snapping rule.** §1 requires the phone's snap to be specified as nearest,
   floor, or ceiling. Confirm what `T1DMDROID` does and record it.

2. **Circadian phase origin.** §6 requires the midnight bin to be named. Confirm
   against the exporter in `T1DMAI`.

3. **The phone's predictive alarm and the scored alarm read different bases.**
   §6.1 fixes the scored hypo/hyper alarm on the τ=`0.25`/`0.75` band edges, and
   `T1DMAI` computes recall and precision that way. `T1DMDROID`'s shipped
   predictive alert reads the **median** line instead
   (`BgGlanceComputer.findCrossings`), and its dose-calculator fan reads the
   τ=`0.05`/`0.95` extremes (`calc/…/RollingForecaster.kt`). A recall figure
   measured on the band edge does not describe the alarm the patient receives.
   Record which basis the phone's alarm reads, and score it on that one.
