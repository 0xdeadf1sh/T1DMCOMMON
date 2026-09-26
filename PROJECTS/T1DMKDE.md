# T1DMKDE — working knowledge

A KDE Plasma 6 wallpaper and the BLE daemon that feeds it. The daemon, `t1dmkd`, is
a peripheral on the watch link (`../SPEC/watch.md`) that sets `EXTENDED`, so the
phone pushes it history, the forecast fan, statistics and the resolved theme as
well as the glance. Rust daemon, QML wallpaper. MIT.

Active: it displays a patient's live record. It never alarms; the daemon drops the
alarm and predicted-low/high bits before the wallpaper sees them.

## Seams

- `daemon/` depends on `../T1DMDROID/crates/t1dm-watch` by path. The crate is
  identical on T1DMDROID's `main` and `private`, so either checkout builds it.
- The daemon writes `$XDG_STATE_HOME/t1dmkde/snapshot.json`; the wallpaper reads
  it every 15 s through Plasma5Support's `executable` engine. No compiled QML
  plugin, so the wallpaper installs per-user with `kpackagetool6`. It draws on
  the GPU; its shaders ship compiled as `.qsb`, rebuilt by `tools/shaders.sh`.
- The wallpaper computes nothing clinical. It ages the glance by the phone's
  `stale_min` and withholds the number past it; it draws the fan stale once its
  anchor is older than that and drops it past its last step. The statistics are
  drawn as sent.

## Pairing

`t1dmkd pair` arms one HELLO for 120 s over a Unix socket in `$XDG_RUNTIME_DIR`.
The daemon takes CONFIRM only from the device that sent that HELLO, and answers
CONFIRM_ACK `ok = 1` only when the desktop user's yes names that handshake's code,
within 12 s of the phone's CONFIRM. Rotation from the phone is a new handshake, so
it too needs `t1dmkd pair`.

PUSH is served through BlueZ AcquireWrite, one socket read in arrival order. An
unpaired daemon answers every push with ERR_AUTH; the phone shows the pairing
refused and keeps its keys. A replayed seq is ignored without an error. The daemon
waits for the adapter to be powered and never powers it on.

## Checks

- `cargo test` — link state machine, model, store.
- `tools/render.sh` on `t1dmkd sample` output — offscreen GPU renders at seven
  resolutions, fresh and aged, through PySide6 and an X display. One layout: the
  graph edge to edge, the reading and statistics on a panel over its top-right
  corner.
