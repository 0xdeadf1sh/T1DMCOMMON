# Domain invariants

Normative definitions shared across the T1DM suite. Where a repository's code
disagrees with this document, one of the two is a defect; neither may be assumed
correct without checking the other.

Each invariant records which repositories it binds. See `../CLAUDE.md` for the
active/passive distinction that governs how strongly.

Two companion specifications apply these definitions to a particular seam, and
are equally normative: `http-api.md`, the wire contract between the app and the
server, and `inference.md`, the model contract between the trainer and the app.
All three are single-copy — see `../scripts/check-no-copies.sh`.

---

## 1. The five-minute grid

*Binds: all four.*

Physiologic samples, meal events, and dose events sit on a fixed five-minute
grid in epoch milliseconds:

```
ts % 300000 == 0
```

The **client snaps** a timestamp to the grid before sending it. The snapping rule
is part of the contract, not an implementation detail: two implementations that
floor where the other rounds both land on the grid, and both pass every
validation, while filing the same reading in different buckets.

A server may reject an off-grid timestamp, because it keys reconstruction on the
grid and an off-grid row is unreachable. That is storage self-defence, not
validation of the client's judgement.

Gaps are explicit. A grid slot with no measurement stores `NULL`; it is never
back-filled with a neighbouring value at rest. Any gap-filling is a presentation
step, and a filled value must never be written back as though measured.

## 2. `tz_offset`

*Binds: all four.*

`tz_offset` is the client's UTC offset **in minutes, east-positive**, at the time
of the event. `UTC−5` is therefore `-300`.

It is carried alongside the timestamp so local time can be rendered after the
fact. It is never used to shift the timestamp itself: `ts` is always UTC.

Anything aggregating by day must state whether its day boundary is UTC or local,
because the two disagree for a quarter of the world and across every DST
transition.

## 3. Units and sign conventions

*Binds: all four.*

Storage units are fixed. Display conversion is presentation-only and never
written back.

| Quantity | Unit | Notes |
| --- | --- | --- |
| Blood glucose | mg/dL | The only BG unit that crosses the wire. See §4. |
| Carbohydrate | grams | |
| Insulin | units | |
| Basal slot dose | units **delivered in that slot** | Not a rate. Summing slots yields a daily total. |
| Glycaemic index | 0–100 | A GI, not a 0–1 fraction. |
| Heart rate | bpm | |
| Duration | minutes | Everywhere `duration_min` appears. |
| Rate constants | per hour | `ka_per_hour`, `ke_per_hour`. |
| Timestamps | epoch milliseconds, UTC | |

A quantity that is a **rate** on one side and an **amount** on the other is the
most damaging error in this table, because it scales by a duration and still
looks plausible. Basal is an amount.

**Display conversion.** Blood glucose is stored and transmitted in mg/dL, and
converted only for display. The molar conversion is

```
mg/dL per mmol/L = 18.0182
```

Not 18.0. The two differ by about 0.1%, which sounds ignorable and is not: both
sides render one decimal place, so the gap straddles the rounding boundary for
roughly one integer mg/dL value in nine. A server using 18.0 prints 100 mg/dL as
`5.6` where a client using 18.0182 prints `5.5` — a visible disagreement between
two screens showing the same reading, with nothing wrong anywhere.

## 4. The two risk spaces

*Binds: all four. The most easily conflated pair in the suite.*

Two Kovatchev parameterizations coexist **by design**. They are numerically
similar, dimensionally incompatible, and must never be mixed.

### Clinical risk space

The published transform, anchored on the physical BG range clinicians assume
when reading a risk index. Used for **LBGI, HBGI, and anything a human reads**.

```
f(BG) = SCALE * (ln(BG)^POWER - OFFSET)
SCALE = 1.509   POWER = 1.084   OFFSET = 5.381
clinical BG domain: [20, 600] mg/dL
```

These constants are published and fixed. They may be hardcoded. Input is clamped
to `[20, 600]` before the transform, so `f` is finite and `f_inv` never takes a
negative base.

The domain is not arbitrary: it is the range the transform was constructed
symmetric over. `f(20) ≈ -3.1633` and `f(600) ≈ +3.1619` — equal and opposite to
within a thousandth. A narrower clamp saturates real glucose early and breaks
that symmetry.

The domain is part of the definition, not a defensive detail. Two
implementations that share the constants but clamp differently return different
risk for the same glucose, and neither looks wrong on inspection.

**The clamp fails closed.** An invalid, missing, or out-of-domain glucose reads
as **maximal hypo risk** — the value at the low bound — never as the risk-neutral
point. This matters more than it looks: zero on this scale is the *symmetry
point*, roughly 112.5 mg/dL, which is to say perfect euglycaemia. Mapping a
garbage reading to zero therefore announces an ideal glucose, and does so exactly
when the input is least trustworthy. The direction of that guard is a safety
property, not a numerical convenience; do not "simplify" it to a zero.

### Model risk space

The same family of transform, **re-anchored to the BG range the network was
trained on**, `[40, 400]`. The model's input and output BG both live here.

The current anchoring (`ARCH_VERSION = risk-v3`) is solved so that
`f(40) = -√10` and `f(400) = +√10` — risk 100 at both rails:

```
SCALE = 2.2211457449985317   POWER = 1.084   OFFSET = 5.540076976170212
```

Note the consequence: the zero-risk centre moves from roughly 112.5 mg/dL in
clinical space to roughly **128 mg/dL** in model space. The two transforms do not
merely differ in scale — they disagree about where euglycaemia sits.

These constants are **a property of a checkpoint**, not of the domain. They must
be read from the model descriptor's `kovatchev` block and **must never be
hardcoded**; `inference.md` §5 gives the block and the guards that go with it. A
re-anchored checkpoint ships different constants, and decoding it against the
clinical ones misreads glucose badly and silently.

The scale triple survives in two hardcoded copies with no shared source and no
cross-repository equality test — `T1DMAI/utils.py` (`_KOVATCHEV_*`) and
`T1DMSIM/cache_simulator.py` (`NORM_BG_RISK_*`). Re-tuning the transform means
editing both.

The **bounds** are not duplicated: `T1DMAI` reaches `BG_CLAMP_MIN` /
`BG_CLAMP_MAX` in `T1DMSIM/simulator.py` through a symlinked checkout, so the two
cannot disagree about the range even while each carries its own copy of the
scale. That is the pattern the constants themselves should follow.

`T1DMDROID` holds no copy. Its Rust core reads the block from the descriptor,
**rejects** a descriptor that omits it rather than defaulting to any scale, and
takes every model-path bound from it — the input clamp, the `f_inv` output clamp,
and the rail-pinned degeneracy test alike. That last one is why the bounds cannot
be assumed either: a rail-pin check against a fixed 20 mg/dL is meaningless for a
model whose output cannot go below 40.

### Rules

1. Every symbol, field, and function carrying a risk value **names its space**.
   `kovatchev_f` without qualification is ambiguous and therefore a defect.
2. A value in one space is never compared to, stored as, or displayed as a value
   in the other.
3. **Risk space never crosses the wire.** Every BG on the HTTP/WebSocket
   contract — samples, prediction lines, quantile fans — is mg/dL. Decoding from
   model space happens on the phone, before anything is sent.
4. Only `T1DMAI` (which trains and exports) and `T1DMDROID` (which decodes) have
   any business with model space. `T1DMSERVER` has none: it displays clinical
   risk in its console and never decodes a checkpoint.
5. **A descriptor and a model artifact are one unit.** They are coherent only if
   they come from the same export run, and nothing on device can check that: a
   stale descriptor beside a fresh artifact decodes finite, plausible, wrong.
   Ship them together, and never hand-edit one to match the other.

## 5. Curve semantics

*Binds: all four.*

A curve is a **per-five-minute rate series that sums to the event's total**. It
is never an amount-in-body.

What the rate *is* differs by channel, and the distinction is load-bearing:

- **Carbohydrate — appearance (Ra) rate.** Grams entering the blood per bucket:
  a gamma curve shaped by the glycaemic index, spread across the absorption
  window. It is *not* the moment of eating.
- **Insulin — PK action rate.** Units of action per bucket across the duration
  of insulin action. A rapid analogue is a gamma peaking near 50 minutes with a
  four-to-five hour tail; a long-acting basal is a broad, near-flat Bateman curve
  running twenty-four hours or more. It is *not* the injection instant, and *not*
  a delivery schedule.

The glycaemic index shapes the carbohydrate gamma rather than scaling it: a high
GI concentrates the appearance into an early peak, a low GI spreads it. Basal is
auto-extended across the whole context and forecast window rather than treated as
a discrete event, because background insulin is always present.

The trap is that both descriptions sum to the same total, so an implementation
that places a whole bolus in the bucket it was injected in still reconciles
against every daily total while being physiologically wrong at every point in
between. Summing is the invariant; the shape is the meaning.

Because a curve sums to its event total, the statistics that aggregate them —
total daily dose, mean daily carbohydrate, the bolus:basal ratio — are bucket
sums and equal the sum of the underlying events.

Amount-in-body is a **derived** quantity, not a stored one: insulin- and
carbohydrate-on-board are the remaining area under the curve from now forward.

An explicit `custom_curve` overrides the parametric form. Where present it is
authoritative and is never re-derived from the parameters beside it.

## 6. Forecast layout

*Binds: `T1DMAI` → `T1DMDROID`; displayed by `T1DMSERVER`.*

A prediction carries a median line, a seven-level quantile fan, and a twelve-bin
circadian distribution with a confidence scalar.

```
quantile levels: 0.05, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95   (median at index 3)
circadian bins:  12
```

How the model produces this layout is `inference.md` §8; how it crosses the wire
is `http-api.md` (Prediction).

The **order** of the fan levels is part of the contract, and consumers do index
it positionally — the median is read at index 3, not searched for. A producer
emitting the levels descending would mirror every interval silently, turning the
95th percentile into the 5th while every value stays in range and every parse
succeeds.

The same applies to the phase origin of the circadian bins: which bin is midnight
must be stated, not inferred.

### 6.1 The metric levels

*Binds: `T1DMAI` ↔ `T1DMDROID`. `T1DMAI` computes these metrics; a forecast
scored on the phone keys off the same four levels, or the two accuracy figures
are not comparable. `T1DMSERVER` scores nothing and reads no band edge.*

Two of the levels above carry four names — one pair for the level metrics, one
for the excursion detectors:

| level | value | governs |
| --- | --- | --- |
| `METRIC_BAND_TAU_LO` | `0.25` | lower edge of the band the level metrics score against (§6.2) |
| `METRIC_BAND_TAU_HI` | `0.75` | its upper edge |
| `HYPO_ALARM_QUANTILE_TAU` | `0.25` | the lower band edge whose dip below the hypo threshold raises the scored hypo alarm |
| `HYPER_ALARM_QUANTILE_TAU` | `0.75` | the upper band edge whose rise above the hyper threshold raises the scored hyper alarm |

Each is a **level resolved to a position by lookup** — the index is wherever that
value sits in the tuple above, never a literal `2` or `4`. The indirection costs
nothing and buys everything: a fan re-levelled without its consumers being
re-pointed still parses, still validates, and scores a different quantile
throughout.

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
descriptor ships them and no consumer can read them off one. Each holds its own
copy, and this section fixes the values those copies take.

The alarm reads a **band edge rather than the median** deliberately: the lower
envelope crosses a hypo threshold before the median does, and the upper crosses a
hyper threshold likewise, so an excursion is scored on its possibility rather
than on its expectation. Every other metric — RMSE, MAE, MARD, Clarke, CG-EGA,
skill against persistence — scores the band projection of §6.2 instead.

What the edge is compared *against* is not fixed here. It is the consumer's own
hypo and hyper threshold: a fixed clinical pair in `T1DMAI`'s validation table,
the patient's configurable bands on the phone (see *Accepted divergences* 3).

### 6.2 The band projection

*Binds: `T1DMAI` ↔ `T1DMDROID`. `T1DMSERVER` scores nothing.*

A forecast is a fan and not a line, so the effective point forecast the level
metrics score is the band point nearest the truth:

```
pred_eff = clip(truth, q[METRIC_BAND_TAU_LO], q[METRIC_BAND_TAU_HI])
```

Three properties, all definitional:

- **zero error** wherever the truth lies inside the band;
- **the distance to the nearer edge** wherever it lies outside;
- a **degenerate band** (`lo == hi`) returns that common value, so the projection
  reduces to a point forecast exactly — score a collapsed fan and the median-line
  numbers come back unchanged.

The projection replaces the prediction fed to the metrics and nothing else. Every
downstream formula is untouched, which is what makes the two bases comparable at
all.

Because a wider band can only lower the error, a band-projected figure means
nothing on its own. Two numbers travel with it: the **realized coverage**, the
fraction of truth falling inside the band, whose target is
`METRIC_BAND_TAU_HI − METRIC_BAND_TAU_LO`, and the **mean edge-to-edge width** in
mg/dL. A band widened until it swallows every truth scores a flawless zero, and
those two are what expose it.

The basis is part of every figure's identity. A band-projected error and a
median-line error are different quantities measured on one forecast: report both
if you wish, never in a single column, and never against an outside number
without naming which basis yours is.

### 6.3 CG-EGA anchoring and window

*Binds: `T1DMAI` ↔ `T1DMDROID`. `T1DMSERVER` scores nothing.*

CG-EGA scores a point-error grid and a rate-of-change grid jointly, so it needs a
step *before* the forecast's first step to difference against. That step is the
**persistence value** — the measured BG at the forecast's `made_at`, the same
anchor the model's flat prior departs from — and never the first forecast step or
a zero:

```
dy[t] = (y[t] − y[t−1]) / 5          y[−1] := the persistence anchor
```

for the truth and the forecast alike, in mg/dL per minute. The `5` is §1's grid
in minutes — one forecast step, not the horizon. Every step in the window
therefore carries a rate, the first included; a consumer that begins at `t = 1`
instead scores one step fewer on a different alignment, which is not this
statistic. A mismatched anchor — one lifted from another cycle — corrupts `dy`
only at `t = 0`, but that is the step at which a fast fall is most decisive.

CG-EGA is scored over the **whole forecast window**, every step from first to
last, yielding one accurate/benign/erroneous triple per glycaemic region. The
level metrics of §6.2 are reported per horizon; this one is not. A CG-EGA
computed at a single horizon is a different statistic and must not be published
under the same name.

Both grids take the **truth** as their reference axis. A point's glycaemic region
is that of its true BG, never of its forecast, and the rate-of-change widening of
the point grid's acceptance band follows the truth's `dy`. Transposing the two
trajectories yields a well-formed table of a different statistic: points are
re-bucketed between the regions, so every denominator moves and the percentages
shift in both directions at once. The two are not comparable, and neither may be
published under this name unless it reads the truth.

**What this suite implements is the `dotXem/CG-EGA` reimplementation's grid, not
Kovatchev's published one.** Both repositories transcribe `dotXem`. That is the
deliberate choice: matching each other bit for bit is what makes the phone's panel
and the trainer's validation table one statistic, which is what this section
exists to guarantee, and it is worth more here than agreement with a published
figure nobody in this suite is being scored against.

It is a choice with a cost, and the cost is not symmetric. On four points the
grids differ, and **two of the four under-report danger**. No figure produced here
may be quoted against a published CG-EGA value without stating them.

- **The rate widening is not directional.** The published grid widens *only the
  upper* limits of `A_P`/`B_P`/`D_P` when the reference is falling, and *only the
  lower* when it is rising — the asymmetry is the point, since the allowance pays
  for interstitial lag. Both implementations here apply one `mod` to both bounds.
  **Safety-relevant:** the cases it misclassifies concentrate at a true BG at or
  below 70 with a rising reference, where the published grid calls an upper-`D`
  failure-to-detect and this suite calls it `A`.
- **The `lD` cell of the hyperglycaemia benign filter.** This suite marks it
  benign; the published grid marks it erroneous — failure to detect a rise while
  already hyperglycaemic. The paper's own totals settle it without reading its
  figure: with hyper benign at 9 % the stated weighted `A` = 84.6 % and `B` = 9.3 %
  both reproduce; at 10 % the second becomes 9.7 %. **Safety-relevant:** it moves
  points from erroneous to benign, in hyperglycaemia.
- **The upper-`C` boundary.** Published `1.03·U + 107.9`; here `(22/17)·U +
  (180 − 70·22/17)`. Same anchor at `(70, 180)`, different slope.
- **The anchor.** The shared persistence anchor above is this suite's own choice;
  `dotXem` differences each series against itself. A forecast has no step before
  its first, so an anchor must come from somewhere, and taking the measured value
  keeps both rates on one origin — at the cost of a transient at `t = 0`. This one
  is a considered choice and is not a defect.

Correcting the first three would make this suite literature-comparable, and would
have to move both implementations together or the guarantee above is lost. That
is a live option, not a closed one; what is settled is that neither repository may
claim the published grid while implementing this one.

One consequence of §6.2 is worth stating outright: where the truth lies inside
the band the projection *equals* the truth, so the rate term inherits the truth's
own derivative there. The rate grid is scored only where the band actually
missed.

## 7. Authority and ordering

*Binds: `T1DMDROID` ↔ `T1DMSERVER`.*

The phone authors every physiologic record. Each carries a phone-minted
`client_id`, stable for the life of the record, and an `updated_at` from the
phone's clock which the server stores and returns **verbatim**, never
re-stamping.

`updated_at` is the ordering key for every idempotent upsert: a redelivery
carrying an equal or older value is a no-op; a newer one replaces the record in
place. This is what makes a durable outbox safe to retry and to deliver out of
order.

Consequence worth stating: if the phone's clock moves backwards, records it
writes afterwards carry stamps older than what is stored, and the server will
correctly ignore them. A backwards clock therefore freezes a record silently.

---

## Known deviations

Places where an implementation is known to disagree with this document. The
document is normative; each entry is a defect awaiting a change in the named
repository. An entry is **deleted** once the implementation agrees — this list
carries live defects, never a record of settled ones.

1. **`T1DMDROID` clamps clinical risk to `[20, 500]`.** §4 fixes the clinical
   domain at `[20, 600]`; `CLINICAL_BG_CLAMP_MAX` in `crates/t1dm-core/src/lib.rs`
   is 500, and `KovatchevScale.kt` mirrors it for the display chrome that cannot
   reach the JNI seam. `T1DMSERVER` clamps at 600, so the two render different
   risk for the same high reading. The client's golden vectors pin the current
   bound and need regenerating alongside the change.

## Accepted divergences

Differences a reviewer will read as drift. They are deliberate. **Do not
"fix" them**; each was decided by the author, and unifying them would be the
defect.

1. **Two Kovatchev parameterizations.** The clinical constants of §4 and the
   model-space constants beside them are both correct and serve different
   purposes. Never unify them.

2. **The operator console renders any stored fan as a confident forecast.**
   `T1DMDROID` classifies degeneracy — non-finite, mis-ordered quantiles,
   rail-pinned, collapsed band — and withholds a bad forecast from the patient.
   That classification does not cross the wire, and the console does not derive
   it. Accepted: the console is an operator surface, not a patient-facing one,
   and the withholding that matters happens on the phone.

3. **Glycaemic thresholds are hardcoded in the console.** Its hypo/hyper rails
   and in-range tinting are fixed at 70/180 mg/dL, while the phone's bands are
   user-configurable and never cross the wire. Accepted: the console's rails are
   fixed reference lines, not a reflection of the patient's settings.

## Open questions

Each is a place where two implementations could diverge without either looking
wrong. None should stay open.

1. **Snapping rule.** §1 requires the client's snap to be specified as nearest,
   floor, or ceiling. Confirm what `T1DMDROID` does and record it.

2. **Circadian phase origin.** §6 requires the midnight bin to be named. Confirm
   against the exporter in `T1DMAI`.

3. **Day boundary for daily aggregates.** §2 requires UTC or local to be stated
   per metric. Confirm against the statistics implementation in `T1DMDROID`.

4. **The phone's predictive alarm and the scored alarm read different bases.**
   §6.1 fixes the scored hypo/hyper alarm on the τ=`0.25`/`0.75` band edges, and
   `T1DMAI` computes recall and precision that way. `T1DMDROID`'s shipped
   predictive alert reads the **median** line instead
   (`BgGlanceComputer.findCrossings`), and its dose-calculator fan reads the
   τ=`0.05`/`0.95` extremes (`calc/…/RollingForecaster.kt`). Neither is wrong on
   its own terms, and both bases are defensible — but a recall figure measured on
   the band edge does not describe the alarm the patient actually receives.
   Record which basis the phone's alarm reads, and score it on that one.
