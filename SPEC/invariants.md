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
