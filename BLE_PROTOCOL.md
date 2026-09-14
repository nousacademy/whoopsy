# WHOOP 4.0 / 5.0 / 5.0 MG BLE Protocol Specification

Reverse-engineered Bluetooth Low Energy protocol for WHOOP hardware. Three straps are in scope and
**they do not share a wire format**: WHOOP 4.0 ("Harvard" / Gen 4), WHOOP 5.0, and WHOOP 5.0 MG
(Member Gift). Which one a claim applies to is stated on every claim below.

## How to read this document

Nothing here has been captured on this project's own hardware yet. Every statement is tagged with
where it came from, and the tags are not decoration — most of the disagreements recorded below exist
because two sources were silently mixed in an earlier revision of this file.

| Tag | Meaning |
| :--- | :--- |
| **[captured]** | Observed on this project's own strap from a recorded session. **There are none of these yet.** |
| **[reported 4.0]** | Stated by the open-source WHOOP 4.0 reference. Not independently confirmed here. |
| **[reported 5.0]** | Stated by the open-source WHOOP 5.0 / MG reference. Not independently confirmed here. |
| **[repo]** | What the code in `Data/BLE/` actually does today. A statement of fact about this codebase, not a claim about the strap. |

Where a source marked a field low-confidence, that is carried across rather than smoothed over.
**Treat every byte offset as a lead until a capture confirms it.**

---

## 1. GATT Services & Characteristics

The strap advertises standard BLE services (`0x180D` Heart Rate, `0x180F` Battery, `0x180A` Device
Info), which remain largely dormant until a secure bond is established and session initialization
occurs. The core data exchange happens over a proprietary custom primary service, and the two
generations use different ones.

### The 4.0 base UUID is unresolved

The document and the code currently disagree, and **neither has been confirmed against hardware**:

| Source | WHOOP 4.0 base |
| :--- | :--- |
| This document (previous revision) | `61080000-8d6d-82b8-614a-1c8cb0f8dcc6` |
| `WhoopGATTConstants` **[repo]** | `61080001-8D6D-82A5-4E40-1CA360B95B30` |

These differ in more than the trailing service digit — the `82b8-614a-1c8cb0f8dcc6` and
`82A5-4E40-1CA360B95B30` halves are unrelated. One of them is wrong, and a wrong service UUID
presents as *no device found* rather than as a decode error, so it is worth settling early. The first
item on the capture plan below is a service scan, which answers this outright.

The 5.0 / MG base does not have this problem — `fd4b0001-cce1-4033-93ce-002d5875f58a` agrees between
the document and the code.

### Characteristic map

* **WHOOP 4.0** (`610800xx-…`) **[repo]**: `…0001` service · `…0002` command write (client → strap) ·
  `…0003` response read / indicate (strap → client) · `…0004` events notification (wear state,
  battery, tap) · `…0005` raw sensor data stream · `…0007` memfault diagnostics.
* **WHOOP 5.0 / MG** (`fd4b000x-…`) **[repo]**: same five roles at `…0001`…`…0005`.

`WhoopGATTConstants.scannableServiceUUIDs` **[repo]** carries the 4.0 service, the 5.0 service and
the standard `180D`, so all three straps are at least discoverable.

---

## 2. Packet Framing & Wire Format

**This is the largest single difference between the generations, and this codebase implements only
one of the two envelopes.**

Both generations share a start-of-frame byte `0xAA`, an inner record of the shape
`[type][seq][cmd][payload…]`, and the same zlib CRC-32 as the payload check (reflected, poly
`0xEDB88320`, init `0xFFFFFFFF`, final XOR `0xFFFFFFFF`). Everything between the SOF and the inner
record differs.

### WHOOP 4.0 envelope **[reported 4.0]**

```
[0]      SOF = 0xAA
[1..3]   length, u16 LE  (occupies bytes 1 and 2)
[3]      crc8
[4]      inner type
[5]      inner seq
[6]      inner cmd
[7..len) payload
[len..+4) crc32, u32 LE
```

* The header check is **CRC8**, table-driven, polynomial `0x07`, computed over **the two length bytes
  only** — `crc8([frame[1], frame[2]])`.
* `length` equals the inner count plus 4; total frame size is `length + 4`.
* The inner record begins at **offset 4**; CRC32 covers `frame[4 ..< length]`.

### WHOOP 5.0 / MG envelope **[reported 5.0]**

```
[0]        SOF = 0xAA
[1]        format = 0x01
[2..4]     declLength, u16 LE
[4..6]     header bytes (2)
[6..8]     crc16, u16 LE
[8]        inner type
[9]        inner seq
[10]       inner cmd
[11..]     payload
tail (4)   crc32, u32 LE
```

* The header check is **CRC16-Modbus**: poly `0xA001`, init `0xFFFF`, reflected, taken over the first
  **six** header bytes (`frame[0..<6]`).
* `declLength` counts the payload **plus** the 4-byte CRC32 trailer, so payload length is
  `declLength − 4` and the trailer starts at `declLength + 8 − 4`. Total frame size is
  `declLength + 8`.
* The inner record begins at **offset 8** — a four-byte shift against 4.0.
* CRC32 covers `frame[8 ..< declLength + 4]`.
* 5.0 has a fixed 16-byte type-35 `CLIENT_HELLO`, beginning `AA 01 08 00 00 01 E6 71 …`; 4.0 has no
  fixed hello.

### What that means for a single decoder

Three consequences, and the third is the one that bites:

1. **The header CRC algorithm is generation-selected** — `.crc8` versus `.crc16Modbus`. `CRCUtils`
   **[repo]** implements both plus `crc32`, and **all three are correct** — see §2.1, where they were
   checked against published reference vectors. `crc16Modbus` is nevertheless **called from no
   production path at all**: the only call sites are the suite's own smoke tests
   ([main.swift:22](Tests/WhoopsyTestRunner/main.swift#L22) and the dead `CRCUtilsTests`), so the
   5.0 envelope's checksum is implemented and correct but wired to nothing.
2. **The inner record origin moves from 4 to 8.** A decoder that reads `cmd` at a fixed offset is
   correct for exactly one generation.
3. **The packet-type numbering itself differs by generation.** 4.0 uses `0x23` / `0x24` / `0x30` /
   `0x2F` / `0x31`; 5.0 uses **35 / 36 / 47 / 48 / 49** for command, command-response,
   historical-data, event and metadata (with 37/38/56 aliased onto command-response and metadata so
   they never decode as unknown, and 40/43 for realtime data). A single `switch` on the type byte
   cannot serve both — the values do not overlap.

### Packet types

| Role | 4.0 **[reported 4.0]** | 5.0 / MG **[reported 5.0]** |
| :--- | :--- | :--- |
| Command / request | `0x23` (also `0x72`) | 35 |
| Response / ack | `0x24` (also `0x73`) | 36 |
| Asynchronous event / heartbeat | `0x30` | 48 |
| Historical data record | `0x2F` | 47 |
| Metadata / sync markers | `0x31` | 49 |
| Realtime data | — | 40, 43 |
| Console logs | — | 50 |

Note for 4.0: **`0x30` is a packet type, not a command.** See §3.

### 2.1 The checksum math is correct; the call site is not **[repo, verified]**

Both references publish concrete frames, which makes the repo's CRC utilities checkable **today,
with no strap**. They were run against them and **all three are correct**:

| Vector | Source | Expected | `CRCUtils` | |
| :--- | :--- | :--- | :--- | :--- |
| `crc8([0x08, 0x00])` | osr `PROTOCOL.md` §2 | `0xA8` | `0xA8` | ✅ |
| `crc8([0x10, 0x00])` | osr `PROTOCOL.md` §2 | `0x57` | `0x57` | ✅ |
| `crc16Modbus(5.0 hello[0..<6])` | noop `PROTOCOL.md` §2.2 | `0x71E6` | `0x71E6` | ✅ |
| `crc32(5.0 hello payload)` | noop `PROTOCOL.md` §2.2 | `0x8D5C3E36` | `0x8D5C3E36` | ✅ |

The 5.0 vector is the whole static `CLIENT_HELLO` frame, so it validates the envelope reading too:

```
AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D
│  │  └─ declLength u16 LE = 8      │  └─ crc32 LE = 0x8D5C3E36
│  │     (payload = declLength − 4) └─ payload [8..<12]
│  └─ format 0x01                         type=35 seq=1 cmd=0x91
└─ SOF                              crc16 LE = 0x71E6 over [0..<6]
```

**The defect is therefore not in the arithmetic — it is in what `buildPacket` feeds it.** The 4.0
format specifies CRC8 over **the two length bytes only** (`raw[3] == crc8(raw[1:3])`), but
`buildPacket` computes `crc8([cmd, lengthLow, lengthHigh])` — three bytes, with `cmd` prepended.
Direct computation of the difference, for the two commands the app actually sends:

| Frame | `buildPacket` writes | Format specifies |
| :--- | :--- | :--- |
| `pingCommand` (cmd `0x20`, len 0) | `0x43` | `0x00` |
| `hapticAlarmCommand` (cmd `0x10`, len 8) | `0x0A` | `0xA8` |

So **every command frame this app has ever sent carries a wrong header CRC**, by construction and
on every call — a plausible first-order reason a strap would ignore the app entirely. The fix is one
expression (`Data([lengthLow, lengthHigh])`), and the vectors above are what pins it.

**This is also why it survived**, and the reason is worth recording next to the bug: the suite does
exercise all three CRCs, but its assertions are `crc8Val >= 0` — a comparison a `UInt8` can never
fail — and `!= 0` for the other two, which proves only that they are not identically zero. The frame
layout assertion beside them (`packet[1] == 0x10`) checks the encoder's output against the encoder's
own constant. So a wrong polynomial, a wrong byte order and a wrong *input* all pass. Replacing
those four assertions with the vectors above is the cheapest correctness win on the BLE path.

---

## 3. Initialization & Handshake Sequence **[reported 4.0]**

To wake live metrics and request historical syncs from a freshly bonded 4.0 strap, the reported
sequence is:

| Step | Value | Description |
| :--- | :--- | :--- |
| 1 | `0x23` | `GET_HELLO_HARVARD` — timestamp exchange; returns a 133-byte device status payload with the hardware serial number. |
| 2 | `0x0A` | Clock synchronization. |
| 3 | `0x75` | Feature flag query initialization. |
| 4 | `0x76` ×13 | Feature flag iteration (`general_ab_test`, `sigproc_10_sec_dp`, …). |
| 5 | `0x78` ×11 | Feature flag configuration (`enable_r19_v2_packets`, `enable_capsense_wear_detect`, …). |
| 6 | `0x22` | Config query (returns a 69-byte block). |
| 7 | `0x16` | `SEND_HISTORICAL_DATA` — starts the flash drain. |
| 8 | `0x17` ×N | `HISTORICAL_DATA_RESULT` — the per-batch ACK. |

**The step-1 value is a category error carried over from the previous revision.** Under both
envelopes `0x23` is the *packet type* for a command, and the command opcode lives in the inner record
(`inner[2]` for 4.0). Steps 7 and 8 are opcodes; step 1 is a type. The table mixes the two fields,
which is part of why the implementation below came out wrong.

### Implementation status **[repo]**

**None of this sequence is implemented.** The complete set of opcodes this codebase transmits is:

| Opcode | Encoder | Purpose |
| :--- | :--- | :--- |
| `0x05` | `enableLiveTelemetry` | enable/disable live telemetry |
| `0x10` | `hapticAlarmCommand` | haptic alarm |
| `0x20` | `pingCommand` | ping / keep-alive |
| `0x30` | `requestHistoricalSync` | **historical sync request — see §4** |

`0x0A`, `0x75`, `0x76`, `0x78`, `0x22`, `0x16` and `0x17` appear nowhere in the Swift sources. There
is no clock synchronization, no feature-flag negotiation, and no ACK loop.

---

## 4. Historical Sync (the flash drain)

This is the section that matters for anything wanting history from a night the app was not running.

### The record carries a wall-clock time

**[reported 4.0]** The flash record is **type 24**, packet type `0x2F`, one record **per second of
wear**, and its header is **96 bytes**:

| Bytes | Field | Confidence in source |
| :--- | :--- | :--- |
| `[0]` | packet type `0x2F` | verified |
| `[1]` | record type = 24 | verified |
| `[2]` | sub-field, constant `0x05` | verified |
| `[3:7]` | u32 record counter, incremented per record | verified |
| `[7:11]` | **u32 UNIX timestamp (seconds)** | verified |
| `[11:13]` | u16 sub-seconds | verified |
| `[17]` | heart rate (bpm); `0` means no reading | verified |
| `[18]` `[19:19+2n]` | rr_count (u8) + R-R intervals (i16 LE, ms) | verified |
| `[36:48]` | tri-axial accelerometer (g), float32 ×3 | verified |
| `[52:64]` | byte-identical mirror of `[36:48]` | — |
| `[88]` | u8 resting / baseline HR | empirical |

Sensor ADCs: raw green PPG `[29]`, red/IR `[31]`, red `[64]`, IR `[66]`, skin temp `[68]`, ambient
`[70]`.

**This is the finding that changes the feasibility question.** The historical record carries an
absolute unix time at `[7:11]` — so a drained night can be placed on a timeline, and a
heart-rate-over-the-night curve is constructible from stored history, not only from live capture.

**The field exists; whether its value is *right* is a separate question, and this is the trap.** An
absolute time is only as good as the clock that stamped it. The strap's RTC is set by
`0x0A SET_CLOCK` (`[u32 epoch LE][u32 0]`), and the reference's event enum carries **type 13
`RTC_LOST` — "battery fully died (clock reset)"** (plus event 16 `SET_RTC`). So a strap that has been
flat for long enough comes back with a clock that is wrong by an unknown offset, and **every
timestamp it then stamps is wrong by that same offset with nothing in the record to show it**. This
app never sends `0x0A` — §3 lists the four opcodes it does send, and none is a clock set — so on a
strap whose battery has fully drained there is nothing that puts the clock right. Two consequences
worth carrying into the capture: draining a battery-flat strap and trusting `[7:11]` would file
history under a wrong day rather than under no day, which is the failure the day-key rule exists to
prevent; and the detection is *indirect*, via event 13 (which is only seen if the app is listening
at the moment the RTC is lost) or by comparing a freshly drained record's `[7:11]` against wall
time. Treat a drained record's absolute time as **verified as a field, unverified as a value** until
that comparison is made.

**[reported 5.0]** The 5.0 / MG record is a different type (47) with a version byte selecting a
schema that inherits from a base layout via a `ref` chain (V12 → V24, …). Its decoded keys are listed
as `hist_version`, schema-versioned biometric fields and `rr_intervals`. **That source does not state
that type-47 records embed a per-record timestamp**, and describes instead a device↔wall clock
correlation taken from a `GET_CLOCK` response. So the two generations may differ here: 4.0 appears to
time each record, 5.0 may time the session and derive. Unresolved, and it is a capture question.

### The drain is a loop, and it needs an ACK

**[reported 4.0]** Commands are sent inside a `0x23` command frame with the opcode at `inner[2]`:

| Opcode | Name | Role |
| :--- | :--- | :--- |
| `0x16` | `SEND_HISTORICAL_DATA` | start the flash drain — the last step of init |
| `0x17` | `HISTORICAL_DATA_RESULT` | the per-batch ACK |
| `0x14` | `ABORT_HISTORICAL_TRANSMITS` | stop the drain cleanly |
| `0x21` | `SET_READ_POINTER` | u32 offset; rewind/seek the read cursor |
| `0x22` | `GET_DATA_RANGE` | the backlog window |

Two opcodes in the reference's full command table are **not to be sent by this app**, and both are
listed here because a drain that is misbehaving is exactly when someone reaches for them:

* **`0x19 FORCE_TRIM` is a flash erase and is destructive.** The reference marks it "never sent".
  The drain is non-destructive by design and does not need it; a trim issued to "clear the backlog"
  would destroy the user's history irreversibly, including the portion not yet drained.
* **`0x9A TOGGLE_PERSISTENT_R21` is a trap.** It forces the optical engine on across reboots, so the
  LED stays lit and the strap burns battery until a fresh boot — clearing the flag does not stop the
  running engine; recovery is `REBOOT_STRAP` (`0x1D`). The reference client keeps to wrist-gated
  optical (`0x6B ENABLE_OPTICAL_DATA`) and never sends `0x9A` casually.

Two more live-path opcodes belong here for completeness, since §5's live producer depends on them:
`0x03 TOGGLE_REALTIME_HR` and `0x6B ENABLE_OPTICAL_DATA` — the reference names `0x6B` as **the** HR
source, wrist-gated. This app uses the standard `0x2A37` GATT characteristic instead (§5), which is
a different route to the same quantity and the reason it needs no proprietary command to start.

Records stream as `0x2F` punctuated by `0x31` metadata markers with a sub-type at `inner[2]`:

* `1` = `HISTORY_START` — informational, ignore.
* `2` = `HISTORY_END` — **ack it and keep listening.**
* `3` = `HISTORY_COMPLETE` — **stop; do not ack.**

The `HISTORY_END` marker carries an 8-byte continuation token at `inner[13:21]`. The reply is:

```
[0x23 COMMAND][seq][0x17 HISTORICAL_DATA_RESULT][0x01 SUCCESS] + token(8B)      # 12 bytes
```

Status codes: `0x01` success, `0` failure, `2` pending, `3` unsupported.

**Without a correct ACK the strap re-sends the same batch forever** — the reference calls it the
"Groundhog Day bug". The cursor advances on a good ACK (≈ +5 per batch) and **persists across
connections**, so a partial drain resumes rather than restarts. The band answers each ACK with a
`0x24` ack-of-ack. The drain is **non-destructive — it never erases its own flash** — so it can be
repeated. Termination is `HISTORY_COMPLETE`, an idle timeout (~8 s reported for 4.0), or catching up
to the live edge. Event 96 (`HIGH_FREQ_SYNC_PROMPT`) signals flash filling and a desire for a faster
sync.

**[reported 5.0]** The same shape with different numbers: command 22 `SEND_HISTORICAL_DATA`,
23 `HISTORICAL_DATA_RESULT` (payload `[0x01] + end_data(8)`), 34 `GET_DATA_RANGE`,
96/97 `ENTER`/`EXIT_HIGH_FREQ_SYNC`. The `HISTORY_END` payload decodes as `'<LHLL'` from frame byte 7:

| Frame offset | Payload offset | Field | Type |
| :--- | :--- | :--- | :--- |
| 7 | 0 | `unix` | u32 LE |
| 11 | 4 | `subsec` | u16 LE |
| 13 | 6 | `unk0` | u32 LE (unmapped) |
| 17 | 10 | `trim_cursor` | u32 LE — **ack with this to advance the trim** |

Safe ordering on 5.0 is decode → insert → optional raw batch → set cursor → ack, so an un-persisted
chunk is never trimmed. Offload traffic is types 47/48/49/50; the live 40/43 streams are excluded
from the idle watchdog (60 s on 5.0, re-armed only by genuine offload frames). Re-offload every 900 s,
first sync ≈1.5 s after the handshake. `FORCE_TRIM` (25) is **destructive** and is excluded from the
safe command set along with reboot/power-cycle/firmware opcodes.

### Implementation status **[repo]**

**The historical sync in this codebase does not match either generation, in four independent ways.**
`DeviceViewModel` → `SyncHistoricalDataUseCase` → `WhoopBLEDeviceRepositoryImpl.requestHistoricalSync`
is reachable from the Device screen, so this is live code, not a stub.

| | This codebase | 4.0 **[reported 4.0]** | 5.0 **[reported 5.0]** |
| :--- | :--- | :--- | :--- |
| Request opcode | `0x30` | `0x16` | 22 |
| Inbound record type | `0x30` | `0x2F` | 47 |
| ACK loop | **absent** | `0x17` + 8-byte token | 23 + `end_data`(8) |
| Record layout | 16 bytes, live layout | 96-byte header | version-selected schema |

`0x30` is a problem in both directions. As an *outbound* command it is not a command at all — it is
the 4.0 event packet type, and this document's own §2 says so. As an *inbound* case it can only match
a frame whose type byte is `0x30`, which is an event, not a record.

Two further defects that are self-contained and worth fixing regardless:

* **`decodeHistoricalSyncPayload`** walks the payload in fixed 16-byte chunks and feeds each through
  `decodeLiveTelemetryPayload`, which stamps `timestamp: Date()`. So every record in a batch gets the
  **same** instant, and the real time at `[7:11]` is discarded. This is the defect that produced the
  (wrong) conclusion that the strap cannot time its own history.
* **`buildPacket`** computes `headerCrc = crc8([cmd, lengthLow, lengthHigh])` but appends only
  `[cmd][lengthLow][crc8]`. The high length byte is hashed and never transmitted, so any payload
  ≥ 256 bytes declares a wrong length on the wire.

And one that affects everything: **no inbound CRC is verified anywhere.** In `Sources/`, `crc8` and
`crc32` are called only from the encoder; `crc16Modbus` is called from nothing. Both references
independently flag length-based reassembly as essential, because payloads contain `0xAA` and BLE
fragments land on it — so today a payload byte that happens to be `0xAA` is indistinguishable from a
frame boundary.

**The suite cannot catch any of this** — its CRC assertions are self-referential, and §2.1 has the
detail, along with the four reference vectors that fix it. The short version: the checksum *math* is
verified correct, so what the vectors catch is the *call site* and the framing around it.

### The frame header does not match this document either

Worth recording because it is the reason none of the above has surfaced locally. The encoder and
decoder are **self-consistent with each other** — they round-trip — but both disagree with §2:

| | Encoder+decoder **[repo]** | §2 of this document **[reported 4.0]** |
| :--- | :--- | :--- |
| Byte 1 | command | length, low byte |
| Byte 2 | length, low byte | length, high byte |
| Byte 3 | crc8 | crc8 |
| Payload from | offset 4 | offset 4 |

Both agree the payload starts at 4, which is presumably why the pair appears to work. But under the
documented layout the decoder's `cmd` is really the length's low byte, which would make the
`case 0x01` / `case 0x02, 0x20` / `case 0x30` dispatch fire on payload length rather than on command.
**Neither has been validated against a strap**, and there is no local evidence either way: the
development database holds zero sample rows, so nothing in it was ever written by this path.

---

## 5. Heart rate: two producers, and which to use

Both are real, and they answer different questions.

### Live: the `0x2A37` R-R series — beat-exact, app-running-only

`0x2A37` is the Bluetooth SIG Heart Rate Measurement characteristic. Its R-R field (present when
flags bit 4, `0x10`, is set) is a **repeated `uint16` list**: one notification may carry several
beat-to-beat intervals, and their count is whatever fits the payload after the flags, the heart rate
and the optional energy-expended field. Each value is in units of 1/1024 s, so milliseconds are
`raw / 1024 * 1000`.

Two things follow, and both are load-bearing:

* **Within a notification the intervals are adjacent beats by definition**, and they arrive in beat
  order. That ordering is exact — unlike a timestamp, which for a BLE notification is an *arrival*
  instant (the app stamps `Date()` when the packet is decoded) and not the time the beats occurred.
* **A client that keeps only the first interval is discarding most of the series.** Whoopsy did
  exactly that until `v8`. Because Respiratory Sinus Arrhythmia is read off the beat-to-beat
  tachogram — a contiguous, correctly ordered series — a thinned stream cannot support it. The full
  list is now stored in `biometric_samples.rrIntervalsMs`, with `rrIntervalMs` retained as the first
  element.

**For a heart-rate-over-the-night curve this path needs no sampling rate at all.** The intervals are
themselves the time base, so beat times come from their cumulative sum and instantaneous HR is
`60000 / rr` at each beat — a finer and more honest curve than a fixed-cadence series, at the cost of
existing only for nights the app was running and the strap was connected. `WhoopBLEManager` already
logs the `0x2A37` frame once per connection to record whether the strap populates the R-R field at
all (`k == 0` means it does not), which is exactly the question that decides whether this path is
usable on a given strap.

### Historical: the drained flash — 1 Hz, needs no app

**[reported 4.0]** Type-24 records at one per second of wear, with heart rate at `[17]`, R-R at
`[18:19+2n]`, and an absolute unix time at `[7:11]`. This is the path that can fill in a night the
app slept through — but only once §4 is corrected.

**It also settles a question this repo has been carrying about respiratory rate.** The 4.0 reference
explicitly **rejects** a respiration field: `[76]`, which other projects list as `resp_rate_raw`, is
**bit-constant `3073` across all 811 records** it examined, and its `[78]` "signal quality" is
likewise bit-constant `3074` — both are fixed trailer bytes, not sensors. Its conclusion is that
**respiration is not in the record at all; WHOOP derives it in-cloud from the PPG**. That is why the
bundled export carries no respiratory-rate column to validate against, and it means this app's
`RespiratoryRateMath` — which derives the figure from the R-R series — is not a second-best route
around a channel it failed to find, but the same route WHOOP itself takes, from the same signal. The
practical reading for the drain: **do not go looking for a breathing channel in the flash**, and do
not treat the constant at `[76]` as a reading.

---

## 6. Open questions to settle by capture

Each of these is a question the sources disagree on, or that no source answers. The capture plan is
deliberately ordered so the cheap, high-leverage answers come first.

1. **Which 4.0 base UUID is real** (§1) — a service scan settles it, and a wrong UUID looks like no
   device at all. Run against the 4.0 strap.
2. **Which envelope does each strap actually speak** (§2) — capture the first frames each strap sends
   on connect and check the header CRC with `crc8` versus `crc16Modbus`, and the inner record origin
   at 4 versus 8. Three straps, three answers, and the 5.0/MG pair may not agree with each other.
3. **Does the 5.0 / MG record carry its own timestamp** (§4) — 4.0 appears to; 5.0's reference
   documents a session clock correlation instead and is silent on per-record time. This decides
   whether drained 5.0 history can be placed on a timeline.
4. **What the real record size and header are, per strap** (§4) — 96 bytes is reported for 4.0 type
   24. The 5.0 type-47 size is not stated anywhere.
5. **Whether the ACK token survives reconnection** (§4) — reported persistent for 4.0's cursor; the
   resume behaviour matters for a sync that runs on a phone that comes and goes.
6. **The full handshake**, per generation — §3 is 4.0-only and unverified, and 5.0's fixed
   `CLIENT_HELLO` is a different starting move entirely.
7. **Is each strap's RTC actually right?** (§4) — the cheapest way to check the most consequential
   assumption in this document. Drain one record and compare its `[7:11]` against wall time; a strap
   that has been flat for a long time reports `RTC_LOST` (event 13) and stamps a wrong clock. Until
   this is confirmed on each of the three straps, `[7:11]` is "a verified field whose value is
   unverified" — and a wrong clock misfiles history onto a wrong day rather than onto no day.

The capture itself is the deliverable: drain once, record the raw frames, and decode from the
recording. **Do not decode from a live drain into a parser written from these notes** — the frame
reassembly trap in §4 makes a coincidental `0xAA` look like a boundary, and a parser built that way
would be tuned to its own bugs.

---

## Sources

* **OpenStrap/research** — WHOOP 4.0 BLE protocol reference (`PROTOCOL.md`, 263 lines) plus a
  2,271-line reference client (`research_playground.py`, whose `sync` drains the historical flash and
  whose `build_batch_ack` is the ACK). Covers the 4.0 envelope, the type-24 record header, the
  `0x2F`/`0x31` types, the ACK/token loop, the full command enum and the session-init sequence.
  **Its evidence base is stronger than its README suggests, and the two disagree**: the README's
  summary says the record past the header is "fingerprinted but unconfirmed", while `PROTOCOL.md` §5
  documents it as validated by **per-byte variance analysis across 811 real records** (550 golden
  capture + 261 R2 spanning 113 h), cross-checked against two independent decoders — and it is that
  section which marks `[7:11]`, `[11:13]`, `[17]` and `[18]`/`[19:19+2n]` **verified**. Read
  `PROTOCOL.md`, not the README, when judging a field's confidence. Two of its rejections matter
  here: the `[76]` "respiration" and `[78]` "signal quality" fields are **bit-constant** across all
  811 records and are fixed trailer bytes, and the README is explicit that **everything was tested on
  a WHOOP 4.0 and nothing else**.
  <https://github.com/OpenStrap/research> · `PROTOCOL.md` §4–§5 are the load-bearing sections.
* **noop `docs/PROTOCOL.md`** — WHOOP 4.0 and 5.0 / MG envelope definitions with the CRC
  specifications, the `HISTORY_END` payload layout, the offload command set and the safe-trim
  ordering. Source of the 5.0 / MG envelope and the 35/36/47/48/49 type values.
  <https://gitcode.com/gh_mirrors/noop/noop/blob/main/docs/PROTOCOL.md>

Neither has been reproduced against this project's hardware. §6 is the list of what would replace
them.
