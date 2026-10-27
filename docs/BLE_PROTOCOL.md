# WHOOP 4.0 / 5.0 / 5.0 MG BLE Protocol Specification

Reverse-engineered Bluetooth Low Energy protocol for WHOOP hardware. Three straps are in scope and
**they do not share a wire format**: WHOOP 4.0 ("Harvard" / Gen 4), WHOOP 5.0, and WHOOP 5.0 MG
(Medical Grade). Which one a claim applies to is stated on every claim below.

## How to read this document

Most of this has not been captured on this project's own hardware, but **the 5.0 half has now been run, on one strap** — the bond, `SET_CLOCK`, live heart rate and R-R, `R21` motion and a full flash drain, with the results recorded where each claim is argued (§3's handshake, §4's drain, §5's producers). What that establishes is a 5.0 on one firmware; the 4.0 column is still spec-only, and no claim here should be generalised past the strap it was measured on. Every statement is tagged with where it came from, and the tags are not decoration — most of the disagreements recorded below exist because two sources were silently mixed.

| Tag | Meaning |
| :--- | :--- |
| **[captured]** | Observed on this project's own strap from a recorded session. **On one 5.0: the bond, `SET_CLOCK`, live heart rate and R-R, live `R21` motion, and a flash drain carrying `R18` records — §3, §4 and §5.** A *banked* `R21` record and both 4.0 halves remain uncaptured. |
| **[reported 4.0]** | Stated by the open-source WHOOP 4.0 reference. Not independently confirmed here. |
| **[reported 5.0]** | Stated by the open-source WHOOP 5.0 / MG reference. Not independently confirmed here. |
| **[filed]** | Stated in a regulatory, standards or equipment-approval filing by or about the hardware. Stronger than a reverse-engineering reference about **which sensors exist**, because the filing is made under a duty of accuracy and the sensor list is the filing's subject. It is still not a capture, and **a filing says nothing about the wire format** — no filing in hand describes a record layout, an opcode or a byte offset. |
| **[repo]** | What the code in `Data/BLE/` actually does today. A statement of fact about this codebase, not a claim about the strap. |
| **[assumed]** | How the hardware is taken to behave in the field, on the owner's own report of the straps in hand. **No capture has confirmed it, and where a reference states it, that reference has not measured it either** — it is the operating premise a design is written against, and §7 carries what would settle it. It is tagged rather than left unmarked because an untagged number here reads as measured, and because **a figure two projects repeat from each other is not two pieces of evidence** — the retention window below is exactly that case, and it is contradicted by the manufacturer's own guidance. |

Where a source marked a field low-confidence, that is carried across rather than smoothed over.
**Treat every byte offset as a lead until a capture confirms it.**

---

## 1. GATT Services & Characteristics

The strap advertises standard BLE services (`0x180D` Heart Rate, `0x180F` Battery, `0x180A` Device
Info), and they are reported to work **unbonded** — `0x2A37` HR Measurement is why a strap can be
read as an ordinary BLE heart-rate sensor with no proprietary handshake at all. The core data
exchange happens over a proprietary custom primary service, and the two generations use different
ones. **The bond gates the proprietary command characteristic, not the SIG services** — and it is a
reported requirement rather than a settled one, so §7 Q6 carries it as an open question. The
constraint the source records is that the 5.0/MG refuses writes and notifies on the proprietary
service with `CBATTError.insufficientAuthentication` / `.insufficientEncryption` until the link is
**encrypted** ("Authentication is insufficient", the community reference #17) — and the bond is established by
**just-works pairing**: the community reference writes the static `CLIENT_HELLO` to `fd4b0002` `.withResponse`, which is
what triggers the strap's just-works bond. **The community reference's source does not say macOS cannot complete that
bond** — the one Apple-platform limit it records is that CoreBluetooth exposes no link-encryption or
bond *state*, so a client cannot ask whether it is bonded. §7 Q6 carries the still-open part.

### The 4.0 base UUID is settled without a capture, and the ecosystem is what settled it

`61080001-8d6d-82b8-614a-1c8cb0f8dcc6`. **This document and `WhoopGATTConstants` now agree** — the
value is sourced rather than captured, because the ecosystem answers it: it is the base half in the
reference clients of half a dozen independent projects — the community reference's Swift, Kotlin and
Python clients, whose own `docs/BLE_REVERSE_ENGINEERING.md` maps the five characteristics, and the
research reference's 5.0 write-up, among them. One project dissents on the trailing service digit only, using `…0000`.

The half `…82A5-4E40-1CA360B95B30` is **unsourced**: it returns no hit in the community reference, in the research reference, or in a public code search across GitHub, and must not be used.
§1 of the suite pins these identifiers against the published literals — not against the constants
they test, which is the distinction that matters here — so the substitution cannot silently reverse.

**Why it was worth a section anyway.** A wrong service UUID does not present as a decode error — it
presents as **no device found**. The scan filters on a service the strap never advertises, so the
peripheral is never discovered, no frame is ever decoded, and nothing downstream of discovery can
distinguish it from a strap that is switched off. It is the first thing to check when a scan finds
nothing, and the cheapest defect in this file to fix.

The 5.0 / MG base is `fd4b0001-cce1-4033-93ce-002d5875f58a`, and the document and the code agree.

### Characteristic map

* **WHOOP 4.0** (`610800xx-…`) **[repo]**: `…0001` service · `…0002` command write (client → strap) ·
  `…0003` response read / indicate (strap → client) · `…0004` events notification (wear state,
  battery, tap) · `…0005` raw sensor data stream · `…0007` memfault diagnostics.
* **WHOOP 5.0 / MG** (`fd4b000x-…`) **[repo]**: same five roles at `…0001`…`…0005`.

`WhoopGATTConstants.scannableServiceUUIDs` **[repo]** carries the 4.0 service, the 5.0 service and
the standard `180D`, so all three straps are at least discoverable.

---

## 2. Packet Framing & Wire Format

**This is the largest single difference between the generations, and this codebase implements both
envelopes on both the read and the write side.** Which one it uses for a given strap is a stored
choice rather than a guess: the device screen
(`Presentation/Screens/Device/DeviceSettingsView.swift`) records the model per peripheral identifier,
and `WhoopProtocolProfile.profile(for:)` turns that into an envelope — or into `nil` for the standard
strap and the simulator, which every command writer refuses. The 5.0 and MG profiles *are* built, and
a frame arriving under either validates in `WhoopPacketDecoder` exactly as a 4.0 one does, and
`WhoopPacketEncoder5` builds one. Their write side is carried by `syncOpcodes` rather than the 4.0's
`commandOpcodes`, which is a shorter table because several of the 4.0's roles have no published 5.0
byte. §3's implementation status has the reasoning.

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
  fixed hello. **Its function is not a greeting — it is the bond trigger.** The community reference writes it
  to `fd4b0002` **`.withResponse`** deliberately, because the write itself is what starts the strap's
  just-works pairing, and the realtime stream can only be armed afterwards. Its failure is silent:
  an unanswered hello raises **no write error**, the link just drops. §7 Q6 carries what that means
  for a third-party client.

### What that means for a single decoder

Three consequences, and the third is the one that bites:

1. **The header CRC algorithm is generation-selected** — `.crc8` versus `.crc16Modbus`. `CRCUtils`
   **[repo]** implements both plus `crc32`, and **all three are correct** — see §2.1, where they were
   checked against published reference vectors. `WhoopProtocolProfile.headerChecksum` selects `crc16Modbus` for the two 5.0 profiles, and `WhoopPacketDecoder` takes one of two branches on that field. **The two branches are separate cases rather than one algorithm behind a boolean, and the
   difference is the input, not the polynomial**: CRC8 covers `[1, 2]` and CRC16-Modbus covers
   `[0 ..< 6]`, which reaches back over the start-of-frame byte and the format byte. A single
   function parameterised by "how many bytes" would have been right for both and would also have made
   the 4.0 case's input a number nobody could check against §2.1.
2. **The inner record origin moves from 4 to 8.** A decoder that reads `cmd` at a fixed offset is
   correct for exactly one generation. The length field moves with it — `[1..3]` under 4.0, `[2..4]`
   under 5.0, because 5.0 spends byte 1 on a format byte — and that pair is why
   `WhoopProtocolProfile` carries `lengthFieldOffset` and `headerChecksumOffset` rather than the
   decoder holding two sets of literals.
3. **The packet-type numbering is shared, and the apparent difference is an artefact of radix.** The
   two references write the same numbering in different bases — the 4.0 reference in hex, the 5.0
   reference in decimal — and every value below corresponds exactly:
   `0x23`=35 · `0x24`=36 · `0x30`=48 · `0x2F`=47 · `0x31`=49 · `0x2B`=43 · `0x33`=51 · `0x34`=52

   **Do not read "the values do not overlap" into this table**: it comes from the two columns
   looking different, and it is the exact failure the preamble warns about — two sources silently
   mixed. Eight exact correspondences across two independently written references is not
   coincidence, and the working assumption is that the **type numbering is shared and the envelope
   is the discriminator** — which is what points 1 and 2 above already require, since neither CRC
   nor record origin can be guessed from a type byte. §7 carries the capture that would settle the
   full enum rather than these eight roles.

### Packet types

Both columns are given in both bases, so the correspondence is checkable rather than asserted.

| Role | 4.0 **[reported 4.0]** | 5.0 / MG **[reported 5.0]** |
| :--- | :--- | :--- |
| Command / request | `0x23` / 35 (also `0x72`) | 35 / `0x23` |
| Response / ack | `0x24` / 36 (also `0x73`) | 36 / `0x24` |
| Asynchronous event / heartbeat | `0x30` / 48 | 48 / `0x30` |
| Historical data record | `0x2F` / 47 | 47 / `0x2F` |
| Metadata / sync markers | `0x31` / 49 | 49 / `0x31` |
| Realtime raw (HR + IMU) | `0x2B` / 43 | 43 / `0x2B` |
| Realtime data | — | 40 |
| IMU stream, live / historical | `0x33` / `0x34` (51 / 52) | 51 / 52 |
| Console logs | — | 50 |

Note for 4.0: **`0x30` is a packet type, not a command.** See §3.

**The historical-data row is one type with several record layouts, and §6 depends on it.** A 4.0
type-`0x2F` record is the 96-byte 1 Hz rollup. **The type carries a layout selector before any length
does**, and the byte is one this document already names: the inner `seq` — the byte §4's table calls
the 4.0 record's "record type" — is `inner[1]`, which is frame `5` under the 4.0 origin and frame `9`
under the 5.0 one. Version 24 *is* the 4.0 record §4 documents, so the two sources are one layout and
are checkable against each other rather than merely similar.

**Both vocabularies are published, and they name the same byte rather than describing two
mechanisms.** The 4.0-enveloped schema keys its `HISTORICAL_DATA` on versions `24` / `12` / `5` /
`7` / `9`; the 5.0/MG sensor reference names record layouts an `R` number — `R16`, `R17`, `R18`,
`R20`, `R21`, `R26`. The community reference is explicit that the type alone identifies nothing — "R16 and R17
ECG use a layout selector at byte 9" — and that **packet number, record layout, command number and
event number are separate namespaces**. The correction worth carrying is that the `24` / `12` / `5`
/ `7` / `9` vocabulary belongs to a schema whose **envelope is the 4.0's** (`SOF` at 0, two-byte
`length` at 1, `crc8` at 3, `packet_type` at 4, `seq` at 5), so it is not "the 5.0 reference's", and
reading it as a 5.0 version set beside 5.0 records mixes two sources — the exact failure the
preamble warns about.

**The record lengths follow from the layout byte rather than forming a second, independent key.** A
5.0/MG type-47 record is fixed-length per layout — `R18` at 124 B, `R21` at 1,244 B, `R20` at
2,140 B. Those are **frame** lengths: the envelope takes 15 bytes (8 header + 3 prefix + 4 CRC32
trailer), so the payloads a decoder actually holds are 109, 1,229 and 2,125 — and all three lengths
are confirmed by two sources that agree with each other (§6, §7 Q4). The one
**length**-keyed discriminator either reference publishes is on a different type:
`REALTIME_RAW_DATA` (`0x2B` / 43) is selected at **1917 B** (6-axis IMU) and **1921 B** (optical)
under the 4.0's naming. A decoder that treats length as the primary key on type 47 therefore has the
relationship backwards and will read an `R20` optical record as an IMU buffer.

### 2.1 The checksum vectors **[repo, verified]**

Both references publish concrete frames, which makes the repo's CRC utilities checkable **today,
with no strap**. All three are correct, and all four are asserted in §1 of the suite rather than merely in a table here:

| Vector | Source | Expected | `CRCUtils` | |
| :--- | :--- | :--- | :--- | :--- |
| `crc8([0x08, 0x00])` | the research reference's `PROTOCOL.md` §2 | `0xA8` | `0xA8` | ✅ |
| `crc8([0x10, 0x00])` | the research reference's `PROTOCOL.md` §2 | `0x57` | `0x57` | ✅ |
| `crc16Modbus(5.0 hello[0..<6])` | the community reference's `PROTOCOL.md` §2.2 | `0x71E6` | `0x71E6` | ✅ |
| `crc32(5.0 hello payload)` | the community reference's `PROTOCOL.md` §2.2 | `0x8D5C3E36` | `0x8D5C3E36` | ✅ |
| `crc16Modbus(toggle hdr[0..<6])` | the APK reading's `whoop-ble-protocol.md` | `0x41E7` | `0x41E7` | ✅ |
| `crc32(toggle payload)` | the APK reading's `whoop-ble-protocol.md` | `0xFC61E958` | `0xFC61E958` | ✅ |

The 5.0 vector is the whole static `CLIENT_HELLO` frame, so it validates the envelope reading too:

```
AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D
│  │  └─ declLength u16 LE = 8      │  └─ crc32 LE = 0x8D5C3E36
│  │     (payload = declLength − 4) └─ payload [8..<12]
│  └─ format 0x01                         type=35 seq=1 cmd=0x91
└─ SOF                              crc16 LE = 0x71E6 over [0..<6]
```

**A second 5.0 frame is in hand, and it is the more useful of the two** because it is a *command*
rather than a handshake — the only published frame here that carries an opcode, and therefore the
only worked example of the 5.0 command payload layout `[type][seq][cmd][params…]`:

```
AA 01 0C 00 00 01 E7 41 23 F1 6A 01 01 00 00 00 58 E9 61 FC
│  │  └─ declLength u16 LE = 12           └─ crc32 LE = 0xFC61E958
│  └─ format 0x01                            type=35 seq=0xF1 cmd=0x6A
└─ SOF                                        params = 01 01 00 00 00
   crc16 LE = 0x41E7 over [0..<6]
```

`0x6A` is **106** — `TOGGLE_IMU_MODE`, §6's producer-3 enable opcode — and its params open `[1,1]`,
the same pair §6's enable sequence records. **This is the 5.0's form and not the 4.0's**: the frame
below is a 5.0 envelope, the pair is the first two bytes of its five-byte selector, and the 4.0 sends
this opcode **one byte** (§3's `0x6A` row) — so the two generations share the opcode and not the
payload, which is the kind of agreement that reads as evidence for the wrong thing. Two sources
agreeing on the opcode, the leading payload
bytes and the frame arithmetic is worth more than either alone: this frame was built from the
decompiled APK and matched against a PacketLogger capture byte-for-byte, and both of its checksums
check out against this document's own utilities. It does **not** settle the record-layout question
(§4, §7 Q3), because a command frame carries no historical record.

It does more than tabulate the hello, too: §1 of the suite pushes those sixteen bytes through
`WhoopPacketDecoder` under both 5.0 profiles and pins every field above as a literal — `type` 35,
`seq` 1, `cmd` 0x91, the one-byte payload — so the 5.0 envelope is asserted against a reference's
bytes rather than against this app's own arithmetic. That is deliberate and is the same rule the
paragraph below states: a frame the repo's own encoder built would round-trip through a decoder
sharing its mistake. The same rule now covers the write side: §1 of the suite asserts that
`WhoopPacketEncoder5.buildPacket` reproduces §2.1's published command frame **byte-for-byte**,
checksums included, and that the decoder reads those bytes back as the fields the builder was asked
for. Both halves are therefore pinned to a third party's bytes rather than to each other.

**The 4.0 format specifies CRC8 over the two length bytes only** (`raw[3] == crc8(raw[1:3])`), so
`buildPacket` feeds it `Data([lengthLow, lengthHigh])`: ping declares length **7** and writes
`0x6B`, the haptic alarm declares length **9** and writes `0xBD`. Both are the length bytes' own
checksum and not the command's, which is the whole of the rule. **Prepending `cmd` to that input
produces a header checksum the format does not agree with**, on every command frame the app sends.

`0xA8` — the first published vector — is the checksum of declared length **8**, which neither frame
declares. That is worth keeping in view: the two published vectors pin the polynomial, the byte order
and the *input rule*, but neither one is a frame this app sends, so a builder that fed the algorithm
the right two bytes of the wrong length would still agree with both.

**How it survived is worth keeping, because the shape recurs.** The suite did exercise all three
CRCs, but its assertions were `crc8Val >= 0` — a comparison a `UInt8` can never fail — and `!= 0` for
the other two, which proves only that they are not identically zero; the frame-layout assertion
beside them (`packet[1] == 0x10`) checked the encoder's output against the encoder's own constant. A
wrong polynomial, a wrong byte order and a wrong *input* all passed. They are replaced by the four
vectors above plus layout assertions derived from the format rather than from the encoder, and the
lesson generalises: **an assertion whose expected value is computed by the code under test is not an
assertion.**

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

**There are now two transmitted opcode tables, one per envelope, and between them they are the whole
of what this build may put on a wire.** They are separate Swift types — `CommandOpcodes` for the 4.0
and `SyncOpcodes` for the 5.0/MG — because the two generations share some numbers and not others, and
a single table would invite a reader to assume the sharing is total. §16 sweeps every field of both
for a forbidden byte, so a byte absent from the tables is a byte the sweep cannot see.

The 4.0's fourteen:

| Opcode | Field | Builder | Purpose |
| :--- | :--- | :--- | :--- |
| `0x05` | `liveTelemetry` | `enableLiveTelemetry` | enable/disable live telemetry |
| `0x10` | `hapticAlarm` | `hapticAlarmCommand` | haptic alarm |
| `0x4F` / 79 | `runHapticsPattern` | `WhoopPacketEncoder.runHapticsPattern` | play a catalog pattern `loops` times — body `[pattern, loops, 0, 0, 0]`; **not the 5.0's byte**, see below |
| `0x20` | `ping` | `pingCommand` | ping / keep-alive |
| `0x16` | `requestHistoricalSync` | `WhoopCommandFrames.historicalSyncRequest` | the drain's request — **`0x16`; see §4** |
| `0x6A` | `toggleIMUMode` | `motionEnableSequence` | IMU on/off — **one byte on the 4.0**, `[01]` to enable and `[00]` to stop. The two-byte form is real but belongs to the optical and persistent toggles; the research reference's `TWO_BYTE_TOGGLES` names those four opcodes and excludes this one, and the community reference's 4.0 branch sends `[0x01]` while giving its 5/MG the two-byte selector. §6's `[1,1]` is the *5/MG's* shorthand — do not carry it back to the 4.0 |
| `0x3F` | `sendRealtimeMotion` | `motionEnableSequence` | start the live 100 Hz motion record — body `[01]`, from the community reference's implemented `sendR10R11Realtime` (hardware-verified) and the research reference's `cmd_send_r10_r11` |
| `0x6B` | `enableOpticalData` | `motionEnableSequence` | body `[01, 01]` — the research reference's running client reads it as wrist-gated optical (the HR source) and this app followed that; the community reference's 4.0 *doc* says it *returns* the stored IMU stream state, while the community reference's own enum uses `enableOpticalData` and never sends it. See the naming note below |
| `0x0A` | `setClock` | `setClockFrames` | SET_CLOCK, both firmware lengths |
| `0x0B` | `getClock` | `clockReadBack` | GET_CLOCK — the read-back; **sent on both generations**, and the reply is logged rather than parsed |
| `0x14` | `abortHistoricalTransmits` | `abortHistoricalTransmits` | stop a drain |
| `0x21` | `setReadPointer` | — | move the flash cursor |
| `0x22` | `getDataRange` | — | the range canary |
| `0x17` | `historicalDataResult` | `historicalDataAck` | the per-batch ACK |

**106 and 107 are where the two references disagree — and the community reference disagrees with itself about 107.** The
two columns of the community reference's command matrix give these bytes different names from the research reference's table, and for
107 the difference is not a label but what the byte is *for*. **The community reference's own implemented enum is a third
column, and it takes the research reference's side of the name**:

| ID | the research reference **[reported 4.0]** | the community reference's command doc **[S · 41.17.6.0]** | the community reference's implemented enum |
| :--- | :--- | :--- | :--- |
| 106 / `0x6A` | `TOGGLE_IMU_MODE` ("live IMU"), body `[01]` | `SET_IMU_DATA_STREAM`, body `[01, state]`, state `0`/`1` — **"Sets the stored IMU data-stream state"** | `toggleIMUMode = 106`, sent as `[0x01]` on a 4.0 and `[0x01, 0x01]` on a 5/MG — **the doc row's two-byte form is the 5/MG's, and the community reference's own code is what says so** |
| 107 / `0x6B` | `ENABLE_OPTICAL_DATA` — "wrist-gated optical (**the HR source**)", body `[01, 01]` | `GET_IMU_DATA_STREAM`, body `[01]` — **"Returns the stored IMU data-stream state"** | `enableOpticalData = 107`, **never sent by any call site** |

**The width question on 106 is settled too, and by the same client that frames the optical opcodes.**
The research reference defines `TWO_BYTE_TOGGLES` — "opcodes that take the special TWO-byte
`[REVISION_1=0x01, enable]` payload", with the failure it prevents spelled out: *"Sending a single
`[0x01]` is read as `[revision, <missing enable>]` → no data flows."* Its members are
`ENABLE_OPTICAL_DATA`, `TOGGLE_OPTICAL_MODE` and the two persistent toggles, and **`0x6A` is not among
them** — every call site builds `bytes([0x01 if on else 0x00])`. The community reference's 4.0 branch agrees, sending
`[0x01]` where its 5/MG gets `[0x01, 0x01]` under a comment that calls the two-byte form *"the two-byte
realtime IMU selector"*. So the community reference's doc row is the only voice claiming a two-byte 4.0, and the community reference's own
code is against it: **the two-byte `[1, 1]` this app sent on a 4.0 was the 5/MG's payload**, and the
4.0 now sends `[01]`.

**The read reading is the command doc's alone, and the code beside it contradicts it.**
`Strand/BLE/Commands.swift` names 107 `enableOpticalData` — the research reference's name, and this app's — and
no call site in that client sends it: the community reference's live-IMU path is `startRawData` plus 106 and nothing
more. So the community reference's `GET_IMU_DATA_STREAM` is a 4.0-column refinement its own enum does not carry, and
the research reference's reading is not outvoted. What the community reference's doc does establish, and this app follows, is that
**107 carries a body on a 4.0**, so a bare 107 is not a frame this app may send. Its 107 row carries
the warning *"The WHOOP 5/MG identifier `ENABLE_OPTICAL_DATA` does not describe this WHOOP 4
operation"*, and its transport profile treats live HR as the standard GATT service and keeps it
"separate".

**Both readings are served by the same byte**, so nothing waits on the resolution.
`[01, 01]` is the research reference's enable form, so an enable starts the optical path live HR depends on; under
the community reference's reading it is a `[01]` read with a trailing byte, which starts nothing and is harmless either
way. **§7 Q12** carries the capture that separates them — write `0x6B` with `[01, 01]` and read the
reply — and the question it settles is what 107 *does*, not what to send. **The research reference's section is
emphatic about its reading** ("Live HR is optical/PPG-derived — no optical, no HR") and builds its live
example on it, which is why the enable is the interpretation this app acts on. **The 5/MG's own 107 is not the live-optical enable its name
suggests either**: the community reference's configuration contract records that on 50.42.1.0 the operation is **optical
session saving**, that "the identifier is historical", and that live optical output is **108** — so
`ENABLE_OPTICAL_DATA` is a legacy label on both columns and not a description of the current
operation on either.

The 5.0/MG's fourteen, under their own envelope. **Seven carry the 4.0's numbering unchanged — both
clock bytes among them — `0x6A` is the same byte with a different body, and six are the 5.0's own**
— which is the whole reason the table is a separate type:

| Opcode | Field | Builder | Purpose |
| :--- | :--- | :--- | :--- |
| `0x91` / 145 | `hello` | `WhoopPacketEncoder5.hello` | §2.1's published 16-byte frame |
| `0x16` / 22 | `requestHistoricalSync` | `historicalSyncRequest` | the drain's request — **shared numbering with the 4.0** |
| `0x17` / 23 | `historicalDataResult` | `historicalDataAck` | the per-batch ACK — **shared numbering** |
| `0x22` / 34 | `getDataRange` | `getDataRange` | the range canary — shared numbering |
| `0x14` / 20 | `abortHistoricalTransmits` | `abortHistoricalTransmits` | the drain's stop — **shared numbering** |
| `0x21` / 33 | `setReadPointer` | — | move the flash cursor — shared numbering |
| `0x03` / 3 | `toggleRealtimeHR` | `realtimeHeartRate` | arm the live packet-40 stream — **the 5.0/MG's only live heart-rate producer**, body `[01]`, enable-only (§4) |
| `0x51` / 81 | `startRawData` | `motionEnableSequence` | start the raw-data producer |
| `0x52` / 82 | `stopRawData` | `motionEnableSequence` | stop it |
| `0x69` / 105 | `toggleIMUModeHistorical` | — | the IMU toggle, historical form |
| `0x6A` / 106 | `toggleIMUModeLive` | `motionEnableSequence` | the IMU toggle, live form — §2.1's published frame |
| `0x0A` / 10 | `setClock` | `setClock` | SET_CLOCK — **the 4.0 opcode under this envelope**, and mandatory before history: an un-clocked 5.0 does not bank sensor data, so offloads complete with zero records |
| `0x0B` / 11 | `getClock` | `getClock` | GET_CLOCK — the read-back, same number as the 4.0's |
| `0x13` / 19 | `notifyHaptics` | `WhoopPacketEncoder5.hapticsNotification` | the buzz, a **remap of catalog pattern 79** rather than 79 itself: an MG capture answers 79 with result `0x03`. Body is the 12-byte notification preset `[01] + [2F 98 00×6] + [00 00] + [loops − 1]` |

**Every published 5.0 byte belongs in the table, and two of the five shared-numbering rows — `0x14`
and `0x21` — are marked supported by the community reference under the same names the 4.0 uses.** The community reference's catalog
enumerates every ID from 1 to 159 once and bounds its 5/MG column to firmware 50.42.1.0. **Omitting a published opcode is its own error rather than a safe default** — it leaves the
drain's only stop with no byte to send, and a builder reaching for one sends `0x52 STOP_RAW_DATA`
instead, which stops the producer and leaves the drain walking. A name is not an opcode this build
may send; but a *published* opcode left out of the table is a byte nothing can assert about. The two
generations' remaining differences are real and are not this kind:
`liveTelemetry`/`hapticAlarm`/`ping`/`sendRealtimeMotion` are 4.0-only under those names, and the
raw-data pair (`0x51`/`0x52`) is the 5.0's way of doing what `0x3F` and the telemetry verb do there
— which is coverage under other names rather than a gap. **106 and 107 are not that kind of
difference**: both generations have both, under names that disagree, which is the naming note above
rather than a missing opcode.

**`None of this sequence is implemented`** still holds for §3's eight **4.0** steps: there is no
`GET_HELLO_HARVARD` exchange, no feature-flag negotiation, and the clock synchronization and ACK loop
exist as builders and a session rather than as a completed handshake. What *is* built is the 5.0/MG's
own starting move — `WhoopPacketEncoder5.hello`, written as a confirmed command and waited on before
any proprietary subscription or producer is armed (a command characteristic with no `.write` property
has no confirmation to wait for, and that fallback arms them anyway) — plus the connect pass it gates
(`WhoopBLEManager.sendConnectCommands()`: the motion enable on both generations and the `0x03`
live-HR arm on a 5.0/MG), and the drain — §4 carries its status.

**On a 5.0/MG the connect pass now starts with the clock, on the premise that that generation banks
nothing until it is set — a premise the 5.0 capture could not confirm, because its archive did not
grow even after the clock latched.** `sendConnectCommands()` sends `0x0A SET_CLOCK` with the phone's epoch before the motion
and live-HR arms, then `0x0B GET_CLOCK` so a capture sees both sides of the exchange; the drain sends
the same pair before its `0x16` request. **The read-back's reply is logged and not decoded** — neither
reference parses it — so this app still does not claim a clock latched. **The Device Information
Service (`0x180A`) is read on both generations once the link is bonded**, filling
`WhoopDevice.firmwareVersion` from `2A26` and `serialNumber` from `2A25`. **`2A24` now resolves the
strap's generation** — `WhoopHardwareGeneration.from(modelNumber:)`, `MG` tested before the digits —
because it is the one rung that separates a 5.0 from a 5.0 MG, which the service list cannot; when the
user has never chosen a model it is also persisted, so a launch does not start from the advertised
name. Hardware revision and manufacturer are logged and have no field.

**The advertised name is a proprietary command, which is why it looks unreachable.** CoreBluetooth
hides the Generic Access service from every third-party app, so GAP's `0x2A00` cannot be read or
written here — and a strap named *"Alex WHOOP"* was named through the WHOOP app's own opcode, not
through GAP. [reported] The community reference's command matrix documents both generations: **5.0/MG uses ID 140
(`SET`) and 141 (`GET`)**, the set body `[revision=1][length][name…]` with 0–15 name bytes and the get
reply a fixed 19 bytes (`[revision][source][length][16-byte field]`, source `1` custom / `2` fallback);
**4.0 uses ID 77 (`SET`) and 76 (`GET`)**, the set body two reserved bytes then a fixed 16-byte field
whose last byte must be NUL — 15 usable bytes — and both are version-bounded to firmware 41.17.6.0.
**The 5.0 table marks the 4.0 ids unsupported (result 3)**, which is why the generation picks the
number. **[captured] 2026-10-25: ID 140 works on this project's 5.0, firmware 50.42.1.0** — a rename sent
from the device page's `NAME` row was applied, and **the advertisement lagged the write by a few
minutes**, exactly as the community reference warns. So the write is real but the acknowledgement proves nothing
and a scan taken immediately afterwards reads `CoreBluetooth`'s cache rather than the radio. **`141`'s reply was captured too, on 2026-10-25:**

```
cmd=0x8D payload=14 01 01 01 0C 57 68 6F 6F 70 73 79 20 35 2E 30 00 …
```

— a leading **length byte `0x14` (20)**, then revision `1`, **the operation's result `1`**, source
`1` (custom), name length `0x0C` (12, NUL included), then `Whoopsy 5.0` and the rest of the 16-byte
field. So the community reference's fixed-19-byte read names the right fields and omits two bytes this envelope
carries: the payload-length prefix in front and the result byte after the revision. `Advertising Name
Payload.decode` tolerates the first and requires the second. The strap had by then stored the name this app
sent, which is how the rename was proven end to end rather than inferred from an advertisement.

**[captured] 2026-10-25, this project's own strap, read from a Mac as a second central** (`bleak`,
read-only — a drain driven from it would advance the strap's trim cursor and rob the app):
`180A` answers `WHOOP Inc.` / `5.0` / `5AG…` / `50.42.1.0` / `WG50_r52`, battery `0x2A19` reads 49%,
and the proprietary surface is **`FD4B0001` with `FD4B0002` write-capable and `FD4B0003`/`4`/`5`/`7`
notify-only** — the four roles this document assigns them, confirmed by an independent central rather
than by this app's own decoder. The strap advertises as `Alex WHOOP`, a name with no digit in it,
which is why the advertised-name heuristic resolved a 5.0 as a 4.0 before discovery. **Events are decoded on both generations** —
`StrapEventDecoder` reads the number from the inner `cmd` and the unix stamp at payload `1`, maps
`CHARGING_ON`/`OFF` and `WRIST_ON`/`OFF` onto `isCharging`/`isOnBody`, and logs the rest, battery
level included, because that event's payload layout is not published.

**That callback is also how the implemented half is re-sent, and state restoration is why it matters.**
A peripheral restored already connected never fires `didConnect`, so `willRestoreState` seeds the
device state and calls `discoverServices(nil)` itself; re-discovery re-runs
`didDiscoverCharacteristicsFor`, which re-sends the connect pass — the 5.0/MG's hello first, then,
on its acknowledgement, the motion enable plus the generation's other producer: the `0x05` telemetry
enable on a 4.0 or the `0x03` live-HR arm on a 5.0/MG.
**Inheriting the previous process's subscription is not a substitute**: a subscription can report
`isNotifying == true` while delivering nothing to the new process, which is the failure the community reference reports
as #613 — so the subscription is re-issued rather than trusted.

**The implemented half is also re-sent on silence, and the threshold belongs to the generation.**
`didDiscoverCharacteristicsFor` runs once per connection, so a strap whose producers were disarmed
without the link dropping would keep a subscription that delivers nothing and never ask again. A 30 s
`KeepAlivePolicy` tick therefore watches *data* — any non-empty notification, and any successful
write — and after **15 s** of silence on a 4.0 re-sends its connect pass (the `0x05` telemetry
enable and the three-frame motion enable). That figure is the Swift 4.0 client's `WhoopBleDataWatchdog.swift`. The
5.0/MG gets **60 s** — the same pass, which on that generation is the two motion frames and the
`0x03` arm — because its resting heart rate has documented at-rest lulls (the community reference #580/#1414,
the research reference's shipped client #191) and a 15 s rule would re-arm a working producer on every quiet minute. Two guards sit around it: the re-send has its own 60 s floor, so noticing is
not the same as poking, and it is withheld unless the bond handshake was itself acknowledged
(`hasSentConnectCommands`), because a 5.0/MG refuses writes made before it. **Past 120 s (4.0) or
600 s (5.0/MG) of total silence the link is not healthy and is bounced** with
`cancelPeripheralConnection`, whose `didDisconnectPeripheral` treats it as involuntary and answers
with the standing connect — so discovery re-runs and the enable sequence is sent again. A drain
suppresses both the re-send and the bounce; a battery read (`0x2A19`, floored at 60 s) stays safe
throughout and doubles as the probe.

**A 5.0/MG that refuses five consecutive fast connection attempts is left alone.** The community reference #747 is the
report the cap comes from, and the handshake being refused is the encrypted bond the strap demands
before its proprietary service answers (§7 Q6). Only a *fast* refusal counts — a `didFailToConnect` inside two seconds of the attempt — and
any drop, slow failure or failure with no previous attempt resets the count, so a strap that dropped
out of range and came back is never mistaken for one refusing its bond. The cap is 5.0/MG-only: a
4.0's refusal is more likely range, which a standing connect is supposed to wait out. When it is
reached no further attempt is made automatically, and the device page's `ADVANCED` tab already
carries the caveat that explains it.

**The 4.0's live enable is three ordered frames** (`0x6A` `[01]`, then `0x3F` `[01]`, then `0x6B`
`[01,01]`), all or nothing. **All three carry a body**, and the references' own running clients are
the basis: the community reference sends `[0x01]` for the realtime record (documented on-device, "2.1/s → 0/s"), and
the research reference sends a two-byte `[revision, enable]` for the optical one. A bodyless `0x3F` is the shape
that matters most, because it starts no live record — which is the stream the step counter reads.
**`0x6A` carries one byte rather than the two-byte form**: it is an IMU verb, and the two-byte
`[revision, enable]` convention belongs to the optical and persistent toggles (see §3's note). The
5.0's motion enable is two (`0x51` then `0x6A`), and **that ordering is the community reference's rather than
this app's** — the community reference's configuration contract states that the live-IMU sequence "starts raw production
before enabling live IMU transport", with stopping production and disabling that transport as
separate cleanup operations. **A 5.0/MG also sends `0x03 TOGGLE_REALTIME_HR` in the same connect
pass**, as a third, independent enable: it starts no motion stream and its notification is packet 40,
so it is the generation's live heart rate rather than a fourth motion frame (§4, §5). The one open
half left in the 4.0's three is what `0x6B` *does*, which is the naming note above and §7 Q12.

**Every one of those frames is written in the §2 envelope**: the header CRC8 is over the two length
bytes, `length` is the inner record plus four, and the inner record is `[type][seq][cmd][payload…]`
with the CRC32 over the whole record. Nothing has been captured on hardware, so this says the frames
match both references — not that a strap accepts them. Three properties are enforced in code rather
than described here: the decoder verifies the header and payload checksums on inbound frames and
refuses anything that fails (§2), the generation decides which envelope is used at all, and
**`buildPacket` tests the envelope alone**, since the opcode table is read by the *builders*. Each
4.0 builder applies `fourEnvelopeOpcodes`, which asserts both the table and the envelope, so a
builder cannot assemble a 4.0-framed command under a 5.0 header.

**Reading a generation and writing to it are separate capabilities, and the fields that carry the
distinction are the two opcode tables.** `WhoopProtocolProfile` holds `commandOpcodes:
CommandOpcodes?` and `syncOpcodes: SyncOpcodes?`; the 4.0 populates the first and the 5.0/MG the
second, and `canTransmitCommands` is `commandOpcodes != nil || syncOpcodes != nil`. It is what every
builder and `WhoopBLEManager.sendCommand` consults, and it is deliberately **not** the envelope:
this app **validates inbound 5.0 frames** (§2), so a guard on the envelope would permit 5.0 writes
because inbound 5.0 frames are readable — right about nothing and wrong about why.

**The two tables exist because the sharing is partial rather than total.** The 4.0 and the 5.0/MG
share `0x16`, `0x17`, `0x22`, `0x14` and `0x21`; the rest of each is its own. A single table would
have implied the sharing was total, and a builder reaching for the wrong one would produce a frame
that is not rejected but is a *different command*.

**`WhoopProtocolCatalog.supportsProprietarySync` asks the same question** —
`profile(for:)?.canTransmitCommands == true` — because a drain is a loop of writes and needs opcodes
regardless of whether the envelope can be read. It now answers `true` for `.whoop4`, `.whoop5` and
`.whoop5MG`, and `false` for `.standardBleHR` and `.simulator`.

**What that does *not* establish is that a 5.0 will answer**, and the device screen says so in as many
words rather than in one generic sentence, because the two generations have different open questions
rather than the same one twice. The 4.0's is unvalidatedness alone. The 5.0's has a second and more
specific blocker: its command characteristic refuses writes and notifies until the link is
**encrypted** (`CBATTError.insufficientAuthentication` / `.insufficientEncryption`), and the bond is
established by **just-works pairing** — the community reference writes the static `CLIENT_HELLO` `.withResponse`, which
triggers it, and ships that path on macOS **and** iOS. The one Apple-platform limit it records is
that CoreBluetooth exposes no bond state, so a client cannot ask whether it is bonded; the one
reported iOS success outside the community reference (the APK reading) reuses the bond the official WHOOP app already made. `DeviceViewModel.protocolCaveat` carries both sentences;
§7 Q6 carries the whole of the open question, and **it stays open rather than softened into a
permission**. Reading a 5.0 and writing to one became the same shape of capability in this build; what
has never happened is either of them against a strap.

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
| `[52:64]` | a **second accelerometer/gravity triplet in g**, byte-identical to `[36:48]` on the frame in hand — not a gyroscope; see below | reported |
| `[88]` | u8 resting / baseline HR | empirical |

Sensor ADCs: raw green PPG `[29]`, red/IR `[31]`, red `[64]`, IR `[66]`, skin temp `[68]`, ambient
`[70]`.

**A second, independent parser now corroborates this table at a measured scale, and adds the one
number a decoder needs that the table did not carry.** The research reference's `parse_r24` reads the same fields
at the same offsets — counter at `[3:7]`, `unix` at `[7:11]`, sub-seconds at `[11:13]`, heart rate
at `[17]`, `rr_count` at `[18]`, then the R-R intervals as **i16 LE milliseconds** from `[19]`, and
the accelerometer triplet at `[36:48]` — and reports that the layout is "verified on **127,971 of
our own stored records** and cross-checked against an independent implementation", with the heart
rate confirmed to match the live stream **within one beat**. It also states a **minimum inner length
of 89 bytes**, which is the guard this table lacked: a record shorter than that cannot hold the
fields below `[88]`, so a walk should refuse it rather than read past its end. Two smaller facts
from the same parser are worth carrying because both bound a decode: **`rr_count` is `0`–`4`**, so
the R-R loop is bounded and does not need to be driven by the record's length, and **the strap's
`[51]` is a contact *quality* (`0`–`198`) and not a wear flag** — the natural misreading of that
field is the one the research reference calls out. Two things this does *not* change: the confidence tags
above are the research reference's own and are left as they were, because a second parser agreeing is
corroboration rather than a new source; and **none of it is a capture on this project's hardware**.
The record walk is therefore a design against a layout a running client has decoded a hundred
thousand times, rather than against a table. The R-R intervals are the field worth noting for this
app in particular: they are what `biometric_samples.rrIntervalsMs` holds, and on the owner's 5.0 they
have now been stored by both producers — live on `0x2A37`, and from a drained `R18` record — so a
real HRV, respiratory rate and within-sleep stress figure has data behind it for the first time.

**The `[52:64]` "mirror" is resolved, and it is not a gyroscope.** The 4.0 reference reports those
twelve bytes as byte-identical to `[36:48]`, with the parenthetical "(not an extra sensor)", validated
by per-byte variance analysis across 811 records. The 5.0 reference names the field: it is
`gravity2_x` / `gravity2_y` / `gravity2_z`, documented as a **second accelerometer/gravity triplet in
g**, and on a real captured 4.0 frame it holds `(0.05, 0.1, 0.994)` — byte-identical to `[36:48]`, and
a plausible gravity vector at rest. So both sources are right and neither needed the other's
correction: it is a real named field that happened to carry duplicate values in the records examined.
**A gyroscope cannot be what it is** — a gyroscope at rest reads ≈0 dps on all three axes where this
reads ≈1 g on one — and the 4.0's gyroscope turns out not to be hiding here at all: it is in the live
raw stream, at documented offsets with a calibrated scale (§6). So the field is a duplicate triplet
and should be documented as such, and the capture that was going to settle it is not needed.

**This is the finding that changes the feasibility question.** The historical record carries an
absolute unix time at `[7:11]` — so a drained night can be placed on a timeline, and a
heart-rate-over-the-night curve is constructible from stored history, not only from live capture.

**The field exists; whether its value is *right* is a separate question, and this is the trap.** An
absolute time is only as good as the clock that stamped it. The strap's RTC is set by
`0x0A SET_CLOCK` (`[u32 epoch LE][u32 0]`), and the community reference's event enum carries **type 13
`RTC_LOST` — "battery fully died (clock reset)"** (plus event 16 `SET_RTC`). So a strap that has been
flat for long enough comes back with a clock that is wrong by an unknown offset, and **every
timestamp it then stamps is wrong by that same offset with nothing in the record to show it**. This
app sends `0x0A` at the start of every drain on both generations (§3), so the repair is issued — but
**the strap's reply is logged and not decoded**, so a clock that refused to latch is not detected
here. Two consequences are worth carrying into the capture: draining a battery-flat strap and
trusting `[7:11]` before a set has latched would file history under a wrong day rather than under
no day, which is the failure the day-key rule exists to prevent; and the detection is *indirect*,
via event 13 (which is only seen if the app is listening at the moment the RTC is lost) or by
comparing a freshly drained record's `[7:11]` against wall time. Treat a drained record's absolute
time as **verified as a field, unverified as a value** until that comparison is made.

**Correcting the clock is a prerequisite for the drain, not a refinement of it, and the reason is
that `SET_CLOCK`'s payload LENGTH is firmware-specific and load-bearing.** The community reference ships **two** 4.0
forms rather than one, and its source states why in as many words:

| Form | Payload | Latches on |
| :--- | :--- | :--- |
| Current, 8-byte | `[seconds u32 LE][subseconds u32 LE]`, subseconds in 1/32768 s (0 is fine) | newer WHOOP 4 firmware; the 5.0/MG's hardware-validated form |
| Legacy, 9-byte | `[seconds u32 LE][5 × 0]` | WHOOP 4 fw 41.17.x, which **ignores the 8-byte form outright** — no `COMMAND_RESPONSE`, RTC unchanged |

The failure mode is what makes this worth a section of its own: **a set that is the wrong length for
the firmware is acknowledged but not latched**, so the RTC stays invalid — and a strap with an
invalid RTC **stops banking sensor data to flash entirely**. The community reference records the symptom as "endless
console-only syncs and no sleep/recovery", which is a strap that looks connected and productive while
silently writing nothing. Its client therefore sends **both** forms on 4.0, because each is a no-op on
the other's firmware and both carry the same `now`, so double-latching is harmless.

Two things follow for this document. **The length is not settled across the ecosystem** — forms of 4,
5, 8 and 9 bytes all appear in published clients, and four independent projects corroborate the
silent-failure mode, which is why the community reference's belt-and-braces approach is the shape to copy rather than
picking one. That is what this app does: **`setClockFrames` sends both forms on every generation** — two for the
4.0 at its drain, and since the link was first run two for the 5.0/MG under its own envelope at command 10.
**That second length was measured rather than chosen**: on the owner's 5.0 the 8-byte
`[u32 epoch LE][u32 0]` was written `.withResponse`, acknowledged by the strap, and left the RTC at
**`2000-01-03 20:25`**; adding the **9-byte legacy form** (`[u32 epoch][5 × 0]`) moved it to a
**0.0 h** drift. The readout was the motion record's own clock field (`R21`'s unix seconds at frame
15), not `GET_CLOCK` — that reply is undocumented, was answered once and then not again, and its
first four bytes decode to a number that is not the RTC. So **a set that is sent is not a set that
latched** still holds, and the way to see the difference without a drain is the record's own stamp.
§7 Q7 keeps the per-firmware question; this strap's answer is 9 bytes.

**[reported 5.0]** The 5.0 / MG record is the **same type** — `0x2F`, 47 — with a layout selector at
`inner[1]` choosing a schema that inherits from a base layout via a `ref` chain (V12 → V24, …), and
that byte is what the 4.0 table above calls the record's "record type" and which reads `24` on a real
captured 4.0 frame. Its decoded keys are `hist_version`, schema-versioned biometric fields and
`rr_intervals`.

**Which source is which.** The `hist_version` /
`ref`-chain schema is published in a machine-readable file whose **envelope is the 4.0's** — `SOF` at
0, two-byte `length` at 1, `crc8` at 3, `packet_type` at 4, `seq` at 5 — so its `24` / `12` / `5` /
`7` / `9` vocabulary is a **4.0-enveloped** version set, not a 5.0 one. The 5.0/MG source proper is
`PROTOCOL_SENSORS.md`, which names record layouts `R16` / `R17` / `R18` / `R20` / `R21` / `R26` and
gives each a fixed byte length. Both describe the same selector byte under different names, and §2
carries the reconciliation.

**It does carry a per-record timestamp, and it is this section's field.** The schema places `unix` as
a u32 at frame offset **11**, described as real unix seconds; its offsets are frame-absolute from the
start-of-frame byte, so 11 is record-relative `7` — exactly this section's `[7:11]` — and frame 15
under the 5.0 origin. One field, written in whichever frame the strap speaks. The community reference's own
type-47 decoder reads that key first and comments that the record carries a **real unix timestamp and
no wall-clock offset**, so §7 Q3 is answered in the affirmative. What a capture still settles is the
narrower question: whether a 5.0 frame lays the version-24 record out at the same **record-relative**
offsets the 4.0 one does. **No 5.0 frame carrying a historical record exists in any fixture in hand**
— the two 5.0 frames that do exist are a handshake and a command (§2.1), and neither carries one — so
the four-byte shift is derived from the envelope and not observed.

### The one oxygen field is a candidate, and it is logged rather than read
**[reported 5.0, decompile-sourced]**

The community reference's `spo2_candidate_82` (issue #709) is the only SpO₂-shaped field anyone has found in strap
data. It comes from decompiling the official app, not from a published layout: the app's `spo2_pct`
reads **frame byte 82**, which is payload `[71]` under the 5.0/MG envelope's 11-byte origin. Its
neighbouring **frame byte 81 (payload 70)** is the sleep-state byte the same record already carries,
and the official app populates `spo2_pct` only while the strap believes the wearer is asleep —
runs of roughly thirty samples at ~1 Hz, about every 1,200 seconds.

**The value is tri-modal, and the three modes are what make it legible.** 70–100 inclusive is a
reading. A value with bit 7 set (`0x80`, `0xA0`) is a saturation sentinel. Any other sub-70 nonzero
value is a diagnostic code. `0` is the normal awake/idle state, and 101–127 has never been observed
and stays unclassified. Treating the byte as one number and printing all of it as a percentage would
turn a status code into a desaturation and a sentinel into 160 %.

**It is a candidate because its validation contradicts itself, and that is the whole reason this app
watches it instead of storing it.** On one 5.0/MG, eight nights tracked the official app at a
correlation of **+0.99** with a mean error around 0.4 points per night, and only byte 82 won an
offset-specificity scan over frame 74–92. On another device, two nights moved in the **opposite**
direction to the app. A field that beats every neighbour on one strap and inverts on another is not
yet a measurement; the bar for promoting it is **≥2 devices × ≥5 paired nights, Pearson r ≥ 0.7,
MAE ≤ 1.0 points, with byte 82 still winning the 74–92 scan** on each.

**This app therefore instruments the byte and never a metric.** `Spo2CandidateProbe` reads payload
70/71 and payload 63–81 (frame 74–92) from an R18 record, and `Spo2CandidateAccumulator` classifies
every record into the four bands above. A drain emits **at most three raw lines** (the first in-band
records, with the nineteen neighbour bytes) and **one summary** — counts per band, the in-band mean,
range and the first/last in-band timestamps — through `os.log` at `.notice` and to
`Documents/spo2-candidate.txt`, which the two `Info.plist` file-sharing keys expose in Files. It
writes no row, no `BiometricSample.spO2Percentage`, and no screen value. The exported recovery rows'
`spo2_percentage` column remains an import of what the official app already recorded, not something
this app derived.

**The 4.0 has no equivalent path.** Its type-24 record carries raw red/IR ADC scalars (record `[31]`
and `[66]`, payload `[61]` and `[63]`), with no wavelength labels and no AC/DC waveform, so a
ratio-of-ratios calculation cannot be formed from it; the published clients that mention it
(two further client reports) call it relative-only and unvalidated. There is also no `GET_SPO2`
command on either generation. The 5.0/MG's `R20` optical stream is the raw engine rather than this
field, and §4's rule against deriving a heart rate from it applies to oxygen too.

### The drain is a loop, and it needs an ACK

**[reported 4.0]** Commands are sent inside a `0x23` command frame with the opcode at `inner[2]`:

| Opcode | Name | Role |
| :--- | :--- | :--- |
| `0x16` | `SEND_HISTORICAL_DATA` | start the flash drain — the last step of init |
| `0x17` | `HISTORICAL_DATA_RESULT` | the per-batch ACK |
| `0x14` | `ABORT_HISTORICAL_TRANSMITS` | stop the drain cleanly |
| `0x21` | `SET_READ_POINTER` | u32 offset; rewind/seek the read cursor |
| `0x22` | `GET_DATA_RANGE` | the backlog window |

Two opcodes in the community reference's full command table are **not to be sent by this app**, and both are
listed here because a drain that is misbehaving is exactly when someone reaches for them:

* **The Gen 5 burst count gate is a membership rule, and Gen 4 has the same offset meaning something
  else.** [reported] The research reference's own write-up (`PROTOCOL-GEN5.md` §8)
  puts **`expected_count`, a u32 LE at `inner[9]`** — payload **6** for this app — in every
  `HISTORY_END`, and says the client counts complete frames **once each, for types 47, 48, 50, 53, 54
  and 55 only**: 49 is the marker that carries the count, 51/52 are the IMU stream, and revision and
  byte length are irrelevant. A client that miscounts makes the band re-offer the same burst
  indefinitely, which is this generation's form of the Groundhog Day bug. The matching negative result
  is `0x17` with body **`00 00`** on Gen 5 (Gen 4's is a single `00`), the default burst size is 50 and
  drops to 10 after five consecutive negative results, and **fifteen consecutive failures** is the
  terminal boundary where the client aborts with `0x14` (`ABORT_HISTORICAL_TRANSMITS`, opcode 20).
  **The Gen 4 reference publishes the same `inner[9]` as "a record-id / batch counter (not echoed)"**,
  so the field is read only under the CRC16 envelope — `WhoopProtocolProfile.declaresBurstFrameCount`
  — and a validator that read it on a 4.0 would refuse every burst.
  **[repo] This app reads and logs the pair and does not enforce it yet**: `HistoricalDrainSession`
  counts `countedFrameTypes` per burst and records `expected`/`counted` on the `DRAIN_BATCH` line, but
  it still ACKs success after every marker, and the
  `DRAIN_BATCH` line carries the token it echoes as `trim=<page> wrap=<count>` — the two
  little-endian words of the 8-byte token — and `repeat=`, which is true when a batch began at or
  before the previous batch's first record. A page that never moved, or a stream that went back, is
  the rewind stated on one line rather than inferred from two batches a rotation can separate.
  **Measured 2026-10-26, the first trim-instrumented drain of real length: 57 consecutive
  bursts, `trim` monotonically increasing, `wrap` constant, `repeat=false` on every one**, and every
  declared count matched. The stride is proportional to the records in the burst — 60 records is +4,
  45 is +3, 17 is +2, i.e. one unit per 15 records rounded up — which is a page-sized cursor rather
  than a per-batch constant. A 53-minute backlog drained in 22 seconds and ended `complete`. **The closing `DRAIN_END` line carries the summary a rotation cannot take** — `started=`, the record range (`oldest=`/`newest=`), `repeats=`, the final `trim=` and the reason — because a night's drain is hundreds of per-batch lines against a 64 KB cap, and the first of them is exactly the one a morning reader needs. Turning a mismatch into the negative result waits until a
  capture shows the two agreeing on an ordinary burst, because a validator with the wrong membership
  would refuse good bursts forever. The owner's 2026-10-25 capture already showed the premise holds —
  bursts carried `types=2F×45,30×2,31×2,32×8` and `2F×30,31×2,32×40`, so types 48 and 50 are really
  there and a 47-only count is short by the console-log traffic. What the gate would fix is a burst
  damaged in transit: today a short burst is acknowledged and the strap trims past records this phone
  never stored, and the strap's ring buffer is the only copy.
  **[measured] 2026-10-25, the owner's 5.0 on `50.42.1.0`: 53 consecutive bursts, every one
  matching its declaration** — including `2F×44,30×3,32×20` against 67 and `2F×20,30×1,32×36`
  against 57, with the two `31` markers never counted. The membership is confirmed on a second strap
  and a second firmware, and only three of the six types (47/48/50) were exercised by it; 53–55 have
  never appeared.
* **A type-47 frame is not automatically a one-second record, and `R26` is the one that says
  so.** [reported] The research reference (§5) lists revision **26 as the Pulse Information Packet** — an
  88-byte frame carrying its own **event time**, not a slot on the 1 Hz grid. [repo + measured] The
  drain met one on 2026-10-26: `layout=26 ... expected=8 counted=8 types=2F×1,30×1,31×2,32×6`, one
  record stamped `00:18:04` arriving after a batch that had already reached `00:18:43`. Read as a
  1 Hz record it made the stall guard log `stalled=1` for a strap that was advancing — and three of
  those end a drain as `.idleTimeout`, so a handful of these packets across a night would stop a
  good drain and call it stalled. **The stamp reader is therefore gated on
  `HistoricalDrainSession.timestampedLayouts` — 18, 21 and the 4.0's 24 — and an `R26` frame still
  counts toward its burst's declared total.** The count gate and the clock are two questions about
  the same record.

* **`0x9B`–`0x9F` — certificate transfer and `LOCK_DEVICE` — are destructive and are refused by name.**
  [reported] The community reference's `#2828` names them from the official app 5.473.0's command table:
  `START_CERTIFICATE_TRANSFER` (155), `LOAD_CERTIFICATE` (156), `VERIFY_CERTIFICATE` (157),
  `PROCESS_CERTIFICATE` (158) and **`LOCK_DEVICE` (159)**. Their reversibility is unknown and a locked
  strap is one this app could not use at all, so `WhoopProtocolProfileTests` sweeps all three command
  tables for these five bytes exactly as it sweeps for `0x19` and `0x9A` — the failure mode being a
  table carrying one under a name that reads innocuous.
* **`0x19 FORCE_TRIM` is a flash erase and is destructive.** The research reference marks it "never sent".
  The drain is non-destructive by design and does not need it; a trim issued to "clear the backlog"
  would destroy the user's history irreversibly, including the portion not yet drained.
* **`0x9A TOGGLE_PERSISTENT_R21` is a trap, and since 2026-10-24 the app has one deliberate way to
  spring it.** It forces the optical engine on across reboots, so the LED stays lit and the strap
  burns battery until a fresh boot — clearing the flag does not stop the running engine; recovery is
  `REBOOT_STRAP` (`0x1D`). The research reference's client keeps to wrist-gated optical (the research reference's name for
  `0x6B`; the community reference reads that byte as a state read — §3) and never sends `0x9A` casually. **The exception
  is a manual control on the device page's ADVANCED tab**, added to test whether the flag is what
  stopped the owner's flash recorder (`docs/TODO.md` §7.2): `[1, 1]` to set it, `[1, 0]` to revert,
  behind a confirmation that names the battery cost. It is **5.0/MG only**, it is never part of a
  connect sequence, and **the byte is in neither opcode table** — `WhoopCommandFrames.persistentR21`
  is the only builder, so §16's forbidden-byte sweep still fails if anything else grows a path to it.
  The ACK does not confirm programming; only a drain does. **Measured on 2026-10-24, firmware
  50.42.1.0:** every drain before the `[1, 1]` write answered `0 record(s)`; the first after it read
  **8,984 `R18` records stamped hours *before* the write**, so on this firmware the flag gates the
  **read path** rather than starting a recorder — and a ten-minute disconnected wear then banked one
  record per ~24 s, `R21` motion cadence, which *looked* motion-only until a longer capture on
  2026-10-25 showed a worn strap banking **one `R18` per second with Bluetooth off** (2,003 records in
  32 minutes) — so the sparse windows were wrist-off time, not a link-state rule. Both readings are
  one unit's and one firmware's. A `0x22 GET_DATA_RANGE`
  sent throughout drew no reply of the app's command-response type — though a **17-byte
  `type=0x28 cmd=0x22`** frame did arrive ten minutes later carrying a body that is neither the community reference's
  65-byte layout nor a decodable cursor, so the canary is **present and undecoded** rather than absent
  (`docs/TODO.md` §7.2).

Two more live-path opcodes belong here for completeness, since §5's live producer depends on them:
`0x03 TOGGLE_REALTIME_HR` and `0x6B` — which **the research reference** names `ENABLE_OPTICAL_DATA` and calls
wrist-gated optical, **the HR source**. **The community reference's 4.0 column disagrees and calls the same byte
`GET_IMU_DATA_STREAM`, a state read** — though the community reference's code names it `enableOpticalData` and never
sends it, so the disagreement is between the two references' documents rather than their clients
(§3's naming note has all three readings). **This app sends `0x03` and not `0x6B`.** A 4.0's live
heart rate is the standard `0x2A37` GATT characteristic (§5), which needs no proprietary command to
start; a 5.0/MG has no live-telemetry opcode of the 4.0's kind, so once its bond handshake is
acknowledged `sendConnectCommands()` writes `0x03 TOGGLE_REALTIME_HR` with the one verified byte
`[01]`, and the packet-40 notifications that follow are decoded by
`HeartRatePayloadDecoder.decodeLive` — heart rate at payload `[5]`, R-R count at `[6]`, intervals at
`[7 + 2i]` in 1/1024 s. **The builder is enable-only**, because nothing establishes what a disarm
body would be. `0x6B` belongs to the 4.0's motion-enable group and is not sent to a 5.0.

**Event 29 `STRAP_CONDITION_REPORT` is the strap's own answer to "how much history do you
hold", and this app reads it.** [reported] Its body — eleven bytes at payload 9, after the event
header's `u16 id`, `u32 unix`, `u16 subsec` and `u16 body length` — is `u32 page backlog`, `u16`
backlog in tenths of an hour, `u16` state of charge in tenths, then `u8` flash, `u8` charging and a
`u8` wrist tri-state. `StrapConditionReport` decodes it for the log only: the layout is one
reference's and no capture here has confirmed it, and the charge figure is deliberately not fed to
the battery badge, whose whole rule is that a figure the strap did not send is not drawn. **This is
the instrument that replaces a fourteen-day wear** — one connect reports the backlog in hours.

**`R18` carries the accelerometer, and that is what makes a phone-away night classifiable.**
body 24 is three `f32` in g — mean acceleration X/Y/Z for that second — and
`HeartRatePayloadDecoder` reads them into `BiometricSample`. **The strap does not bank `R21` motion
records in flash** [measured 2026-10-26 — every drained burst carried layouts 18 and 26, never 21],
so the stillness signal the sleep classifier needs was never in the motion record after a
disconnected wear: it was in the heart-rate record all along. The community reference reached the same conclusion from
the other side (`#1801`: "staged WITHOUT a motion spine, from heart rate alone … weaker by
construction"), and this app takes the stronger route because the accelerometer is present in the
records it already drains.

Records stream as `0x2F` punctuated by `0x31` metadata markers with a sub-type at `inner[2]`:

* `1` = `HISTORY_START` — informational, ignore.
* `2` = `HISTORY_END` — **ack it and keep listening.**
* `3` = `HISTORY_COMPLETE` — **stop; do not ack.**

The `HISTORY_END` marker carries an 8-byte continuation token at **payload 10** — frame 17 under
the 4.0 envelope (`inner[13:21]`) and frame **21** under the 5.0's (`data[10:18]`, the community reference's
hardware-verified trim cursor). The reply is:

```
[0x23 COMMAND][seq][0x17 HISTORICAL_DATA_RESULT][0x01 SUCCESS] + token(8B)      # 12 bytes
```

Status codes: `0x01` success, `0` failure, `2` pending, `3` unsupported.

**Without a correct ACK the strap re-sends the same batch forever** — the community reference calls it the
"Groundhog Day bug". The cursor advances on a good ACK (≈ +5 per batch) and **persists across
connections**, so a partial drain resumes rather than restarts. The band answers each ACK with a
`0x24` ack-of-ack. The drain is **non-destructive — it never erases its own flash** — so it can be
repeated. Termination is `HISTORY_COMPLETE`, an idle timeout (~8 s reported for 4.0), or catching up
to the live edge. Event 96 (`HIGH_FREQ_SYNC_PROMPT`) signals flash filling and a desire for a faster
sync.

**There is always a backlog, and coming to get it is the app's job rather than the strap's.** The band
records for as long as it is worn and holds the record on board, so a drain is not something the
hardware decides to do — it is a request this app makes, and how much comes back is decided by how
long the app has been away. **[assumed]** The working figure for that reach is **about fourteen days**
on every generation, which is the retention this project plans against. **Read that as a planning
premise and not as a measurement.** Two reverse-engineering projects state ~14 days and **neither
measured it** — no project has drained to `HISTORY_COMPLETE` and read the oldest record's `[7:11]`
against wall time — while **WHOOP's own user-facing guidance says roughly 72 hours** of offline
storage on the 4.0. That is a five-fold disagreement with nothing in hand to break it, and the two
reverse-engineering figures may simply be repeating each other. Design against the smaller number;
§7 Q10 is the one drain that settles it.

**A commercial source now points at ~14 days, and still without a measurement.** The ~72-hour figure
is reported to describe the **3.0 and older firmware**, while current 4.0/5.0 firmware is reported at
two weeks [reported, commercial]. That is a lead rather than a resolution: no drain here has returned
a record stamped inside a wear window. **The cheapest test is not a wear at all.** `GET_DATA_RANGE`'s
65-byte reply carries a write page and an acknowledged page, so two drains either side of a
disconnected wear show whether the write page moved. The community reference's #689 diagnostic gives the fields —
`V(1)` read, `V(2)` write, `V(3)` acknowledged, `V(5)` capacity, with backlog
`write < ack ? write + (capacity − ack) : write − ack` — marks the 5.0/MG layout **unconfirmed**, and
uses the figure log-only. `WhoopDataRange` decodes it on the same terms. **A write page that never
moves says the strap is not storing**, which no retention window explains. The community reference also re-offloads the
type-47 store **every ~15 minutes while connected**, and preserves the exact eight-byte `HISTORY_END`
block in a **confirmed** ACK; this app's ACK keeps the same body and now writes it confirmed. If the
write page moves during a connected session, one drain per connection is too rare.

Two consequences hold whatever the true figure turns out to be. **A fresh connection is the trigger** — the right default on
connect is that there is something to fetch, not that there is not, which is the same "assume it is
recording" rule §6 states for motion applied to the flash as a whole. And the drain is **additive**:
nothing here deletes anything, so the window is a bound on how far back the strap still *has* history,
not on how much this app may ask for, and a strap that has gone a fortnight unwatched is a strap with
a backlog rather than a strap that has lost one.

**[reported 5.0]** The same shape with different numbers: command 22 `SEND_HISTORICAL_DATA`,
23 `HISTORICAL_DATA_RESULT` (payload `[0x01] + end_data(8)`), 34 `GET_DATA_RANGE`,
96/97 `ENTER`/`EXIT_HIGH_FREQ_SYNC`. The `HISTORY_END` payload decodes as `'<LHLL'` from frame
byte **11** — the 5.0 envelope is four bytes longer than the 4.0's, so the payload origin moves with
it (§2: inner origin 8 rather than 4, plus the three bytes of `[type][seq][cmd]`):

| Frame offset | Payload offset | Field | Type |
| :--- | :--- | :--- | :--- |
| 11 | 0 | `unix` | u32 LE |
| 15 | 4 | `subsec` | u16 LE |
| 17 | 6 | `unk0` | u32 LE (unmapped) |
| 21 | 10 | `trim_cursor` | u32 LE — **ack with this to advance the trim** |

Safe ordering on 5.0 is decode → insert → optional raw batch → set cursor → ack, so an un-persisted
chunk is never trimmed. Offload traffic is types 47/48/49/50; the live 40/43 streams are excluded
from the idle watchdog (60 s on 5.0, re-armed only by genuine offload frames). Re-offload every 900 s,
first sync ≈1.5 s after the handshake. `FORCE_TRIM` (25) is **destructive** and is excluded from the
safe command set along with reboot/power-cycle/firmware opcodes.

### Implementation status **[repo]**

**The drain is implemented on both generations, and the `0x30` gap is closed.** `DeviceViewModel` →
`SyncHistoricalDataUseCase` → `WhoopBLEDeviceRepositoryImpl.requestHistoricalSync` reaches a
`HistoricalDrainSession` for whichever envelope the connected strap uses.

| | This codebase | 4.0 **[reported 4.0]** | 5.0 **[reported 5.0]** |
| :--- | :--- | :--- | :--- |
| Request opcode | `0x16` | `0x16` | `0x16` / 22 |
| Request body | a single `00` — **the same byte on both generations**, and the four sources below agree on it | `00` | explicit `00`; "Command 22 returns state plus two zero bytes" |
| Inbound record type | `0x2F` counted toward the batch on a 4.0; on a 5.0/MG the layout selector at frame byte 9 picks the walk (see below), and the burst's **frame count** is the six-type membership rather than the record type alone | `0x2F` | 47 |
| ACK loop | `0x17` + the 8-byte token, per batch | `0x17` + 8-byte token | `0x17` + `end_data`(8) |
| Batch ending | `HISTORY_END` acknowledged, `HISTORY_COMPLETE` not | metadata `0x31`, sub-type at `inner[2]` | 49, same sub-type offset |
| Count gate | **read and logged, not enforced**: `expected` from payload 6 and `counted` from types 47/48/50/53/54/55, both on the `DRAIN_BATCH` line, 5.0/MG only | `inner[9]` is a record-id / batch counter — no gate | `inner[9]` u32 expected count, six-type membership, negative result `00 00`, abort with `0x14` after 15 failures |
| Record layout | **R18, R21 and the 4.0's type-24 record are walked; R20 is not** — R18 → `HeartRatePayloadDecoder.decodeR18Historical` (heart rate and R-R), R21 → `MotionPayloadDecoder` (§6), type 24 → `HeartRatePayloadDecoder.decodeWhoop4Historical` (heart rate and signed-ms R-R), R20 has no reader (see below) | 96-byte header; HR at `[17]`, count `[18]`, R-R `[19+2i]` | layout selector at frame byte 9: R18 124 B, R21 1,244 B, R20 2,140 B (frame) |

**The request body is one `00` byte on both generations.** A `[u32 startEpoch][u32 endEpoch]` little-endian window has no source behind it and must not be reintroduced at either builder. **Four sources agree on the bare byte, three of
them code that runs**, which is why this is a correction rather than a judgement call between two
readings:

| Source | Kind | 4.0, ID 22 | 5.0/MG, ID 22 |
| :--- | :--- | :--- | :--- |
| the community reference's `BLEManager.swift` | **implemented** | `send(.sendHistoricalData, payload: [0x00])` | same builder |
| the community reference's `docs/PROTOCOL_COMMANDS.md` | documented, observed | request body **`00`** — "observed working in device captures on 41.17.6.0, outside the documented command set" | "Older requests use explicit **`00`** for each operation"; "Command 22 returns state plus two zero bytes" |
| the research reference's `research_playground.py` | **implemented** | `build_command(seq, Cmd.SEND_HISTORICAL_DATA, b"\x00")` | — |
| the research reference, same file | **captured frame** | `aa0800a823041600c7c25288` annotated `0x16 [00]` | — |

**The eight-byte shape this app copied belongs to the reply, and it runs the other way.** ID 23's body
is `01` plus the exact eight-byte `HISTORY_END` block — which the community reference calls **opaque** and warns against
reconstructing ("never reconstruct the opaque second word") — and `inner[13:21]` on the 4.0 /
payload `[10,18)` on the 5.0 (frame 21) is where the ACK above reads it. **The token is at the same
*payload* offset on both generations; a reader built on the 4.0's *frame* offset is four bytes early
on a 5.0, the strap accepts the acknowledged write, and its trim cursor never moves** — measured on
the owner's 5.0 on 2026-10-23, where the drain replayed the same two August batches indefinitely.
**Nothing selects a
range on this command**, and a window has somewhere else to live — `0x21 SET_READ_POINTER` seeks the
read cursor and takes a **u32 offset**, not an epoch pair.

**No "newer form" exists.** The community reference's "older requests use explicit `00`" contrasts an explicit `00` with
its builder's *default* payload, which is also `[0x00]` — both spellings are the same single byte, and
no start/end body appears in any reference for either generation. The frame lengths are where a
widening would show: **12 bytes for the 4.0 and 16 for the 5.0/MG**, each `header + 3 + 1 + 4`, so an
eight-byte body lands at 19 and 23 and §16 fails on both.

**One oddity stays on the record rather than being tidied away.** The community reference's 4.0 row for ID 22 describes it
as starting **type-47** delivery — the 5.0/MG record type, on a row whose records this document
elsewhere calls `0x2F` type 24 — and its status is `O / U`, observed rather than documented. That is a
question about the *reply*, not the request, and **§7 Q11** carries it; it needs no new decoder,
because a `00` body either delivers records or does not.

**`0x30` is a packet type and not a command, and §2's own table says so.** An outbound `0x30`
therefore asks a strap for an event rather than for a drain — a command it ignores, which is benign
on its own. **A missing ACK is not benign, because it makes the strap re-send the same batch
forever**, so starting a drain this app cannot acknowledge leaves a strap looping. The byte lives in
the opcode tables rather than in the builders, which makes it one edit per generation rather than a
search for a literal.

**The record layouts are walked on both generations, and one layout remains unread on the 5.0.** What
the drain reads out of the stream today is the batch structure — the records, the `HISTORY_END` that
closes a batch and carries the continuation token, and the `HISTORY_COMPLETE` that ends the drain —
plus **two of the 5.0/MG's three type-47 layouts**, selected by the layout byte at frame `9` (the byte
`WhoopRawFrame.seq` exposes), **and the 4.0's type-24 record**: `R18` is the heart-rate record and
`HeartRatePayloadDecoder.decodeR18Historical` walks it at payload `[11]` for the heart rate and
`[13 + 2i]` for the R-R intervals, stamped from the record's own unix at payload `[4]`; **the same
record carries the strap's own pedometer at payload `[46]` and its activity class at `[52]`, walked by
`StepCounterPayloadDecoder`** — see §6's counter subsection for the offsets, their provenance and why
they are an unvalidated candidate; `R21` is
§6's IMU buffer and `MotionPayloadDecoder` walks it into a `MotionBatch` for the step path. **That walk
uses the record's own clock only because this is the banked path**: the same decoder takes a *live*
packet 43 and keys it on the arrival instant instead, because a strap whose RTC was lost stamps every
live record with a date years in the past — measured on a real 5.0, where a whole walk's steps were filed under `2000-01-03` and no screen could draw them. A banked record has no
arrival-time substitute (it may be hours old), so it keeps the stamp and the RTC question above stays
open for it. **`R20`,
the optical engine's raw sample stream, has no reader** — a heart rate assembled from it would be a
sensor byte read as a pulse. **The type-24 record is now walked for heart rate and R-R**:
`HeartRatePayloadDecoder.decodeWhoop4Historical` reads the unix seconds at record `[7:11]`, the heart
rate at `[17]`, the interval count at `[18]` and up to four **signed 16-bit milliseconds** at
`[19+2i]`, requiring the record's minimum inner length of 89. **The rest of the record's header and
body are still unread** — accelerometer samples, skin temperature, contact and resting heart rate
have no consumer here, and nothing claims they do. `docs/TODO.md` §5 carries that half.

**The R18 record also carries the oxygen candidate at payload `[71]`, and the app reads it as
instrumentation rather than as a metric.** `Spo2CandidateProbe` classifies every drained record and
`Spo2CandidateAccumulator` emits at most three raw lines and one per-drain summary to `.notice` and
`Documents/spo2-candidate.txt`; nothing writes a percentage to a row, a sample or a screen, and the
candidate offset is documented above rather than promoted to a field. The reason is the cross-device
contradiction, not a missing consumer: a byte that tracks the official app at +0.99 on one strap and
moves the wrong way on another is evidence to collect, not a reading to ship.

**The timestamp that would place a drained batch on a timeline is still verified as a field and
unverified as a value.** `[7:11]` of the type-24 record is a u32 unix time, but the strap's RTC is set
by `0x0A SET_CLOCK`, and the 4.0 reference's event enum carries type 13 `RTC_LOST` ("battery fully
died — clock reset") — so a battery-flat strap stamps every record with a wrong offset and nothing in
the record shows it. **That failure is silent in the worst way: it files history onto a wrong day
rather than onto no day.** A prerequisite for trusting any of it is sending `SET_CLOCK` first, which
is why `WhoopCommandFrames.setClockFrames` exists and why it sends **both** of the 4.0's lengths (see
§7 Q7: a wrong-length set is *acknowledged but not latched*) — and why **sending a clock set is not
the same as knowing it latched.** `0x0B GET_CLOCK` is the read-back both generations offer, and it is
sent after every drain's set; its reply is logged as an ordinary inbound response, and **no path in
this app decodes it or claims a clock latched.** §7 Q7 stays open.

**The 5.0/MG's `R18` carries the same field at payload `[4]` (frame 15), and both walks refuse a
record whose unix is zero.** That guard catches a clock that was never set — the state a
strap with a dead battery boots into — and not one that is merely wrong by an offset, which nothing
in the record shows. So the zero-lowest failure is closed on the 5.0 path and the offset failure is
not; both remain Q7's, and no decoder can close the second.

**The decoder returns the validated inner record as a `WhoopRawFrame` for a later parser to walk**,
which is the order §7 sets out. **The app cannot fabricate a reading from a record it does not
understand**, and the type-24 walk is the shape of that rule rather than an exception to it: it reads
the four published fields at their published offsets and refuses the record when the selector, the
minimum length or either guard field does not check out — it does not scan the 96-byte header looking
for a plausible pulse, which is how a record-counter byte becomes a heart rate in
`biometric_samples`.

Inbound CRCs **are** now verified — the header CRC8 and the payload CRC32, both enforced in
`decodeProprietaryFrame`, which refuses a frame that fails either. That closes the `0xAA`-in-payload
ambiguity at the frame level: a false boundary yields a frame that fails its checksum instead of
plausible garbage.

**Length-based reassembly is implemented**, in `WhoopFrameReassembler`. A notification carries at
most `MTU − 3` bytes while the 5.0/MG type-47 record runs to 2140 and the 4.0 live IMU stream to
roughly 1.9 KB, so `decodeProprietaryFrame` — handed one notification and requiring
`data.count >= frameByteCount(declaredLength:)`, which is `innerOrigin + declaredLength` and so `+ 4`
under 4.0 and `+ 8` under 5.0 — cannot complete a frame that spans a second one, and without the reassembler
that `nil` is all the manager has. The reassembler owns **boundaries, not validity**: it finds a
start of frame, reads the declared length **at the profile's own `lengthFieldOffset`** — byte 1
under 4.0, byte 2 under 5.0 — holds bytes until that many have arrived, and hands the candidate to
the decoder, whose checksums remain the only thing that decides whether those bytes were a frame. A
candidate the decoder refuses is treated as evidence the `0xAA` it started on was a payload byte,
and the scan resumes one byte later — so a notification lost to a dropped link costs bytes and never
a reading. Two properties are consequences rather than tuning: a boundary declaring more than
`maximumFrameBytes` (4096, above every documented record shape) is skipped rather than waited on,
which is what bounds the buffer without a trim rule; and the buffer is **per-connection**, reset on
both connect and disconnect, since bytes held across a reconnect would be prepended to the new
stream's first frame and shift every field in it.

**The historical half has now been run too, on one 5.0, and it corrected the live-edge rule.** A flash
drain completed end to end (`59 record(s) in 1 batch(es), ending caughtUpToLiveEdge`), every record
logged as `type=0x2F layout=18 payload=109 B` — the `R18` walk — and the samples were stored
(`LAST SYNC` moved to the drain's own instant). The `HISTORY_END` marker's head decodes to the
drain's **own** instant (the phone's clock, on the 2026-10-23 run: `headAsUnix` was the wall clock
while the five records it closed were stamped `2026-08-24 12:51:13` onward). The old rule compared
that head with the wall clock and so declared the live edge after one batch over two months of
unread backlog — reported as `caughtUpToLiveEdge`. **The live edge is now the newest **record's** stamp, with the **drain-wide highest record** as the fallback for a batch that carries none — and the marker is used only by a session that has seen no record at all, because the strap closes its last chunk with an empty marker stamped now over two-month-old records and a batch whose newest
record does not advance is counted as a stall (`maximumStalledBatches = 3`) so a re-sending strap
cannot keep the idle window armed forever. **A multi-batch drain has since been observed, and it is the ordinary case now.** On 2026-10-24 the
same strap answered **`412 record(s) in 8 batch(es)`** in one session — `type=0x2F layout=18
payload=109 B` throughout, one record per second, batch boundaries a minute apart, the last
`HISTORY_END` reporting `liveEdge=true` — so the cursor, the ACK loop, the stall guard and the
live-edge rule all ran over more than one batch on real records. **The connected rate is `[captured]`; the disconnected rate is not.** Connected, the strap writes one
`R18` per second — that is every record of the 412, logged. What happens while the phone is away is
**inferred rather than seen**: a 30-minute disconnected wear came back as **30 records in 2 batches**
(the app's own completion line, not a frame), and the drain after it opened its window at
`SET_CLOCK`'s own stamp (`14:22:51Z`, the reconnect), which says the earlier drain had consumed what
lay before it. The step total moved across that first drain, and a cumulative pedometer needs only one
record to account for a whole gap, so **at least one offline record carried a step counter and at
least one was presumably `R18`** — which record, and at what layout, has never been read. Until an
offline drain is captured inside the archive's window, "about one record a minute while disconnected"
is a rate estimate from a count, not a measurement. The `R18` walk itself is proven on real records;
what makes the strap write at one rate rather than the other is unknown.

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
  list is stored in `biometric_samples.rrIntervalsMs`, with `rrIntervalMs` retained as the first
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
**respiration is not in the record at all; WHOOP derives it in-cloud from the PPG**. It means this
app's `RespiratoryRateMath` — which derives the figure from the R-R series — is not a second-best
route around a channel it failed to find, but the same route WHOOP itself takes, from the same
signal. **What that route cannot be validated against is the absent R-R series, not an absent
column**: the bundled export does carry `Respiratory rate (rpm)` — one figure per cycle, non-empty
on 910 of its 935 rows — and the importer stores it on both the `recoveries` row
(`RecoveryMetric.respiratoryRate`) and the `sleeps` row (`SleepSession.respiratoryRate`). A per-cycle
figure with no beats behind it is a second opinion about a night, not a test of an estimator that
reads a tachogram; the validation this doc would need is WHOOP's own rate *and* the intervals that
produced it on the same night, and the export has never carried the second. The practical reading for
the drain: **do not go looking for a breathing channel in the flash**, and do not treat the constant
at `[76]` as a reading.

### Implementation status **[repo]**

**Three routes ship, and the newest two are 5.0/MG-only.** A 4.0's live heart rate is the `0x2A37`
notification in `didUpdateValueFor`, decoded by `WhoopPacketDecoder.decodeStandardHeartRate` and
stamped with the arrival instant. A 5.0/MG's is packet 40, armed by `0x03 TOGGLE_REALTIME_HR` in
`sendConnectCommands()` once the bond handshake is acknowledged and decoded at payload
`[5]`/`[6]`/`[7 + 2i]` by `HeartRatePayloadDecoder.decodeLive`; its builder is enable-only, and the
notification's own unix field is deliberately not read, so both live producers share one time base.
Both yield on `liveTelemetryStream`, and the device page draws the latest figure for 30 seconds before
it returns to a dash.

**History is the drain, and both generations' heart-rate records are walked.** A 5.0/MG's `R18`
records are walked by `HeartRatePayloadDecoder.decodeHistorical` and yielded on
`historicalTelemetryStream` as the batch arrives; the 4.0's type-24 records take the same path through
`decodeWhoop4Historical`; `SyncHistoricalDataUseCase` consumes that stream concurrently with the drain
and batch-saves it, so a sample is persisted before the drain ends rather than after. A drained sample
is stamped from the strap's own clock, not from arrival, because it belongs to the day it was measured
on. The 4.0 walk reads only the record's time, heart rate and R-R; its accelerometer, contact, skin
temperature and resting-rate fields stay unread.

**Hardware status: the live producer is captured on a 5.0, the history producer is not.** The capture
is one connect, recorded on 2026-10-18 from a log archive of the app's own process. The advertisement
carried `FD4B0001-…`, so the strap was resolved as a 5.0 before any characteristic was discovered —
which matters here because the strap's advertised name is user-settable and does not contain a
generation. The 16-byte `CLIENT_HELLO` was written with response to `FD4B0002-…` and acknowledged
**178 ms** later; the four proprietary notify characteristics were subscribed only after that
acknowledgement; the connect pass then wrote `0x03 TOGGLE_REALTIME_HR` with `[01]`; and the first
packet-40 notification — a 109-byte record — decoded through `HeartRatePayloadDecoder.decodeLive`
0.7 s after the pass and 1.3 s after discovery, at `bpm=86` with an empty R-R run. That confirms, on
this project's own hardware, the offsets at `[5]` / `[6]` / `[7 + 2i]`, the arm's one-byte body, the
post-bond ordering, and `0x2A37` on one of the four discovered services. **Two things it does not
confirm.** No `0x03` acknowledgement was observed — the frame is written and the arriving stream is
the evidence it took effect, not a receipt — and **no drained heart-rate record has been captured on
either generation** (`R18` or the 4.0's type 24), so both walks remain pinned against hand-built
frames taken from §4's table, and §7 is still the capture that would replace them.

---

## 6. Motion: three producers, and which strap has which

**The wearer produces the motion and the strap records it.** Both halves matter to how this section
is read: the motion is not something the hardware generates or withholds, it is generated by the
person wearing the band and captured continuously for as long as the band is on. That is why the
default below is "assume it is recording" rather than "assume there is nothing to read", and why a
gap in this app's data is a gap in this app's *coverage* rather than an absence in the strap.

**The strap this app talks to is a strap being worn, and the app's frame starts there.** **One strap
is connected at a time** — `WhoopBLEManager` holds a single `connectedPeripheral` and one
`disconnect()` — so the assumption is never a statement about three straps at once. Which band it is
is the per-identifier model the selection rule below records, and that model is the thing that says
which band is on the wrist. Whichever strap is in hand is the one recording: it captures motion at
the resolution its generation supports, whether or not this app is running, in range, or even
installed. A band in a drawer is a state the user creates and the app can be told about; it is not
the state to design the default around. Everything below follows from that premise, and the
per-generation differences are differences in what survives to be collected, never in whether the
strap was measuring.

The section exists because the app's only documented motion field — the tri-axial accelerometer in
the type-24 record at `[36:48]` — is the *worst* of the three routes the hardware offers, and treating
it as the whole of what the strap measures is how a gyroscope goes missing from a specification that
then concludes strength training is unmeasurable.

### The selection rule already exists, and this section is written against it

The user assigns a model on the device page's `ADVANCED` tab (`DeviceSettingsView`) — `WhoopHardwareGeneration.selectableModels`, which is
`[.whoop4, .whoop5, .whoop5MG]` — persisted **per peripheral identifier** by `StrapModelRepository`,
because a strap that advertises no name arrives as `"WHOOP Strap"` and the name cannot tell a 5.0 from
a 5.0 MG. `WhoopBLEManager.resolvedGeneration(stored:advertisedName:)` resolves the stored choice
ahead of any advertised name.

That value is the branch point for everything below. It is already the only place the app knows which
of the three straps it is talking to, so a motion decoder reads it rather than re-deriving a
generation from an advertisement. `standardBleHR` and `simulator` have no motion producer and are not
enumerated further: the first is not a WHOOP strap, and the second synthesises samples in
`WhoopMockBLEManager` and frames nothing.

### The hardware

| Strap | Accelerometer | Gyroscope | Basis |
| :--- | :--- | :--- | :--- |
| 4.0 | yes — in the type-24 record at `[36:48]`, and at 100 Hz in the live raw stream | **yes** — in the live raw stream | a hardware-verified `REALTIME_RAW_DATA` layout puts the gyroscope at frame `692` / `892` / `1092` with scale `0.06103515625` deg/s/LSB, a full scale of ±2000 dps, confirmed against a controlled 720° rotation. Two deep teardowns name no IMU part and the FCC exhibit discloses the sensor board part number not at all — which is why reading the flash record alone suggested there was no gyroscope, and why an absence in a teardown is not an absence in the hardware |
| 5.0 / MG | yes | **yes** | an ITF Player Analysis Technology approval report lists "3-axis accelerometer and gyroscope" in the sensor suite **[filed]**; WHOOP claims 26 Hz for motion sensing |

**This is a difference between the generations the rest of this document had no reason to record
until now**, and it is why a per-generation motion table can be written at all. Mind what the
`[filed]` tag does and does not buy: a filing establishes that a sensor exists, because that is the
filing's subject and it is made under a duty of accuracy. It says nothing about the wire format, and
no filing in hand describes a record layout, an opcode or a byte offset.

### The three producers

**1. The type-24 flash record — 4.0 historical, 1 Hz, accelerometer only.**
[reported 4.0] Tri-axial acceleration at `[36:48]`, float32 ×3, one record per second of wear.
**This cannot carry a cadence and is not a step source.** A walking cadence is ≈1.5–2 Hz, and a 1 Hz
series cannot represent anything above 0.5 Hz — the step fundamental is above its Nyquist limit
before any filter question is asked. What this record can support is what the sleep classifier
already reads from it: a still-versus-moving epoch, which is a gross activity signal and not a count.

**2. The live IMU stream — 4.0, 100 Hz, live-only, and the 4.0's gyroscope.**
[reported 4.0] `0x6A TOGGLE_IMU_MODE` enables it, paired with `SEND_R10_R11_REALTIME (0x3F)` and
`ENABLE_OPTICAL_DATA (0x6B)`. Records arrive as type `0x2B REALTIME_RAW_DATA` (live R10 = HR + IMU,
across several BLE notifications) and as types `0x33` / `0x34`, the realtime and historical IMU
streams. **On the 4.0 the raw motion layouts are live-stream only** — its flash holds type-24 and
nothing else — so on a 4.0 this path exists only while the app is running and connected. The source's
wording here is "raw R10/R21 are live-stream only", and it is quoted in §8; that phrase spans two
generations and only its 4.0 half generalises. `R21` is the **5.0/MG** layout, and it *is* banked —
producer 3 below, §4's drain table and §7's closing paragraph all say so.

**This is the best-documented motion layout in this document and it belongs to the 4.0.** A
`REALTIME_RAW_DATA` variant declaring **1917 bytes** carries **100 samples per axis at ~100 Hz** —
one packet per second per axis — as signed int16 **little-endian**: accelerometer X / Y / Z at frame
`89` / `289` / `489` at `0.000244140625` g/LSB (1/4096 g), then gyroscope X / Y / Z at frame `692` /
`892` / `1092` at `0.06103515625` deg/s/LSB (±2000 dps full scale), with the trailer from `1292`.
Each 600-byte lane is contiguous and the two are separated by three bytes. The scales were verified
against a motion-capture reference and a controlled **720° rotation** respectively, on generation-4
hardware. The length is **1917 declared**, which is 1921 bytes of frame, and the layout behind it is
published rather than inferred — a second-hand 1928-byte / 100 Hz figure is not this frame's own.

**3. The layout-selected `R21` record — 5.0 / MG, 100 Hz, six axes, live *and* banked.**
[reported 5.0, hardware-validated] The 5.0/MG **does** have a live raw-IMU stream: layout 21 is
carried by **live packet 43 and historical packet 47**, so the same 1,244-byte buffer is both
streamed and banked. Three sources agree and none dissents — the 5.0/MG sensor reference states the
dual carriage outright, the deep-data page records the enable sequence, and an independent APK-
decompilation capture names packet `0x2B` / 43 `REALTIME_RAW_DATA` with the "Maverick R21 format"
behind it. The previous claim that the 5.0/MG had "no live raw-IMU stream at all" traces to no
source in hand: it was this document's own inference from an absence, and the absence was in the
reference it was reading, not in the hardware.

The record is `R21`: **fixed 1,244 bytes**, CRC32 at 1,240 covering `[8,1240)`, layout selector `21`
at `inner[1]`. Its content is **100 accelerometer samples and 100 gyroscope samples per axis — 100 Hz
across a one-second buffer** — stored **columnar** (all `ax`, then all `ay`, then all `az`; likewise
the gyro), `i16` little-endian. The offsets are **frame-absolute** (8-byte envelope + payload) and are
confirmed **byte-for-byte by two independent sources** — one written against the strap's own firmware
reference, the other from APK decompilation plus live probing — whose tables reconcile exactly once
the envelope is added:

| Field | Frame offset | Count | Scale |
| :--- | :--- | :--- | :--- |
| strap unix seconds | 15 (`u32`), fraction 19 (`u16`) | — | `seconds + fraction / 32768` |
| `countA` | 24 (`u16`) | 100 | — |
| `ax` / `ay` / `az` | 28 / 228 / 428 | 100 × `i16` | **`1/4096` g/LSB — a ±8 g full scale** |
| `countB` | 630 (`u16`) | 100 | — |
| `gx` / `gy` / `gz` | 640 / 840 / 1040 | 100 × `i16` | **`2000/32768` deg/s/LSB — ±2000 dps** |

**The two scales are a matched pair, and both sources state them the same way.** `1/4096` g/LSB over
a signed `int16` is `32767 / 4096 = 7.9998` g, and the independent source writes it out as "±8g
(1g ≈ 4096 LSB)" — so the two agree, and a ±4 g scale is exactly half — it would leave the top bit of every sample unused. The gyro's `2000/32768` is the same pairing at
±2000 dps. **These are the same two scales producer 2 above carries**, which is what lets one
magnitude threshold mean the same thing across both generations instead of one per strap.

**What the enable sequence is, and what it is not.** The deep-data page records the workflow as
command **81** (`START_RAW_DATA`) followed by command **106** (`TOGGLE_IMU_MODE`) with payload
`[1,1]`; stop is **82** then **106** with `[1,0]`. **106 on its own acknowledges without starting the
producer** — so a decoder that sends the toggle and waits sees nothing, and reads that silence as a
strap that does not stream. An independent source describes the `0x2B` flow as **passive, needing no
toggle**; that is not a contradiction but a different starting state, because it describes
piggybacking on a session the WHOOP app has already configured, where the toggle has been sent by
someone else. **This app does not piggyback and does not bond**, so the passive route is not
available to it and the two-command sequence is the one that applies.

**The feature names are not load-bearing.** `gyroEnergyDps`, `accelEnergyG`, `jerkRms`, `cadenceHz`
and `cadenceStrength` come from a feature extractor whose offsets are unverifiable from here, and
the layout above supersedes them: a gyroscope reading in degrees per second is reproducible from
published offsets and a published scale rather than from a named feature. What survives is why the
producer matters: six-axis motion at 100 Hz recoverable from **banked** history, on a strap the app
was not running beside. That the sensor pair `docs/PATENTS.md` §1.4's musculoskeletal family requires
("fused 3-axis accelerometer and gyroscope data") is present on both generations is established
twice over and by different evidence: the 5.0/MG's by the sensor suite the ITF filing lists
**[filed]**, the 4.0's by the live raw layout above **[reported 4.0, hardware-verified]**. What that
pair can *do* still differs by generation — see the table below.

### What each generation can deliver

| `WhoopHardwareGeneration` | High-rate motion | Delivered | For time the app was not running |
| :--- | :--- | :--- | :--- |
| `.whoop4` | **100 Hz, 6-axis** [reported 4.0, hardware-verified] | live stream only | **1 Hz accel** from the §4 drain — coarser, not absent |
| `.whoop5` / `.whoop5MG` | **100 Hz, 6-axis** [reported 5.0, hardware-validated] | live packet 43, *and* banked in flash | **100 Hz** — the same buffer is in the flash |
| `.standardBleHR` | none | — | — |
| `.simulator` | synthesised | — | — |

The top two rows are the straps a user can add — `WhoopHardwareGeneration.selectableModels` is exactly
`.whoop4`, `.whoop5` and `.whoop5MG` — and they are the rows the worn-and-recording assumption covers.
**That assumption applies to whichever of them is connected, and only one is at a time**, so these
rows are a per-generation statement about what a strap records, not a claim that three are on a wrist
together. The bottom two are transports rather than straps: a third-party heart-rate belt has no
motion sensor to record with, and the simulator's motion is generated by this app. Neither is a wrist
the app can assume anything about, and neither is offered in the picker.

**Assume the band is worn and recording — on every generation, including the 4.0.** That is the right
default and it is what makes the strap the producer: a strap on a wrist records motion continuously
whether or not a phone is nearby, and that record survives on board until the next connect.

**What differs by generation is the resolution of what survives, never whether anything does.** Read
the table's last column that way, because it is the column easiest to misread: it says what this app
can come back for, not what the strap was doing. A 4.0 records at 100 Hz and streams it, while its
flash keeps a 1 Hz accelerometer rollup — so a window the app missed comes back **coarser**, not
absent. A 5.0/MG banks the full 100 Hz buffer, so the same window comes back whole. The 4.0 records at 100 Hz but banks only a 1 Hz accel rollup, so its high-rate detail is perishable rather than absent. Every strap holds history for the
retention window §4 states — the 5.0 and the MG share a row here but are two separate straps, and
neither has been shown to behave like the other — and on any of them a gap in this app's data is a gap
in this app's coverage.

**The backlog is per strap, and only one strap is reachable at a time**, so history on a band the app
is not connected to waits for that band's own connection. A user who rotates between three straps
therefore has three separate backlogs rather than one, each bounded by its own retention window — which
is the practical reason §4's retention window matters more to this app than to a single-strap one.

### The R18 step counter: a pedometer field in the historical record, and the only one not captured here **[reported 5.0]**

`R18` carries the strap's own pedometer beside the heart rate, and `StepCounterPayloadDecoder` reads
three fields out of it. **All three are the community reference's reverse-engineering (`docs/PROTOCOL_SENSORS.md` in that
project), not a capture on this strap**, and that provenance is the point: a wrong offset decodes a
plausible number, so the decoder is guarded by the record's exact identity and the writer logs its
first sample.

| Frame offset | Payload offset | Width | Field |
| ---: | ---: | :--- | :--- |
| 57 | 46 | `u16` LE | cumulative "selected step/motion counter" |
| 59 | 48 | `u16` | cadence-like raw value; **not** a steps-per-minute figure and read by nothing |
| 61 | 50 | `u16` | the hardware counter while a software override is active; zero otherwise |
| 63 | 52 | `u8` | activity class: `0` still, `1` walk, `2` run; other codes are `FF` and treated as unknown |
| 64 | 53 | `u8` | `0x10` when the software counter override is active, otherwise zero |

**The counter is cumulative, not a daily total.** It climbs while the strap moves, holds flat while
still, wraps at 65,536 and can restart on a reboot — so a count is the sum of wrap-aware differences
between consecutive records (`docs/ALGORITHMS.md` §7), never the value or a low byte. **The source
byte exists because the firmware can change which counter `57` is**; a delta across that change is
subtracted one instrument from another and is dropped. **Neither counter is established as equal to
the official app's step count**, and the record's cadence byte is not a cadence.

`StepCounterPayloadDecoder` requires the 5.0/MG envelope, the historical packet type, layout selector
`18`, an exact 109-byte payload, and a stamp at or after 2020-01-01 — the `v24` cutoff, because a
lost RTC stamps history in 2000 and a counter filed there is steps no screen can draw. The one-shot
`step_counter` diagnostic records the first decoded sample of each connection.
Whether a strap's retention clock advances while it is off the wrist, or only while it is recording,
is part of what §7 Q10's capture settles; nothing in hand says.

### Implementation status **[repo]**

**Motion now reaches this app on all three straps, through two transports that converge on one
producer.** `MotionPayloadDecoder` walks both layouts, dispatched by generation and never by trying
one and falling back; the result is a `MotionBatch` — a hundred samples per axis with the record's own
start instant — which is what `StepAccumulator` counts peaks from and what `TrackStepsUseCase` writes
to `stepCounts` as one row per day. **The 5.0/MG's own counter is a second step source**, read from the same drain's `R18` records
and preferred where it exists.

| Generation | Transport | Record | Status |
| :--- | :--- | :--- | :--- |
| `.whoop4` | live | `0x2B` / 43, R10, payload 1910 | **live-only**, by design: the 4.0's flash holds the 1 Hz type-24 rollup and no high-rate buffer, so its step path runs only while the app is connected |
| `.whoop5` / `.whoop5MG` | banked | 47, R21, payload 1229 (frame 1,244) | through §4's drain — **dropped by the step writer**, which takes the day from the counter instead; `RecordMotionUseCase` still consumes it for sleep |
| `.whoop5` / `.whoop5MG` | live | 43, R21, payload 1229 (frame 1,244) | the same buffer streamed, and the detector's only input |
| `.whoop5` / `.whoop5MG` | banked | 47, R18, payload 109 (frame 124) | **the strap's counter at frame 57, class at 63, source at 64** — `StepCounterPayloadDecoder`, §6's counter subsection. The community reference's offsets; **not captured here** |

**The two layouts are frame-absolute and the origins differ, which is the decoder's one real trap.**
§6's `R21`/`R10` offsets are measured from the **frame's** first byte, while `WhoopRawFrame.payload`
begins at `innerOrigin + innerPrefixBytes` — **11** under the 5.0/MG envelope and **7** under the
4.0's. `MotionPayloadDecoder` subtracts that origin while keeping this section's numbers verbatim, so
a reader comparing the two side by side sees an off-by-eleven that looks like a broken decoder and is
not. Both layouts also **require an exact payload length** (1,229 and 1,910) and return `nil`
otherwise, because a short payload is a truncated record rather than a smaller one. **The 1,244 in
§2 and §7 Q4 is R21's *frame* length, not its payload**: a 5.0/MG type-47 record spends 15 bytes on
the envelope (8 header + 3 prefix + 4 CRC32 trailer), which is the arithmetic every payload in this
document obeys — R18's 124-byte frame carries 109 bytes and R20's 2,140-byte frame carries 2,125.

**A day the strap did not measure gets no row, and the count is stored rather than computed on read.**
A full day at 100 Hz × 3 axes is ~26M samples, so `StepAccumulator` runs incrementally and
`stepCounts` keeps the running total per day; `hasMeasurement` is `measuredSeconds > 0`, which is what
separates a measured day of no walking (a real `0`) from a day with no row at all.

**What none of this is: evidence about hardware.** The layouts are pinned against hand-built frames,
the pedometer against synthetic waveforms, and `biometric_samples` holds zero rows in every database
on this machine. No strap has answered any of these frames, and §7 is the plan that would settle it.

### Two things a motion consumer must not do

**Do not read `accelerationMagnitude` as the strap's motion — and note that it is `nil`, not zero.**
`BiometricSample` carries `accelerometerX/Y/Z` as optionals and computes a magnitude from them, but
the `0x2A37` heart-rate decode path constructs samples with a timestamp, a heart rate and R-R
intervals and nothing else, so **the magnitude is `nil` on every sample that path produces**. Only the
mock manager fills the axes on a sample.

**The strap's accelerometer is read, and it does not come through that path.** §6's motion records
are decoded by `MotionPayloadDecoder` into a `MotionBatch` — a batch of a hundred samples per axis,
carrying its own start instant — and never become `BiometricSample` rows: they feed
`TrackStepsUseCase` and land in `stepCounts` as one count per day. So the paragraph above is about the
heart-rate path's samples and not about this app's reach into the strap; the two are separate
producers with separate tables. What remains true is that **nothing here has been seen on hardware** —
the motion layouts are pinned against hand-built frames, and no strap has answered any of them.

**`accelerationMagnitude` must be `nil` when unmeasured, never a defaulted `0.0`.** Gravity is
inside the magnitude, so a motionless *worn* strap reads ≈1.0 G, and `0.0` is free fall — which a body
cannot produce. Worse, `0.0` sits on the **still** side of every movement threshold in this app, so a
fabricated zero did not read as "no motion was measured"; it read as "measured, and perfectly still",
which is the one answer a stillness gate must never be handed. The stress model therefore *refuses*
such a window rather than passing it, while the sleep classifier — whose motion tests sit beside a
decidable heart-rate band — *drops* the motion test instead of failing it. The two answers are
opposite on purpose, and a reader who "fixes" one to match the other breaks it.

**Do not let a per-generation difference collapse into a fallback.**
`WhoopProtocolProfile.profile(for:)` returns `nil` for the standard strap and the simulator, and the
encoder returns no frame rather than a 4.0 one. A motion path follows the same rule: a generation
whose records this app cannot walk gets no motion decoding, because a 4.0-framed read of a 5.0/MG
type-47 buffer would parse a length-selected payload as a fixed 96-byte record and produce numbers
from the wrong bytes.

**The 5.0 and MG profiles now exist, and they write as well as read.** A 5.0 strap's traffic is
*legible* — `decodeProprietaryFrame` validates a frame under either envelope — and the same profile
makes it *askable*: `WhoopPacketEncoder5` builds the frame and `syncOpcodes` carries the bytes, so a
5.0/MG motion path can negotiate the offload burst into existence.

**Motion has a reader, a walk, and on the 5.0 family a way to be asked for.** The two generations
arrived there by different routes, so read them separately.

**The 4.0's live path is implemented end to end.** `0x6A` / `0x3F` / `0x6B` are in the transmitted
set (§3), `motionEnableSequence` sends them in that order from `didDiscoverCharacteristicsFor` on
connect, `MotionPayloadDecoder` walks the R10 layout into a `MotionBatch`, and `TrackStepsUseCase`
accumulates it into a day-keyed row. **The 4.0 half of that is still uncaptured** — it says the command bytes match the references and
the walk matches §6's table, not that a 4.0 accepts the enable or answers with a record. The **5.0**
half has run: packet 43 carries `R21` and the step path consumes it (a counted walk read within a few percent,
and a day counter that keys on the arrival instant — see `MotionBatch.strapTimestamp`). What it also does not change: **R10 is streamed and
never banked**, so a 4.0 fills only the time the app was running with the strap connected.

**The 5.0/MG has a way to ask.** Its profile carries `syncOpcodes` and `WhoopPacketEncoder5` writes
its envelope, so `motionEnableSequence` produces a real two-frame sequence (`0x51` then `0x6A` —
§3), and `HistoricalDrainSession` is the loop that answers it. The layout is settled and walked:
`MotionPayloadDecoder` reads R21 out of a live type-43 frame and a banked type-47 one alike, so a
banked record reaches `MotionBatch` and `stepCounts` through the same code the 4.0's live path uses
— which is the whole reason the shared core is shared, and §7 Q9 is answered. **Both drained
heart-rate records are walked** — the 5.0/MG's `R18` and the 4.0's type 24, each through
`HeartRatePayloadDecoder` (§4) — and the `R18` walk has since run against real records: a drain on
the owner's 5.0 returned 59 of them, `type=0x2F layout=18 payload=109 B`, and they decoded and
stored. The 4.0's type-24 walk remains unexercised on hardware, as does `R21` from a **banked**
record — the motion captured so far has all been live.

That is also why **the payoff of the two routes still runs the way it does**: the 4.0 route is
reachable now and cannot cover an hour the app slept through, and the 5.0/MG route costs more to
reach and is the only one that can fill a night at the resolution the motion models want.

---

## 7. Open questions to settle by capture

Each of these is a question the sources disagree on, or that no source answers. The capture plan is
deliberately ordered so the cheap, high-leverage answers come first.

1. **Which 4.0 base UUID is real** (§1) — **answered and applied; no capture was needed.**
   `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` is what every independent reference uses, and
   `WhoopGATTConstants` carries it as of this revision. What a scan would still add is confirmation
   on this project's own hardware — worth having, given that a wrong UUID looks like no device at
   all, but not a question about which value is right.
2. **Which envelope does each strap actually speak** (§2) — capture the first frames each strap sends
   on connect and check the header CRC with `crc8` versus `crc16Modbus`, and the inner record origin
   at 4 versus 8. Three straps, three answers, and the 5.0/MG pair may not agree with each other.
3. **Does the 5.0 / MG record carry its own timestamp** (§4) — **answered: yes.** The published
   `HISTORICAL_DATA` schema carries `unix` u32 at record-relative `[7:11]`, the same field this
   document already documents for the 4.0, and its decoder reads it as real unix seconds with no
   wall-clock offset. What remains is narrower and still needs a frame: whether a **5.0** frame lays
   that record out at the 4.0's record-relative offsets, because the four-byte envelope shift is
   derived rather than observed and **no 5.0 frame carrying a historical-data record exists in any
   fixture in hand** — the 5.0 frames that do exist are the static `CLIENT_HELLO` (§2.1) and a
   checksum-verified command frame, and neither carries a record. **`HeartRatePayloadDecoder` already
   places drained R18 records on that derived shift** (payload `[4]`, frame 15); what a frame would
   add is confirmation of the placement rather than the placement itself — with the RTC caveat at Q7
   below attached, which is a separate failure and not a smaller one.
4. **What the real record size and header are, per strap** (§4) — **the 4.0 half is answered, and by
   more than the table above was built from.** 96 bytes is reported for 4.0 type 24, a real captured
   4.0 frame agrees with that table field for field, and an **implemented parser** now corroborates
   it at scale: the research reference's `parse_r24` gives the same offsets this section records — counter at
   `[3:7]`, `unix` at `[7:11]`, sub-seconds at `[11:13]`, heart rate at `[17]`, `rr_count` at `[18]`
   with the R-R intervals as i16 LE from `[19]` — and states they are "verified on 127,971 of our
   own stored records and cross-checked against an independent implementation", with the heart rate
   confirmed to match the live stream within a beat. It also gives a **minimum inner length of 89
   bytes**, which is a decodable guard this section did not have. So the walk is corroborated by a
   second parser that has run over real history rather than read off a table, and the three 5.0/MG
   type-47 sizes — `124` / `1244` / `2140` — are independently sourced: they are the fixed lengths
   of layouts `R18` / `R21` / `R20`, published in the 5.0/MG sensor reference and stated
   independently in the deep-data page. What is still unobserved is the *record header* on a 5.0
   frame, which is Q3's narrower question. **None of this is a capture on this project's hardware**,
   and the corroboration is of the *layout* — that a record can be decoded at all is still this
   app's first drain away.
5. **Whether the ACK token survives reconnection** (§4) — reported persistent for 4.0's cursor; the
   resume behaviour matters for a sync that runs on a phone that comes and goes. **The references
   answer this one by design rather than by measurement, and the design is the answer to copy:** the community reference
   does not rely on the strap's token outliving a disconnect at all, it persists its **own** cursor
   client-side so a resumed backfill continues from where its last one stopped. Nothing in either
   reference states that a token survives a reconnection, so the working assumption is that it does
   **not** have to — a client that stores what it has already drained is correct under both
   behaviours, and a client that trusts the strap's word is correct under only one. What a strap does
   with its own token across a reconnect stays a hardware question and is not worth spending a
   capture on before the client-side cursor exists.
6. **The full handshake**, per generation — §3 is 4.0-only and unverified, and 5.0's fixed
   `CLIENT_HELLO` is a different starting move entirely. **And whether a command can be written at
   all without BLE bonding**, which belongs here because it precedes the handshake rather than
   following it: one source reports every unbonded command answered by `PUFFIN_COMMAND_RESPONSE` with
   error `0x049c`, regardless of opcode, format or checksum, while the standard SIG services are
   separately reported to work **unbonded**. If that holds, both of §6's motion routes are gated on a
   bond this app does not establish — and note what it would *not* explain, since this app's live
   `0x2A37` heart rate is claimed to work unbonded. Cheap to settle: attempt one command write on an
   unbonded connection and read the response.

   **Read that report as single-sourced, because it is.** `0x049c` appears in exactly one project —
   the APK reading, whose `whoop-ble-protocol.md` states that unbonded commands return
   `PUFFIN_COMMAND_RESPONSE (0x26)` with error `0x049c` (1180) "regardless of command type, format, or
   CRC", while a bonded connection is accepted. A public code search finds that constant in the APK reading's
   docs and nowhere else: not in the community reference, which detects a refused bond through
   `CBATTError.insufficientEncryption` / `.insufficientAuthentication` instead, and not in the research reference.
   It is also **not a standard ATT code** — it is an application-level error in the Puffin payload —
   so it is not something a reader can look up.

   **And the APK reading's iOS half is weaker than it reads.** Its working iOS path is not a bond the APK reading
   creates: it is `retrieveConnectedPeripherals(withServices:)` **piggybacking on the bond the
   official WHOOP app already made**. Across the ecosystem, the platforms reported as able to
   *initiate* pairing are Android (`createBond`), Linux/BlueZ — and, on the community reference's own path, Apple too
   (next paragraph), so the claim that no third-party iOS app establishes its own bond no longer
   holds. Independently, the community reference observes that Apple's CoreBluetooth exposes **no link-encryption or
   bond state at all**, so a client cannot even ask whether it is bonded, and it records that its own
   unbonded-offload probe returned an inconclusive first result on real hardware rather than a
   refusal.

   **What the implemented 5.0 path does narrows it, and it cuts both ways.** The community reference's own `BLEManager`
   does attempt a bond from the app: on connect it writes the static 16-byte `CLIENT_HELLO` to the
   `fd4b0002` characteristic **`.withResponse`**, specifically so the write triggers the strap's
   **just-works bonding**. So a third-party client does reach for its own bond rather than only
   piggybacking — but the community reference labels the whole path **"EXPERIMENTAL"** and **"Unverified on real MG
   hardware"**, and its issue tracker is where the failure is described rather than its docs: an
   unanswered `CLIENT_HELLO` produces **no write error at all — the link simply drops**, which is the
   worst shape a failure can take here because it is indistinguishable from a strap going out of
   range. Repeated refusals latch a give-up in the client (a `HelloSuppressionStore`), after which the
   app stays on the standard-profile heart rate and reports itself as **not fully paired**; the
   recovery observed to work is **putting the strap into pairing mode by tapping it until the LEDs
   flash blue**. Two further facts about the ordering are worth carrying: the realtime heart-rate
   stream is armed **after** the bond, with the note that "writing it pre-bond on an unauthenticated
   link did nothing", and a 5/MG's `0x2A19` battery read is **refused** pre-bond. So the honest
   reading is not "iOS cannot bond" but "an implemented client tries, sometimes succeeds, and the
   failure mode is silent" — which is worse for this app than a refusal, because this app cannot
   distinguish a dropped link from a strap that is out of range.
7. **Is each strap's RTC actually right — and which `SET_CLOCK` length does its firmware latch?**
   (§3, §4) — **now two questions, and the second is the highest-value capture in this document.**
   The *field* is settled: `[7:11]` is a real u32 unix time. Whether its *value* is right is not, and
   a strap that has been flat reports `RTC_LOST` (event 13) and stamps a wrong clock, which misfiles
   history onto a **wrong day** rather than onto no day.

   The second half is the prerequisite, and it is cheap because it needs no drain: **write `SET_CLOCK`
   in each candidate length and watch whether the RTC actually moves.** The community reference records that a
   wrong-length set is **acknowledged but not latched** — and that a strap with an invalid RTC stops
   banking sensor data to flash altogether, so the symptom is a strap that looks connected while
   writing nothing. Published clients disagree on the length (4, 5, 8 and 9 bytes all appear in the
   wild), and the community reference's own resolution is to send both the 8-byte and 9-byte forms on 4.0 rather than
   choose. **Settle it per strap before building anything on top of the drain**, and expect the three
   straps to differ — the 5.0/MG's 8-byte form is the hardware-validated one, and its 9-byte form is
   unverified there. A clock read that returns success is not evidence the clock is right; the community reference notes
   a read failure can return zero time with a success result and no independent validity flag.
8. **What is the full packet-type enum per generation?** (§2) — eight roles now correspond exactly
   across the two columns once the radix is equalised, which is strong evidence the numbering is
   shared and the envelope is the only discriminator. The evidence covers eight values; a decoder
   that dispatches on a shared type byte needs all of them, and the aliases the 5.0 reference reports
   (37/38/56) have no 4.0 counterpart in hand. Capture a session per strap and tabulate every type
   byte seen.
9. **What is the sub-record layout inside the 5.0/MG IMU buffer?** (§6) — **answered; no capture
   needed.** The layout is `R21`, fixed at 1,244 bytes, and both the per-axis offsets and the units
   are published and reconciled byte-for-byte between two independent sources (§6). What remains is
   narrower and does not block a decoder: **the sample-timing rule**, since `seconds + fraction /
   32768` for the frame base with 100 samples spread evenly across the second is a stated convention
   rather than an observed one — and **what types 51 and 52 carry**, both described as IMU streams
   whose "current strap producer" is unconfirmed, with the community reference forbidding the `R10`, `R21` or
   `R22` layout being substituted for them. Capture settles both; neither gates reading packet 43.
10. **How far back does each strap's flash actually reach?** (§4) — the retention window this sync is
   designed against is **[assumed]** at fourteen days, and **the sources now disagree about it by a
   factor of five.** Two reverse-engineering projects state ~14 days (the community reference's README, "the strap's
   last ~14 days offload automatically"; andyguzmaneth/whoop4-ble, "~14 days of circular buffer,
   ~86,000 records per day", which is at least self-consistent at 1 Hz), and **neither measured it** —
   no project has drained to `HISTORY_COMPLETE` and read the oldest record's `[7:11]` against wall
   time. Against those, **WHOOP's own user-facing guidance says roughly 72 hours** of offline storage
   on the 4.0. So the figure is **sourced twice and contradicted once**, and the reverse-engineering number is the one with no measurement behind it. Design against the
   smaller number until the drain settles it. It is also among the cheapest questions here to settle, because it
   needs no new code and no decode — connect, drain to `HISTORY_COMPLETE`, and read how far back the
   first record's `[7:11]` reaches against wall time, which is the read **Q7 already requires**, so
   one drain answers both. **Ask it per strap**: nothing establishes that three generations of
   hardware share a flash size or a retention policy, and since **only one strap is connected at a
   time**, the answer decides how long each band may go unvisited before its own history starts being
   overwritten rather than merely waiting to be collected. Whether the limit is strap-side retention
   or a drain-side window, and whether that clock advances while a strap is off the wrist, are part of
   what the capture settles. **The ~72-hour figure is reported to be the 3.0/older-firmware number**,
   while current 4.0/5.0 firmware is reported at two weeks [reported, commercial] — a lead, not a
   measurement. **The cheapest capture is `GET_DATA_RANGE`, not a wear**: its 65-byte reply carries a
   write page and an acknowledged page, so two drains either side of a disconnected wear show whether
   the write page moved at all. The community reference's #689 diagnostic gives the indices and marks the 5.0/MG layout
   unconfirmed; `WhoopDataRange` decodes it for the log only. A write page that does not move is the
   observation that says this strap is not storing, which no retention window can explain.

11. **What is the drain request's body, and does it take a window at all?** (§4) — **answered by
   three implemented clients and one captured frame, and applied.** The body is a single `00` on both
   generations: the community reference's `BLEManager` sends `payload: [0x00]`, the research reference's `research_playground.py`
   builds `b"\x00"`, and that file carries the captured vector `aa0800a823041600c7c25288` annotated
   `0x16 [00]` — corroborated by the community reference's own doc. This app's eight-byte `[u32 start][u32 end]` window
   has been corrected to the bare byte at both builders and at §16. **What the capture still adds is
   confirmation on this project's own hardware**, since no implementation here has been run against a
   strap: one drain, and the question is only whether records arrive. Two sub-questions come free with
   the same drain, because the community reference's own 4.0 row is odd in both respects: it calls the delivery
   **type-47** where this document calls the 4.0 record `0x2F` type **24**, and its status is observed
   (`O / U`) rather than documented. Record the type byte of the first record to come back — that
   answers which is which for this strap, per strap.
12. **What does the 4.0's `0x6B` do — and is it the optical enable or a state read?** (§3, §5) —
   **the two references' *documents* disagree; their code does not, so what is left is a question
   about the byte's effect rather than its name.** The research reference reads 107 as `ENABLE_OPTICAL_DATA`,
   "wrist-gated optical (**the HR source**)", and builds its live example on it. The community reference's 4.0 column
   reads the same byte as `GET_IMU_DATA_STREAM` — body `[01]`, "Returns the stored IMU data-stream
   state" — and its 107 row warns that *"The WHOOP 5/MG identifier `ENABLE_OPTICAL_DATA` does not
   describe this WHOOP 4 operation."* **But the community reference's own enum names the byte `enableOpticalData` and
   no call site sends it**, so the read reading rests on the doc alone (§3's note has the sites),
   and the byte is sent as the research reference's two-byte `[01, 01]` — an enable under one reading, a `[01]`
   read with a trailing byte under the other, harmless either way. **The capture is cheap and needs
   no drain:** write `0x6B` with `[01, 01]` on a connected 4.0 and read the reply — a state byte or
   a stream coming up are different answers — then confirm whether live HR responds at all, since
   this app reads HR from `0x2A37` and may not need the frame. Note the 5/MG is a third answer
   again: its 107 is optical *session saving* on 50.42.1.0, its `ENABLE_OPTICAL_DATA` identifier is
   historical on that column too, and live optical output there is **108**.

The capture itself is the deliverable: drain once, record the raw frames, and decode from the
recording. **Do not decode from a live drain into a parser written from these notes** — a parser
built while watching a strap is tuned to its own bugs, and the recording is what lets a later
reading be checked against the bytes that produced it. §4's reassembler has closed one hazard behind
this advice (a coincidental `0xAA` does not read as a boundary, because the decoder's checksums
refuse it), and the ordering is unchanged: the frames are the evidence and the parser comes after.
The motion paths in §6 need a **separate recording on the 4.0**, because they are live-stream
traffic and will not appear in a flash drain at all — and that recording is worth more than this
document once assumed, since the layout is published and hardware-verified and what it lacks is only
an opcode and a payload walk on this side of the link. **The 5.0/MG is the opposite case, and this
document had it backwards**: layout 21 is banked, so a flash drain *is* the motion capture there,
and the separate thing that generation needs recorded is the enable sequence (`81` then `106`)
rather than the samples.

---

## Sources

This document cites other projects by **role rather than by name**. Each role has one file under
`docs/` holding that project's identity, its URLs, and verbatim excerpts of the pages this document
leans on — so a citation below can be traced in full without this document repeating anyone's
project name:

| Role | Where it lives |
| :--- | :--- |
| **the community reference** — the multi-platform client whose protocol, sensor and command documents §3's command matrix, §4's drain and §6's Gen 5 layouts come from | [`docs/noop/BLE_PROTOCOL.md`](noop/BLE_PROTOCOL.md) |
| **the research reference** — a 4.0 `PROTOCOL.md`, a 5.0/MG `PROTOCOL-GEN5.md`, and the sibling iOS client that actually syncs a strap | [`docs/OpenStrap/BLE_PROTOCOL.md`](OpenStrap/BLE_PROTOCOL.md) |
| **the APK reading** — a third independent reading, from WHOOP Android decompilation | [`docs/dofek/BLE_PROTOCOL.md`](dofek/BLE_PROTOCOL.md) |
| **the Swift 4.0 client** — the source of the 15 s silent-stream window | [`docs/Asherlc/BLE_PROTOCOL.md`](Asherlc/BLE_PROTOCOL.md) |

A role name is not a claim about quality. Where two references disagree this document says so and
carries both readings, and **a figure two projects repeat from each other is not two pieces of
evidence** — §7 is the list of what a capture would settle. **That rule has already caught one here:
the 4.0 client this document used to carry as a third, independent source turned out to be the research
reference under its former repository name** — GitHub redirects the old path to the new one and the two
share a repository id — so it is one project agreeing with itself, and it is now cited once, under the
research reference.

* **ITF Player Analysis Technology approval report PAT 25-025, for the WHOOP 5.0 and MG** — the
  `[filed]` source for the 5.0/MG sensor suite, including the "3-axis accelerometer and gyroscope"
  that §6's 5.0/MG hardware row rests on. Read it for what it is: a filing establishes **which sensors
  exist**, because the sensor list is the filing's subject and it is made under a duty of accuracy —
  and it says nothing whatever about the wire format.
  <https://www.itftennis.com/media/15583/whoop-pat-approval-report-pat-25-025.pdf>

None of these has been reproduced against this project's hardware. §7 is the list of what would
replace them.
