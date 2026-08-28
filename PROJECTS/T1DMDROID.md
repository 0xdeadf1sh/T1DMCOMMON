# T1DMDROID — working knowledge

The Android client: reads the CGM, runs forecasting on device, owns the
patient's data, syncs to `T1DMSERVER`, drives an optional BLE watch, and can
mirror a subset outward — see *Outbound destinations*.

Kotlin + Compose, multi-module Gradle, with a Rust core (`crates/t1dm-core`) over
JNI. GPL-3.0. Sideload-only, never a store listing. Targets exactly one phone.

> Some of this project's knowledge is **deliberately not here**: device protocol
> work, the branch seam, and safety-override design stay in the project's own
> memory and its local-only branch, because this repository is public. See
> `../skills/common-boundary`. Absence from this file is not absence of rules —
> read the project's own skills.

## Priorities

Performance > easy-to-refactor > easy-to-understand, stated by the author. Code
quality is held high because the repository is public.

**All heavy compute runs off the main thread.** Inference, dose grid-search,
statistics recomputation, backups and database writes go to background
dispatchers, WorkManager, or the foreground service. The UI observes reactively
and must never block.

## Target device

**Redmi K90 Max** (`ro.product.model 2604FRK1EC`, adb codename `prague`),
**MediaTek Dimensity 9500 / MT6993**, NPU **APU 990**, Android **16** / SDK
**36**, HyperOS OS3.0, arm64-v8a only, ~16 GB RAM, 165 Hz panel. Step counter
present.

The NPU stack is **NeuroPilot / Neuron**, not NNAPI (deprecated on Android 16) —
but nothing reaches it. The APU sits idle; see *Inference runtime*. Do not
describe this phone's accelerated path as an NPU one.

Runtime page size is **4 KB**, not 16 KB. The NDK build targets 16 KB ELF
alignment anyway, and a 16 KB-aligned `.so` loads correctly on a 4 KB-page kernel
— alignment at or above page size is always safe. Forward-compatible, not a bug;
do not "fix" it.

## Inference runtime

**ExecuTorch**, one exported model on **two** implemented backends: **CPU fp32
via XNNPACK** as the reference authority, and **GPU fp16 via the Vulkan compute
delegate** on the Mali GPU as a measured shadow, behind a clean backend seam. No
integer quantization. The Vulkan delegate needs a custom `executorch-android` AAR
built with `EXECUTORCH_BUILD_VULKAN=ON` and its own `.vulkan.pte`; the stock AAR
registers XNNPACK only.

**There is no NPU inference.** The Neuron and LiteRT backend ids are enumerated
but route nowhere — each `load` fails loudly with its own reason, so a mis-routed
model is refused rather than silently served. The NeuroPilot runtime ships
through Play feature delivery, which a sideload-only build cannot fetch, and the
stock ExecuTorch AAR carries no MediaTek delegate. Any claim that the fp16 shadow
runs on the NPU is a claim about the GPU.

Everything numerically sensitive — the Savitzky-Golay causal smoother,
normalize/denormalize, the Kovatchev transform and its inverse, quantile assembly
— runs in the **fp32/fp64 Rust core on CPU**. Only the transformer core reaches
the GPU, which is what makes fp16 tolerable there.

The artifact is a **single fixed shape**; the graph is cut in risk space, with the
anchor, inverse transform and quantile assembly left to Rust. The exporter lives
in `T1DMAI/exporters/`, and the **descriptor is the sole source** of pre/post
constants — the app never parses a checkpoint pickle, and parses the descriptor
in the shape the exporter writes rather than projecting it onto a second schema.
`../SPEC/invariants.md` §4 says why those constants come from the descriptor.

**The masked set is an input, not the trailing horizon.** It crosses as a one-hot
selection matrix naming the patch each head slot reads, so forecast, backcast and
infill are one artifact under different inputs. Nothing in the app holds a
geometry of its own: sequence length, context bounds, slot count and span
envelope all come from the descriptor, and the graph input is built in the Rust
core.

**A reconstruction can be promoted into the record.** A stretch selected on the
BG panel is reconstructed and drawn; a deliberate second action on the same panel
writes it into `sample` and `cgm_reading` as a stored, syncable value,
permanently flagged `RECONSTRUCTED`. `../SPEC/invariants.md` §1 carries the narrow
exception and what such a value may never do. Four consumers discriminate on the
flag rather than trusting the column: the alarm path, which may only be cleared
by a measured reading; the dose series; the fit's target and its windows'
context; and the statistics. Promotion refuses a forecast span, a backcast with
nothing measured before it, a slot already holding a measurement, and a
degenerate band. Demotion takes it back out, across every sensor the span may
have been filed under.

**The head is re-runnable, and that is the adapter seam.** The graph emits
`hidden`, the trunk's state for every patch, and the export ships the head's
weights beside the artifact. The app gathers each span's nodes out of `hidden`,
builds the step states by the spline of `../SPEC/inference.md` §8.2, and runs the
head's MLP on them, so it reproduces `head_raw` outside the graph and can put a
low-rank adapter on the node states, ahead of the spline. The trunk stays frozen
inside the `.pte`; a fit is a few thousand numbers trained from the patient's own
matured windows. A head that does not reproduce the graph's own output is
refused.

**An adapter is refused at attach unless it has been measured against the model's
own dose response.** A few thousand parameters fitted to one patient's weeks can
null the model's marginal response to insulin with a rank-1 map, score better on
the loss it was fitted on, and leave the dose calculator reading a forecaster
that does not move when insulin is added — which is what the predicted-low veto
tests, since that rail reads the median line and not a band edge. Two things
stand against it: a distillation term pinning the adapted response to the frozen
model's during the fit, and a verdict measured on held-out forecast windows and
stored on the adapter's row. The refusal is structural rather than a disabled
button, covers an adapter nobody measured as well as one that failed, and is
overridable only by a deliberate second action that sticks to that row.

Attaching or detaching an adapter drops that model's band correction and stored
predictions — both described the forecaster that was there before. A
channel-affecting edit or deletion of a logged meal or dose drops the same two
from the other direction: those forecasts were conditioned on a history that no
longer exists. The band correction goes only where the window it was fitted over
reaches the change; a blanket drop would narrow the displayed band over a
week-old correction, the wrong direction to fail in.

Agreement between the fp16 GPU path and the fp32 CPU path is measured and
surfaced; safety decisions gate on it. A non-authoritative backend may render a
forecast before it has cleared that gate, but may never feed a dose.

**Cold start**: the model needs a minimum context of patches before it may
predict, and a configurable warm-up window on top suppresses forecasts until
enough *measured* context has accrued.

**The band correction is fitted here, per patient.** No exported descriptor
carries a `conformal_delta`, so the fan the phone draws is the raw fan until the
user asks for a fit from the Models drill-down. That fit is
`../SPEC/inference.md` §8.4's, run in the Rust core over the patient's own
matured `(forecast, realized)` windows at the model's own horizon, stored per
model id, and reaching three **display** fans and nothing else: the BG panel's
forecast overlay, the hindsight sweep beside it, and the exercise review's swept
fan. All three, or a raw fan would state a second and narrower uncertainty beside
a calibrated one. The two sweeps apply it in-sample to the rows the delta was
fitted on, which §8.4's exchangeability argument does not cover — accepted,
because nothing either sweep draws is read by anything. Every classifier — alarm
engine, calculator rails, accuracy suite — reads the raw fan, the wire carries the
raw fan, and the median never moves. A stored correction lapses one fitting
window after it was made, and replacing the artifact under the same id drops the
correction and the forecasts it was fitted on together.

**A classical baseline runs beside the exported models**, under `model_id`
`ridge-cgm-iob-cob-v1`: direct multi-step ridge on twelve lagged CGM values,
causal IOB/COB, and the committed carb appearance and insulin action summed over
the next 30, 60 and 120 minutes — fitted on device from the patient's own history
when the user presses the button on the model's own screen. It is what makes a
forecast-accuracy figure mean anything, so the fit reports held-out RMSE against
persistence per horizon.

Those forward blocks are what make it respond to a logged dose at all. On-board
alone is a scalar at the anchor, and doses snap to the *nearest* grid slot, so one
landing after the anchor moved nothing until the next CGM sample arrived. They
count every committed curve overlapping the window, including one starting after
the anchor — the same information the neural model's prediction-zone channels
carry. The cost: the held-out RMSE is mildly optimistic and may not be quoted
against a strictly-causal figure without saying so.

From the app's side it is an ordinary model wherever a model is a fan: it joins
the running set, selecting it hands it the graph, the alert and the widget,
it is scored by the same suite through the same §3.6 gates, and it streams under
its own id — `../SPEC/http-api.md`'s `prediction` frame carries `model_id`
whatever produced the fan.

**It cannot drive the dose calculator.** `:calc`'s rolled search sizes its context
from descriptor patch geometry and runs a graph forward per roll with the
candidate dose in the prediction zone, so a model with neither a descriptor nor a
graph cannot answer it. With the baseline selected the calculator, the ISF/ICR
probe and the rolled display overlay fail closed — safe, but the refusal reads
"no selected model", which names the wrong cause.

Three other specifics. It has no descriptor and no artifact, so it sits beside
the discovered set rather than inside it, and outside the running cap. Its band
is constitutive, not corrective — `../SPEC/inference.md` §8.4. And it is fitted on
gapped history rather than the carry-forward series the neural cycle conditions
on, because a filled gap is a flat stretch that never happened and a
least-squares fit learns persistence from enough of them.

## Safety posture

**Advisory only. The app never actuates insulin** — no pump, no closed loop. It
recommends; the patient administers. That is the mitigation that makes
model-driven calculators defensible at all.

The fail-closed architecture, load-bearing and not to be weakened:

- a **model-free** threshold and loss-of-signal alarm path, independent of
  inference and with no dependency on the inference module
- a **forecast-degeneracy guard** in Rust — NaN, rail-pinned flat output,
  collapsed band, mis-ordered quantiles
- **every rail structurally fail-closed** on missing, degenerate or stale input:
  it blocks rather than silently doing nothing
- an **fp16 ↔ fp32 agreement gate**
- a point-of-decision confirmation the user must acknowledge

Guard-rail *toggles* exist (maximum bolus, IOB ceiling, predicted-low veto), but
their thresholds are user-set and deliberately **unbounded** — the author
explicitly overrode a proposed compiled ceiling. Advisory-only plus manual
administration is the safety net. Respect that decision.

Interpolated or warm-up readings never clear an alarm; only a measured in-range
value does.

CI enforces this: `rail-invariants.yml` is a blocking gate on the calculator
invariants, and `rust-golden.yml` holds the core to bit-for-bit vectors.

## Outbound destinations

Three, and only the first is a contract:

- **`T1DMSERVER`** — the full record, both directions, `SPEC/http-api.md`.
- **The Nightscout bridge** — one way, and only BG, carbohydrate and bolus, to a
  host speaking the Nightscout `/api/v1` subset. It sends whenever the user has
  configured a URL and a secret and left the switch on; nothing else gates it.
  Not a specification: it binds nothing but `T1DMDROID`, and nothing about it
  belongs in `SPEC/`.
- **OpenStreetMap tile servers** — the exercise review's map fetches basemap
  tiles directly while a bout is being read. Nothing of the patient's is sent,
  but the request discloses which tiles are being looked at, and a review of a
  recorded route is what that is a function of.

The server record rides the durable outbox, distinguished by `OutboxKind`. A
forecast does not: at contract `0.5.0` it goes up the WebSocket, nothing stores
it, and a frame that finds no socket is lost rather than queued.

The bridge's failures are its own: a host that is off, unreachable, or rejecting
its credential backs off one row and must never stand the queue down — that would
let a third party stall the patient's own sync.

Basal and exercise are withheld deliberately. Nightscout's basal is a **rate**
where §3 makes ours an **amount**, and `exercise` is carbohydrate-equivalent
disposal whose sign is opposite a meal's. Either mapping misreports the record
while looking plausible.

A bridged BG entry keys on the five-minute grid. A bridged **treatment does not**:
it carries the event's unsnapped `updatedAt`. Snapping put a meal and the bolus
taken with it on one instant, and the host keys treatments by timestamp — so the
second was acked `200` and silently discarded, losing a logged meal. Do not
"restore" the grid here; the grid still governs the phone's own record and
everything on the wire to `T1DMSERVER`.

The `/api/v1` write has no idempotency key, so a lost acknowledgement can
duplicate an upload. The phone narrows that window by reading back before a
retry; it does not close it. What comes back is not what was sent — the observed
host rewrites `notes` and `enteredBy`, normalises `created_at` to UTC,
materialises absent amounts as `0`, and ignores `find[…]` queries outright.
Recognition tolerates all of that and is pinned by tests carrying verbatim
response bodies. Treat any new assumption about what a host preserves as false
until a real response says otherwise.

## Platform traps — HyperOS / MIUI

**Background BLE scanning stops when the screen locks.** Not a process kill — the
foreground service survives and its heartbeat keeps advancing — the platform
*suspends* a backgrounded app's scan. `dumpsys bluetooth_manager` is decisive:
the scan reads `Filter Suspended` rather than `Filter`. Scan *mode* is a red
herring; a suspended scan delivers nothing at any mode, and `onScanFailed` never
fires because suspension is not a failure. The diagnostic discriminator is a
process that is alive while the newest reading timestamp is frozen.

Two mitigations, both costly: **offloaded batch scanning** while locked (the
controller buffers in hardware and the OS flushes on roughly a five-minute timer)
at the price of latency and dropped marginal signal; or holding a
genuinely-interactive display behind a dimmed activity, which is heavy on
battery. A plain background `startActivity` is **BAL-blocked on Android 16**; the
working raise is a full-screen-intent notification.

**Foreground-service type matters.** `dataSync` carries a cumulative daily
runtime cap and cannot be started from `BOOT_COMPLETED` on Android 15+, which
kills an always-on service. `connectedDevice` has neither limit.

**Thermal sensors are unreadable.** A sideloaded app cannot read any absolute
CPU/SoC/GPU/NPU temperature: sysfs thermal zones are denied even via `run-as`,
and `HardwarePropertiesManager` requires device-owner. Never ship a sysfs thermal
path. What works: `getThermalHeadroom(forecastSec)` (1.0 marks the severe-throttle
point and follows the slow skin sensor, so treat it as a sustained-load gate
rather than a per-inference thermometer), `getThermalHeadroomThresholds()`, the
coarse thermal-status bucket, and battery temperature.

**Widgets.** The HyperOS picker is a server-curated Xiaomi catalogue that excludes
third-party widgets; the reliable path is in-app `requestPinAppWidget`. It fails
*silently* — no failure callback — so two things are load-bearing: a real
`previewLayout` **and** `previewImage`, and an `exported="true"` receiver so the
launcher can render the preview cross-process. Widgets cannot animate
continuously: a widget is `RemoteViews` in the launcher's process with no render
loop. Glance has no canvas, so a chart must be rasterised to a bitmap.

**Notification icons.** The prominent icon HyperOS shows in the shade is the
static `<application android:icon>`, immutable at runtime. `setSmallIcon` drives
only the status-bar silhouette; `setLargeIcon` renders but lands on the *right*,
leaving two mismatched icons. Theming the notification app-chip is not achievable
here.

**Lock-screen notifications** are hidden by default: MIUI classifies any silent
notification as suppressible and removes the AOSP control. One device-wide secure
setting restores them; it persists across reboot and cannot be set by an app on
the user's behalf.

**Install quirks.** Session-split installs fail with
`INSTALL_FAILED_USER_RESTRICTED` — use `adb install -r`. A *new package* install
also needs a physical tap unless "Install via USB" is enabled.
`POST_NOTIFICATIONS` prompts even after `install -g`; grant it before a scripted
launch or the dialog stalls the launch.

## Build traps

- **`cargo test -p <libs>` skips the root binary.** A non-exhaustive match in a
  binary crate passes the test gate and fails `cargo build --release`. Always
  build the release profile in any Rust gate. Related: `cmd | tail` returns
  *tail's* status and masks a cargo failure — capture `PIPESTATUS[0]`.
- **Room rejects leftover columns.** Dropping a column requires recreating the
  table, not a leave-the-column migration; Room compares the live table to the
  entity exactly on open and crashes on launch otherwise. Verify a migration both
  by instrumented test *and* by a real reinstall over old data — they catch
  different failures.
- **Stale cross-compiled `.so`.** If the Rust sources are not declared as task
  inputs, Gradle repackages an old library while the bindings reference new
  functions. The signature is an `UnsatisfiedLinkError` naming
  `uniffi_..._checksum_func_*`.
- **`cargo-ndk` must be on `PATH`** or the native build silently *skips*.
  `cargo install`ed tools live in `~/.cargo/bin`, not on the default path here.
- **Wrapping arithmetic in checksums.** A checksum that summed in wider precision
  than the specification passed every published golden vector — none of which
  overflowed — while failing on real data, where the fail-closed gate then dropped
  every frame silently. Test against real captures, not only golden vectors.

## Driving the device over adb

**Do not type text into the app with `adb shell input text`.** It has a known IME
race that drops or rotates the first character — `localhost` arriving as
`ocalhostl`. Use the app's deeplink handler:

```sh
adb shell "am start -W -a android.intent.action.VIEW -d \
  't1dmdroid://settings?host=…&port=…&token=…'"
```

The quoting is load-bearing: `&` separates commands on the device side, so the
whole URL must sit inside single quotes that survive the trip through
`adb shell`. Without that, only the first query parameter arrives.

**When the phone cannot reach the laptop over the network** — access-point
isolation on public WiFi is the usual cause — pipe the connection down the USB
cable:

```sh
adb reverse tcp:<port> tcp:<port>    # then point the app at 127.0.0.1:<port>
```

The mapping persists until the device disconnects or the adb server restarts;
`adb reverse --list` confirms it.

## Debugging discipline

When something that **used to work** breaks, it is a regression: something
changed. Do not chase the symptom by disabling protections — optimization tiers,
full-mode shrinking, keep-everything rules, lint, or safety gates. Ask what
changed since it last worked, and inspect the resolved dependency graph for
transitive version bumps before touching build flags. A version pin that restores
the known-good state beats switching off an optimization the author wants on.

## Watch accessory

Optional; the app is fully functional without it. Data flows **phone → watch
only**, pushed periodically: current glucose, trend, a one-line forecast summary,
alerts, status. No images.

BLE GATT with the phone as central. Security is **app-layer AES-128-GCM** as the
source of truth — per-direction keys, monotonic nonce, X25519 key agreement on
first pair confirmed by a short authentication string on both ends — over a
bonded link for defence in depth only. Manual key rotation and session reset are
exposed. The hardware is not built; the phone side is validated against a desktop
BLE peripheral emulator.

## Working with the author on this project

- The phone is a daily driver. It may be disconnected between tasks, never
  mid-task. Say plainly when it is about to be needed.
- **Announce before any on-device sensor test** — it requires the vendor app to
  be shut off on the author's other phone.
- Each phase runs as its own multi-agent workflow, by standing preference.
- Never commit a server URL or token, a sensor serial, personal thresholds, or
  planning notes. Those belong in gitignored local configuration.
