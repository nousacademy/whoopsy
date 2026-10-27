# The community reference

`docs/BLE_PROTOCOL.md` and `docs/ALGORITHMS.md` cite this project by role as **the community
reference**: the multi-platform client whose protocol, sensor and command documents this repository
compares its decoders against. Its pages are named below and quoted in the excerpts, because a
citation that says only "the community reference's sensor document" cannot be checked.

It is a reference rather than a specification, and every claim taken from it is tagged `[reported]`
in `docs/BLE_PROTOCOL.md` unless this project has captured it.

## Identity and evidence base

* **noop `docs/PROTOCOL.md`** — the hub of a reference that **is reachable**. The repository is **`ryanbr/noop`**, whose `docs/` tree carries
  `PROTOCOL.md`, `PROTOCOL_SENSORS.md`, `PROTOCOL_COMMANDS.md`, `PROTOCOL_WHOOP5.md`,
  `PROTOCOL_CONCEPTS.md`, `PROTOCOL_TRANSPORT.md`, `PROTOCOL_CONFIGURATION.md` and
  `WHOOP5_DEEP_DATA.md` alongside the Swift
  protocol package. **`PROTOCOL_COMMANDS.md` is the canonical command matrix and the one to read a
  name out of**: it enumerates every ID once with a **WHOOP 4 column beside a WHOOP 5/MG column**,
  so it is the page that shows where the two generations name one byte differently — which is §3's
  naming note, and the reason a name taken from the wrong column is visible there and nowhere else.
  `PROTOCOL_CONFIGURATION.md` carries the per-operation contracts behind those names. The pages
  below are quoted from the upstream tree, and its lineage moved rather than disappeared: the
  canonical `NoopApp/noop` is now a 404 (the README describes the project as deplatformed and meant
  to be mirrored), the repo cited here is the live continuation, and a same-named third repo is an
  unrelated near-empty stub — so **cite this one by its full path** rather than by the name.

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
  **100 samples per axis**, the accelerometer at frame `89` / `289` / `489` at `0.000244140625`
  g/LSB and the **gyroscope at `692` / `892` / `1092` at `0.06103515625` deg/s/LSB (±2000 dps)**,
  and **1921 B** as an optical buffer. Its IMU scales are annotated as verified against a motion-
  capture reference and a controlled 720° rotation on generation-4 hardware, which is the strongest
  evidence in this document for any **position on the strap's own axes**, and the source of §6's 4.0
  gyroscope row. Its `HISTORICAL_DATA` decoder reads the record's unix stamp first and comments that
  there is **no wall-clock offset** to apply. **Its envelope is the 4.0's** — `SOF` at 0, two-byte
  `length` at 1, `crc8` at 3, `packet_type` at 4, `seq` at 5 — so its `24` / `12` / `5` / `7` / `9`
  vocabulary is 4.0-enveloped, and §2 does not attribute it to a 5.0 schema. The 5.0/MG record set
  is `PROTOCOL_SENSORS.md` above, which is where the `R`-number layouts and §6's producer 3 come
  from. <https://github.com/ryanbr/noop> · the schema is
  `Packages/WhoopProtocol/Sources/WhoopProtocol/Resources/whoop_protocol.json`.

* **noop's deep-data page (`WHOOP5_DEEP_DATA.md`)** — reachable at the upstream tree above. Two things in it matter. It states the 5.0/MG motion carriage plainly — "**the
  large records are no longer an undifferentiated type-`0x2F` blob**. Layout v21 (1,244 bytes)
  contains six-axis IMU data; layout v20 (2,140 bytes) contains five repeated measurement blocks
  whose producer is optical" — so the two lengths §6 carried on its authority are **confirmed here
  independently of the sensor reference** — and it records the enable sequence §6 now quotes:
  "command 81 followed by command 106 with `[1,1]`; stop uses command 82 followed by command 106
  with `[1,0]`", with the caution that requests, effective collection state and packet delivery are
  separate things. **What it does not say is that the 5/MG has no live raw-IMU stream.** Nothing in
  it supports the claim this document attributed to it, and two other sources contradict it. The
  residue that remains genuinely unverifiable from here is only the feature extractor
  (`accelEnergyG`, `gyroEnergyDps`, `jerkRms`, `cadenceHz`, `cadenceStrength`), whose offsets are
  still unpublished — and §6 does not rest on it. Worth noting for method, since it is stronger than
  a capture alone: the page correlates captured frames against the tester's own **WHOOP data
  export** to pin an offset by known plaintext, and runs locally so that only offsets and encodings
  ever leave the machine. It also keeps raw buffers aside so a byte-exact decoder can be reversed
  offline — capture first, decode after, which is this document's own ordering.
  <https://github.com/ryanbr/noop/blob/main/docs/WHOOP5_DEEP_DATA.md>

## Excerpts

The counter and activity-class material that `docs/ALGORITHMS.md` cites is in
[`ALGORITHMS.md`](ALGORITHMS.md) beside this file.

Quoted verbatim from the reference's own `docs/PROTOCOL_IMPLEMENTATION.md`,
`docs/PROTOCOL_SENSORS.md` and `docs/PROTOCOL_COMMANDS.md`, and from four of its issues. Quoted here so
this repository's prose can cite a path rather than repeat a project name, and so each claim carries
the words it came from. Issue numbers are the source's own and are kept as identifiers, not as links.

### Command framing and the historical ack

> | Code | Command | Typical payload | Purpose |
> |-----:|---------|-----------------|---------|
> | 22 | `SEND_HISTORICAL_DATA` | `[0x00]` | begin offload of the type-47 store |
> | 23 | `HISTORICAL_DATA_RESULT` | `[0x01] + end_data(8)` | ack a `HISTORY_END` chunk / advance trim |
> | 34 | `GET_DATA_RANGE` | `[0x00]` | strap's stored oldest/newest record range; #689 also logs a diagnostic ring-buffer page backlog |

> High-frequency offload sends **one** `HISTORY_START` then **repeated** `HISTORY_END`s (a chunk …)
> The ack itself is the link-layer half: `HISTORICAL_DATA_RESULT(23)` with payload `[0x01] + end_data`

### The R18 sensor block — step counter, class, and the SpO₂ candidate byte

> | 57 | 2 / u16 | Selected cumulative step/motion counter; selection detailed below |
> | 63 | 1 / u8 | Activity: 0 still, 1 walk, 2 run; other input classes become FF and must not be surfaced as those three classes |
> | 64 | 1 / u8 | 10 hex when software counter override is active, otherwise zero |
> | 82 | 1 / u8 | Sleep-adjacent raw byte; 80/A0 hex are candidate sentinels, not established physiological labels |

> For this layout, the normal value at 57 is the hardware pedometer count. When software counter
> override is enabled, 57 carries the software count, 61 retains the hardware count and 64 becomes
> `0x10`. With no override, bytes 61–62 and 64 are zero. This allows a client to retain both sources
> and avoid turning a change of source into a false step delta.

> A cadence value is **not a documented steps-per-minute conversion**; even a consistent relationship
> to speed is not guaranteed. Preserve it raw. Neither counter is established as equal to the official
> app's aggregated step count.

### The SpO₂ candidate, as the reference frames it (#709)

> A decompile-sourced decode reads v18 byte `@82` (= inner 74) as a **strap-computed SpO2 % scalar**:
> tri-mode — 70–100 a real %, bit-7 values (0x80/0xA0…) saturation sentinels, other sub-70 nonzero
> diagnostic codes; populated only during sleep.

> The two nights checked on the original #103 capture device **failed** the cross-night test … An
> 8-night independent validation **with real spread** then met exactly that bar: corr +0.99, ~0.4 %/night
> error … So the evidence is currently **split across devices**.

> **Instrumentation only — this does not ship an SpO2 metric.**

### Destructive and unknown commands (#2828)

> | Code | Name |
> |---:|---|
> | 155 | `START_CERTIFICATE_TRANSFER` |
> | 156 | `LOAD_CERTIFICATE` |
> | 157 | `VERIFY_CERTIFICATE` |
> | 158 | `PROCESS_CERTIFICATE` |
> | 159 | `LOCK_DEVICE` |

> All five are destructive or of unknown reversibility. … Nothing can send them.

> Source: [LeonardSEO/wearable5.0], command table (app-derived names).

### `GET_DATA_RANGE`'s page backlog is a diagnostic, not a contract (#689)

> `pagesBehind = W < U ? W + (T - U) : W - U`
>
> where the parser reads unsigned 32-bit words from the inner command-response payload … `T() = V(5)`
> ring capacity, `U() = V(3)` read pointer.

> This would improve sync diagnostics without changing sync behavior.

### Unknown layouts stay closed

> | [Type 47 v24/v25 and legacy layouts] | … | Unknown layouts remain fail-closed |

### The stillness spine: documented here, used there only as a motion count

The `R18` table above carries the field `docs/ALGORITHMS.md` §4 builds this app's sleep spine from —
quoted verbatim, with the frames they name:

> | 41 | 4 / f32 | Dynamic, gravity-removed acceleration; g in the retained convention, accept finite values in [0,8] |
> | 45, 49, 53 | 4 each / f32 | Gravity x/y/z, g; no established per-axis sentinel |

The Gen 5 reference calls body 24 of the same record "mean acceleration X/Y/Z"; these are the same
three `f32`. **Neither reference uses them as a spine** — this project's `grav` comes from the motion
record, so a strap that banks `R18` and not `R21` reports no motion at all. Two open issues state the
consequence and the two alternatives this repository rejected, quoted verbatim:

> #1801 — **Sleep: no HR-only staging fallback, so a strap that never banks motion can never report Rest**
>
> > With no motion the stager has no HR-only fallback, so no quantity of HR can stage a night — a
> > strap capability limit, not a coverage gap.
>
> > An HR-only staging path, used only when `gravCount == 0` and HR coverage over the window is
> > sufficient. It should be clearly marked lower-confidence than the motion-backed stager rather than
> > presented as equivalent …

> #1949 — **Does an unbonded 5/MG stream realtime IMU? If so, an unbondable strap could still get a motion spine**
>
> > If it does, a strap that can never offload motion could still supply a live motion spine, and
> > HR-only staging would stop being the only option for these straps.

`docs/ALGORITHMS.md` §4 records why this app takes neither path where the record is banked, and why
#1949's question is still the right one for a strap that banks nothing.
