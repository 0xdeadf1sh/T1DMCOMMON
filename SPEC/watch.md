# Watch link

*Binds: `T1DMDROID` (central) → `T1DMKDE` and any watch firmware (peripherals).*

A BLE GATT link on which the phone pushes sealed records to paired peripherals.
Data flows phone → peripheral only. Multi-byte integers are little-endian unless
stated. Glucose is mg/dL. Timestamps are epoch milliseconds on the five-minute
grid (`invariants.md` §1).

## 1. Identity and discovery

| Field | Value |
| --- | --- |
| Role | peripheral; the phone is the central |
| `device_id` | 8 random bytes, minted once per peripheral, stable across pairings |
| Advertised name | `T1DM-Watch-` + the first four `device_id` bytes as lowercase hex, in the advertising data |

The phone holds any number of pairings, one per `device_id`, and one link per
pairing. Pairing connects to an advertiser carrying the name prefix and no name
of a pairing in use, and refuses one whose STATUS `device_id` does not give the
name it advertised. Every connection reads STATUS before anything sealed is
sent; a `device_id` other than the pairing's disconnects and touches no key.

## 2. GATT map

Service `7ed10000-c0de-4a7c-9b0d-1d0a7a7c0f01`. Characteristics share the base
and differ in the first group.

| Characteristic | UUID first group | Properties | Carries |
| --- | --- | --- | --- |
| KEX | `7ed10001` | write with response | HELLO, CONFIRM (§3) |
| CONTROL | `7ed10002` | notify | acks and errors (§6) |
| PUSH | `7ed10003` | write without response | sealed records (§5) |
| STATUS | `7ed10004` | read | `[u8 proto][u8 epoch][u8 flags][8B device_id]` |

CONTROL is subscribed through CCCD `00002902-0000-1000-8000-00805f9b34fb`.
Bring-up: connect, request MTU 247, discover, subscribe CONTROL, read STATUS.

STATUS `flags` bit 0 is `EXTENDED`: the peripheral takes record kinds `0x02`–`0x05`.
The other bits are zero.

## 3. Handshake

Frames on KEX and CONTROL are `[u8 type][u8 proto = 0x01][body]`, unsealed.

| Frame | Dir | type | Body |
| --- | --- | --- | --- |
| HELLO | → KEX | `0x01` | `[u8 epoch][32B central X25519 public]` |
| HELLO_ACK | ← CONTROL | `0x02` | `[u8 epoch][32B peripheral X25519 public]` |
| CONFIRM | → KEX | `0x03` | `[u8 epoch][u8 ok]` |
| CONFIRM_ACK | ← CONTROL | `0x04` | `[u8 epoch][u8 ok]` |

Both sides mint an ephemeral X25519 keypair, derive keys (§4) and show the SAS.
The central sends CONFIRM after its user confirms. The peripheral answers
CONFIRM_ACK `ok = 1` only after its own user confirms; the keys go live on that
answer. A frame whose `proto` or `epoch` differs from the handshake in flight
fails the pairing.

A peripheral takes one HELLO each time its user opens pairing, and CONFIRM only
from the device that sent that HELLO. Its user confirms the code shown; a
confirmation of any other code refuses the pairing.

Rotation re-runs this handshake with fresh keypairs on the live link. `epoch` is
0 on the wire. The old keys stay live on both sides until CONFIRM_ACK `ok = 1`.
`INFO_RATCHET` and the crate's `rotate` implement a root ratchet
that no central drives; a peripheral does not implement it.

## 4. Cryptography

Application-layer AES-128-GCM is authoritative. A BLE bond, where present, is
defence in depth.

### 4.1 Key agreement

`dh = X25519(own_secret, peer_public)`, RFC 7748 raw 32-byte keys. Reject an
all-zero `dh`, an all-zero peer key, and a peer key equal to one's own.

### 4.2 Key derivation

`pk_low ≤ pk_high` are the two public keys sorted as byte strings. Side **A** owns
`pk_low`, side **B** `pk_high`.

```
root   = HKDF-SHA256-Expand(HKDF-SHA256-Extract(salt = SALT, ikm = dh), INFO_ROOT, 32)
k_A2B  = HKDF-SHA256-Expand(root, INFO_A2B || pk_low || pk_high, 16)
k_B2A  = HKDF-SHA256-Expand(root, INFO_B2A || pk_low || pk_high, 16)
```

A sends with `k_A2B` and receives with `k_B2A`; B the reverse.

| Name | ASCII value |
| --- | --- |
| `SALT` | `t1dm-watch/x25519/hkdf-sha256/aes128gcm/v1` |
| `INFO_ROOT` | `t1dm-watch root v1` |
| `INFO_A2B` | `t1dm-watch key A->B v1` |
| `INFO_B2A` | `t1dm-watch key B->A v1` |
| `INFO_RATCHET` | `t1dm-watch ratchet v1` |
| `SAS_INFO` | `t1dm-watch sas v1` |

### 4.3 SAS

```
d   = SHA-256(SAS_INFO || pk_low || pk_high)
sas = u32_be(d[0..4]) mod 1_000_000, six zero-padded digits
```

### 4.4 Record AEAD

AES-128-GCM with the sender's key, 16-byte tag, and
`nonce = epoch:u32_le || seq:u64_le`. The 13-byte record header is the
associated data.

### 4.5 Nonce discipline

`seq` is per epoch and per direction, strictly increasing from 0. A sender
persists a ceiling 64 seqs ahead (`NONCE_WINDOW`) before sealing inside it, and
after a restart resumes at the persisted ceiling. A receiver keeps `recv_min`,
rejects `seq < recv_min`, tolerates gaps, and advances `recv_min` only after the
tag verifies. A peripheral persists `recv_min` so a replay fails across its
restart too.

## 5. Records

### 5.1 Sealed frame

```
off type  field
 0  u8    version = 0x01
 1  u32   epoch
 5  u64   seq
13  ..    ciphertext || 16-byte tag
```

One record per PUSH write. Plaintext is at most 215 bytes (`RECORD_MAX`): MTU 247
less 3 ATT, 13 header and 16 tag bytes. Plaintext byte 0 is the record kind. A
receiver ignores a kind it does not know.

A peripheral opens PUSH writes in arrival order. `seq` rises along a burst, so a
record opened ahead of its turn moves `recv_min` past the ones before it.

### 5.2 Kinds and schedule

| kind | record | sent to | when |
| --- | --- | --- | --- |
| `0x01` | glance | every peripheral | each measured reading, each grid tick |
| `0x02` | history | `EXTENDED` | each measured reading and each tick, last 12 slots; 24 h on connect |
| `0x03` | forecast | `EXTENDED` | each tick, each new inference cycle, on connect |
| `0x04` | stats | `EXTENDED` | hourly, on connect |
| `0x05` | display | `EXTENDED` | on connect, on change |
| `0x06` | unpair, no body | every peripheral | when its user unpairs (§7) |

The central sends kinds `0x02`–`0x05` only when STATUS sets `EXTENDED` and the
negotiated ATT MTU is at least 247. The low-power suspension (§5.3) holds every
kind but unpair.

### 5.3 Glance, `0x01`

```
off type  field
 0  u8    kind = 0x01
 1  u8    status_bits
 2  i16   bg_mgdl            -1 = none
 4  i16   trend_tenths       0.1 mg/dL/min; 0x8000 = none
 6  u8    alert_band         0 URGENT_LOW, 1 LOW, 2 IN_RANGE, 3 HIGH, 4 URGENT_HIGH; 0xFF none
 7  u8    forecast_status    0 OK, 1 NON_FINITE, 2 RAIL_PINNED, 3 COLLAPSED_BAND,
                             4 MISORDERED_QUANTILES; 0xFF none
 8  i16   fc_end_mgdl        selected model's median at the horizon end; -1 = none
10  u8    fc_horizon_steps
11  u8    fc_trend           0 FLAT, 1 RISING, 2 FALLING, 3 RISING_FAST, 4 FALLING_FAST
12  u32   reading_age_s      since the last measured reading
16  u8    bg_trend           bits 0–6 the direction, as fc_trend; bit 7 FITTED; 0xFF = none
17  u8    summary_len N      N ≤ 40
18  N     summary            UTF-8
```

`bg_trend` is the direction the phone draws beside its reading: the sensor's reported rate, or,
with FITTED set, the slope the phone fits when the sensor reports none. A peripheral shows it as
sent and never derives one from `trend_tenths`.

| bit | status |
| --- | --- |
| 0 | `LOW_POWER`: the central has suspended pushing; this is the last record until it resumes |
| 1 | `STALE` |
| 2 | `SIGNAL_LOSS` |
| 3 | `WARMUP`: the forecast is withheld |
| 4 | `PREDICTED_LOW` |
| 5 | `PREDICTED_HIGH` |
| 6 | `ALARM` |
| 7 | `FORECAST_UNAVAILABLE` |

### 5.4 History, `0x02`

```
off type   field
 0  u8     kind = 0x02
 1  u64    start_ts          grid slot of the first value
 9  u8     n                 1..102, (RECORD_MAX − 10) / 2
10  n×u16  slot              slot i sits at start_ts + i·300000
```

A slot is `0xFFFF` when empty, else bits 0–11 are mg/dL and bits 12–13 the
provenance: 0 measured, 1 interpolated, 2 reconstructed, 3 measured during
sensor warm-up. Bits 14–15 are zero. The values are the authoritative source's
rows; empty covers gaps, tombstones and invalid rows. A record overwrites every
slot it covers, empty ones included.

### 5.5 Forecast, `0x03`

```
off type   field
 0  u8     kind = 0x03
 1  u64    anchor_ts         the last measured reading the forecast grows from
 9  u16    anchor_mgdl
11  u8     forecast_status   as §5.3
12  u8     flags             bit 0 STALE, bit 1 CALIBRATED
13  u8     H                 horizon steps; 0 withdraws the forecast
14  u8     L                 fan levels
15  u8     step_min
16  u8     first             first step in this record, 0-based
17  u8     m                 steps in this record, ≤ 12
18  m×(1+L)×u16             per step: median, then the L levels
```

Step `k` (0-based) sits at `anchor_ts + (k + 1)·step_min·60000`. The levels are
the fan of `invariants.md` §6, in its order. Values are mg/dL rounded to the
nearest integer, `0xFFFF` where non-finite. The fan is the selected model's as the
phone draws it: `CALIBRATED` says the §8.4 correction of `inference.md` was
applied, and no peripheral applies it. A forecast is complete when steps
`0..H−1` of one `anchor_ts` have arrived.

### 5.6 Stats, `0x04`

```
off type    field
 0  u8      kind = 0x04
 1  u16     target_low         mg/dL
 3  u16     target_high
 5  u8      k                  windows, ≤ 3
 6  k×23    window
```

| off | type | window field |
| --- | --- | --- |
| 0 | u8 | days |
| 1 | u32 | n_samples; 0 = nothing to show |
| 5 | 5×u16 | very_low, low, in_range, high, very_high, time-weighted, ‰ |
| 15 | u16 | mean, 0.1 mg/dL |
| 17 | u16 | SD, 0.1 mg/dL |
| 19 | u16 | CV, ‰ |
| 21 | u16 | GMI, 0.01 % |

The figures are the phone's statistics over the last `days`, unchanged.

### 5.7 Display, `0x05`

```
off type    field
 0  u8      kind = 0x05
 1  u8      flags              bit 0 DARK
 2  15×u32  palette ARGB       background, surface, surface_variant, primary, on_primary,
                               secondary, on_secondary, ink, ink_muted, grid,
                               urgent_low, low, in_range, high, urgent_high
62  4×u16   thresholds         urgent_low, low, high, urgent_high, mg/dL
70  u16     range_min          graph Y range, mg/dL
72  u16     range_max
74  u8      window_h           graph history window, hours
75  u8      stale_min          a reading older than this is stale
76  u8      loss_min           signal loss after this long without a measured reading
77  u8      name_len N         N ≤ 32
78  N       theme name         UTF-8
```

The palette is the phone's resolved theme, custom themes included.

## 6. Control frames

Peripheral → central on CONTROL, `[u8 type][u8 proto][body]`.

| Frame | type | Body |
| --- | --- | --- |
| HELLO_ACK | `0x02` | §3 |
| CONFIRM_ACK | `0x04` | §3 |
| ERR_EPOCH | `0x10` | `[u8 peripheral_epoch]` |
| ERR_AUTH | `0x11` | `[u8 epoch]` |
| PUSH_ACK | `0x20` | `[u8 epoch][u32 seq]`, optional |

## 7. Pairings and recovery

- **Unpair.** The central seals the unpair record (§5.2) to the peripheral and
  wipes that pairing's keys and counters; a peripheral that opens it wipes its
  own. Sealed, it can come only from the paired central.
- **Refusal.** ERR_EPOCH, ERR_AUTH and a STATUS epoch other than the session's
  are unauthenticated, so none touches a key. The central drops the connection,
  shows the pairing refused, and retries at the reconnect backoff's ceiling.
  Pairing again replaces the keys; unpairing removes them.
- **Reconnect.** A dropped link reconnects with exponential backoff while its
  pairing exists.

## 8. Constants and golden vectors

`RECORD_MAX = 215`, MTU 247, `NONCE_WINDOW = 64`, frame version `0x01`, proto
`0x01`, name prefix `T1DM-Watch`.

X25519, RFC 7748 §5.2:

```
scalar = a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4
u      = e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c
out    = c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552
```

HKDF-SHA256, RFC 5869 test case 1:

```
IKM  = 0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b
salt = 000102030405060708090a0b0c
info = f0f1f2f3f4f5f6f7f8f9
OKM  = 3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865
```

AES-128-GCM:

```
key       = 000102030405060708090a0b0c0d0e0f
nonce     = 101112131415161718191a1b
aad       = feedfacedeadbeef
plaintext = 48656c6c6f2c20776174636821
ct || tag = 8c4b6fc36063969876a93e9de6265a21d754cb10add2e5c59b74c78fe3
```

SAS, symmetric:

```
pk_a = 7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13
pk_b = 0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20
SAS(pk_a, pk_b) = SAS(pk_b, pk_a) = 013208
```

Sealed record. Secrets `11…11` (a) and `22…22` (b) handshake; `public_b < public_a`,
so b is side A. a seals at epoch 0, seq 0, empty extra AAD; b opens it and its
`recv_min` becomes 1.

```
public_a   = 7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13
public_b   = 0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20
root       = 0be77e9a87b1e44a64c930b5d5447269e953d7a9fe12c6d391d65cc77bbd8a8b
a_send_key = 073d0e97b2b5208f5604905dfd12528b
plaintext  = 01730580620a4f4b2c66635f656e64403435
frame      = 01 00000000 0000000000000000
             142a05b0d197782e62c52722ca05bfcd79d79a2428685774eba1acecf5297964d17e
```

Record encodings are pinned by `T1DMDROID/crates/t1dm-watch/testdata/records_golden.json`.
