# T1DMAUTO — working knowledge

An Android app for a car head unit (Android 10, 2 GB RAM): the reading, its arrow,
6 h of history, the 2 h forecast, the phone's status and its forecast message, in a
light or dark theme. A Rust core behind JNI is a peripheral on the watch link
(`../SPEC/watch.md`) that sets `EXTENDED`; Kotlin runs the GATT server, the
advertiser and one `Canvas` view. No AndroidX. MIT.

Active: it displays a patient's live record. It never alarms; the core drops the
alarm and predicted-low/high bits before the screen sees them. The outlook is
shown as text, as sent.

## Seams

- `core/` depends on `../T1DMDROID/crates/t1dm-watch` by path. GATT UUIDs reach
  Kotlin from the crate through JNI.
- `core/src/link.rs`, `model.rs` and `store.rs` are ports of T1DMKDE
  `daemon/src/`: the peripheral state machine, the stale rule
  (`fresh_until_ms`) and the key store exist twice. A fix to one is owed to the
  other.
- The phone matches peripherals by advertised name, and Android advertises the
  adapter's name, so the app renames the head unit's Bluetooth adapter to
  `T1DM-Watch-xxxxxxxx`.
- The zone colours are the app's own, one palette per theme; the phone's display
  record supplies only thresholds, Y range and stale limit.
- The boot receiver starts the link only once the app has run live, so a device
  that has only rendered the sample keeps its Bluetooth name.

## Status

Untested on the head unit: whether its Bluetooth stack can advertise over BLE is
unknown, and the app says so on screen when it cannot. Pairing and pushes have
not run against a phone; `cargo test` covers the link, pairing and model.

## Checks

- `cargo test` — link state machine, pairing flow, model, store.
- `tools/render.sh <serial>` — the synthetic day drawn offscreen by the app on a
  device in sample mode, at 1024x600, 1280x720 and 2000x1200, both themes, fresh
  and aged, and the pairing states; uninstalls afterwards. It leaves the device's
  display alone: a `wm size` or `wm density` change makes a HyperOS launcher
  re-lay out its home screen, and the layout stays after a reset.
