# T1DMKDE — working knowledge

A KDE Plasma 6 wallpaper, a panel widget, and the BLE daemon that feeds both. The
daemon, `t1dmkd`, is a peripheral on the watch link (`../SPEC/watch.md`) that sets
`EXTENDED`, so the phone pushes it history, the forecast fan, statistics and the
resolved theme as well as the glance. The panel widget shows the glance alone: the
reading, its arrow and its age; `t1dmkd prompt` prints the same for a shell
prompt. Rust daemon, QML packages. MIT.

Active: it displays a patient's live record. It never alarms; the daemon drops the
alarm and predicted-low/high bits before either package sees them.

## Seams

- `daemon/` depends on `../T1DMDROID/crates/t1dm-watch` by path. The crate is
  identical on T1DMDROID's `main` and `private`, so either checkout builds it.
- The daemon writes `$XDG_STATE_HOME/t1dmkde/snapshot.json`; both packages read
  it every 15 s through Plasma5Support's `executable` engine. No compiled QML
  plugin; `tools/install.sh` installs both per-user with `kpackagetool6`, copying
  in the QML they share from `shared/`. The wallpaper draws on the GPU; its
  shaders ship compiled as `.qsb`, rebuilt by `tools/shaders.sh`.
- Nothing here computes anything clinical. The daemon writes the glance's
  `fresh_until_ms`: `stale_min` past the reading, null when the phone flags it
  stale or signal lost. The packages and the prompt withhold the number past it.
  The wallpaper draws the fan stale once its anchor is older than `stale_min`
  and drops it past its last step. The statistics are drawn as sent.
- Restarting `t1dmkd` while the phone is connected moves the watch service to
  new GATT handles. The phone's next STATUS read fails and it reconnects
  (`../SPEC/watch.md` §7): data resumes within about 40 s.

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
  corner. Then the panel widget, one line and stacked, on Breeze dark and light.
