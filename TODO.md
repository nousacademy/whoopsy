# TODO.md — every CSV column, and whether this app reads it

The bundled WHOOP export is four files. **One of them is read.** This file is the inventory of what
each column is worth and what it would take to use the rest.

**One section at the end is not a column inventory** — the strap's own historical sync, which is a
wire-protocol task rather than an export one. It is here because this is the file the project's
outstanding work is recorded in, and it is marked as sitting outside the per-column rule so that the
invariant below still holds for everything above it.

**Re-measure, never trust.** Every count here is a measurement over
`Sources/Whoopsy/Data/Resources/`, not a recollection. The `csv-field-coverage` skill owns this file
and carries the command that reproduces the numbers; run it before you flip anything.

## How to read a line

- `[x]` **covered** — a named symbol consumes the column. The line names it, with a file.
- `[ ]` **not covered** — and the line says which of the three it is: a **decision** (do not cover
  it), a **redundancy** (the app derives it, and the derivation is what ships), or **work**.

A line marked **Decision** is closed. Flipping it is not a coverage win — it is the change the
line exists to prevent. `Recovery score %` and `Sleep performance %` are both in that class.

**One line per column, in the file's own order.** That is the invariant that makes this document
checkable: a checklist shorter than the column count is a column nobody has looked at.

## Summary

| File | Rows | Cols | Covered | Bundled | Read by |
| :--- | ---: | ---: | ---: | :--- | :--- |
| `physiological_cycles.csv` | 935 | 26 | **18** | yes | `WhoopExportParser` → `WhoopExportImporter` |
| `sleeps.csv` | 918 | 18 | **0** | no | nothing |
| `journal_entries.csv` | 3403 | 6 | **0** | no | nothing |
| `workouts.csv` | 673 | 17 | **0** | no | nothing |

`physiological_cycles.csv` is the only file in `Package.swift`'s `resources:` — see `CLAUDE.md`.

---

## 1. `physiological_cycles.csv` — 26 columns · 935 rows

The day key is `startOfDay(Wake onset)`. 910 rows carry one; the other 25 are the fragments that
never closed and become `strains`-only rows (`CLAUDE.md` has the 23:30 boundary pair).

### Cycle identity

- [x] **`Cycle start time`** — 935/935 — parsed to `WhoopExportRow.cycleStart` ([WhoopExportParser.swift:132](Sources/Whoopsy/Data/Import/WhoopExportParser.swift#L132)); the **day-key fallback** for a row with no wake onset ([WhoopExportImporter.swift:93](Sources/Whoopsy/Data/Import/WhoopExportImporter.swift#L93))
- [ ] **`Cycle end time`** — 934/935 — not parsed. **Redundancy**: a day's extent is its wake onset, and the session's end is that same value, so nothing needs it
- [x] **`Cycle timezone`** — 935/935 — parsed and applied as the UTC offset when every date in the row is built; a row whose offset cannot be read throws rather than shifting silently

### Recovery inputs

- [ ] **`Recovery score %`** — 910/935 (1–99) — parsed into `WhoopExportRow.recoveryScorePercent` and consumed by **nothing but `isEmpty`**. **Decision — do not cover.** `WhoopExportImporter` re-scores all 910 days through `RecoveryScoring` so one formula covers the whole history; storing WHOOP's would put two models on one chart
- [x] **`Resting heart rate (bpm)`** — 910 (46–98) — → `recoveries.resting_heart_rate`; the `RecoveryScoring` z-score input and Home's RHR panel
- [x] **`Heart rate variability (ms)`** — 910 (15–99) — → `recoveries.hrv_value_ms` + `hrv_metric` (classified `.rmssd` — an inference, `ALGORITHMS.md` §1); the scoring input and Home's HRV panel
- [x] **`Skin temp (celsius)`** — 909 (29.73–35.84) — → `recoveries.skin_temp`. **Stored, exported, and printed by no screen.** `RecoveryDashboardView` says so in prose instead
- [x] **`Blood oxygen %`** — 909 (87.88–100) — → `recoveries.spo2`. Same: stored, never drawn

### Strain inputs

- [x] **`Day Strain`** — 933 (0–19.8) — → `strains.strainScore` **verbatim**; the export has no HR series, so there is nothing to integrate
- [x] **`Energy burned (cal)`** — 933 (14–5613) — → `strains.activeCalories`. **Stored and printed by no screen**
- [x] **`Max HR (bpm)`** — 933 (93–206) — → `strains.maxHeartRate` → Strain screen "Peak HR"
- [x] **`Average HR (bpm)`** — 933 (56–101) — → `strains.averageHeartRate` → Strain screen "Average HR"

### Sleep

- [x] **`Sleep onset`** — 910 — → `SleepSession.startTime`
- [x] **`Wake onset`** — 910 — **the day key**, and → `SleepSession.endTime`
- [ ] **`Sleep performance %`** — 910 (5–100) — parsed, consumed by nothing. **Decision — do not cover.** `SleepSession.sleepPerformancePercentage` derives asleep-over-need ([SleepSession.swift:89](Sources/Whoopsy/Domain/Entities/SleepSession.swift#L89)); the two disagree on **457 of 910 nights**, and one rule is the point. **The column stays uncovered, but the derivation is now drawn**: it is the SLEEP PERFORMANCE breakdown row on the Recovery screen and, below it, the sleep-performance week chart (`MetricDay.sleepPerformance` → `WeekBarSeries(sleepPerformanceWeek:)`). So this line reads as "the export's number is not used", not "the quantity is absent from the app" — the figure on those two screens is this app's own, and it will not match WHOOP's for the same night
- [x] **`Respiratory rate (rpm)`** — 910 (13.5–20.2) — → `sleeps.respiratory_rate`, `recoveries.respiratory_rate` and `MetricDay.respiratoryRate` → the Recovery screen's RESPIRATORY RATE breakdown row and the Respiratory Rate week chart under it. Read to **one decimal** there, because a week spans about two units — the reference week is 14.8…16.5, which whole numbers flatten to six `15`s
- [ ] **`Asleep duration (min)`** — 910 (68–940) — parsed into `WhoopExportRow.asleepMinutes` and read by **nothing**. **Redundancy**: `totalTimeAsleepSeconds` sums the three stages, and on this export the two agree **exactly on all 910 rows**
- [ ] **`In bed duration (min)`** — 910 (87–954) — parsed into `WhoopExportRow.inBedMinutes` and read by nothing. **Redundancy, and the measurement is the interesting part**: `sleepPeriodSeconds` (asleep + awake) reproduces this column **exactly on 904 of 910 rows**, so the app already holds this number and the column has nothing to add — see the in-bed section below for the 6 that differ and why storing them would not help
- [x] **`Light sleep duration (min)`** — 910 (31–940) — → `sleeps`
- [x] **`Deep (SWS) duration (min)`** — 910 (0–173) — → `sleeps`
- [x] **`REM duration (min)`** — 910 (0–241) — → `sleeps`
- [x] **`Awake duration (min)`** — 910 (1–252) — → `sleeps`
- [x] **`Sleep need (min)`** — 910 (321–650) — → `sleeps.target_sleep_need_seconds` → Home's SLEEP NEEDED panel. Stored verbatim; imported and strap nights must not be crossed
- [ ] **`Sleep debt (min)`** — 910 (0–127) — not parsed. **Decision — do not cover.** A fitted 7-night deficit buys 0.35 of a point for a second fitted constant, and WHOOP's own column does no better. The measurement is in `ALGORITHMS.md` §4
- [ ] **`Sleep efficiency %`** — 910 (59–99) — not parsed. **Decision — do not cover, and the reason is measured.** `sleepEfficiencyPercentage` is the standard TST-over-TIB and matches this column on 826 of 910 rows. On 83 of the other 84 the mismatch is **not** a denominator problem: the export's own `In bed duration` equals asleep + awake on those rows, and the column still reads 2–5 points higher, so **WHOOP's efficiency is not a function of the two durations WHOOP publishes beside it**. There is no input to store that would reproduce it — see the efficiency section below
- [ ] **`Sleep consistency %`** — 892 (7–94) — not parsed. Neither producer nor consumer exists: nothing in this app measures night-to-night timing

---

## 2. `sleeps.csv` — 18 columns · 918 rows

**Every column below is uncovered for the same single reason, so it is stated once:**

> **Blocker: the file is not bundled and nothing reads it.** `physiological_cycles.csv` is the only
> file in `Package.swift`'s `resources:`; this one is on disk in the repo and in the app's reach of
> nobody. Covering any column here starts by deciding to read the file at all.

What reading it would buy is measured, and it is small: its 910 non-nap rows carry the *same 910
wake onsets* as the bundled file — `0` sleeps-only, `0` cycles-only — so its entire unique
contribution is the **8 nap rows**. Those need their own table (they are a fourth sleep type, and
`ALGORITHMS.md` §4 records the omission) — which is the work, and is the same work regardless of
which days they land on.

- [ ] **`Cycle start time`** — 918 — not parsed (file unbundled)
- [ ] **`Cycle end time`** — 917 — not parsed
- [ ] **`Cycle timezone`** — 918 — not parsed
- [ ] **`Sleep onset`** — 918 — not parsed. Already covered for the 910 nights by the bundled file
- [ ] **`Wake onset`** — 918 — not parsed. Same
- [ ] **`Sleep performance %`** — 918 — not parsed; derived on the entity and drawn from there. Same **Decision** as §1
- [ ] **`Respiratory rate (rpm)`** — 917 — not parsed. Already covered for the 910 nights
- [ ] **`Asleep duration (min)`** — 918 — not parsed; derivable from the stages
- [ ] **`In bed duration (min)`** — 918 — not parsed; same discrepancy as §1 applies
- [ ] **`Light sleep duration (min)`** — 918 — not parsed
- [ ] **`Deep (SWS) duration (min)`** — 918 — not parsed
- [ ] **`REM duration (min)`** — 918 — not parsed
- [ ] **`Awake duration (min)`** — 918 — not parsed
- [ ] **`Sleep need (min)`** — 918 — not parsed. Already covered for the 910 nights
- [ ] **`Sleep debt (min)`** — 918 — not parsed. Same **Decision** as §1
- [ ] **`Sleep efficiency %`** — 918 — not parsed; derived on the entity
- [ ] **`Sleep consistency %`** — 892 — not parsed; no producer and no consumer
- [ ] **`Nap`** — 918 (`false` × 910, **`true` × 8**) — **the only column in this file that carries anything the bundled export does not.** The 8 naps run 33–237 min asleep; each one is an unread fourth sleep type

---

## 3. `journal_entries.csv` — 6 columns · 3403 rows

**The largest table in the export and the only one with no schema, no parser and no screen.** 27
distinct questions, 1377 `true` answers. Nothing in this app asks the user anything, so this is the
one file whose coverage is a *feature*, not a column mapping — and the blocker is the same for all
six rows: there is no `journal` table and no UI that would write or read one.

- [ ] **`Cycle start time`** — 3403 — not parsed
- [ ] **`Cycle end time`** — 3403 — not parsed
- [ ] **`Cycle timezone`** — 3403 — not parsed
- [ ] **`Question text`** — 3403 (**27 distinct**) — not parsed. Free text used as a key; a journal table would need a stable identity for a question whose wording can change
- [ ] **`Answered yes`** — 3403 (`false` 2026 / **`true` 1377**) — not parsed. Boolean, so the column is a fact about a day and would join the recovery inputs rather than stand alone
- [ ] **`Notes`** — **550**/3403 — not parsed. The only free-text column in the export; empty on 2853 rows, and empty-means-absent is already this app's rule

---

## 4. `workouts.csv` — 17 columns · 673 rows

**673 workouts across 445 distinct days** — 1.5 per day, which is exactly why `workouts` is
keyed on `id` and not on `date` (`CLAUDE.md`). The table, its route table and its splits table all
exist from `v6` and are populated only by live sessions from the strap. Nothing reads this file.

- [ ] **`Cycle start time`** — 673 — not parsed
- [ ] **`Cycle end time`** — 673 — not parsed
- [ ] **`Cycle timezone`** — 673 — not parsed
- [ ] **`Workout start time`** — 673 — not parsed. Would become `WorkoutSession.startedAt`
- [ ] **`Workout end time`** — 673 — not parsed. Would become `WorkoutSession.endedAt`
- [ ] **`Duration (min)`** — 673 (1–458) — not parsed. **Redundancy**: the entity's duration is the two timestamps' difference
- [ ] **`Activity name`** — 673 (**21 distinct**; `Walking` 222, `Activity` 197, `Yoga` 89, …) — not parsed. A string with no column behind it — each name needs a decision about what this app calls it
- [ ] **`Activity Strain`** — 673 (0–19.1) — not parsed. Would be WHOOP's own figure stored verbatim, the same bargain §1's `Day Strain` makes
- [ ] **`Energy burned (cal)`** — 673 (2–3011) — not parsed
- [ ] **`Max HR (bpm)`** — 673 (76–206) — not parsed
- [ ] **`Average HR (bpm)`** — 673 (57–153) — not parsed
- [ ] **`HR Zone 1 %`** — 673 (0–100) — not parsed. **The only zone breakdown in the whole export** — a day's strain has none, which is why the Strain screen renders "No zone data recorded."
- [ ] **`HR Zone 2 %`** — 673 (0–84) — not parsed
- [ ] **`HR Zone 3 %`** — 673 (0–93) — not parsed
- [ ] **`HR Zone 4 %`** — 673 (0–76) — not parsed
- [ ] **`HR Zone 5 %`** — 673 (0–36) — not parsed
- [ ] **`GPS enabled`** — 673 (**`false` on all 673**) — not parsed, and **nothing to parse**: the export carries no route for any workout, so `workout_route_points` can never be filled from this file

---

## Cross-file findings, measured

Four facts that decide more than one line above.

1. **`sleeps.csv` is the bundled file plus eight naps.** The 910 non-nap wake onsets are the same
   910 days, set-for-set — `0` sleeps-only, `0` cycles-only. So the file's entire unique
   contribution is the 8 nap rows (33–237 min asleep). All 8 do fall on a day that already holds a
   night, but that is an artefact of aiming them at `sleeps`, which is primary-keyed on `date`: give
   naps their own table and the question does not arise. **The work is the table, not the
   collision.**

2. **`In bed duration (min)` is already the app's number, and the 6 rows that differ are not
   fixable by storing it.** `sleepPeriodSeconds` is asleep + awake, and it equals the export's
   column on **904 of 910** rows — the same quantity, derived. On the other 6 the column is larger
   by 3–34 min: unstaged time the classifier never accounted for, which is exactly the part no
   derivation can recover. Storing the column would move the Sleep screen's efficiency on only 2 of
   those 6 — **one closer to WHOOP's own column and one further from it**. There is nothing here
   worth a migration.
   **What was actually wrong was the name**, and it has been fixed: the property was called
   `totalTimeInBedSeconds`, which named a measurement this app has never taken on either path. It is
   now `sleepPeriodSeconds`. See below.

3. **The wall-clock span is not a time-in-bed either, and this is measured rather than assumed.**
   `endTime − startTime` is never *shorter* than the classified minutes (0 of 910) and longer on
   **295 of 910, by up to 6 hours** — one row's `Sleep onset` is literally `00:00:00`. The truth
   sits between a lower bound and an upper bound that can be six hours apart, so the timestamps
   cannot produce it. Any future change that tries to derive in-bed from `startTime`/`endTime`
   should read this line first.

4. **`workouts.csv` can never fill `workout_route_points`** — `GPS enabled` is `false` on all 673
   rows. And the three unread files are not equally cheap: `workouts.csv` maps onto three existing
   tables and needs a parser plus an activity-name decision; `journal_entries.csv` needs a table, a
   parser and a UI that does not exist at all; `sleeps.csv` needs one table and buys eight rows.

## The in-bed duration, in full

This is the one line in the document that has been argued with, so the whole measurement is here.

**`SleepSession.sleepPeriodSeconds` = `totalTimeAsleepSeconds` + `awakeSeconds`** = light + deep +
REM + awake. It has exactly one consumer: `sleepEfficiencyPercentage` (asleep / sleep period), which
the Sleep screen prints. It is never displayed directly.

| Question | Measured answer |
| :--- | :--- |
| Does it match WHOOP's `In bed duration`? | **904/910 rows exactly.** It is the same sum |
| Is it time in bed? | **No.** It is the classified span, a *lower bound* — unstaged time is not in it |
| Is `endTime − startTime` better? | **No.** Never shorter (0/910), longer on 295/910 by up to 6 h |
| Would storing the column fix the 6? | **Net zero.** Moves the displayed efficiency on 2 of 6 — one toward WHOOP, one away |

**The efficiency column cannot be matched at all, and that is a separate finding.** WHOOP's own
`Sleep efficiency %` agrees with ours on 826/910. Of the 84 that differ, **83 have an in-bed gap of
zero** — the export's own two duration columns reproduce *our* 92% while the export's efficiency
column says 94%. So the column is computed from something the export does not publish, and adding
any column to `sleeps` will not reach it. This is why the line in §1 is a **Decision**: the gap is
in the source, not in the app.

**The defect was the name, and it is fixed.** A property called `totalTimeInBedSeconds` that is not a
measurement of time in bed is the same class of claim as a defaulted field rendered as a reading — it
named a measurement the app never took. The arithmetic was right; the name was not. It is now
`sleepPeriodSeconds`, the polysomnography term for total sleep plus intra-period wake
([SleepSession.swift:85](Sources/Whoopsy/Domain/Entities/SleepSession.swift#L85)), and its doc comment carries the three
measurements above so the next reader does not try `endTime − startTime` again.

---

## 5. Strap historical sync — **not a column, and not covered by the rule above**

**This section is not part of the per-column inventory.** Every `[ ]` above is a CSV column; every
`[ ]` here is a work item, and all of them are **work** — none is a decision and none is a
redundancy. The section exists because the strap holds **up to 14 days of cached data** that this app
is supposed to pull down on sync, and it currently cannot.

**Sequencing: this is not started until the screens are considered done.** The gate is deliberate,
not a technical dependency — the strap feeds the screens, so building the sync first would mean
writing interfaces around a data shape that was still moving. Nothing below should be picked up
while UI work is open, however urgent the list reads.

Unlike every other section in this file, **this one has never run against its source.** Signing is
not functional (`CLAUDE.md` §Building for iOS) and the app has never executed against a strap, so
`biometric_samples` is empty in the dev database and in both simulator containers. Every claim below
is read off the code and the spec; none is a measurement of a device. Read it as a list of what is
wrong on paper, not as a list of observed failures.

### The chain that exists

Settings → `DeviceViewModel.syncNow()` ([DeviceViewModel.swift:10](Sources/Whoopsy/Presentation/Screens/Device/DeviceViewModel.swift#L10)) →
`SyncHistoricalDataUseCase.execute()` → `WhoopPacketEncoder.requestHistoricalSync`
([WhoopPacketEncoder.swift:54-60](Sources/Whoopsy/Data/BLE/Parser/WhoopPacketEncoder.swift#L54-L60)) →
`WhoopPacketDecoder` `case 0x30` ([WhoopPacketDecoder.swift:87](Sources/Whoopsy/Data/BLE/Parser/WhoopPacketDecoder.swift#L87)) →
`decodeHistoricalSyncPayload` ([WhoopPacketDecoder.swift:156](Sources/Whoopsy/Data/BLE/Parser/WhoopPacketDecoder.swift#L156)) →
`.historicalBatch` → `yieldTelemetry` → `StreamBiometricsUseCase` →
`biometric_samples`. The pipe is connected end to end. Six things stop it working.

### Blocked on hardware — do not guess twice

- [ ] **No handshake is implemented at all.** `BLE_PROTOCOL.md` §3 ([line 45](BLE_PROTOCOL.md#L45)) specifies a strict eight-step sequence a freshly bonded strap must be walked through before it will serve a historical sync: step 1 `0x23` `GET_HELLO_HARVARD` (133-byte status payload), step 7 `0x16` historical request, step 8 `0x17`×N acknowledge-and-trim loop ([lines 51, 57-58](BLE_PROTOCOL.md#L51)). `grep -rn "0x23\|0x16\|0x17\|handshake" Sources/` returns **nothing** — the command is sent cold to a strap that has not been opened
- [ ] **The opcode disagrees with the spec.** `BLE_PROTOCOL.md` §2 assigns `0x23`/`0x72` to Command and `0x30` to **Asynchronous Event / Heartbeat** ([lines 38-40](BLE_PROTOCOL.md#L38-L40)); the historical request is `0x16`. The code sends `0x30` as a *command id* and decodes responses on `0x30`. One of the two is describing the wrong field, and which one cannot be settled without a device
- [ ] **The frame layout disagrees with the spec too.** `BLE_PROTOCOL.md` §2 frames `SOF | len_lo | len_hi | crc8 | type | seq | cmd | data | crc32` — a 4-byte header and a 3-byte payload prefix. `buildPacket` ([WhoopPacketEncoder.swift:8](Sources/Whoopsy/Data/BLE/Parser/WhoopPacketEncoder.swift#L8)) writes `SOF | cmd | len_lo | crc8 | data | crc32` with a **1-byte** length, and the decoder mirrors it ([WhoopPacketDecoder.swift:64-66](Sources/Whoopsy/Data/BLE/Parser/WhoopPacketDecoder.swift#L64-L66)) — so the app is self-consistent and its tests pass, against a spec it does not match
- [ ] **The received CRC8 is read and discarded.** The decoder binds `data[3]` to `_` and never verifies it ([WhoopPacketDecoder.swift:66](Sources/Whoopsy/Data/BLE/Parser/WhoopPacketDecoder.swift#L66)), so a corrupted notification is accepted as a sample
- [ ] **The 16-byte record layout is a guess.** `decodeHistoricalSyncPayload` slices the payload into 16-byte records and feeds each through `decodeLiveTelemetryPayload`, which reads that function's *live* offsets. Nothing has checked that a historical record and a live notification share a layout

### Not blocked — true whatever the strap turns out to say

- [ ] **Every historical sample would be filed under today.** `decodeLiveTelemetryPayload` hardcodes `timestamp: Date()` ([WhoopPacketDecoder.swift:125](Sources/Whoopsy/Data/BLE/Parser/WhoopPacketDecoder.swift#L125)) and the batch decoder reuses it per record, so fourteen days of cache land on the instant Sync was tapped. This is the one defect here that would corrupt the *other* screens rather than just this one: `recoveries`, `sleeps` and `strains` are all keyed on `startOfDay`, and the app's whole day model cannot represent a batch that spans fourteen of them. It needs a per-record time — either a field in the record or a reconstruction from the request epoch — before any of this is worth storing
- [ ] **The window asked for is one day, not fourteen.** `SyncHistoricalDataUseCase` starts from `getLatestSample()`, which is `nil` on an empty `biometric_samples`, so it falls back to `now − 1 day` ([SyncHistoricalDataUseCase.swift:17](Sources/Whoopsy/Domain/UseCases/SyncHistoricalDataUseCase.swift#L17)). The stated goal — the band's full retained cache — is not what the code requests
- [ ] **Nothing owns the persistence.** `StreamBiometricsUseCase` is the **only** writer to `biometric_samples` ([line 35](Sources/Whoopsy/Domain/UseCases/StreamBiometricsUseCase.swift#L35)) and its writer *is* its stream consumer. `syncNow()` sends the command and returns; if no screen holds `liveTelemetryStream` open, a decoded batch is yielded to zero continuations and dropped with no error. The sync must persist on its own rather than depend on a screen being on
- [ ] **`syncNow()` reports the send, not the result.** It sets `"History sync complete."` whenever `execute()` does not throw ([DeviceViewModel.swift:10](Sources/Whoopsy/Presentation/Screens/Device/DeviceViewModel.swift#L10)) — and in mock mode `requestHistoricalSync` is `if !isMockMode { … }` ([WhoopBLEDeviceRepositoryImpl.swift:79](Sources/Whoopsy/Data/BLE/Repositories/WhoopBLEDeviceRepositoryImpl.swift#L79)), a silent no-op under the same banner. "Complete" should mean rows written
- [ ] **`biometric_samples` has no retention.** No pruning exists anywhere in `Sources/` — `grep -rn "deleteOlderThan\|prune\|retention\|purge"` returns nothing. Fourteen days of beat-to-beat R-R is a large number of rows, so the retention policy is a decision to take *before* the first successful sync rather than after

### What this couples to

The R-R series this sync would deliver is the same series the RSA respiratory-rate work needs — a
contiguous, correctly ordered beat-to-beat record. Both are blocked by the same two things above:
the per-record timestamp, and the fact that a `biometric_samples` row's `timestamp` is an arrival
instant rather than a beat time (`CLAUDE.md`). Anything built on top of a sync that lands every
record under one instant inherits that defect rather than fixing it.
