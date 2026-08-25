# T1DMSERVER — working knowledge

The sync backend: one binary that is at once an HTTP/WebSocket server and a live
terminal dashboard over an in-process SQLite store. Rust, MIT. Runs unattended on
a Raspberry Pi Zero 2 W, watched from a tmux session over SSH.

Its remit is narrow — see `../CLAUDE.md`, *What T1DMSERVER is, and is not*. The
most common mistake here is giving the server a job that belongs to the phone.

## Shape

A single process. A four-worker Tokio runtime serves the axum router and watches
the models directory; the ratatui TUI owns the main thread. SQLite runs in WAL
mode with every write serialized behind one mutex and reads served from an r2d2
pool on blocking tasks. Stored records reach the TUI over an in-process broadcast
channel, so the dashboard updates without polling.

Four crates plus a root binary: `core` (domain types, units, curve maths,
config), `store` (schema, writer, read pool, tokens, sessions, model registry),
`api` (router, auth extractors, handlers, hub), `tui` (layout, panes, widgets,
themes, animation, boot sequences).

## What the server does not do

It is a verbatim store and a read-only fan-out:

- statistics are **pushed by the phone** and stored opaquely; the server computes
  none
- meals and doses are **first-class events** keyed by a phone-minted
  `client_id`; `samples` holds scalars only
- forecasts are **not stored**: they arrive on the stream, are fanned out and
  drawn live, and are gone when the socket closes
- a deletion arrives as a **tombstone** on the same upsert; no route serves a
  `DELETE`
- the phone's `updated_at` is stored **verbatim** and is the ordering key for
  every idempotent upsert
- every write fans out to all sessions **except its origin**
- a `store_epoch` marks store identity so a client can detect a wipe and
  re-mirror

Documentation or comments implying an older participant design are stale.

## Gates

**No CI.** Nothing runs unless a person runs it. The commands, and the two traps
that make a skipped step look like a pass, are in the project's own `CLAUDE.md`.
Read it before claiming a change works.

## Storage layout

Everything sits under `storage.data_dir` (default `./data`): the database, plus
`models/`, `photos/` and `backups/`. The binary uses `<data_dir>/models`, not the
repository-root `models/`.

**One artifact, one sidecar — a model with a third file does not fit.**
`refresh_models` registers every non-`.json` file in the directory as a model in
its own right and pairs it with a sibling `<stem>.descriptor.json`. The export
now writes a head side file beside each artifact — the seam an on-device adapter
attaches to — so a model delivered through the server arrives without it and the
phone offers no adapter for it. Dropping the head file into the models directory
would register `<id>.head.bin` as a model of its own, with no descriptor, and
offer it for download. Serving it needs a registry that knows a model can have
companion files. An `adb`-pushed model is unaffected.

The database grows by roughly a gigabyte per year and is not compacted. Backups
are taken on demand from the Settings pane; there is no scheduler, despite
`BackupConfig` existing in the configuration structs where nothing reads it.

**Take a backup before first starting a binary that moves the schema forward.**
The migration ladder runs on open and has no down-migration; the `0.4.0` →
`0.5.0` step drops the `prediction` table outright. The guard that refuses to
start on a short head is one-sided — it catches a binary older than the store,
never a store older than the binary that has already been migrated. The ladder
runs in one transaction, so a part-way failure leaves the store as it was; a
completed migration is the irreversible one.

The Developer pane's teardown drops and recreates every table and clears the
photos directory, leaving the models directory alone. It re-mints the
`store_epoch`, which is what tells a client to replay its history.

## Access

Opaque bearer tokens — 32 random bytes as hex, stored only as a salted SHA-256
verifier, never expiring, revocable. At most one live `rw` token exists at a
time, enforced by a partial unique index; each viewing device gets its own `ro`
token.

Tokens are minted **only** from the TUI's Sessions pane; there is no HTTP
endpoint for token management. First light therefore requires terminal access:
start the binary, open Sessions, mint the `rw` token, scan the QR.

Plain HTTP, permissive CORS, non-expiring tokens: a tailnet or LAN appliance that
must not face the open internet.

## The console

Four themes — Tron Legacy, Umbrella Corp, Hello Kitty, Windows XP — each with its
own palette, animations, boot sequence and glyph set, hot-swappable at runtime.
Panes: Dashboard, Data, Models, Sessions, Device, Developer, Logs, Settings,
Help. `Tab` cycles panes, `t` cycles themes, `h` or `?` opens help, `q` quits.

Rendering is demand-driven: the UI idles near zero cost and wakes on input, a
data event, or a live animation. Layout reflows from a wide multi-panel view down
to a single-column Termux layout.

The console carries its own curve mathematics and risk transform purely to draw
these panes. They are display conveniences and must never write back into stored
data. Divergence there misleads the operator; it does not corrupt a record.

## Deployment

Cross-compiled for aarch64 via `cross`, which supplies the C toolchain
`rusqlite`'s bundled SQLite needs (`just build-pi`). Run inside tmux so it
survives SSH disconnects; the TUI expects truecolor and mouse forwarding.
