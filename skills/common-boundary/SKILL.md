---
name: common-boundary
description: >-
  MANDATORY before adding, moving, or promoting any file into T1DMCOMMON. This repository is public
  and is consumed by repositories that are not — T1DMDROID keeps a local-only branch carrying
  reverse-engineered CGM sensor-control protocol and real patient data, and it has twice had to be
  deleted after such content reached GitHub. Triggers: "move this into common", "promote", "share
  this constant", "put it in the spec", adding any file under T1DMCOMMON, or copying anything out of
  a sister repository into it.
---

# What may enter T1DMCOMMON

`T1DMCOMMON` is published. Treat every file placed here as already public. A
push is not undoable: GitHub keeps unreferenced commits reachable by SHA long
after a branch moves, so a force-push does not retract an exposure. Deleting the
repository is the only complete remedy, and that has been necessary twice.

## Never promote

- CGM sensor-control protocol: activation, reset, bonding, session-key
  derivation, serial-derived material, or reverse-engineered frame formats
- device identifiers, serial numbers, MAC addresses, or anything naming a
  specific piece of hardware
- real patient data in any form — traces, exports, screenshots, figures plotted
  from them
- credentials, bearer tokens, API keys, private network or tailnet addresses,
  hostnames, home directory paths
- anything from a sister repository's local-only branch, whatever it contains

## Safe to promote

- published clinical formulae and their citations
- synthetic data, and constants describing its shape
- wire contracts, schemas, interface definitions
- units, conventions, domain vocabulary
- agent instructions and process documentation

## Before adding a file

1. **Name the source.** Which repository, which branch? A local-only branch
   stops here.
2. **Read it whole.** Not the part in use — the whole file. Promoting unread
   content is how the last two exposures happened.
3. **Ask what it reveals.** A constant can be innocuous and its variable name
   disclosing; a comment can name a device; an example value can be a real
   reading. Check the surrounding prose, not only the value.
4. **Prefer a reference.** Default is to leave content in the repository that
   owns it and point at it. Promote only what must be shared to keep two
   implementations in agreement.
5. **Scrub examples.** Illustrative values must be obviously synthetic:
   documentation-range addresses, round numbers, placeholder identifiers.

## If something has already leaked

Say so immediately and stop. Do not quietly amend it away. Establish first
whether the repository has ever been pushed: content that has never left the
machine can be rewritten out of history completely, and pushed content cannot.
The two call for different responses, and the difference is not recoverable once
the wrong one is chosen.
