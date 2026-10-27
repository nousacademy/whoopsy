# The research reference

`docs/BLE_PROTOCOL.md` cites this project by role as **the research reference**: two write-ups —
a 4.0 `PROTOCOL.md` and a 5.0 / 5.0 MG `PROTOCOL-GEN5.md` — plus the sibling client that actually
ships. All three are here, because this repository leans on them for different things: the 4.0
write-up for that generation's envelope and record header, the Gen 5 one for the `R`-number layouts
and the count gate, and the client for what a third-party iOS app can and cannot do against a strap.

Nothing in this file is this repository's own measurement. The only Gen 5 capture this project holds
is the one `docs/BLE_PROTOCOL.md` tags `[captured]`.

## Identity and evidence base

* **OpenStrap/research** — WHOOP 4.0 BLE protocol reference (`PROTOCOL.md`, 263 lines) plus a
  2,271-line reference client (`research_playground.py`, whose `sync` drains the historical flash
  and whose `build_batch_ack` is the ACK). Covers the 4.0 envelope, the type-24 record header, the
  `0x2F`/`0x31` types, the ACK/token loop, the full command enum and the session-init sequence.
  **Its evidence base is stronger than its README suggests, and the two disagree**: the README's
  summary says the record past the header is "fingerprinted but unconfirmed", while `PROTOCOL.md` §5
  documents it as validated by **per-byte variance analysis across 811 real records** (550 golden
  capture + 261 R2 spanning 113 h), cross-checked against two independent decoders — and it is that
  section which marks `[7:11]`, `[11:13]`, `[17]` and `[18]`/`[19:19+2n]` **verified**. Read
  `PROTOCOL.md`, not the README, when judging a field's confidence. Two of its rejections matter
  here: the `[76]` "respiration" and `[78]` "signal quality" fields are **bit-constant** across all
  811 records and are fixed trailer bytes, and the README is explicit that **everything was tested
  on a WHOOP 4.0 and nothing else**. It is also the source of §6's 4.0 rows — the live IMU opcodes
  and record types, and the statement that **raw R10/R21 are live-stream only** while the flash
  holds type-24 — and of the `[52:64]` byte-identical-mirror claim §4 now carries as a named
  duplicate triplet. Note that this source reports **no gyroscope offset anywhere**, and that an
  absence of evidence in a reference that did not go looking for one is not evidence of absence: the
  community reference's schema
  ([`../noop/BLE_PROTOCOL.md`](../noop/BLE_PROTOCOL.md)) publishes the offsets and the calibrated
  scale.
  <https://github.com/OpenStrap/research> · `PROTOCOL.md` §4–§5 are the load-bearing sections.

* **OpenStrap/edge** — the sibling project, and **the closest thing in the ecosystem to this app**:
  a Flutter client for **iOS and Android** under MIT, which pairs over BLE and drains history from
  **4.0, 5.0 and MG** alike, shipped to real users as a public iOS TestFlight beta and an Android
  APK. It is cited here for one thing this document cannot get from a reference: it is a
  **third-party iOS client that actually syncs a strap**, which is the existence proof that the
  target of this document is reachable from this platform at all. Three of its findings are load
  bearing. It states that **Bluetooth lets only one app own the band at a time** and instructs users
  to stop the official WHOOP app first — the same single-bond constraint the community reference reports, arrived at
  independently. Its `SET_CLOCK` notes carry the payload-length warning §3 now documents, marked
  hardware-verified, including the specific failure where a wrong-length set is **acknowledged but
  not latched**, leaving the RTC "lost" so records come back dated to 1971. And it is the source of
  the platform asymmetry a sync design has to plan around: **Apple gives third-party apps no real
  background-service option**, so iOS background sync is best-effort and OS-scheduled, while Android
  has no equivalent limit — which is the reason a drain on iOS is a foreground activity rather than
  something the app can promise to do unattended. Its own README labels its metrics approximations
  from published research and explicitly not medical-grade.
  <https://github.com/OpenStrap/edge>

  **The client used to be cited under a second name, and that was wrong.** The repository was once
  `abdulsaheel/whoopsie`, and GitHub redirects that path to `OpenStrap/edge` — the same repository id,
  renamed and transferred, **not a second project**. So the 4.0 corroborations this file records
  (the clock set on connect, the exact 8-byte token, the save-before-acknowledge ordering) are the
  client agreeing with the write-up it shares an author with, not an independent second client
  agreeing with it. Read as strong self-consistency and not as replication.

## Excerpts

Quoted verbatim from the reference's `PROTOCOL-GEN5.md` (open PR against `OpenStrap/research`),
validated by its author against one WHOOP 5.0 on firmware `50.40.1.0`. Quoted here so this
repository's prose can cite a path rather than repeat a project name, and so every claim carries the
words it was taken from.

The confidence markers are the source's own: **verified**, **empirical**, **unknown**.

### The shipped client's sync rules, in its own words

From the client's `docs/DEVELOPMENT.md` — the passage `docs/BLE_PROTOCOL.md` §4's corroborations rest
on. It is the client's documentation rather than a captured frame, and it is the same project as the
write-up above.

> A few rules the sync path depends on: the device clock is set on connect, history
> arrives in batches that each need an acknowledgement, and every batch is saved locally
> before it is acknowledged, so a crash mid-sync can't lose data. The protocol repo's
> README has the details.

That last sentence is also why the widely-quoted 1928-byte / 100 Hz layout figures reach this
repository second-hand: the client defers record layouts to a separate protocol repository, and
`docs/BLE_PROTOCOL.md` §6's lengths come from the community reference's schema instead.

### Packet types

> | type | meaning |
> |---:|---|
> | 40 | realtime heart rate |
> | 43 | realtime sensor body (revision at `inner[1]`) |
> | 47 | historical sensor body (revision at `inner[1]`) |
> | 48 | events |
> | 49 | history metadata markers |
> | 51 / 52 | dedicated IMU stream wrapper |
>
> For types 43/47 the body starts at **inner offset 13**.

> | rev | full frame | content |
> |---:|---:|---|
> | 18 | **124** | **processed sensor body, 99-byte body — the main payload** |
> | 20 | 2,140 | optical / PPG, five channel blocks |
> | 21 | 1,244 | IMU |
> | 22 | 188 | research telemetry, six tagged variants |
> | 26 | 88 | Pulse Information Packet |

### The 1 Hz record — type 47 revision 18 (abridged)

> 99-byte body. This is the Gen 5 equivalent of Gen 4's type-24 and it is considerably richer.
>
> | body | size | field |
> |---:|---:|---|
> | 1 | 1 | heart rate (rounded signal-processing estimate; same value as type-40 HR) |
> | 2 | 1 | **emitted R-R interval count, 0..4** |
> | 3 | 8 | **four R-R intervals in ms, `u16` LE**; unused slots zero |
> | 20 | 4 | max adjacent acceleration-magnitude delta, `float32` g |
> | 24 | 12 | mean acceleration X/Y/Z, three `float32` g |
> | 36 | 2 | cumulative step count, `u16` LE |
> | 42 | 1 | step-activity class: `0` unknown, `1` walk, `2` run, `0xff` invalid |
> | 60 | 1 | packed state byte — **sleep state in bits 4..5** |
> | 84 | 1 | movement-fundamental bin, `0.732421875` cycles/min per LSB — **not** heart rate |

### The R-R motion gate

> Emission is suppressed by movement. The band takes 100 Hz acceleration magnitude in g, passes it
> through two IIR stages, takes the absolute value, applies a third IIR stage, keeps each one-second
> block's maximum in a 30-entry history, and emits intervals only while the maximum of that history
> is strictly below `0.03`.

> - The count is **not** a beat count for that second. It is zero in most records and falls further as
>   heart rate rises.
> - **A zero count is ambiguous** — it does not distinguish "no new interval" from "suppressed by
>   motion".
> - **The series across records is sparse.** Never bridge a zero-count record, a timestamp gap, or
>   non-adjacent records.

### Historical sync and the count gate

> Same shape as Gen 4 — a drain with an echo-back ACK — but a different correctness rule.
>
> ```
> GET_DATA_RANGE(34)        → bounds
> SEND_HISTORICAL_DATA(22)  → band streams records + type-49 markers
>   … per burst: HISTORY_END marker → HISTORICAL_DATA_RESULT(23) echoing the markers …
> HISTORY_COMPLETE          → done
> ```
>
> ### The count gate — the Gen 5 equivalent of the Groundhog Day bug
>
> Each `HISTORY_END` declares an expected count. **Count each complete frame once,
> independent of revision or byte length**, and only for these types:
>
> | type | counts |
> |---:|---|
> | 47, 48, 50, 53, 54, 55 | **yes**, once per complete frame |
> | 49 | no |
> | 51, 52 | no |
>
> Get the membership wrong and the band re-offers the same burst forever. Retain both markers
> alongside your database position as an audit trail.
>
> Other behaviour worth knowing:
>
> - Default burst size **50**; after **5 consecutive negative results** it drops to **10**.
> - **15 failed validations** is the terminal stuck boundary — abort with opcode 20.
> - The drain is **non-destructive**: it never erases flash, so you can re-drain freely.

### Event 29 — the strap condition report

> `STRAP_CONDITION_REPORT(29)` is logged, and only logged:
> `pages behind 4321, backlog 45.6, SoC 87.2%, flash 3, charging, wrist 2.`

### Other bodies

> - **Revision 20 — optical/PPG.** 2,115-byte body, five blocks (CH1, CH2, CH4, CH5-with-CH3-fallback,
>   CH6), each a count + 20-byte descriptor + two `50 × i32` A/B streams. Raw 20-bit optical ADC codes
>   off a MAX86176. CH2/CH4 blocks are dormant while awake.
> - **Revision 26 — Pulse Information Packet.** 63-byte body, episodic detector output — observed
>   episodes are exactly 40 records at 1 Hz, not one-per-second. The saturating `i16` delta encoding is
>   **lossy**.
>
> **Is [R22] worth enabling?** Mostly no. Tag 5 duplicates R26. Tags 1–4 are a lossy subset of what R20
> already carries across five channel blocks. Only tag 6 — historical raw acceleration — is
> unavailable elsewhere.

### Footguns

> The config and feature-flag stores use ASCII `"1"` = enabled, `"2"` = disabled, and `"0"` =
> raw/unset. A band commonly sits at `"2"`, so writing `"0"` to enable something turns it off.

> - `0x19 FORCE_TRIM` is a flash erase and is destructive. The reference marks it "never sent".
