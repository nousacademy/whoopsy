# WHOOP 4.0 / 5.0 / 5.0 MG BLE Protocol Specification

Reverse-engineered Bluetooth Low Energy protocol for WHOOP hardware. Three straps are in scope and
**they do not share a wire format**: WHOOP 4.0 ("Harvard" / Gen 4), WHOOP 5.0, and WHOOP 5.0 MG
(Medical Grade). Which one a claim applies to is stated on every claim below.

## How to read this document

Nothing here has been captured on this project's own hardware yet. Every statement is tagged with
where it came from, and the tags are not decoration — most of the disagreements recorded below exist
because two sources were silently mixed in an earlier revision of this file.

| Tag | Meaning |
| :--- | :--- |
| **[captured]** | Observed on this project's own strap from a recorded session. **There are none of these yet.** |
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
constraint noop states, in its Swift source and in its `WHOOP5_DEEP_DATA.md`, is that the 5.0/MG
command characteristic needs an **authenticated SMP bond** which **macOS CoreBluetooth cannot
complete** — so on the host that barrier is not one a better encoder would clear. **What that
sentence does not say is that iOS can create one**, which is the half this document used to assume:
see Q6, where the ecosystem's evidence points both ways.

### The 4.0 base UUID is settled without a capture, and the ecosystem is what settled it

`61080001-8d6d-82b8-614a-1c8cb0f8dcc6`. **This document and `WhoopGATTConstants` now agree** — the
value is sourced rather than captured, because the ecosystem answers it: it is the base half in the
reference clients of half a dozen independent projects (noop's Swift, Kotlin and Python clients —
whose own `docs/BLE_REVERSE_ENGINEERING.md` maps the five characteristics — OpenStrap/research,
atria, Whoopless, WhoopBLE). One project dissents on the trailing service digit only, using `…0000`.

The half this file used to carry, `…82A5-4E40-1CA360B95B30`, is **unsourced**: it returns no hit in
noop, in OpenStrap, or in a public code search across GitHub. It has been replaced in the constant.
§1 of the suite pins these identifiers against the reference literals — not against the constants
they test, which is the distinction that matters here — so the substitution cannot silently reverse.

**Why it was worth a section anyway.** A wrong service UUID does not present as a decode error — it
presents as **no device found**. The scan filters on a service the strap never advertises, so the
peripheral is never discovered, no frame is ever decoded, and nothing downstream of discovery can
distinguish it from a strap that is switched off. It is the first thing to check when a scan finds
nothing, and the cheapest defect in this file to fix.

The 5.0 / MG base never had the problem — `fd4b0001-cce1-4033-93ce-002d5875f58a` agrees between the
document and the code.

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
envelopes — and only one of them on the write side.** Which one it uses for a given strap is a stored
choice rather than a guess: the device screen
(`Presentation/Screens/Device/DeviceDetailView.swift`) records the model per peripheral identifier,
and `WhoopProtocolProfile.profile(for:)` turns that into an envelope — or into `nil` for the standard
strap and the simulator, which every command writer refuses. The 5.0 and MG profiles *are* built, and
a frame arriving under either validates in `WhoopPacketDecoder` exactly as a 4.0 one does; what they
do not carry is a command opcode set, so no builder produces a frame for them. §3's implementation
status has the reasoning — read it before assuming the asymmetry is an oversight.

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
  fixed hello. **Its function is not a greeting — it is the bond trigger.** The reference writes it
  to `fd4b0002` **`.withResponse`** deliberately, because the write itself is what starts the strap's
  just-works pairing, and the realtime stream can only be armed afterwards. Its failure is silent:
  an unanswered hello raises **no write error**, the link just drops. §7 Q6 carries what that means
  for a third-party client.

### What that means for a single decoder

Three consequences, and the third is the one that bites:

1. **The header CRC algorithm is generation-selected** — `.crc8` versus `.crc16Modbus`. `CRCUtils`
   **[repo]** implements both plus `crc32`, and **all three are correct** — see §2.1, where they were
   checked against published reference vectors. `crc16Modbus` was for some time called from no
   production path at all, because no profile selected it; `WhoopProtocolProfile.headerChecksum` now
   selects it for the two 5.0 profiles and `WhoopPacketDecoder` takes one of two branches on that
   field. **The two branches are separate cases rather than one algorithm behind a boolean, and the
   difference is the input, not the polynomial**: CRC8 covers `[1, 2]` and CRC16-Modbus covers
   `[0 ..< 6]`, which reaches back over the start-of-frame byte and the format byte. A single
   function parameterised by "how many bytes" would have been right for both and would also have made
   the 4.0 case's input a number nobody could check against §2.1.
2. **The inner record origin moves from 4 to 8.** A decoder that reads `cmd` at a fixed offset is
   correct for exactly one generation. The length field moves with it — `[1..3]` under 4.0, `[2..4]`
   under 5.0, because 5.0 spends byte 1 on a format byte — and that pair is why
   `WhoopProtocolProfile` carries `lengthFieldOffset` and `headerChecksumOffset` rather than the
   decoder holding two sets of literals.
3. **The packet-type numbering was believed to differ by generation, and the belief was an artefact
   of radix.** The two references write the same numbering in different bases — the 4.0 reference in
   hex, the 5.0 reference in decimal — and every value below corresponds exactly:

   `0x23`=35 · `0x24`=36 · `0x30`=48 · `0x2F`=47 · `0x31`=49 · `0x2B`=43 · `0x33`=51 · `0x34`=52

   **Do not read "the values do not overlap" into this table.** It was written that way in an earlier
   revision, on the strength of the two columns looking different, and it is the exact failure the
   preamble warns about: two sources silently mixed. Eight exact correspondences across two
   independently written references is not coincidence, and the working assumption is now that the
   **type numbering is shared and the envelope is the discriminator** — which is what points 1 and 2
   above already require, since neither CRC nor record origin can be guessed from a type byte. §7
   carries the capture that would settle the full enum rather than these eight roles.

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
mechanisms.** The 4.0-enveloped schema keys its `HISTORICAL_DATA` on versions `24` / `12` / `5` / `7`
/ `9`; the 5.0/MG sensor reference names record layouts an `R` number — `R16`, `R17`, `R18`, `R20`,
`R21`, `R26`. The reference is explicit that the type alone identifies nothing — "R16 and R17 ECG use
a layout selector at byte 9" — and that **packet number, record layout, command number and event
number are separate namespaces**. The correction worth carrying is that the `24` / `12` / `5` / `7` /
`9` vocabulary belongs to a schema whose **envelope is the 4.0's** (`SOF` at 0, two-byte `length` at
1, `crc8` at 3, `packet_type` at 4, `seq` at 5), so it is not "the 5.0 reference's" and reading it as
a 5.0 version set beside 5.0 records is what this section used to do.

**The record lengths follow from the layout byte rather than forming a second, independent key.** A
5.0/MG type-47 record is fixed-length per layout — `R18` at 124 B, `R21` at 1,244 B, `R20` at
2,140 B — and all three are confirmed by two sources that agree with each other (§6, §7 Q4). The one
**length**-keyed discriminator either reference publishes is on a different type:
`REALTIME_RAW_DATA` (`0x2B` / 43) is selected at **1917 B** (6-axis IMU) and **1921 B** (optical)
under the 4.0's naming. A decoder that treats length as the primary key on type 47 therefore has the
relationship backwards and will read an `R20` optical record as an IMU buffer.

### 2.1 The checksum vectors **[repo, verified]**

Both references publish concrete frames, which makes the repo's CRC utilities checkable **today,
with no strap**. They were run against them and **all three are correct** — and since the framing was
corrected, all four are asserted in §1 of the suite rather than merely in a table here:

| Vector | Source | Expected | `CRCUtils` | |
| :--- | :--- | :--- | :--- | :--- |
| `crc8([0x08, 0x00])` | osr `PROTOCOL.md` §2 | `0xA8` | `0xA8` | ✅ |
| `crc8([0x10, 0x00])` | osr `PROTOCOL.md` §2 | `0x57` | `0x57` | ✅ |
| `crc16Modbus(5.0 hello[0..<6])` | noop `PROTOCOL.md` §2.2 | `0x71E6` | `0x71E6` | ✅ |
| `crc32(5.0 hello payload)` | noop `PROTOCOL.md` §2.2 | `0x8D5C3E36` | `0x8D5C3E36` | ✅ |
| `crc16Modbus(toggle hdr[0..<6])` | dofek `whoop-ble-protocol.md` | `0x41E7` | `0x41E7` | ✅ |
| `crc32(toggle payload)` | dofek `whoop-ble-protocol.md` | `0xFC61E958` | `0xFC61E958` | ✅ |

The 5.0 vector is the whole static `CLIENT_HELLO` frame, so it validates the envelope reading too:

```
AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D
│  │  └─ declLength u16 LE = 8      │  └─ crc32 LE = 0x8D5C3E36
│  │     (payload = declLength − 4) └─ payload [8..<12]
│  └─ format 0x01                         type=35 seq=1 cmd=0x91
└─ SOF                              crc16 LE = 0x71E6 over [0..<6]
```

**A second 5.0 frame is now in hand, and it is the more useful of the two** because it is a *command*
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
sharing its mistake. It cannot do that here, because **no builder in this app can construct a 5.0
frame at all** — see §3's implementation status. The toggle frame's two checksums are currently
verified against those utilities by hand rather than by assertion, and are the obvious next pair to
pin.

**The defect was not in the arithmetic — it was in what `buildPacket` fed it, and that is now fixed.**
The 4.0 format specifies CRC8 over **the two length bytes only** (`raw[3] == crc8(raw[1:3])`), and
`buildPacket` used to compute `crc8([cmd, lengthLow, lengthHigh])` — three bytes, with `cmd`
prepended — so every command frame the app sent carried a header checksum the format does not agree
with. The input is now `Data([lengthLow, lengthHigh])`: ping declares length **7** and writes
`0x6B`, the haptic alarm declares length **9** and writes `0xBD`. Both are the length bytes' own
checksum and not the command's, which is the whole of the rule.

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

The 4.0's twelve:

| Opcode | Field | Builder | Purpose |
| :--- | :--- | :--- | :--- |
| `0x05` | `liveTelemetry` | `enableLiveTelemetry` | enable/disable live telemetry |
| `0x10` | `hapticAlarm` | `hapticAlarmCommand` | haptic alarm |
| `0x20` | `ping` | `pingCommand` | ping / keep-alive |
| `0x16` | `requestHistoricalSync` | `WhoopCommandFrames.historicalSyncRequest` | the drain's request — **`0x30` until the ACK loop landed; see §4** |
| `0x6A` | `toggleIMUMode` | `motionEnableSequence` | IMU on/off — **one byte on the 4.0**, `[01]` to enable and `[00]` to stop. The two-byte form is real but belongs to the optical and persistent toggles; OpenStrap's `TWO_BYTE_TOGGLES` names those four opcodes and excludes this one, and noop's 4.0 branch sends `[0x01]` while giving its 5/MG the two-byte selector. §6's `[1,1]` is the *5/MG's* shorthand — do not carry it back to the 4.0 |
| `0x3F` | `sendRealtimeMotion` | `motionEnableSequence` | start the live 100 Hz motion record — body `[01]`, from noop's implemented `sendR10R11Realtime` (hardware-verified) and OpenStrap's `cmd_send_r10_r11` |
| `0x6B` | `enableOpticalData` | `motionEnableSequence` | body `[01, 01]` — OpenStrap's running client reads it as wrist-gated optical (the HR source) and this app followed that; noop's 4.0 *doc* says it *returns* the stored IMU stream state, while noop's own enum uses `enableOpticalData` and never sends it. See the naming note below |
| `0x0A` | `setClock` | `setClockFrames` | SET_CLOCK, both firmware lengths |
| `0x14` | `abortHistoricalTransmits` | `abortHistoricalTransmits` | stop a drain |
| `0x21` | `setReadPointer` | — | move the flash cursor |
| `0x22` | `getDataRange` | — | the range canary |
| `0x17` | `historicalDataResult` | `historicalDataAck` | the per-batch ACK |

**106 and 107 are where the two references disagree — and noop disagrees with itself about 107.** The
two columns of noop's command matrix give these bytes different names from OpenStrap's table, and for
107 the difference is not a label but what the byte is *for*. **noop's own implemented enum is a third
column, and it takes OpenStrap's side of the name**:

| ID | OpenStrap/research **[reported 4.0]** | noop's command doc **[S · 41.17.6.0]** | noop's implemented enum |
| :--- | :--- | :--- | :--- |
| 106 / `0x6A` | `TOGGLE_IMU_MODE` ("live IMU"), body `[01]` | `SET_IMU_DATA_STREAM`, body `[01, state]`, state `0`/`1` — **"Sets the stored IMU data-stream state"** | `toggleIMUMode = 106`, sent as `[0x01]` on a 4.0 and `[0x01, 0x01]` on a 5/MG — **the doc row's two-byte form is the 5/MG's, and noop's own code is what says so** |
| 107 / `0x6B` | `ENABLE_OPTICAL_DATA` — "wrist-gated optical (**the HR source**)", body `[01, 01]` | `GET_IMU_DATA_STREAM`, body `[01]` — **"Returns the stored IMU data-stream state"** | `enableOpticalData = 107`, **never sent by any call site** |

**The width question on 106 is settled too, and by the same client that frames the optical opcodes.**
OpenStrap defines `TWO_BYTE_TOGGLES` — "opcodes that take the special TWO-byte
`[REVISION_1=0x01, enable]` payload", with the failure it prevents spelled out: *"Sending a single
`[0x01]` is read as `[revision, <missing enable>]` → no data flows."* Its members are
`ENABLE_OPTICAL_DATA`, `TOGGLE_OPTICAL_MODE` and the two persistent toggles, and **`0x6A` is not among
them** — every call site builds `bytes([0x01 if on else 0x00])`. noop's 4.0 branch agrees, sending
`[0x01]` where its 5/MG gets `[0x01, 0x01]` under a comment that calls the two-byte form *"the two-byte
realtime IMU selector"*. So noop's doc row is the only voice claiming a two-byte 4.0, and noop's own
code is against it: **the two-byte `[1, 1]` this app sent on a 4.0 was the 5/MG's payload**, and the
4.0 now sends `[01]`.

**The read reading is the command doc's alone, and the code beside it contradicts it.**
`Strand/BLE/Commands.swift` names 107 `enableOpticalData` — OpenStrap's name, and this app's — and no
call site in that client sends it: noop's live-IMU path is `startRawData` plus 106 and nothing more. So
noop's `GET_IMU_DATA_STREAM` is a 4.0-column refinement its own enum does not carry, and OpenStrap's
reading is not outvoted. What noop's doc does establish, and this app follows, is that **107 carries a
body on a 4.0** — where this app used to send none. Its 107 row carries the warning *"The WHOOP 5/MG
identifier `ENABLE_OPTICAL_DATA` does not describe this WHOOP 4 operation"*, and its transport profile
treats live HR as the standard GATT service and keeps it "separate".

**Both readings are now served by the same byte, which is why nothing is waiting on the resolution.**
`[01, 01]` is OpenStrap's enable form, so an enable starts the optical path live HR depends on; under
noop's reading it is a `[01]` read with a trailing byte, which starts nothing and is harmless either
way. **§7 Q12** carries the capture that separates them — write `0x6B` with `[01, 01]` and read the
reply — and the question it settles is what 107 *does*, not what to send. **OpenStrap's section is
emphatic about its reading** ("Live HR is optical/PPG-derived — no optical, no HR") and builds its live
example on it, which is why the enable is the interpretation this app acts on. **The 5/MG's own 107 is not the live-optical enable its name
suggests either**: noop's configuration contract records that on 50.42.1.0 the operation is **optical
session saving**, that "the identifier is historical", and that live optical output is **108** — so
`ENABLE_OPTICAL_DATA` is a legacy label on both columns and not a description of the current
operation on either.

The 5.0/MG's twelve, under their own envelope. **Two of these are the 4.0's numbers and ten are not**,
which is the whole reason the table is a separate type:

| Opcode | Field | Builder | Purpose |
| :--- | :--- | :--- | :--- |
| `0x91` / 145 | `hello` | `WhoopPacketEncoder5.hello` | §2.1's published 16-byte frame |
| `0x16` / 22 | `requestHistoricalSync` | `historicalSyncRequest` | the drain's request — **shared numbering with the 4.0** |
| `0x17` / 23 | `historicalDataResult` | `historicalDataAck` | the per-batch ACK — **shared numbering** |
| `0x22` / 34 | `getDataRange` | `getDataRange` | the range canary — shared numbering |
| `0x14` / 20 | `abortHistoricalTransmits` | `abortHistoricalTransmits` | the drain's stop — **shared numbering** |
| `0x21` / 33 | `setReadPointer` | — | move the flash cursor — shared numbering |
| `0x51` / 81 | `startRawData` | `motionEnableSequence` | start the raw-data producer |
| `0x52` / 82 | `stopRawData` | `motionEnableSequence` | stop it |
| `0x69` / 105 | `toggleIMUModeHistorical` | — | the IMU toggle, historical form |
| `0x6A` / 106 | `toggleIMUModeLive` | `motionEnableSequence` | the IMU toggle, live form — §2.1's published frame |
| `0x92` / 146 | `setClock` | `setClock` | SET_CLOCK |
| `0x93` / 147 | `getClock` | `getClock` | GET_CLOCK — **the read-back, and the 4.0 has no counterpart** |

**Four of the 5.0's twelve were missing until the drain's ACK loop landed, and the way they were
missing is the part worth keeping.** The table's earlier form asserted that six of the 4.0's roles had
*no published 5.0 byte at all*, and that claim was false for `0x14` and `0x21`: the noop catalog
enumerates every ID from 1 to 159 once, bounds its 5/MG column to firmware 50.42.1.0, and marks both
supported under the same names the 4.0 uses. **Omitting a published opcode is its own error rather
than a safe default** — it left the drain's only stop with no byte to send, and the builder that
should have sent `0x14` sent `0x52 STOP_RAW_DATA` instead, which stops the producer and leaves the
drain walking. A name is not an opcode this build may send; but a *published* opcode left out of the
table is a byte nothing can assert about. The two generations' remaining differences are real and are
not this kind: `liveTelemetry`/`hapticAlarm`/`ping`/`sendRealtimeMotion` are 4.0-only under those
names, and the raw-data pair (`0x51`/`0x52`) is the 5.0's way of doing what `0x3F` and the
telemetry verb do there — which is coverage under other names rather than a gap. **106 and 107 are
not that kind of difference**: both generations have both, under names that disagree, which is the
naming note above rather than a missing opcode.

**`None of this sequence is implemented`** still holds for §3's eight steps: there is no CLIENT_HELLO,
no feature-flag negotiation, and the clock synchronization and ACK loop exist as builders and a
session rather than as a completed handshake. What *is* built is the motion enable, sent from
`didDiscoverCharacteristicsFor` on connect, and the drain — §4 carries its status.

**The 4.0's live enable is three ordered frames** (`0x6A` `[01]`, then `0x3F` `[01]`, then `0x6B`
`[01,01]`), all or nothing. **All three now carry a body, and `0x3F` and `0x6B` did not before** —
they were sent bare on the reasoning that the references named the opcodes and stopped, which the
references' own running clients disprove: noop sends `[0x01]` for the realtime record (documented
on-device, "2.1/s → 0/s"), and OpenStrap sends a two-byte `[revision, enable]` for the optical one. A
bodyless `0x3F` is the shape that matters most, because it starts no live record — which is the
stream the step counter reads. **The toggle's width moved the other way and is the one byte here that
got narrower rather than wider**: `0x6A` is an IMU verb, and the two-byte `[revision, enable]`
convention belongs to the optical and persistent toggles (see §3's note). The 5.0's is two (`0x51`
then `0x6A`), and **that ordering is the
reference's rather than this app's** — noop's configuration contract states that the live-IMU
sequence "starts raw production before enabling live IMU transport", with stopping production and
disabling that transport as separate cleanup operations. The one open half left in the 4.0's three is
what `0x6B` *does*, which is the naming note above and §7 Q12.

**Every one of those frames is written in the §2 envelope**, which none of them were before: the
header CRC8 is over the two length bytes, `length` is the inner record plus four, and the inner
record is `[type][seq][cmd][payload…]` with the CRC32 over the whole record. Nothing has been
captured on hardware, so this says the frames match both references — not that a strap accepts them.
Three properties are new and all are enforced in code rather than described here: the decoder verifies
the header and payload checksums on inbound frames and refuses anything that fails (§2), the
generation decides which envelope is used at all, and **`buildPacket` now tests the envelope alone** —
the opcode-table half of its old guard was doing no work, since the table is read by the *builders*.
Each 4.0 builder applies `fourEnvelopeOpcodes`, which asserts both the table and the envelope, so a
builder cannot assemble a 4.0-framed command under a 5.0 header.

**Reading a generation and writing to it are separate capabilities, and the fields that carry the
distinction are the two opcode tables.** `WhoopProtocolProfile` holds `commandOpcodes: CommandOpcodes?`
and `syncOpcodes: SyncOpcodes?`; the 4.0 populates the first and the 5.0/MG the second, and
`canTransmitCommands` is `commandOpcodes != nil || syncOpcodes != nil`. It is what every builder and
`WhoopBLEManager.sendCommand` consults, and it is deliberately **not** the envelope: this app
**validates inbound 5.0 frames** (§2), so a guard on the envelope would have started permitting 5.0
writes the moment the decoder learned to read them — right about nothing and wrong about why.

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
specific blocker: its command characteristic needs an authenticated SMP bond, which noop reports
**macOS CoreBluetooth cannot complete** — and **nothing establishes that iOS can**, since no project
demonstrates a third-party iOS app bonding a WHOOP and the one reported iOS success reuses the bond
the official WHOOP app already made. `DeviceDetailViewModel.protocolCaveat` carries both sentences;
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
number a decoder needs that the table did not carry.** OpenStrap's `parse_r24` reads the same fields
at the same offsets — counter at `[3:7]`, `unix` at `[7:11]`, sub-seconds at `[11:13]`, heart rate at
`[17]`, `rr_count` at `[18]`, then the R-R intervals as **i16 LE milliseconds** from `[19]`, and the
accelerometer triplet at `[36:48]` — and reports that the layout is "verified on **127,971 of our own
stored records** and cross-checked against an independent implementation", with the heart rate
confirmed to match the live stream **within one beat**. It also states a **minimum inner length of 89
bytes**, which is the guard this table lacked: a record shorter than that cannot hold the fields below
`[88]`, so a walk should refuse it rather than read past its end. Two smaller facts from the same
parser are worth carrying because both bound a decode: **`rr_count` is `0`–`4`**, so the R-R loop is
bounded and does not need to be driven by the record's length, and **the strap's `[51]` is a contact
*quality* (`0`–`198`) and not a wear flag** — the natural misreading of that field is the one the
reference calls out. Two things this does *not* change:
the confidence tags above are the 4.0 reference's own and are left as they were, because a second
parser agreeing is corroboration rather than a new source; and **none of it is a capture on this
project's hardware**. What it does change is that the record walk is no longer a design against a
table — it is a design against a layout that a running client has decoded a hundred thousand times.
The R-R intervals are the field worth noting for this app in particular: they are what
`biometric_samples.rrIntervalsMs` holds and what no strap has ever filled (§5), so a drain is the
only path by which a stored R-R series — and with it a real HRV, respiratory rate and within-sleep
stress figure — could exist at all.

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

**Correcting the clock is a prerequisite for the drain, not a refinement of it, and the reason is
that `SET_CLOCK`'s payload LENGTH is firmware-specific and load-bearing.** noop ships **two** 4.0
forms rather than one, and its source states why in as many words:

| Form | Payload | Latches on |
| :--- | :--- | :--- |
| Current, 8-byte | `[seconds u32 LE][subseconds u32 LE]`, subseconds in 1/32768 s (0 is fine) | newer WHOOP 4 firmware; the 5.0/MG's hardware-validated form |
| Legacy, 9-byte | `[seconds u32 LE][5 × 0]` | WHOOP 4 fw 41.17.x, which **ignores the 8-byte form outright** — no `COMMAND_RESPONSE`, RTC unchanged |

The failure mode is what makes this worth a section of its own: **a set that is the wrong length for
the firmware is acknowledged but not latched**, so the RTC stays invalid — and a strap with an
invalid RTC **stops banking sensor data to flash entirely**. noop records the symptom as "endless
console-only syncs and no sleep/recovery", which is a strap that looks connected and productive while
silently writing nothing. Its client therefore sends **both** forms on 4.0, because each is a no-op on
the other's firmware and both carry the same `now`, so double-latching is harmless.

Two things follow for this document. **The length is not settled across the ecosystem** — forms of 4,
5, 8 and 9 bytes all appear in published clients, and four independent projects corroborate the
silent-failure mode, which is why noop's belt-and-braces approach is the shape to copy rather than
picking one. And **this app sends no `0x0A` in any form**, so the prerequisite is absent: a drain
built on top of it would come back empty on a strap whose clock is lost and would present that as
*history does not exist* rather than as *the clock is wrong*. §7 Q7 is where the length gets settled
per strap.

**[reported 5.0]** The 5.0 / MG record is the **same type** — `0x2F`, 47 — with a layout selector at
`inner[1]` choosing a schema that inherits from a base layout via a `ref` chain (V12 → V24, …), and
that byte is what the 4.0 table above calls the record's "record type" and which reads `24` on a real
captured 4.0 frame. Its decoded keys are `hist_version`, schema-versioned biometric fields and
`rr_intervals`.

**Which source is which, because this section previously conflated them.** The `hist_version` /
`ref`-chain schema is published in a machine-readable file whose **envelope is the 4.0's** — `SOF` at
0, two-byte `length` at 1, `crc8` at 3, `packet_type` at 4, `seq` at 5 — so its `24` / `12` / `5` /
`7` / `9` vocabulary is a **4.0-enveloped** version set, not a 5.0 one. The 5.0/MG source proper is
`PROTOCOL_SENSORS.md`, which names record layouts `R16` / `R17` / `R18` / `R20` / `R21` / `R26` and
gives each a fixed byte length. Both describe the same selector byte under different names, and §2
carries the reconciliation.

**It does carry a per-record timestamp, and it is this section's field.** The schema places `unix` as
a u32 at frame offset **11**, described as real unix seconds; its offsets are frame-absolute from the
start-of-frame byte, so 11 is record-relative `7` — exactly this section's `[7:11]` — and frame 15
under the 5.0 origin. One field, written in whichever frame the strap speaks. The reference's own
type-47 decoder reads that key first and comments that the record carries a **real unix timestamp and
no wall-clock offset**, so §7 Q3 is answered in the affirmative. What a capture still settles is the
narrower question: whether a 5.0 frame lays the version-24 record out at the same **record-relative**
offsets the 4.0 one does. **No 5.0 frame carrying a historical record exists in any fixture in hand**
— the two 5.0 frames that do exist are a handshake and a command (§2.1), and neither carries one — so
the four-byte shift is derived from the envelope and not observed.

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
  optical (OpenStrap's name for `0x6B`; noop reads that byte as a state read — §3) and never sends
  `0x9A` casually.

Two more live-path opcodes belong here for completeness, since §5's live producer depends on them:
`0x03 TOGGLE_REALTIME_HR` and `0x6B` — which **OpenStrap** names `ENABLE_OPTICAL_DATA` and calls
wrist-gated optical, **the HR source**. **noop's 4.0 column disagrees and calls the same byte
`GET_IMU_DATA_STREAM`, a state read** — though noop's code names it `enableOpticalData` and never
sends it, so the disagreement is between the two references' documents rather than their clients
(§3's naming note has all three readings). This app uses the standard `0x2A37` GATT characteristic
instead (§5), which is a different route to the same quantity and the reason it needs no proprietary
command to start — and which is noop's own account of where live HR comes from.

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
§7 Q10 is the one drain that settles it. Two consequences hold
whatever the true figure turns out to be. **A fresh connection is the trigger** — the right default on
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
| Inbound record type | `0x2F` counted toward the batch; the record layout itself is unwalked (see below) | `0x2F` | 47 |
| ACK loop | `0x17` + the 8-byte token, per batch | `0x17` + 8-byte token | `0x17` + `end_data`(8) |
| Batch ending | `HISTORY_END` acknowledged, `HISTORY_COMPLETE` not | metadata `0x31`, sub-type at `inner[2]` | 49, same sub-type offset |
| Record layout | **no walk for the type-24 record** — the raw inner record is handed up undecoded. The *motion* layouts **are** walked (`MotionPayloadDecoder`, §6), and those are what the step path reads | 96-byte header | version-selected schema |

**The request body is one `00` byte on both generations, and this app used to send eight.** It
composed a `[u32 startEpoch][u32 endEpoch]` little-endian window; that window was this codebase's own
invention and it has been corrected at both builders. **Four sources agree on the bare byte, three of
them code that runs**, which is why this is a correction rather than a judgement call between two
readings:

| Source | Kind | 4.0, ID 22 | 5.0/MG, ID 22 |
| :--- | :--- | :--- | :--- |
| noop `BLEManager.swift` | **implemented** | `send(.sendHistoricalData, payload: [0x00])` | same builder |
| noop `docs/PROTOCOL_COMMANDS.md` | documented, observed | request body **`00`** — "observed working in device captures on 41.17.6.0, outside the documented command set" | "Older requests use explicit **`00`** for each operation"; "Command 22 returns state plus two zero bytes" |
| OpenStrap `research_playground.py` | **implemented** | `build_command(seq, Cmd.SEND_HISTORICAL_DATA, b"\x00")` | — |
| OpenStrap, same file | **captured frame** | `aa0800a823041600c7c25288` annotated `0x16 [00]` | — |

**The eight-byte shape this app copied belongs to the reply, and it runs the other way.** ID 23's body
is `01` plus the exact eight-byte `HISTORY_END` block — which noop calls **opaque** and warns against
reconstructing ("never reconstruct the opaque second word") — and `inner[13:21]` on the 4.0 / payload
`[6,14)` on the 5.0 is where the ACK above reads it. The widths coincided and the provenance did not:
the request had been built out of the reply's token, which no source supports. **Nothing selects a
range on this command**, and a window has somewhere else to live — `0x21 SET_READ_POINTER` seeks the
read cursor and takes a **u32 offset**, not an epoch pair.

**No "newer form" exists.** noop's "older requests use explicit `00`" contrasts an explicit `00` with
its builder's *default* payload, which is also `[0x00]` — both spellings are the same single byte, and
no start/end body appears in any reference for either generation. The frame lengths are where a
widening would show: **12 bytes for the 4.0 and 16 for the 5.0/MG**, each `header + 3 + 1 + 4`, so an
eight-byte body lands at 19 and 23 and §16 fails on both.

**One oddity stays on the record rather than being tidied away.** noop's 4.0 row for ID 22 describes it
as starting **type-47** delivery — the 5.0/MG record type, on a row whose records this document
elsewhere calls `0x2F` type 24 — and its status is `O / U`, observed rather than documented. That is a
question about the *reply*, not the request, and **§7 Q11** carries it; it needs no new decoder,
because a `00` body either delivers records or does not.

**`0x30` was `Asynchronous Event / Heartbeat` and its correction waited for the loop rather than
preceding it.** As an outbound command it was not a command at all — §2's own table says so — so an
outbound `0x30` asked a strap for an event rather than for a drain, which is a command it ignores.
That failure mode was benign, and the byte sat uncorrected because **a missing ACK makes the strap
re-send the same batch forever**: starting a drain this app could not acknowledge would have left a
strap looping, which is worse than sending a command it ignores. The byte moved when the ACK loop
landed, and it lives in the opcode tables rather than in the builders, so the correction was one edit
per generation rather than a search for a literal.

**The record layout is the one gap left, and it is narrower than it looks.** What the drain reads out
of the stream today is the batch structure — the records, the `HISTORY_END` that closes a batch and
carries the continuation token, and the `HISTORY_COMPLETE` that ends the drain — plus the motion
records, which §6's decoder walks and which are what produces a `MotionBatch` for the step path. The
type-24 heart-rate record's own 96-byte header is still not walked: `WhoopRawFrame` is handed up
validated and stops there, exactly as the order §7 sets out. `TODO.md` §5 carries it.

**The timestamp that would place a drained batch on a timeline is still verified as a field and
unverified as a value.** `[7:11]` of the type-24 record is a u32 unix time, but the strap's RTC is set
by `0x0A SET_CLOCK`, and the 4.0 reference's event enum carries type 13 `RTC_LOST` ("battery fully
died — clock reset") — so a battery-flat strap stamps every record with a wrong offset and nothing in
the record shows it. **That failure is silent in the worst way: it files history onto a wrong day
rather than onto no day.** A prerequisite for trusting any of it is sending `SET_CLOCK` first, which
is why `WhoopCommandFrames.setClockFrames` exists and why it sends **both** of the 4.0's lengths (see
§7 Q7: a wrong-length set is *acknowledged but not latched*) — and why **sending a clock set is not
the same as knowing it latched.** The 5.0's `0x93 GET_CLOCK` is the only read-back either generation
offers; it is sent, its reply is logged as an ordinary inbound response, and **no path in this app
decodes it or claims a clock latched.** §7 Q7 stays open.

Two defects that used to sit here are **fixed and have left this table**. The 16-byte walk through the
live layout is gone — `decodeHistoricalSyncPayload` and `decodeLiveTelemetryPayload` no longer exist,
and the decoder now returns the validated inner record as a `WhoopRawFrame` for a later parser to
walk, which is the order §7 sets out. And the encoder's `headerCrc`/length-byte mismatch is gone with
the framing rewrite in §2. What that buys is negative and worth stating as such: **the app can no
longer fabricate a reading from a record it does not understand**, which is what the old walk did by
reading a record-counter byte as a heart rate and writing it to `biometric_samples`.

Inbound CRCs **are** now verified — the header CRC8 and the payload CRC32, both enforced in
`decodeProprietaryFrame`, which refuses a frame that fails either. That closes the `0xAA`-in-payload
ambiguity at the frame level: a false boundary yields a frame that fails its checksum instead of
plausible garbage.

**Length-based reassembly is now implemented**, in `WhoopFrameReassembler`, and it was the remaining
half of that problem. Its absence was not a rejection but an invisibility: a notification carries at
most `MTU − 3` bytes while the 5.0/MG type-47 record runs to 2140 and the 4.0 live IMU stream to
roughly 1.9 KB, so `decodeProprietaryFrame` — handed one notification and requiring
`data.count >= declaredLength + 4` — returned `nil` for every frame that spanned a second one, and
the manager discarded that `nil`. The reassembler owns **boundaries, not validity**: it finds a start
of frame, reads the declared length **at the profile's own `lengthFieldOffset`** — byte 1 under 4.0,
byte 2 under 5.0 — holds bytes until that many have arrived, and hands the candidate
to the decoder, whose checksums remain the only thing that decides whether those bytes were a frame.
A candidate the decoder refuses is treated as evidence the `0xAA` it started on was a payload byte,
and the scan resumes one byte later — so a notification lost to a dropped link costs bytes and never a
reading. Two properties are consequences rather than tuning: a boundary declaring more than
`maximumFrameBytes` (4096, above every documented record shape) is skipped rather than waited on,
which is what bounds the buffer without a trim rule; and the buffer is **per-connection**, reset on
both connect and disconnect, since bytes held across a reconnect would be prepended to the new
stream's first frame and shift every field in it.

**There is still no local evidence either way.** The development database holds zero sample rows, so
nothing in it was ever written by this path, and no frame — split or whole — has been captured on this
project's own hardware. Correcting the framing makes the frames agree with both references; it does
not make a strap answer them.

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

The user assigns a model in Settings — `WhoopHardwareGeneration.selectableModels`, which is
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
`REALTIME_RAW_DATA` variant declaring **1917 bytes** carries **100 samples per axis at ~100 Hz** — one
packet per second per axis — as signed int16 **little-endian**: accelerometer X / Y / Z at frame
`89` / `289` / `489` at `0.000244140625` g/LSB (1/4096 g), then gyroscope X / Y / Z at frame `692` /
`892` / `1092` at `0.06103515625` deg/s/LSB (±2000 dps full scale), with the trailer from `1292`. Each
600-byte lane is contiguous and the two are separated by three bytes. The scales were verified against
a motion-capture reference and a controlled **720° rotation** respectively, on generation-4 hardware.
The 1928-byte / 100 Hz figures this section used to carry as second-hand are superseded: the length is
**1917 declared**, which is 1921 bytes of frame, and the layout behind it is published rather than
inferred.

**3. The layout-selected `R21` record — 5.0 / MG, 100 Hz, six axes, live *and* banked.**
[reported 5.0, hardware-validated] **This reverses what this section previously claimed.** The 5.0/MG
**does** have a live raw-IMU stream: layout 21 is carried by **live packet 43 and historical packet
47**, so the same 1,244-byte buffer is both streamed and banked. Three sources agree and none
dissents — the 5.0/MG sensor reference states the dual carriage outright, the deep-data page records
the enable sequence, and an independent APK-decompilation capture names packet `0x2B` / 43
`REALTIME_RAW_DATA` with the "Maverick R21 format" behind it. The previous claim that the 5.0/MG had
"no live raw-IMU stream at all" traces to no source in hand: it was this document's own inference
from an absence, and the absence was in the reference it was reading, not in the hardware.

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
(1g ≈ 4096 LSB)" — so the two agree, and the ±4 g reading this document once carried is exactly half
and would leave the top bit of every sample unused. The gyro's `2000/32768` is the same pairing at
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

**The feature names this section used to rest on are no longer load-bearing.** `gyroEnergyDps`,
`accelEnergyG`, `jerkRms`, `cadenceHz` and `cadenceStrength` came from a feature extractor whose
offsets were unverifiable from here; the layout above supersedes them, because a gyroscope reading in
degrees per second is now reproducible from published offsets and a published scale rather than from
a named feature. What survives is why the producer matters: six-axis motion at 100 Hz recoverable
from **banked** history, on a strap the app was not running beside. That the sensor pair
`PATENTS.md` §1.4's musculoskeletal family requires ("fused 3-axis accelerometer and gyroscope data")
is present on both generations is now established twice over and by different evidence: the 5.0/MG's
by the sensor suite the ITF filing lists **[filed]**, the 4.0's by the live raw layout above
**[reported 4.0, hardware-verified]**. What that pair can *do* still differs by generation — see the
table below — but neither strap is missing a sensor this section once had reason to think it might be.

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
absent. A 5.0/MG banks the full 100 Hz buffer, so the same window comes back whole. The 4.0 is
therefore not the strap that fails to record; it is the one whose high-rate detail is perishable,
which is a weaker claim than the one this section used to make. Every strap holds history for the
retention window §4 states — the 5.0 and the MG share a row here but are two separate straps, and
neither has been shown to behave like the other — and on any of them a gap in this app's data is a gap
in this app's coverage.

**The backlog is per strap, and only one strap is reachable at a time**, so history on a band the app
is not connected to waits for that band's own connection. A user who rotates between three straps
therefore has three separate backlogs rather than one, each bounded by its own retention window — which
is the practical reason §4's retention window matters more to this app than to a single-strap one.
Whether a strap's retention clock advances while it is off the wrist, or only while it is recording,
is part of what §7 Q10's capture settles; nothing in hand says.

### Implementation status **[repo]**

**Motion now reaches this app on all three straps, through two transports that converge on one
producer.** `MotionPayloadDecoder` walks both layouts, dispatched by generation and never by trying
one and falling back; the result is a `MotionBatch` — a hundred samples per axis with the record's own
start instant — which is what `StepAccumulator` counts peaks from and what `TrackStepsUseCase` writes
to `stepCounts` as one row per day.

| Generation | Transport | Record | Status |
| :--- | :--- | :--- | :--- |
| `.whoop4` | live | `0x2B` / 43, R10, payload 1910 | **live-only**, by design: the 4.0's flash holds the 1 Hz type-24 rollup and no high-rate buffer, so its step path runs only while the app is connected |
| `.whoop5` / `.whoop5MG` | banked | 47, R21, payload 1244 | through §4's drain — the path that works with no phone present |
| `.whoop5` / `.whoop5MG` | live | 43, R21, payload 1244 | the same buffer streamed |

**The two layouts are frame-absolute and the origins differ, which is the decoder's one real trap.**
§6's `R21`/`R10` offsets are measured from the **frame's** first byte, while `WhoopRawFrame.payload`
begins at `innerOrigin + innerPrefixBytes` — **11** under the 5.0/MG envelope and **7** under the
4.0's. `MotionPayloadDecoder` subtracts that origin while keeping this section's numbers verbatim, so
a reader comparing the two side by side sees an off-by-eleven that looks like a broken decoder and is
not. Both layouts also **require an exact payload length** (1244 and 1910) and return `nil`
otherwise, because a short payload is a truncated record rather than a smaller one.

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

**The strap's accelerometer is now read, and it does not come through that path.** §6's motion records
are decoded by `MotionPayloadDecoder` into a `MotionBatch` — a batch of a hundred samples per axis,
carrying its own start instant — and never become `BiometricSample` rows: they feed
`TrackStepsUseCase` and land in `stepCounts` as one count per day. So the paragraph above is about the
heart-rate path's samples and not about this app's reach into the strap; the two are separate
producers with separate tables. What remains true is that **nothing here has been seen on hardware** —
the motion layouts are pinned against hand-built frames, and no strap has answered any of them.

**The change from a defaulted `0.0` to `nil` is the whole point and is not cosmetic.** Gravity is
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

**The 5.0 and MG profiles now exist, and that changes what this rule is guarding.** They exist so a
5.0 strap's traffic is *legible* — `decodeProprietaryFrame` validates a frame under either envelope,
which is what makes a capture worth taking — and for nothing else. The 5.0 profiles carry **no command
opcodes**, so a 5.0/MG motion path cannot negotiate the offload burst into existence either.

**Motion now has a reader and a walk on this side of the wire, and on the 5.0 family it still has no
way to be asked for.** The two halves have moved in opposite directions, so read them separately.

**The 4.0's live path is implemented end to end.** `0x6A` / `0x3F` / `0x6B` are in the transmitted
set (§3), `motionEnableSequence` sends them in that order from `didDiscoverCharacteristicsFor` on
connect, `MotionPayloadDecoder` walks the R10 layout into a `MotionBatch`, and `TrackStepsUseCase`
accumulates it into a day-keyed row. **None of it has been captured on this project's own hardware**,
so this says the command bytes match the references and the walk matches §6's table — not that a
strap accepts the enable or answers with a record. What it also does not change: **R10 is streamed and
never banked**, so a 4.0 fills only the time the app was running with the strap connected.

**The 5.0/MG is no longer the side with no way to ask.** Its profile carries `syncOpcodes` and
`WhoopPacketEncoder5` writes its envelope, so `motionEnableSequence` produces a real two-frame
sequence (`0x51` then `0x6A` — §3) rather than the empty array an earlier revision of this paragraph
described, and `HistoricalDrainSession` is the loop that answers it. The layout is settled and walked:
`MotionPayloadDecoder` reads R21 out of a live type-43 frame and a banked type-47 one alike, so a
banked record reaches `MotionBatch` and `stepCounts` through the same code the 4.0's live path uses —
which is the whole reason the shared core is shared, and §7 Q9 is answered. What remains unwalked on
**both** generations is the drain's heart-rate record (§4), and what remains absent on both is
hardware: none of it has been captured on this project's own strap.

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
   all, but no longer a question about which value is right.
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
   checksum-verified command frame, and neither carries a record. Drained 5.0
   history can therefore be placed on a timeline as soon as one frame confirms the shift — with the
   RTC caveat at Q7 below attached, which is a separate failure and not a smaller one.
4. **What the real record size and header are, per strap** (§4) — **the 4.0 half is answered, and by
   more than the table above was built from.** 96 bytes is reported for 4.0 type 24, a real captured
   4.0 frame agrees with that table field for field, and an **implemented parser** now corroborates it
   at scale: OpenStrap's `parse_r24` gives the same offsets this section records — counter at `[3:7]`,
   `unix` at `[7:11]`, sub-seconds at `[11:13]`, heart rate at `[17]`, `rr_count` at `[18]` with the
   R-R intervals as i16 LE from `[19]` — and states they are "verified on 127,971 of our own stored
   records and cross-checked against an independent implementation", with the heart rate confirmed to
   match the live stream within a beat. It also gives a **minimum inner length of 89 bytes**, which is
   a decodable guard this section did not have. So the walk is no longer blind and no longer
   single-sourced from a table; it is corroborated by a second parser that has run over real history.
   The three 5.0/MG type-47 sizes — `124` / `1244` / `2140` — are **no longer single-sourced** either:
   they are the fixed lengths of layouts `R18` / `R21` / `R20`, published in the 5.0/MG sensor
   reference and stated independently in the deep-data page. What is still unobserved is the *record
   header* on a 5.0 frame, which is Q3's narrower question. **None of this is a capture on this
   project's hardware**, and the corroboration is of the *layout* — that a record can be decoded at
   all is still this app's first drain away.
5. **Whether the ACK token survives reconnection** (§4) — reported persistent for 4.0's cursor; the
   resume behaviour matters for a sync that runs on a phone that comes and goes. **The references
   answer this one by design rather than by measurement, and the design is the answer to copy:** noop
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
   `Asherlc/dofek`, whose `whoop-ble-protocol.md` states that unbonded commands return
   `PUFFIN_COMMAND_RESPONSE (0x26)` with error `0x049c` (1180) "regardless of command type, format, or
   CRC", while a bonded connection is accepted. A public code search finds that constant in dofek's
   docs and nowhere else: not in noop, which detects a refused bond through
   `CBATTError.insufficientEncryption` / `.insufficientAuthentication` instead, and not in OpenStrap.
   It is also **not a standard ATT code** — it is an application-level error in the Puffin payload —
   so it is not something a reader can look up.

   **And dofek's iOS half is weaker than it reads.** Its working iOS path is not a bond dofek
   creates: it is `retrieveConnectedPeripherals(withServices:)` **piggybacking on the bond the
   official WHOOP app already made**. Across the ecosystem, **no project demonstrates a third-party
   iOS app establishing its own WHOOP bond** — the platforms reported as able to *initiate* pairing
   are Android (`createBond`) and Linux/BlueZ, and iOS is not among them. Independently, noop
   observes that Apple's CoreBluetooth exposes **no link-encryption or bond state at all**, so a
   client cannot even ask whether it is bonded, and it records that its own unbonded-offload probe
   returned an inconclusive first result on real hardware rather than a refusal. The useful reading is
   therefore: **noop says macOS cannot complete the bond; nothing says iOS can create one**, and for a
   third-party app on iOS the honest status is unknown rather than blocked or permitted.

   **What the implemented 5.0 path does narrows it, and it cuts both ways.** noop's own `BLEManager`
   does attempt a bond from the app: on connect it writes the static 16-byte `CLIENT_HELLO` to the
   `fd4b0002` characteristic **`.withResponse`**, specifically so the write triggers the strap's
   **just-works bonding**. So a third-party client does reach for its own bond rather than only
   piggybacking — but noop labels the whole path **"EXPERIMENTAL"** and **"Unverified on real MG
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
   in each candidate length and watch whether the RTC actually moves.** noop records that a
   wrong-length set is **acknowledged but not latched** — and that a strap with an invalid RTC stops
   banking sensor data to flash altogether, so the symptom is a strap that looks connected while
   writing nothing. Published clients disagree on the length (4, 5, 8 and 9 bytes all appear in the
   wild), and noop's own resolution is to send both the 8-byte and 9-byte forms on 4.0 rather than
   choose. **Settle it per strap before building anything on top of the drain**, and expect the three
   straps to differ — the 5.0/MG's 8-byte form is the hardware-validated one, and its 9-byte form is
   unverified there. A clock read that returns success is not evidence the clock is right; noop notes
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
   whose "current strap producer" is unconfirmed, with the reference forbidding the `R10`, `R21` or
   `R22` layout being substituted for them. Capture settles both; neither gates reading packet 43.
10. **How far back does each strap's flash actually reach?** (§4) — the retention window this sync is
   designed against is **[assumed]** at fourteen days, and **the sources now disagree about it by a
   factor of five.** Two reverse-engineering projects state ~14 days (noop's README, "the strap's
   last ~14 days offload automatically"; andyguzmaneth/whoop4-ble, "~14 days of circular buffer,
   ~86,000 records per day", which is at least self-consistent at 1 Hz), and **neither measured it** —
   no project has drained to `HISTORY_COMPLETE` and read the oldest record's `[7:11]` against wall
   time. Against those, **WHOOP's own user-facing guidance says roughly 72 hours** of offline storage
   on the 4.0. So this is no longer "unsourced"; it is **sourced twice and contradicted once**, and
   the reverse-engineering figure is the one with no measurement behind it. Design against the
   smaller number until the drain settles it. It is also among the cheapest questions here to settle, because it
   needs no new code and no decode — connect, drain to `HISTORY_COMPLETE`, and read how far back the
   first record's `[7:11]` reaches against wall time, which is the read **Q7 already requires**, so
   one drain answers both. **Ask it per strap**: nothing establishes that three generations of
   hardware share a flash size or a retention policy, and since **only one strap is connected at a
   time**, the answer decides how long each band may go unvisited before its own history starts being
   overwritten rather than merely waiting to be collected. Whether the limit is strap-side retention
   or a drain-side window, and whether that clock advances while a strap is off the wrist, are part of
   what the capture settles.

11. **What is the drain request's body, and does it take a window at all?** (§4) — **answered by
   three implemented clients and one captured frame, and applied.** The body is a single `00` on both
   generations: noop's `BLEManager` sends `payload: [0x00]`, OpenStrap's `research_playground.py`
   builds `b"\x00"`, and that file carries the captured vector `aa0800a823041600c7c25288` annotated
   `0x16 [00]` — corroborated by noop's own doc. This app's eight-byte `[u32 start][u32 end]` window
   has been corrected to the bare byte at both builders and at §16. **What the capture still adds is
   confirmation on this project's own hardware**, since no implementation here has been run against a
   strap: one drain, and the question is only whether records arrive. Two sub-questions come free with
   the same drain, because noop's own 4.0 row is odd in both respects: it calls the delivery
   **type-47** where this document calls the 4.0 record `0x2F` type **24**, and its status is observed
   (`O / U`) rather than documented. Record the type byte of the first record to come back — that
   answers which is which for this strap, per strap.
12. **What does the 4.0's `0x6B` do — and is it the optical enable or a state read?** (§3, §5) —
   **the two references' *documents* disagree; their code does not, so what is left is a question
   about the byte's effect rather than its name.** OpenStrap reads 107 as `ENABLE_OPTICAL_DATA`,
   "wrist-gated optical (**the HR source**)", and builds its live example on it. noop's 4.0 column
   reads the same byte as `GET_IMU_DATA_STREAM` — body `[01]`, "Returns the stored IMU data-stream
   state" — and its 107 row warns that *"The WHOOP 5/MG identifier `ENABLE_OPTICAL_DATA` does not
   describe this WHOOP 4 operation."* **But noop's own enum names the byte `enableOpticalData` and no
   call site sends it**, so the read reading rests on the doc alone (§3's note has the sites), and the
   byte is now sent as OpenStrap's two-byte `[01, 01]` — an enable under one reading, a `[01]` read
   with a trailing byte under the other, harmless either way. **The capture is cheap and needs no
   drain:** write `0x6B` with `[01, 01]` on a connected 4.0 and read the reply — a state byte or a
   stream coming up are different answers — then confirm whether live HR responds at all, since this
   app reads HR from `0x2A37` and may not need the frame. Note the 5/MG is a third answer again: its
   107 is optical *session saving* on 50.42.1.0, its `ENABLE_OPTICAL_DATA` identifier is historical on
   that column too, and live optical output there is **108**.

The capture itself is the deliverable: drain once, record the raw frames, and decode from the
recording. **Do not decode from a live drain into a parser written from these notes** — a parser
built while watching a strap is tuned to its own bugs, and the recording is what lets a later reading
be checked against the bytes that produced it. §4's reassembler has removed the specific hazard that
used to stand behind this advice (a coincidental `0xAA` no longer reads as a boundary, because the
decoder's checksums refuse it), but the ordering is unchanged: the frames are the evidence and the
parser comes after. The motion paths in §6 need a **separate recording on the 4.0**, because they are
live-stream traffic and will not appear in a flash drain at all — and that recording is worth more
than this document once assumed, since the layout is published and hardware-verified and what it
lacks is only an opcode and a payload walk on this side of the link. **The 5.0/MG is the opposite
case, and this document had it backwards**: layout 21 is banked, so a flash drain *is* the motion
capture there, and the separate thing that generation needs recorded is the enable sequence (`81`
then `106`) rather than the samples.

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
  a WHOOP 4.0 and nothing else**. It is also the source of §6's 4.0 rows — the live IMU opcodes and
  record types, and the statement that **raw R10/R21 are live-stream only** while the flash holds
  type-24 — and of the `[52:64]` byte-identical-mirror claim §4 now carries as a named duplicate
  triplet. Note that this source reports **no gyroscope offset anywhere**, and that an absence of
  evidence in a reference that did not go looking for one is not evidence of absence: for some time
  §6 read that silence as the 4.0 having no established gyroscope at all, and it was wrong — see the
  noop schema below, which publishes the offsets and the calibrated scale.
  <https://github.com/OpenStrap/research> · `PROTOCOL.md` §4–§5 are the load-bearing sections.
* **OpenStrap/edge** — the sibling project, and **the closest thing in the ecosystem to this app**:
  a Flutter client for **iOS and Android** under MIT, which pairs over BLE and drains history from
  **4.0, 5.0 and MG** alike, shipped to real users as a public iOS TestFlight beta and an Android
  APK. It is cited here for one thing this document cannot get from a reference: it is a
  **third-party iOS client that actually syncs a strap**, which is the existence proof that the
  target of this document is reachable from this platform at all. Three of its findings are load
  bearing. It states that **Bluetooth lets only one app own the band at a time** and instructs users
  to stop the official WHOOP app first — the same single-bond constraint noop reports, arrived at
  independently. Its `SET_CLOCK` notes carry the payload-length warning §3 now documents, marked
  hardware-verified, including the specific failure where a wrong-length set is **acknowledged but
  not latched**, leaving the RTC "lost" so records come back dated to 1971. And it is the source of
  the platform asymmetry a sync design has to plan around: **Apple gives third-party apps no real
  background-service option**, so iOS background sync is best-effort and OS-scheduled, while Android
  has no equivalent limit — which is the reason a drain on iOS is a foreground activity rather than
  something the app can promise to do unattended. Its own README labels its metrics approximations
  from published research and explicitly not medical-grade.
  <https://github.com/OpenStrap/edge>
* **noop `docs/PROTOCOL.md`** — the hub of a reference that **is reachable**, and this entry corrects
  a claim this document used to make. The repository is **`ryanbr/noop`**, whose `docs/` tree carries
  `PROTOCOL.md`, `PROTOCOL_SENSORS.md`, `PROTOCOL_COMMANDS.md`, `PROTOCOL_WHOOP5.md`,
  `PROTOCOL_CONCEPTS.md`, `PROTOCOL_TRANSPORT.md`, `PROTOCOL_CONFIGURATION.md` and
  `WHOOP5_DEEP_DATA.md` alongside the Swift
  protocol package. **`PROTOCOL_COMMANDS.md` is the canonical command matrix and the one to read a
  name out of**: it enumerates every ID once with a **WHOOP 4 column beside a WHOOP 5/MG column**, so
  it is the page that shows where the two generations name one byte differently — which is §3's
  naming note, and the reason a name taken from the wrong column is visible there and nowhere else.
  `PROTOCOL_CONFIGURATION.md` carries the per-operation contracts behind those names. Earlier revisions here cited a fork and a read-only mirror and concluded the
  project's current pages could not be reached; **that was wrong**, and the pages below are quoted
  from the upstream tree. Its lineage moved rather than disappeared: the canonical `NoopApp/noop` is
  now a 404 (the README describes the project as deplatformed and meant to be mirrored), the repo
  cited here is the live continuation, and a same-named third repo is an unrelated near-empty stub —
  so **cite this one by its full path** rather than by the name.

  **This is the ecosystem's strongest evidence and it is stronger than "a reference".** noop is a
  shipped product on three platforms — a Swift macOS app with an iOS build, a Kotlin Android app and
  Python Linux capture tooling — with tens of thousands of downloads and a release history, and its
  protocol core is **implemented rather than documented**: the historical flash drain (request, the
  per-chunk persist → cursor → `HISTORICAL_DATA_RESULT` ACK loop, `HISTORY_START`/`END`/`COMPLETE`
  handling) is real code and is **hardware-verified on WHOOP 4.0**, with its changelog recording a
  live run of 0 → 246 `HISTORICAL_DATA` frames. So where this document says a protocol detail is
  "reported", read that as *reported by a client that runs*, not as *described by someone who read
  about it*. Two caveats keep it honest: the project's own status notes say **iOS live BLE is still
  being validated** and that no captured 5/MG `HISTORY_END` frame exists in-repo, and its 5/MG
  deep-biometric decode is documented-only. Its licence is source-available and **noncommercial**,
  deliberately not OSI — protocol facts are not copyrightable but its code is, so anything borrowed
  from it must be reimplemented rather than copied.

  Read this one for the envelope split and for the compatibility rule that
  governs everything else in this document: **"WHOOP 5 historical data is not a WHOOP 4 layout with
  shifted offsets"**, and "a shared command name does not establish the same request or response
  bytes." It is also the source of §2's second column being written in **decimal**, which is the
  whole of the radix problem §2 records.
  <https://github.com/ryanbr/noop> · `PROTOCOL.md` is the hub and `PROTOCOL_CONCEPTS.md` carries the
  CRC parameters and the durable-save-before-ACK invariant.
* **noop `docs/PROTOCOL_SENSORS.md` — the 5.0/MG sensor-record reference, and the source of §6's
  producer 3.** It names the record layouts `R16` / `R17` / `R18` / `R20` / `R21` / `R26`, gives each
  a fixed byte length (`R18` 124, `R21` 1,244, `R20` 2,140), and publishes the `R21` six-axis IMU
  layout — its columnar `i16` arrangement, its per-axis offsets and both of its scales. Decisively,
  it states that **layout 21 is carried by live packet 43 *and* historical packet 47**, which is what
  reverses this document's old "no live raw-IMU stream" finding. It is also where the namespace rule
  comes from: packet number, record layout, command number and event number are separate namespaces,
  and unmapped fields "must remain opaque, not silently converted to zero measurements."
  <https://github.com/ryanbr/noop/blob/main/docs/PROTOCOL_SENSORS.md> · the `R21` section and the
  type-43/47 carriage statement are the load-bearing parts.
* **noop's Swift IMU decoder, in the same repository** — the `R21` layout translated into code, and
  the closest thing to a third check on it. Two things about it matter here. It gates on the exact
  1,244-byte length **and on both in-packet sample counts being 100** rather than on the type byte, so
  it cannot misfire on a same-type frame that is not an IMU buffer — the shape a motion decoder in
  this app should copy. And its header records hardware validation on **1,423 buffers from a real 5.0
  (firmware 50.40.1.0)**: the accelerometer magnitude is a 1.01 g gravity shell, 100% of samples
  within ±15% of the median at **4,117 ± 11 LSB** across 200 s, while the gyro sits near zero at rest
  and correlates 0.79 with accelerometer motion. **That LSB figure is the measurement that settles
  this document's ±4 g question**: 4,117 LSB at 1 g is `1/4096` g/LSB, and a ±4 g full scale would
  put gravity at 0.50 g.
  <https://github.com/ryanbr/noop> ·
  `Packages/WhoopProtocol/Sources/WhoopProtocol/Whoop5RawImu.swift`.
* **noop's protocol schema and decoder, in the same repository** — and this is the part of that
  project this document leans on hardest, because it is machine-readable rather than prose. A JSON
  schema keys `HISTORICAL_DATA` on its **version byte** (versions `24` / `12` / `5` / `7` / `9`) and
  gives its fields at frame-absolute offsets — which is where §4's answer to Q3 comes from — and it
  carries two length-keyed `REALTIME_RAW_DATA` variants: **1917 B** as a 6-axis IMU buffer with
  **100 samples per axis**, the accelerometer at frame `89` / `289` / `489` at `0.000244140625` g/LSB
  and the **gyroscope at `692` / `892` / `1092` at `0.06103515625` deg/s/LSB (±2000 dps)**, and
  **1921 B** as an optical buffer. Its IMU scales are annotated as verified against a motion-capture
  reference and a controlled 720° rotation on generation-4 hardware, which is the strongest evidence
  in this document for any **position on the strap's own axes**, and the source of §6's 4.0 gyroscope
  row. Its `HISTORICAL_DATA` decoder reads the record's unix stamp first and comments that there is
  **no wall-clock offset** to apply. **Its envelope is the 4.0's** — `SOF` at 0, two-byte `length` at
  1, `crc8` at 3, `packet_type` at 4, `seq` at 5 — so its `24` / `12` / `5` / `7` / `9` vocabulary is
  4.0-enveloped, and §2 no longer attributes it to a 5.0 schema. The 5.0/MG record set is
  `PROTOCOL_SENSORS.md` above, which is where the `R`-number layouts and §6's producer 3 come from.
  <https://github.com/ryanbr/noop> · the schema is
  `Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json`.
* **noop's deep-data page (`WHOOP5_DEEP_DATA.md`)** — the page this document used to call the
  "depth-buffer research log" and record as **unreachable**. It is reachable at the upstream tree
  above, and reading it changes two things. It states the 5.0/MG motion carriage plainly — "**the
  large records are no longer an undifferentiated type-`0x2F` blob**. Layout v21 (1,244 bytes)
  contains six-axis IMU data; layout v20 (2,140 bytes) contains five repeated measurement blocks whose
  producer is optical" — so the two lengths §6 carried on its authority are **confirmed here
  independently of the sensor reference** — and it records the enable sequence §6 now quotes:
  "command 81 followed by command 106 with `[1,1]`; stop uses command 82 followed by command 106 with
  `[1,0]`", with the caution that requests, effective collection state and packet delivery are
  separate things. **What it does not say is that the 5/MG has no live raw-IMU stream.** Nothing in
  it supports the claim this document attributed to it, and two other sources contradict it. The
  residue that remains genuinely unverifiable from here is only the feature extractor
  (`accelEnergyG`, `gyroEnergyDps`, `jerkRms`, `cadenceHz`, `cadenceStrength`), whose offsets are
  still unpublished — and §6 no longer depends on it. Worth noting for method, since it is stronger
  than a capture alone: the page correlates captured frames against the tester's own **WHOOP data
  export** to pin an offset by known plaintext, and runs locally so that only offsets and encodings
  ever leave the machine. It also keeps raw buffers aside so a byte-exact decoder can be reversed
  offline — capture first, decode after, which is this document's own ordering.
  <https://github.com/ryanbr/noop/blob/main/docs/WHOOP5_DEEP_DATA.md>
* **Asherlc/dofek `docs/whoop-ble-protocol.md`** — a third independent reading, from APK
  decompilation of WHOOP Android v5.439.0 plus PacketLogger captures and live probing, and **the
  source of §2.1's second worked 5.0 frame**. It corroborates §6's `R21` layout **independently of
  noop**: its table lists the same eight fields, at the same frame-absolute offsets once its 8-byte
  envelope is added, and it states the range in as many words — "±8g (1g ≈ 4096 LSB)". It also names
  packet `0x2B` / 43 `REALTIME_RAW_DATA` with the "Maverick R21 format" behind it, which is a third
  independent statement that layout 21 rides a **live** packet. Two of its claims are recorded here
  without being adopted, because each needs a capture to settle. It describes the `0x2B` flow as
  needing no toggle, which is true only when piggybacking on a session the WHOOP app has already
  configured (§6). And it states that **the strap requires BLE bonding before accepting any
  commands**, with unbonded writes answered by `PUFFIN_COMMAND_RESPONSE` and error `0x049c` — which,
  if it holds, is a precondition this app does not currently satisfy and would have to before any
  command path is worth building. Note that the standard SIG services are separately reported to work
  **unbonded**, so the two claims are consistent and describe different paths: `0x2A37` is why this
  app's live heart rate works at all, and the custom command characteristic is a different question.

  **Two limits on that claim, and both matter.** It is **single-sourced**: a public code search finds
  `0x049c` in this project's docs and nowhere else in the ecosystem, so it is one unreplicated report
  rather than a settled fact — and it is not a standard ATT code, being an application-level error in
  the Puffin payload, so it cannot be checked against a spec. And its **bonded iOS evidence is
  piggybacking, not bonding**: the successful path it reports is
  `retrieveConnectedPeripherals(withServices:)` **reusing the bond the official WHOOP app already
  established**, which is a different claim from a third-party app creating one. Read together with
  noop's report that macOS cannot complete the bond and that Apple exposes no bond state at all (§7
  Q6), the honest status for a third-party iOS client is **unknown**, not permitted.
  <https://github.com/Asherlc/dofek/blob/main/docs/whoop-ble-protocol.md>
* **ITF Player Analysis Technology approval report PAT 25-025, for the WHOOP 5.0 and MG** — the
  `[filed]` source for the 5.0/MG sensor suite, including the "3-axis accelerometer and gyroscope"
  that §6's 5.0/MG hardware row rests on. Read it for what it is: a filing establishes **which sensors
  exist**, because the sensor list is the filing's subject and it is made under a duty of accuracy —
  and it says nothing whatever about the wire format.
  <https://www.itftennis.com/media/15583/whoop-pat-approval-report-pat-25-025.pdf>
* **abdulsaheel/whoopsie** — a second WHOOP 4.0 client, read here only for corroboration, and it
  corroborates two things §4 already carries: that the strap's clock **ships unset**, so a session
  that skips setting it stamps garbage times, and that history transfers in batches requiring an exact
  8-byte token echoed back. It adds one ordering §4 does not record — the local save must complete
  **before** the acknowledgement is sent, or a crash mid-drain loses records the strap believes were
  delivered. Its README defers record layouts to a separate repository, so the widely-quoted
  1928-byte / 100 Hz figures reach this document second-hand and are not what §6 relies on — the
  length and the rate there come from the noop schema above, which publishes the layout behind them.
  <https://github.com/abdulsaheel/whoopsie>

None of these has been reproduced against this project's hardware. §7 is the list of what would
replace them.
