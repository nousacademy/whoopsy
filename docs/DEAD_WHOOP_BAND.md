# The strap → phone path

> **Reading order.** This file answers *how the band's bytes become rows in the database*.
> Wire detail (offsets, CRCs, layouts): **[BLE_PROTOCOL.md](BLE_PROTOCOL.md)** ·
> Who owns each row and in what order: **[DATAFLOW.md §2](DATAFLOW.md#2-who-owns-each-stored-row)** and
> **[§4](DATAFLOW.md#4-the-foreground-chain-in-order)** ·
> What the rows feed: **[ALGORITHMS.md](ALGORITHMS.md)** ·
> Screens: **[PAGES.md](PAGES.md)** · Traps: **[GOTCHAS.md](GOTCHAS.md)**

**This document covers the strap and nothing else.** A phone can be filled from five sources — the live
strap, its flash, a recorded session, HealthKit, the bundled export, a cloud restore — and only the
first two come off the radio. The full list, with what each writes and when, is
[DATAFLOW.md §1](DATAFLOW.md#1-the-ways-data-comes-in); this file starts at the antenna and ends at the
tables, and links rather than restates.

## 1. Three straps, two wire formats

The app supports the 4.0, the 5.0 and the 5.0 MG. **They do not share an envelope**: two header CRCs
(CRC8 over the length bytes, CRC16-Modbus over the header), two length offsets, two record origins. The
packet-type numbering *is* shared — the same eight roles in both references — so the envelope is what
discriminates a generation, never the type byte. The layouts are
[BLE_PROTOCOL.md §2](BLE_PROTOCOL.md#2-packet-framing--wire-format); this file only needs the fact.

**Which strap is in hand is a stored choice, and a guess must never override it.** `resolvedGeneration`
takes three inputs in order:

1. **the user's choice** for this strap (`StrapModelRepository`) — and it wins even when evidence
   disagrees, because a 5.0 MG that advertises like a 5.0 is exactly the case the choice exists for;
2. **observed evidence** — the `FD4B0001` GATT service, or the DIS model string;
3. **the advertised name**, which is a proprietary command's reply rather than GAP's `0x2A00`, used only
   for a strap nobody has been asked about.

`WhoopProtocolProfile.profile(for:)` answers `nil` for standard-HR and simulator sources, and a `nil`
profile means no proprietary framing at all — the strap is read as a plain `0x2A37` heart-rate sensor.

## 2. The link

- **Discovery.** `scannableServiceUUIDs` filters the scan; the first match is connected.
- **The standing connect.** `centralManager.connect` is issued with **no timeout**, because it has to
  survive suspension and let iOS relaunch the app on re-advertisement. There is no reconnect timer —
  the outstanding connect *is* the reconnect ([GOTCHAS](GOTCHAS.md), "the reconnect is an outstanding
  connect").
- **Reconnect policy** (`ReconnectPolicy`). A failure inside `fastFailureSeconds` (2 s) is retried no
  sooner than `retryFloorSeconds` (30 s); five fast refusals in a row on a 5.0/MG end the loop
  (`refusalCap`). A slow failure keeps the standing connect as it was.
- **Keep-alive** (`KeepAlivePolicy`, a 30 s tick): read battery `0x2A19` at most once a minute; re-send
  the activation commands when the link has been silent for 15 s (4.0) or 60 s (5.0/MG); **bounce** the
  connection after 120 s (4.0) or 600 s (5.0/MG) of silence, so the standing connect recovers a link
  that has gone quiet without a disconnect. A tick gap over `suspensionGapSeconds` (90 s) means the app
  was suspended, and the window restarts rather than counting time nobody observed.
- **Radio off** does not deliver a disconnect; the state callback is what marks the link lost
  ([GOTCHAS](GOTCHAS.md), "a radio that is turned off does not deliver a disconnect").
- **Restore** (`willRestoreState`) seeds `.connected`, re-discovers services and restarts the keep-alive
  window; a restored-but-disconnected peripheral gets a standing connect.
- **Handshake.** 4.0 sends its connect commands on the command characteristic immediately; 5.0/MG must
  first write `CLIENT_HELLO` **confirmed** and wait for the write to land. Both then send the clock, the
  live-telemetry/real-time-HR enables and the motion enable sequence, and read DIS. The sequence is
  [BLE_PROTOCOL.md §3](BLE_PROTOCOL.md#3-initialization--handshake-sequence-reported-40).

**A connected peripheral is not a producing strap.** Link state says the radio is up, not that data is
arriving — which is why the keep-alive watches silence rather than trusting `.connected`.

## 3. The five streams

Everything this path produces leaves the manager as one of these. They are **multicast**: each is a
dictionary of continuations keyed by a `UUID` and pruned on termination, so a session leaving the screen
does not starve another reader ([GOTCHAS](GOTCHAS.md), "the BLE streams are multicast").

| Stream | Element | Consumer | Lands in |
| :--- | :--- | :--- | :--- |
| `deviceStream` | `WhoopDevice` | `DeviceViewModel`, the reconnect badge, the drain trigger | — |
| `liveTelemetryStream` | `BiometricSample` | `StreamBiometricsUseCase` | `biometric_samples` |
| `historicalTelemetryStream` | `BiometricSample` | `SyncHistoricalDataUseCase` | `biometric_samples` |
| `motionStream` | `MotionBatch` | `RecordMotionUseCase`, `TrackStepsUseCase`, `LiveSessionUseCase` | `motionEpochs`, `stepCounts` |
| `stepCounterStream` | `StepCounterSample` | `TrackStepsUseCase` | `stepCounts` |

## 4. Decode

`WhoopFrameReassembler` accumulates bytes across notifications and finds frame boundaries; the decoder
owns validity, not the reassembler. `decodeProprietaryFrame` checks four things in order — start byte,
the generation's declared-length offset, the header CRC (CRC8 or CRC16-Modbus) and the payload CRC32 —
and returns a `WhoopRawFrame` whose `seq` is the **record-layout selector**, not a sequence number.

Every validated frame is then offered, in this order, to: the motion decoder, the live heart-rate
decoder, the strap-event decoder, the condition report (log only), the clock-reply probe, and finally
`routeToDrain` — which runs **always**, not as an `else`, because a drained record and a live one arrive
through the same characteristic.

| Data | Decoder | Notes |
| :--- | :--- | :--- |
| HR, R-R (live, standard) | `WhoopPacketDecoder.decodeStandardHeartRate` | `0x2A37` |
| HR, R-R (live, 5.0/MG packet 40) | `HeartRatePayloadDecoder.decodeLive` | — |
| HR, R-R (drained) | `HeartRatePayloadDecoder.decodeHistorical` | R18 on 5.0/MG (u16 ticks), 4.0 type 24 (signed i16 ms) |
| Motion / accelerometer | `MotionPayloadDecoder.decode` | R10 (4.0 live) and R21 (5.0/MG) |
| Step counter | `StepCounterPayloadDecoder.decode` | R18 cumulative, 5.0/MG only |
| Skin temperature | `HeartRatePayloadDecoder.skinTemperature(inPayload:)` | payload offset 62, gated 5–45 °C |
| SpO₂ | `Spo2CandidateProbe` | **instrumentation** — never written as a measurement |
| Strap events | `StrapEventDecoder.decode` | log and state, not rows |

The offsets and layouts behind that table are [BLE_PROTOCOL.md §5](BLE_PROTOCOL.md#5-heart-rate-two-producers-and-which-to-use)
and [§6](BLE_PROTOCOL.md#6-motion-three-producers-and-which-strap-has-which); this file does not repeat
them, because a byte offset written down twice is a byte offset that will disagree with itself.

## 5. The flash drain

**The drain is the only path that makes a night visible the morning after.** A strap worn overnight
banks records with no phone near it; the app pulls that flash, acknowledges it, and the strap advances
its trim cursor so the same records are not offered again.

- **Triggers, and they are two.** `DrainCoordinator` is called from the `deviceStream`'s `.connected`
  arm, once per link, and from the scene's `.active` phase. The second exists because a phone that
  stayed connected all night never reconnects, so the connect trigger would miss the night entirely.
  A manual `SYNC HISTORY` calls the use case directly and bypasses the coordinator.
- **Single-flight.** The coordinator is an actor with `isRunning`; a second call returns `nil` — "another
  drain is running", not an error.
- **Retry.** Up to three attempts, a zero-batch answer counting as unanswered (retried after 5 s), while
  an error carrying a record range counts as answered.
- **The loop.** `HistoricalDrainSession` consumes metadata frames: `HISTORY_START` does nothing,
  `HISTORY_END` closes a batch and is **acknowledged**, `HISTORY_COMPLETE` finishes and is **not**
  acknowledged. The ACK ordering is the whole rule ([BLE_PROTOCOL.md §4](BLE_PROTOCOL.md#4-historical-sync-the-flash-drain)).
- **The continuation token is at payload 10**, not at one frame offset shared by both generations — the
  frame offset is `innerOrigin + innerPrefixBytes + 10`, so 17 on 4.0 and 21 on 5.0. It carries the trim
  cursor (page + wrap count), which is logged rather than sent.
- **Three ways it ends, and two guards that produce them.** A batch whose newest stamp does not beat the
  drain's own maximum three times in a row is a stall (`.idleTimeout`); silence for 8 s (4.0) or 60 s
  (5.0/MG) is idle; a 5.0 batch whose newest record is within 5 s of now is the live edge
  (`.caughtUpToLiveEdge`). 4.0 never trips the live edge — its marker layout carries no timestamp.
- **The hand-off.** The session becomes a `HistoricalSyncOutcome` (records, batches, how it ended,
  oldest/newest record stamp) and `DrainCoordinator` feeds that range to `RefreshStrainUseCase` and
  `RefreshNightsUseCase`. A drain that ends without a strap-confirmed ending throws
  `WhoopSyncError.endedWithoutConfirmation`, so "returned" and "finished" cannot be confused.

Per-generation differences that matter to a reader of this path:

| Aspect | 4.0 | 5.0 / MG |
| :--- | :--- | :--- |
| Envelope | CRC8, length at 1, origin 4 | CRC16-Modbus, length at 2, origin 8 |
| Idle window | 8 s | 60 s |
| Live-edge detection | never | record stamp, marker fallback |
| Drained HR layout | packet `0x2F`, selector 24, ms | packet 47, selector 18 (R18), ticks |
| Step counter | none | R18 |
| Pre-drain clock | sent at the drain | also sent at connect |
| Bond gate | none | `CLIENT_HELLO` acknowledged first |

## 6. What each record writes

The **rows** are owned by writers — one per table, with the provenance each stamps — and that table is
[DATAFLOW.md §2](DATAFLOW.md#2-who-owns-each-stored-row). What this path contributes to it:

- **`biometric_samples`** — heart rate and R-R intervals, live or drained, at most once per second;
  an R18 record also carries accelerometer X/Y/Z and the skin temperature on the same row.
- **`motionEpochs`** — 30-second windows (`meanMagnitudeG`, `maxMagnitudeG`, `sampleCount`) written by
  `RecordMotionUseCase`.
- **`stepCounts`** — two producers into one row: the R18 counter (5.0/MG, drained) and the rhythm-gated
  detector (live motion only). Banked motion is refused by the detector so one drained window is never
  counted twice; the split is kept in `StepCounterStateStore` because the row has no provenance column.

What those rows then feed — sleep staging, strain's motion term, steps, stress — is
[ALGORITHMS.md](ALGORITHMS.md), and the page-side index is
[PAGES.md §The figures](PAGES.md#the-figures-and-where-each-one-comes-from).

## 7. What this path cannot do

Each of these is a rule with a measurement behind it, and the measurement is in
[GOTCHAS.md](GOTCHAS.md):

- **The strap banks no `R21` motion**, so a night's stillness comes from `R18`'s accelerometer, merged
  window by window with any live `R21`.
- **A drain re-covers the window the live detector already counted**, so banked motion must not feed the
  step detector.
- **A drained record's timestamp is verified as a field and unverified as a value** — a wrong stamp files
  history onto a wrong day rather than onto no day.
- **The oxygen field is instrumentation**, and no screen or row may read it as a measurement.
- **A worn strap banks at full rate with no phone; a strap off the wrist banks almost nothing.**

## 8. Where to go next

- The bytes: [BLE_PROTOCOL.md](BLE_PROTOCOL.md) — start at its two implementation-status tables before
  touching the sync path.
- The rows and the order: [DATAFLOW.md](DATAFLOW.md).
- The math: [ALGORITHMS.md](ALGORITHMS.md).
- The screens: [PAGES.md](PAGES.md).
