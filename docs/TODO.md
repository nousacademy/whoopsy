# docs/TODO.md — every CSV column, and whether this app reads it

The bundled WHOOP export is four files. **Three of them are read** — `physiological_cycles.csv` in
full, `sleeps.csv` for its eight nap rows alone, and `workouts.csv` for the 673 workouts. This file
is the inventory of what each column is worth and what it would take to use the rest.

> **Sources.** Other people's reverse-engineering is cited here by **role**, never by project
> name — the community reference, the research reference, the APK reading and the Swift 4.0
> client. Each role resolves to one file under `docs/<project>/`
> holding that project's identity, URLs and verbatim excerpts; the table is
> [`docs/BLE_PROTOCOL.md` § Sources](BLE_PROTOCOL.md#sources).

**Three sections at the end are not a column inventory** — §5, the strap's own historical sync, which
is a wire-protocol task rather than an export one, §6, the walk to run on a sideloaded build, which
is a device task rather than an export one, and **§7, the flash recorder and the step counter**, added
2026-10-23. All three are here because this is the file the project's outstanding work is recorded in,
and all three are marked as sitting outside the per-column rule so that the invariant below still
holds for everything above them.

**Re-measure, never trust.** Every count here is a measurement over
`ios/Sources/Whoopsy/Data/Resources/Whoop/`, not a recollection. The `csv-field-coverage` skill owns this file
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
| `physiological_cycles.csv` | 935 | 26 | **20** | yes | `WhoopExportParser` → `WhoopExportImporter` |
| `sleeps.csv` | 918 | 18 | **1** | yes | `WhoopExportParser.parseNaps` → `WhoopExportImporter.importNaps` |
| `journal_entries.csv` | 3403 | 6 | **0** | no | nothing |
| `workouts.csv` | 673 | 17 | **12** | yes | `WhoopExportParser.parseWorkouts` → `WhoopExportImporter.importWorkouts` |

Three of these four WHOOP files are in `Package.swift`'s `resources:` — `physiological_cycles.csv`,
`sleeps.csv` for its eight nap rows alone, and `workouts.csv` for its zone block and its `Activity
name` column, neither of which is in any other file. `journal_entries.csv` is on disk in the repo, in
no bundle, and read by nothing. **The manifest declares more than these four** — two JSON resources
sit beside them, `ZeroFasting/fasts.json` and `Custom/dreams.json` — so this paragraph is the WHOOP
export's inventory and not the resource list; `CLAUDE.md` carries the whole set.

---

## 1. `physiological_cycles.csv` — 26 columns · 935 rows

The day key is `startOfDay(Wake onset)`. 910 rows carry one; the other 25 are fragments that never
closed. **24** of those carry a `Day Strain` and **22** of the 24 become `strains`-only rows — two land
on a day a closed cycle already claims, which is `CLAUDE.md`'s 23:30/23:48 boundary pair (2024-02-11,
2024-03-20), and the 25th fragment carries neither a wake onset nor a strain, so it produces no row at
all. That is the whole arithmetic behind the export's **931** `strains` rows from 933 `Day Strain`
values: 909 measured wake days plus 22 fragment days.

### Cycle identity

- [x] **`Cycle start time`** — 935/935 — parsed to `WhoopExportRow.cycleStart` ([WhoopExportParser.swift:18](../ios/Sources/Whoopsy/Data/Import/WhoopExportParser.swift#L18)); the **day-key fallback** for a row with no wake onset ([WhoopExportImporter.swift:139](../ios/Sources/Whoopsy/Data/Import/WhoopExportImporter.swift#L139))
- [ ] **`Cycle end time`** — 934/935 — not parsed. **Redundancy**: a day's extent is its wake onset, and the session's end is that same value, so nothing needs it
- [x] **`Cycle timezone`** — 935/935 — parsed and applied as the UTC offset when every date in the row is built; a row whose offset cannot be read throws rather than shifting silently

### Recovery inputs

- [ ] **`Recovery score %`** — 910/935 (1–99) — parsed into `WhoopExportRow.recoveryScorePercent` and consumed by **nothing but `isEmpty`**. **Decision — do not cover.** `WhoopExportImporter` re-scores all 910 days through `RecoveryScoring` so one formula covers the whole history; storing WHOOP's would put two models on one chart
- [x] **`Resting heart rate (bpm)`** — 910 (46–98) — → `recoveries.resting_heart_rate`; the `RecoveryScoring` z-score input and Home's RHR panel
- [x] **`Heart rate variability (ms)`** — 910 (15–99) — → `recoveries.hrv_value_ms` + `hrv_metric` (classified `.rmssd` — an inference, `docs/ALGORITHMS.md` §1); the scoring input and Home's HRV panel
- [x] **`Skin temp (celsius)`** — 909 (29.73–35.84) — → `recoveries.skin_temperature`. **Stored, exported, and printed by no screen.** `RecoveryDashboardView` says so in prose instead
- [x] **`Blood oxygen %`** — 909 (87.88–100) — → `recoveries.spo2_percentage`. Same: stored, never drawn

### Strain inputs

- [x] **`Day Strain`** — 933 (0–19.8) — → `strains.strainScore` **verbatim**; the export has no HR series, so there is nothing to integrate
- [x] **`Energy burned (cal)`** — 933 (14–5613) — → `strains.kilojoules`. **Stored and printed by no screen.** Three notes, because this column's storage is the one place in the app where an absence is written as a `0`. (a) The column is `NOT NULL` and has no readers, so `CalculateStrainUseCase` stores `0.0` when no body weight is on file and *that is a gap rather than a reading* — relaxing it to nullable needs a table rebuild rather than an `ALTER`, which is a different and riskier change than the one the profile page arrived with. **Do not copy the pattern to a column anything reads.** (b) The live session screen does not inherit it: `LiveSessionAccumulator` carries the `nil` through to the `CALORIES` tile, so the figure a user actually sees is `—` rather than zero. (c) The division is `4.184` kJ per kcal in `GRDBStrainRepository`, which is why a kilocalorie-valued function's output lands in a kilojoule-named column at all
- [x] **`Max HR (bpm)`** — 933 (93–206) — → `strains.maxHeartRate` → Strain screen "Peak HR"
- [x] **`Average HR (bpm)`** — 933 (56–101) — → `strains.averageHeartRate` → Strain screen "Average HR"

### Sleep

- [x] **`Sleep onset`** — 910 — → `SleepSession.startTime`
- [x] **`Wake onset`** — 910 — **the day key**, and → `SleepSession.endTime`
- [ ] **`Sleep performance %`** — 910 (5–100) — parsed, consumed by nothing. **Decision — do not cover.** `SleepSession.sleepSufficiencyPercentage` derives asleep-over-need ([SleepSession.swift:193](../ios/Sources/Whoopsy/Domain/Entities/SleepSession.swift#L193)); the two disagree on **454 of 910 nights** — but that total hides a regime change and must not be quoted alone: across the export's **137-day gap (2024-12-31 → 2025-05-17)** WHOOP's column becomes a different function, matching the app's expression on **423 of 451** pre-gap nights (MAE 0.062) and only **33 of 459** after it (MAE 7.05). So on the older half the app's derivation *is* WHOOP's, and the disagreement is entirely a post-2025 phenomenon. Re-measure era by era and by driving `sleepSufficiencyPercentage`, not by re-deriving the ratio — the clamp is part of the answer (dropping `min(100, …)` reports 457), and one rule is the point. **The column stays uncovered, but the derivation is now drawn**: it is the SLEEP PERFORMANCE breakdown row on the Recovery screen and, below it, the sleep-performance week chart (`MetricDay.sleepSufficiency` → `WeekBarSeries(sleepSufficiencyWeek:)`), and it is the HOURS VS. NEEDED row and need card on the sleep-performance screen Home's sleep ring pushes. **The ring itself is now `SleepScoreScoring`'s composite** (`MetricDay.sleepScore` → `WeekBarSeries(sleepScoreWeek:)`), which divides by the same need but adds efficiency, restorative share and timing; it is not this column either. So this line reads as "the export's number is not used", not "the quantity is absent from the app" — the figure on all of those is this app's own, and it will not match WHOOP's for the same night
- [x] **`Respiratory rate (rpm)`** — 910 (13.5–20.2) — → `sleeps.respiratory_rate`, `recoveries.respiratory_rate` and `MetricDay.respiratoryRate` → the Recovery screen's RESPIRATORY RATE breakdown row and the Respiratory Rate week chart under it. Read to **one decimal** there, because a week spans about two units — the reference week is 14.8…16.5, which whole numbers flatten to six `15`s. **Now a two-producer column**, the same shape as `Sleep consistency %` below: stored verbatim for an imported night, computed by `RespiratoryRateMath` ([RespiratoryRateMath.swift](../ios/Sources/Whoopsy/Core/Math/RespiratoryRateMath.swift)) for a strap night, and the two are told apart only by `source`. The model is respiratory sinus arrhythmia off the R-R series — `docs/ALGORITHMS.md` §4 — and it is **unvalidatable against this app's data**, because the export carries no R-R series at all
- [ ] **`Asleep duration (min)`** — 910 (68–940) — parsed into `WhoopExportRow.asleepMinutes` and read by **nothing**. **Redundancy**: `totalTimeAsleepSeconds` sums the three stages, and on this export the two agree **exactly on all 910 rows**
- [ ] **`In bed duration (min)`** — 910 (87–954) — parsed into `WhoopExportRow.inBedMinutes` and read by nothing. **Redundancy, and the measurement is the interesting part**: `sleepPeriodSeconds` (asleep + awake) reproduces this column **exactly on 904 of 910 rows**, so the app already holds this number and the column has nothing to add — see the in-bed section below for the 6 that differ and why storing them would not help
- [x] **`Light sleep duration (min)`** — 910 (31–940) — → `sleeps`
- [x] **`Deep (SWS) duration (min)`** — 910 (0–173) — → `sleeps`
- [x] **`REM duration (min)`** — 910 (0–241) — → `sleeps`
- [x] **`Awake duration (min)`** — 910 (1–252) — → `sleeps`

**The four stage columns above gained a second reader, and no new column is covered by it.**
`SleepStageRangeScoring` reads all four off a `SleepSession`: their sum is the `DURATION` the card
prints, each one's share of that sum is the percent column, and the same four shares taken over the
prior thirty nights give the bands the bars mark. So `SleepDetailView` now draws each of these columns
twice — once as the night's own breakdown and once as a row of the typical-range card below the band
legend. They were `[x]` before that and are `[x]` after it, which is the point: this is a second reader
of a covered column, not a newly covered one, and the rule that a *parsed* column is not a covered one
does not make a covered column count twice. `docs/ALGORITHMS.md` §4 carries the band's definition and the
explicit note that WHOOP publishes no stage boundaries, so every threshold in it is this app's own.
- [x] **`Sleep need (min)`** — 910 (321–650) — → `sleeps.total_sleep_needed` → Home's SLEEP NEEDED panel, **and the SLEEP NEEDED figure of the `HOURS VS. NEEDED` card on the Sleep detail screen**. Stored verbatim; imported and strap nights must not be crossed
- [x] **`Sleep debt (min)`** — 910 (0–127) — → `sleeps.sleep_debt` (× 60, seconds like every duration on that table) → the **`Sleep Debt` row of the `HOURS VS. NEEDED` card's breakdown box**, which is also the column's second consumer of `Sleep need (min)` above: the card's other row is that need minus this debt. Stored verbatim for an imported night, computed by `SleepDebtMath` ([SleepDebtMath.swift](../ios/Sources/Whoopsy/Core/Math/SleepDebtMath.swift)) for a strap night — **a two-producer column**, distinguished by `source`, like `Sleep consistency %` below. **The two producers' values are not the same quantity and the card may only use one of them**: WHOOP's need is a total containing its debt term, so `need − debt` is WHOOP's own base-plus-strain, while `SleepNeedMath`'s need deliberately omits any debt term — so the box is gated on `SleepSession.hasWhoopSleepNeed` and is not drawn at all on a strap night, where both of its rows would sum to the printed total and both be mislabelled. The card is gated on the *pair*, so a night with no stored debt and a night whose debt exceeds its need draw no box either. The row carries no band, because a running deficit is not monotone the way the three banded rows are. The model is lagged (WHOOP's column correlates 0.891 with the *prior* night's shortfall against 0.506 with its own) and fitted, MAE 8.31 against a column of sd 33.9 — `docs/ALGORITHMS.md` §4. **It stays out of `SleepNeedMath`**, and that is a separate decision from covering the column: the 7-night deficit term buys 0.35 of a point for a second fitted constant, and the nap term that the newly-stored `naps` table makes measurable is significant in sample (t = −5.74) and harmful out of it (3.634 against 3.588). Both measurements are in `docs/ALGORITHMS.md` §4
- [ ] **`Sleep efficiency %`** — 910 (59–99) — not parsed. **Decision — do not cover, and the reason is measured.** `sleepEfficiencyPercentage` is the standard TST-over-TIB and matches this column on 826 of 910 rows. On 83 of the other 84 the mismatch is **not** a denominator problem: the export's own `In bed duration` equals asleep + awake on those rows, and the column still reads 2–5 points higher, so **WHOOP's efficiency is not a function of the two durations WHOOP publishes beside it**. There is no input to store that would reproduce it — see the efficiency section below
- [x] **`Sleep consistency %`** — 892 (7–94) — → `sleeps.sleep_consistency` → the **SLEEP CONSISTENCY** row of the Sleep detail screen **and the card of the same name that closes the page**. `SleepConsistencyScoring.summary(for:history:score:typicalScore:)` reads the stored value for the anchor night (stored-first, `session.sleepConsistency`), scores the four priors through `SleepConsistencyMath` when they carry none, and hands the pair to `SleepViewModel.consistencySummary` for `SleepConsistencyCard`; the card's headline is the figure the row prints two elements up, and the window mean it carries is a mean over this column. That mean is **computed and spoken but not drawn**: `SleepConsistencyCard.headline` passes `change: nil`, so a sighted reader sees the figure alone and the mean reaches only the card's `spoken(for:)` description. **The mean skips nights the model cannot score rather than counting them as zero**: `typicalScore` maps each window night stored-first and `compactMap`s the ones that still produce nothing, so two stored values beside two unscoreable nights average the two, and the mean is withheld below `RecoveryScoring.minimumBaselineDays`. The chart's five columns are all imported nights on a real device, so the stored value is what every one of them is drawn from. Stored verbatim for an imported night; a strap night is computed by `SleepConsistencyMath` ([SleepConsistencyMath.swift](../ios/Sources/Whoopsy/Core/Math/SleepConsistencyMath.swift)), a four-prior boundary-shift fit — `docs/ALGORITHMS.md` §4. The column is nullable because the two producers must stay distinguishable: NULL is "not scored", `0` is "scored as badly as the scale allows"

---

## 2. `sleeps.csv` — 18 columns · 918 rows

**Every column below is uncovered for the same single reason, so it is stated once:**

> **This file is now bundled, and read for its nap rows alone.** It is in `Package.swift`'s
> `resources:` as of `v11`, and every column below other than `Nap` is still uncovered — not because
> nothing reads the file, but because those columns duplicate `physiological_cycles.csv` for the same
> 910 nights. **`WhoopExportParser.parseNaps` requires the `Nap` column**, so pointing the nap reader
> at the cycle file throws `missingColumns(["Nap"])` rather than reporting a successful import of
> nothing.
>
> **Naps arrive from this file and from nowhere else — strap-side nap detection is rejected, not
> deferred.** The strap records motion and heart rate, and it produces a step count of its own
> (`docs/ALGORITHMS.md` §7) — which does not change the answer, because the binding constraint is
> **specificity** rather than sensitivity and a step count is not what supplies it. The only
> general-purpose open-source pipeline
> (GGIR/wristpy) is accelerometer-only, ships nap detection **off by default**, and warns that
> nonwear may itself be detected as a nap. The one PSG-validated pure-actigraphy threshold
> (Kanady 2011, ≥ 40 min) reaches sensitivity 92–96 % but **specificity 40–67 %**, and a step count
> says nothing about whether a still hour was a nap or a film. On this screen a nap is
> an **absent row** rather than a dash, so a detector at 50 % specificity would put a row on days the
> user did not nap — a fabricated measurement of exactly the class the absent-row rule exists to
> prevent, drawn on a card whose whole premise is that not napping is an ordinary answer.
> **Nothing shipped is removed by this decision**: the `v11` table, the NAP row, the bundled-CSV read
> and its tests all stand.

What reading it would buy is measured, and it is small: its 910 non-nap rows carry the *same 910
wake onsets* as the bundled file — `0` sleeps-only, `0` cycles-only — so its entire unique
contribution is the **8 nap rows**, which now have their own table — `naps`, added by `v11` — and a
reader. The nap path is the whole of this file's coverage.

- [ ] **`Cycle start time`** — 918 — not parsed. The file is bundled and read, but only `parseNaps` reads it, and that requires the `Nap` column alone
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
- [ ] **`Sleep debt (min)`** — 918 — not parsed **here**. Redundant with §1: the two files carry the same 910 nights, so this column and the bundled file's are the same 910 values. §1's line is the one that is covered
- [ ] **`Sleep efficiency %`** — 918 — not parsed; derived on the entity
- [ ] **`Sleep consistency %`** — 892 — not parsed here. Already covered for the 910 nights
- [x] **`Nap`** — 918 (`false` × 910, **`true` × 8**) — **the only column in this file that carries anything the bundled export does not**, and the one column here that is consumed. It gates `parseNaps`, and the 8 rows it selects → `naps` (`id`, `date`, `started_at`, `ended_at`, `asleep_seconds`, `source`) → the **NAP** row of the Sleep detail screen. The 8 naps run 33–237 min asleep. **They are keyed on their own onset, not their wake**, which is the opposite of the night table's rule and is worth a whole day on the two that cross midnight; and a nap's own `Sleep performance %` (6–43, on a night-sized denominator) is deliberately **not** stored — `SleepNap` carries its window and its duration and nothing derived from a need it does not have

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

**673 workouts across 445 distinct days, 2023-07-23 → 2026-08-21** — 1.5 per day, which is exactly
why `workouts` is keyed on `id` and not on `date` (`CLAUDE.md`). It is bundled and read, and its path
is `WhoopExportParser.parseWorkouts` → `WhoopExportImporter.importWorkouts`, reached from
`importBundled(.workouts)` — the `IMPORT WORKOUTS` button on the profile page's `LOGS` pane. What it
buys is the strain page's two `HEART RATE ZONES` rows
— the only zone breakdown in the whole export — the `ACTIVITIES` card's worth of sessions on Home, and
the name each of those rows is labelled with.

**Twelve of the seventeen columns are covered, and five of those twelve are one block.** The five
`HR Zone n %` columns are read **all-or-nothing**: `WhoopExportRow.hrZonePercents` is `nil` unless all
five parse, because a partial block would sum to a confident figure from a partial set. They are
stored as percentages on `workouts.hr_zone_percents` rather than as the seconds they imply, so the
file's own resolution survives and no derived duration is baked into a row — the conversion to
seconds happens once, on read, in `WorkoutZoneTime`.

### Workout identity and window

- [ ] **`Cycle start time`** — 673/673 — parsed into `WhoopExportRow.cycleStart`, and **not covered**: `parseWorkouts` requires the column, so its absence throws, but no reader consumes the value — these sessions are keyed on their own two instants rather than on a cycle
- [ ] **`Cycle end time`** — 673/673 — not parsed. **Redundancy**: the session's extent is its own `Workout end time`
- [x] **`Cycle timezone`** — 673/673 — applied as the UTC offset when every date in the row is built, workout start and end included; a row whose offset cannot be read throws rather than shifting silently
- [x] **`Workout start time`** — 673 (all distinct) — → `WorkoutSession.startedAt`, and half of the **derived id** ([WhoopExportImporter.workoutID](../ios/Sources/Whoopsy/Data/Import/WhoopExportImporter.swift)): the two unix seconds are packed as big-endian 64-bit halves into a `UUID`. Distinct on all 673 rows' starts and on all 673 start+end pairs, which is what makes the id collision-free — and a **derived** id rather than a `UUID()` is what makes a second press of the import button update the same 673 rows instead of writing 673 more, since GRDB's `save` is INSERT-or-UPDATE *by primary key*
- [x] **`Workout end time`** — 673 — → `WorkoutSession.endedAt`. A row whose end is not after its start is refused rather than stored
- [ ] **`Duration (min)`** — 673 (1–458) — not parsed. **Redundancy, and measured**: it equals `floor((end − start) / 60)` on **670 of 673** rows and exceeds the span on **0**, so it is the stored pair with a minute's truncation and nothing more. Zone seconds are therefore `percent/100 × (end − start)`, which is strictly finer than going through this column

### Activity and intensity

- [x] **`Activity name`** — 673/673 non-empty (**21 distinct**; `Walking` 222, `Activity` 197, `Yoga` 89, `Dance` 34, `Basketball` 28, `Manual Labor` 18, …) — → `WhoopExportRow.activityName` → `WorkoutSession.activityName` → `workouts.activity_name` (`v15`) → the row's label in Home's `ACTIVITIES` card, uppercased at the drawing by `HomeDashboardView.activityRow`, and its glyph by [ActivityGlyph](../ios/Sources/Whoopsy/Presentation/DesignSystem/ActivityGlyph.swift). Read **without being required** — the one field on the workout row that is, because a name has a natural absence while a measurement does not — so a file without the column imports and every row falls back, rather than throwing. `Activity` (197 rows) and `Other` (11) are deliberately unmapped: they are WHOOP's own words for an activity it did not categorise, so they draw the `figure.run` fallback and print `ACTIVITY` like every other unmapped name
- [x] **`Activity Strain`** — 673 (0–19.1) — → `workouts.strain` **verbatim**, the same bargain §1's `Day Strain` makes: the export carries no heart-rate series, so there is nothing to integrate. `WorkoutSession.strain` is what the `ACTIVITIES` card and the workout summary read
- [ ] **`Energy burned (cal)`** — 673 (2–3011) — parsed into `WhoopExportRow.energyKcal` and read by **nothing on this path**. §1's `Energy burned (cal)` covers the column for a cycle and lands in `strains.kilojoules`; nothing prints either
- [x] **`Max HR (bpm)`** — 673 (76–206) — → `WorkoutSession.maxHeartRate`
- [x] **`Average HR (bpm)`** — 673 (57–153) — → `WorkoutSession.averageHeartRate`

### The zone block — the only zone breakdown in the export

- [x] **`HR Zone 1 %`** — 673 (0–100) — the first of `WorkoutSession.hrZonePercents`, all five or none
- [x] **`HR Zone 2 %`** — 673 (0–84) — second
- [x] **`HR Zone 3 %`** — 673 (0–93) — third. Zones 1–3 are summed for the strain page's **`HEART RATE ZONES 1-3`** row
- [x] **`HR Zone 4 %`** — 673 (0–76) — fourth
- [x] **`HR Zone 5 %`** — 673 (0–36) — fifth. Zones 4–5 are summed for **`HEART RATE ZONES 4-5`**

**Three properties of this block decide what the two rows may claim, and each is measured over all
673 rows.** The five **sum to ≤ 100 on every row** (0–100) and to exactly 100 on 146 of them — the
remainder is time below zone 1, for which the export publishes no column, so the two rows deliberately
do **not** sum to the day's workout duration. **45 rows are all-zero in every band**, and those are
**measurements rather than absences**: a session that never reached zone 1 is a real `0:00`, and
`WorkoutZoneTime.aggregate` keeps them in while dropping the rows whose block is `nil`. And a session
this app recorded itself carries no block at all, which is `nil` and draws a dash — the user's rule,
applied per row. The zone figures are **WHOOP's own measurement read out of a column**, not this app's
computation from a heart rate it measured: the export has no HR series for `StrainAccumulatorMath` to
integrate, `biometric_samples` holds no rows on any database here, and the drain's type-24 record now
has a reader (§5) but no row has ever been drained. `docs/ALGORITHMS.md` §2 carries the conversion.

- [ ] **`GPS enabled`** — 673 (**`false` on all 673**) — not parsed, and **nothing to parse**: the export carries no route for any workout, so `workout_route_points` can never be filled from this file

---

## Cross-file findings, measured

Four facts that decide more than one line above.

1. **`sleeps.csv` is the bundled file plus eight naps.** The 910 non-nap wake onsets are the same
   910 days, set-for-set — `0` sleeps-only, `0` cycles-only. So the file's entire unique
   contribution is the 8 nap rows (33–237 min asleep). All 8 fall on a day that already holds a
   night, which would be a collision if naps were aimed at `sleeps`, whose primary key is `date`;
   they have their own table instead (§2), keyed on `id`, so the question does not arise.

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
   rows. It now fills `workouts` itself (§4), which is what its twelve covered columns buy; the
   route and split tables it maps onto stay empty on every imported session, and no CSV can fill
   either. The workout HUD was the app's only *recording* path and it was deleted with the Workout
   tab; the `+` menu's `START ACTIVITY` replaced it, opening a live session that writes a `workouts`
   row on END. **That session is now the route table's one producer, and it is opt-in** — a
   `RECORD ROUTE` toggle on `LiveSessionView`, off by default, which writes `workout_route_points`
   through `SaveWorkoutUseCase` when it was on and `route: []` when it was not. So an imported
   session's route is empty (the export carries no position for any of its 673 rows) and so is a
   recorded session the user did not opt in to, which is the ordinary case rather than an absent
   column. **`workout_splits` still has no producer at all**: there is no lap model and no control
   that creates a split, so `splits: []` is passed deliberately at that one call site. That leaves
   §14's own fixture, through `GRDBWorkoutRepository.save`, as the proof of the storage seam for
   both tables — and for the split table it is still the only writer anywhere.
   `HomeDashboardView`'s
   `ACTIVITIES` card reads a session's `activityName`, strain and span and neither field.
   A self-recorded session is also the one `workouts` row whose `activityName` is `nil`, so it draws
   the fallback chip rather than a named one; that is the same absence the importer leaves on a row
   whose `Activity name` is empty, not a second state.
   **`journal_entries.csv` is the only file left unread**, and it is not one
   decision away from being read: it needs a table, a parser and a UI that does not exist at all.

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
([SleepSession.swift:189](../ios/Sources/Whoopsy/Domain/Entities/SleepSession.swift#L189)), and its doc comment carries the three
measurements above so the next reader does not try `endTime − startTime` again.

---

## 5. Strap historical sync — **not a column, and not covered by the rule above**

**This section is not part of the per-column inventory.** Every `[ ]` above is a CSV column; every
`[ ]` here is a work item, and all of them are **work** — none is a decision and none is a
redundancy. The section exists because the strap holds **a backlog of cached data** that this app is
supposed to pull down on sync, and it has never done so on a strap. **How far back that backlog reaches is
unmeasured and the sources disagree by a factor of five** — two reverse-engineering projects say ~14
days and neither measured it, while WHOOP's own user-facing guidance says ~72 hours — so plan for a
drain that does not assume a depth. `docs/BLE_PROTOCOL.md` §4 carries the disagreement.

**Sequencing: this is not started until the screens are considered done.** The gate is deliberate,
not a technical dependency — the strap feeds the screens, so building the sync first would mean
writing interfaces around a data shape that was still moving. Nothing below should be picked up
while UI work is open, however urgent the list reads.

Unlike every other section in this file, **this one has not been fully exercised against hardware.**
A 5.0 has run the chain end to end — bond, enable, drain, decode and store — so those parts are
observations rather than readings; the 4.0 half remains read off the code and the spec, and the
strap's own archive stopped growing (see below). Read the unmeasured lines as what is wrong on paper,
not as a list of observed failures.

**The table has a reader, and the gaps below are what stand between the strap's cache and it.**
The sleep detail screen's `HOURS OF SLEEP` card draws the night's heart rate out of
`biometric_samples` (`HoursOfSleepChartSeries`, read in
`SleepViewModel.resolveHoursOfSleepSeries`), so an empty table is not latent — it is the `No
Data` state on a screen a user can open, on every night the export can show. Nothing below changes
because of it: a read path does not drain anything, and the gaps in this section are exactly what
still stand between the strap's cache and that chart. It is recorded here so the next person to read
a screenshot of that chart knows the absence is this section's, not a chart bug.

### First question: does a disconnected wear write anything?

**The capacity question cannot be asked until this one is answered.** The 5.0's archive held two
~60-record bursts stamped months earlier, and every attempt to make it grow — an overnight, a `0x1D`
reboot, a 15-minute disconnected wear and a hard Bluetooth-off window — returned the same
`HISTORY_END` at the drain's own instant. That is evidence that nothing is being written, not
evidence of a small cache, and a capacity test against a non-appending archive measures nothing.

**Ask the strap before spending a night.** `0x22 GET_DATA_RANGE` now decodes its 65-byte reply and
logs the **write page** and **acknowledged page** (`WhoopDataRange`; the layout is the community reference's #689
diagnostic, reported and unconfirmed on 5.0/MG, and it gates nothing). Run one drain and record the
write page, then run another after a disconnected wear. **Write page unchanged** means nothing was
written, and capacity is moot. **Write page moved with a backlog** means records exist and the drain's
request or ACK is at fault. This costs minutes rather than a night.

**Retention is reported rather than measured.** Current 4.0/5.0 firmware is reported at ~14 days; the
~72-hour figure is reported to describe the **3.0 and older firmware**. Both are commercial/reference
claims, not this unit's behaviour. `docs/BLE_PROTOCOL.md` §4 and §7 Q10 carry the sources.

**The ACK and cadence are part of the mechanism.** `HISTORY_END` carries an eight-byte block whose
first `u32` is the trim cursor; `0x17` is `[0x01] + those exact eight bytes`, written only after the
records are stored, and it may release the strap's history. This app now writes that ACK confirmed
and preserves the token. The community reference re-offloads the type-47 store **every ~15 minutes while connected**, so
if the write page moves during a session, one drain per connection is too rare.

#### Test A — does the write page move? (minutes, no night needed)

**Before starting:** the build with the range log, strap worn, bonded, clock set. Keep the phone's
Bluetooth on; force-quitting the app is what releases the strap.

1. Open the app, connect, and tap `SYNC HISTORY` once.
2. Record the log line `Data range: read=… write=… acked=… capacity=… backlog=…`. **If the line never
   appears, that is itself a result** — the strap did not answer `GET_DATA_RANGE`.
3. **Force-quit from the app switcher** (not merely background it). Wear the strap for **20–30
   minutes** away from the phone, or turn the phone's Bluetooth off.
4. Reopen the app, reconnect, and tap `SYNC HISTORY` once. Record the line again.
5. Compare the two write pages. Repeat A once: a single pair is a lead, two identical pairs are a
   result.

| What you see | What it means | Next |
| :--- | :--- | :--- |
| **write unchanged**, acked unchanged, backlog 0 | Nothing was written during the disconnected window | The strap is not storing. Suspect the subscription state or firmware; Test B will not help |
| **write moved**, acked behind it | The strap wrote and there are unread records | If the drain still returns 0 records, the **drain** is at fault — debug the request/ACK path, not storage |
| **write moved**, acked caught up | It wrote and the app already drained it | Working; go to Test B for capacity |
| No `Data range:` line | `GET_DATA_RANGE` is unanswered on this firmware | Fall back to Test B; the query is a lead, not a required path |

**Two cautions.** The 65-byte layout is the community reference's unconfirmed 5.0 diagnostic: a nonsensical number means
the layout is wrong for this firmware, not that the strap is broken. And **never send `FORCE_TRIM`
(`0x19`)** — it is the command that wiped five hours in the 4.0 investigation.

#### Test B — the disconnected wear (a night)

Only needed if A is ambiguous or to confirm a pass. **It costs a night of motion, sleep and
recovery**, so it must not be the same night the sleep model is being tested.

1. Confirm the clock is set. A banked record is stamped by the strap's own RTC, and a wrong clock
   files history onto the wrong day (`docs/BLE_PROTOCOL.md` §5, Q7).
2. Force-quit the app and wear the strap for **4–8 hours**.
3. Reconnect and run `SYNC HISTORY` once. Record the range line, the outcome, and every record's
   timestamp.
4. **Pass**: at least one record's timestamp falls inside the wear window, or the write page moved.
   **Fail**: both the range's write page and the newest record are unchanged.
5. Repeat once if it fails. A single window is a result only if the procedure is identical.

#### Test C — capacity (only after a pass)

Wear disconnected for increasing spans — **24 h → 72 h → 7 days → 14 days** — draining between each
and recording the **oldest timestamp** the strap still returns. That is the only measurement that can
settle the 14-day-versus-72-hour disagreement, and the point at which the oldest record starts moving
forward is the point at which the ring overwrites.

**What to record each time.**

| When | write | acked | capacity | backlog | Drain outcome (records / newest stamp) | App state | Phone Bluetooth | Firmware (DIS `2A26`) |
| :--- | ---: | ---: | ---: | ---: | :--- | :--- | :--- | :--- |
| | | | | | | connected / force-quit / background | on / off | |

**A subscription is the untested alternative explanation.** WHOOP's terms say data collected while
the account is inactive may not be available on the device or recoverable; third-party guides say the
strap keeps recording heart rate and R-R regardless. Test A distinguishes those on this unit. Nothing
in this app can verify the account's side, so record it as a hypothesis, not a cause, until the same
test runs on a strap with an active membership.

**Firmware is the other variable.** The community reference's 5.0/MG baseline is `50.42.1.0`; record this strap's DIS
`2A26` reading beside the result. A write-page result from one firmware is not a statement about
another.

### The chain that exists

Home's status badge → `DeviceSettingsView` → `DeviceViewModel.syncNow()` ([DeviceViewModel.swift:22](../ios/Sources/Whoopsy/Presentation/Screens/Device/DeviceViewModel.swift#L22)) →
`SyncHistoricalDataUseCase.execute()` ([SyncHistoricalDataUseCase.swift:23](../ios/Sources/Whoopsy/Domain/UseCases/SyncHistoricalDataUseCase.swift#L23)), which returns a `HistoricalSyncOutcome` →
`WhoopBLEDeviceRepositoryImpl.requestHistoricalSync` ([line 107](../ios/Sources/Whoopsy/Data/BLE/Repositories/WhoopBLEDeviceRepositoryImpl.swift#L107)) →
`WhoopCommandFrames.historicalSyncRequest` ([line 43](../ios/Sources/Whoopsy/Data/BLE/Parser/WhoopCommandFrames.swift#L43)) →
the profile's own builder (`WhoopPacketEncoder` or `WhoopPacketEncoder5`) → `WhoopBLEManager.drainHistoricalData` → `HistoricalDrainSession`.

**Inbound frames do not continue that line.** A frame reaches `WhoopPacketDecoder.decodeProprietaryFrame`
([WhoopPacketDecoder.swift:147](../ios/Sources/Whoopsy/Data/BLE/Parser/WhoopPacketDecoder.swift#L147)) and
comes back a `WhoopRawFrame`, which is where the decoder stops; the manager then routes by what the
frame *is* — metadata to the drain session, a motion record to `MotionPayloadDecoder` and on to
`StepAccumulator` → `stepCounts`, a heart-rate record to `HeartRatePayloadDecoder` →
`historicalTelemetryStream` → `biometric_samples` (the 5.0/MG's `R18` or the 4.0's type 24), and a
packet-48 (5.0) or `0x30` (4.0) event to `StrapEventDecoder`, whose wrist and charging pairs update
`WhoopDevice.isOnBody` / `isCharging`. `yieldTelemetry` → `StreamBiometricsUseCase` →
`biometric_samples` is the **live** path and not this one. **Both generations' heart-rate records are
walked now**, though on offsets no hardware here has confirmed — see the record-walk item below.

**The pipe is connected end to end, and on both generations it now reaches a heart rate.** The
decoder validates the envelope and hands up a `WhoopRawFrame`: start-of-frame, declared length, header
checksum and payload checksum are all checked. `HeartRatePayloadDecoder` walks the 5.0/MG's `R18`
layout into a `BiometricSample` — heart rate at payload `[11]`, R-R at `[13 + 2i]` in 1/1024 s, the
strap's own unix at `[4]` — and the 4.0's type-24 record at heart rate `[14]`, R-R at `[16 + 2i]` in
**signed milliseconds**, the strap's own unix at `[4]` — and `SyncHistoricalDataUseCase` persists
those samples as the drain runs. The deleted `decodeHistoricalSyncPayload` and
`decodeLiveTelemetryPayload` must not be restored: they were the 16-byte-chunk walk this pass replaced.

**There are two decoded record types, the heart-rate one now has a walk on both generations, and a
third frame class feeds the device page rather than the database.** `MotionPayloadDecoder` reads the
strap's accelerometer out of the two motion layouts (R21 for the 5.0/MG, R10 for the 4.0, dispatched
by **generation** rather than by trying one and falling back) and `TrackStepsUseCase` accumulates a
day's steps from it into `stepCounts`. `StrapEventDecoder` reads the event number off the inner `cmd`
byte — which is what makes one decoder serve both envelopes — and `DeviceInformationPayload` turns the
standard DIS strings into firmware and serial. Motion, heart rate, events and DIS are four different
things on one link, and a step count is not a beat.

Both the encoder and the decoder take a `WhoopProtocolProfile`, and both refuse rather than guess when
handed a generation this build cannot frame. **All three WHOOP models now carry a transmitted opcode
table** — the 4.0's `commandOpcodes` and the 5.0/MG's `syncOpcodes`, which are separate types because
the two generations share only part of their numbering — so a 5.0 or 5.0 MG is not refused a
command on the grounds that this build cannot frame one. **What is unproven on that generation is
whether it will answer**: its command characteristic refuses writes until the link is **encrypted**
(`CBATTError.insufficientAuthentication` / `.insufficientEncryption`), a bond a third-party app
establishes by just-works pairing but whose failure is silent (`docs/BLE_PROTOCOL.md` §7 Q6), and the
strap page says so in as many words rather than in a generic sentence. What remains below is what stops the drain
producing a heart rate.

### The shape of the protocol, from the open-source references

Added after a survey of the two public reverse-engineering projects (`docs/BLE_PROTOCOL.md` §Sources).
**This changes the status of several items below from "unknown" to "documented but unverified"** —
it does not make any of them measured. Three straps are in scope and they do not share a wire
format: **4.0, 5.0 and 5.0 MG**, with two envelopes, two header CRCs and two non-overlapping
packet-type numberings.

- **The record layout is known for 4.0.** The flash record is type 24, packet type `0x2F`, one per
  second of wear, with a **96-byte header** carrying a u32 UNIX timestamp at `[7:11]` and
  sub-seconds at `[11:13]`. Heart rate is at `[17]`, R-R intervals at `[18:19+2n]`. Marked verified
  by the source, and tested by it on 4.0 only. **A second, independent parser now corroborates the
  same map at a measured scale**: the research reference's `parse_r24` reads these fields at these offsets and
  reports them "verified on **127,971 of our own stored records** and cross-checked against an
  independent implementation", with the heart rate matching the live stream within a beat — and it
  supplies the **minimum inner length of 89 bytes** a decoder needs as a guard. So the map below has
  two independent sources, and nothing here has to be discovered before the parser can be written.
- **The drain is a loop with a mandatory ACK.** `0x16` starts it, records stream as `0x2F` punctuated
  by `0x31` metadata markers, and each `HISTORY_END` carries an 8-byte continuation token that must
  be echoed in a `0x17` reply. **Without a correct ACK the strap re-sends the same batch forever.**
  The cursor persists across connections, so a partial drain resumes, and the drain never erases
  flash — it is re-runnable.
- **5.0 / MG differ where it matters most for this work.** Packet types are 35/36/47/48/49 rather
  than `0x23`/`0x24`/`0x2F`/`0x30`/`0x31`; the envelope inserts a format byte and swaps CRC8 for
  CRC16-Modbus; the inner record moves from offset 4 to offset 8. And the 5.0 reference **does not
  state that type-47 records carry a per-record timestamp**, describing a session↔wall clock
  correlation instead — so 4.0 appears to time each record and 5.0 may not.

### Blocked on hardware — do not guess twice

- [ ] **The 4.0's eight-step handshake is unimplemented; the 5.0/MG's hello is sent and confirmed.**
  `docs/BLE_PROTOCOL.md` §3 specifies a strict eight-step sequence a freshly bonded 4.0 must be walked
  through before it will serve a historical sync, and it is 4.0-only and unverified. What does exist
  is the 5.0's static `CLIENT_HELLO`, constructed by `WhoopPacketEncoder5.hello`
  ([WhoopPacketEncoder5.swift:130](../ios/Sources/Whoopsy/Data/BLE/Parser/WhoopPacketEncoder5.swift#L130)),
  written by `WhoopBLEManager.didDiscoverCharacteristicsFor` as a **confirmed** command, and waited on
  before any proprietary subscription or producer is armed — a pre-bond notification subscription is
  refused with "Authentication is insufficient" and wedges the bond. (A command characteristic with
  no `.write` property is the one fallback: no confirmation can arrive, so the arms go out anyway.)
  `WhoopCommandFrames` carries the live-HR arm (`realtimeHeartRate`) beside its other builders (motion
  enable, history request, data ACK, abort, set clock, clock read-back). **On a 5.0/MG the connect pass
  now opens with command 10 `SET_CLOCK` and 11 `GET_CLOCK`, before any producer is armed** — an
  un-clocked 5.0 banks no sensor data, which is the empty-drain failure this app had been chasing. What
  remains is the 4.0's eight-step sequence.
- [x] **The ACK loop.**
  `HistoricalDrainSession` replies `0x17` with the eight-byte token each `HISTORY_END` carries, keeps
  listening, and stops on `HISTORY_COMPLETE` without acknowledging it. Termination is that, an idle
  timeout whose window comes off the profile (8 s for the 4.0, 60 s for the 5.0/MG), or catching up to
  the live edge, which is two-sided because a strap whose RTC is wrong is wrong in both directions.
  **A drain request must never be sent without this loop running**: a batch that is not acknowledged
  is re-sent forever, which is worse than a command the strap ignores
- [x] **The request opcode is `0x16` on both generations, and it lives in the opcode tables rather than
  in the builders.** §2 assigns `0x30` to **Asynchronous Event / Heartbeat**, so an outbound `0x30`
  asks for an event rather than a drain — a command a strap ignores
- [x] **Both heart-rate records are walked, and the 4.0's type 24 is read at published offsets rather
  than at the live ones.** `HeartRatePayloadDecoder.decodeHistorical` dispatches on `frame.generation`.
  The 5.0/MG's `R18` reads payload `[11]` (heart rate), `[12]` (interval count, capped at four) and
  `[13 + 2i]` (1/1024 s ticks), stamped from its own unix at `[4]` and guarded by the exact 109-byte
  payload. The 4.0's type-24 record reads `[14]` (heart rate), `[15]` (count, capped at four),
  `[16 + 2i]` (**signed** `i16` milliseconds, dropped at `<= 0`) and unix at `[4]`, behind an exact
  type-`0x2F` / seq-24 test and a minimum 86-byte payload — the record's 89-byte minimum inner length
  less the three prefix bytes. Both refuse a zero unix and a zero heart rate, so a record cannot be
  filed on day zero or at a zero beat. **The 4.0's record header is 96 bytes** (§4), so the 16-byte
  chunk walk through the *live* offsets remains the mistake it was: `decodeHistoricalSyncPayload` and
  `decodeLiveTelemetryPayload` stay **deleted**. **None of this is a capture.** The type-24 map has two
  published sources, one having confirmed it across 127,971 records, but every offset here is
  exercised only by hand-built frames — §7's cheapest-first capture order still stands, and the log
  lines this pass adds are what a sideloaded drain will read.
- [x] **Events decode into wrist and charging state, and battery stays log-only.** `StrapEventDecoder`
  takes the event number from the inner `cmd` byte — frame 10 on 5.0, 6 on 4.0, the same field in
  either envelope — with the timestamp as a u32 LE at payload offset 1. IDs 7/8 flip
  `isCharging`, 9/10 flip `isOnBody`, and 13 `RTC_LOST` is logged at `.warning` without changing the
  device, because the consequence is on the day key rather than on the page. Battery (3), boot (15),
  set-RTC (16) and anything unknown are `.other`: logged with the full payload and acted on by nothing,
  since no published body exists to read. `0x2A19` stays the battery source.
- [x] **The Device Information Service is read, and the fabricated firmware default is gone.**
  `2A26` firmware and `2A25` serial are read once per link after the connect pass — post-bond on a
  5.0/MG, where a pre-bond read is refused — trimmed of NULs and whitespace, and written through
  `WhoopDevice.updating` so neither displaces battery, RSSI or the wrist flags. `WhoopDevice.firmwareVersion`
  now defaults to `nil` and the device page draws a dash until the strap answers. Serial is stored and
  logged but not drawn: the facts row is three columns, and a fourth would squeeze the peripheral
  identifier.
### Not blocked — true whatever the strap turns out to say

- [x] **A drained record carries its own instant on both generations, so a batch cannot collapse onto
  today.** The R18 walk reads payload `[4]`, the type-24 walk reads payload `[4]` (record `[7:11]` of
  the 96-byte header), and an R21 motion batch carries `seconds + fraction / 32768`; each refuses a
  stamp of zero, and the motion path additionally refuses one outside the window it asked for — which
  is what turns the `RTC_LOST` caveat below from a silent wrong day into no row. This matters beyond
  this section: `recoveries`, `sleeps` and `strains` are all keyed on `startOfDay`, and the app's whole
  day model cannot represent a batch spanning fourteen of them, so a batch collapsed onto one instant
  would corrupt three screens at once. That the 5.0 lays its unix at the 4.0's record-relative offset
  is still §7 Q3's unconfirmed shift: the decoder reads the published field, and a capture is what
  would confirm it.
- [ ] **The clock that stamps those records is still unverified, and a strap that has been flat gives
  every record a silent offset — this is a hardware check, not a code change.** The strap's RTC is set
  by `0x0A SET_CLOCK`, and the community reference's event enum has **type 13 `RTC_LOST`, "battery fully died
  (clock reset)"**, so on a strap that has been flat every drained record is wrong by an unknown
  offset with nothing in the record to show it, and the failure files history onto a **wrong day**
  rather than onto no day. **This app sends the clock set as a prerequisite** —
  `WhoopCommandFrames.setClockFrames`, both of the 4.0's firmware lengths and the 5.0/MG's single
  command-10 form, because a wrong-length set is acknowledged but not latched — every drain on both
  generations, and the 5.0/MG's connect pass opens with it. **Sending it is not the same as its having
  latched.** The read-back is command 11 on both generations, it is sent, and nothing here decodes the
  reply (the community reference parses none either); the reply is logged raw. So check a drained record's unix
  field against wall time on each of the three straps before trusting it — `[4]` of either heart-rate
  record's payload — and do not treat a clock set having been written as evidence about it
- [ ] **The window asked for is one day, not fourteen.** `SyncHistoricalDataUseCase` starts from
  `getLatestSample()`, which is `nil` on an empty `biometric_samples`, so it falls back to
  `now − 1 day` ([SyncHistoricalDataUseCase.swift:25](../ios/Sources/Whoopsy/Domain/UseCases/SyncHistoricalDataUseCase.swift#L25)).
  The stated goal — the band's full retained cache — is not what the code requests. `GET_DATA_RANGE`
  is the command that would answer "what does the strap actually hold", and it is unimplemented
- [x] **The drain owns its persistence.** `SyncHistoricalDataUseCase` subscribes to
  `historicalTelemetryStream` *before* it asks for the drain, consumes it in a concurrent task, and
  batch-saves every 50 samples (or every 5 s) — awaiting that writer before it returns or rethrows, so
  a decoded sample is persisted whether or not a screen is open. `StreamBiometricsUseCase` remains the
  live path's only writer, and that path still needs a subscriber; the drain no longer does
- [x] **`syncNow()` reports the drain's outcome.** It awaits `execute()`, which now runs the drain to
  a conclusion, and prints the record and batch counts. One wording caveat remains: "History sync
  complete" is set for every non-throwing ending, so an idle timeout says it too —
  `HistoricalSyncOutcome.Ending.isStrapConfirmed` is the distinction to draw if that sentence is
  tightened
- [ ] **`biometric_samples` has no retention.** No pruning exists anywhere in `ios/Sources/` —
  `grep -rn "deleteOlderThan\|prune\|retention\|purge"` returns nothing. Fourteen days of beat-to-beat
  R-R is a large number of rows, so the retention policy is a decision to take *before* the first
  successful sync rather than after

### Capture first, decode second

The findings above come from public references, and the two disagree on record numbering and on
whether 5.0 times its records. **They are a reason to go and capture, and the heart-rate decoders have
been written without one — which is said here rather than papered over.** The walks are gated on an
exact type, an exact or minimum payload length and a nonzero record stamp, and both generations' walks
refuse rather than fabricate, so a wrong offset should produce no row instead of a plausible wrong one.
That is the design and not a measurement: **the first drain's output is evidence about the parser, and
not data to trust until it has been checked against a recording.** The `0xAA`-in-payload trap above is
what makes a wrong parser look like a working one, and its bugs would be tuned to the source's errors
rather than to the strap's behaviour. `docs/BLE_PROTOCOL.md` §7 orders the questions cheapest-first.
The 4.0 base UUID sat first while it was open; it was settled from the references rather than from a
scan and the constant now carries it, so the first capture is the envelope question.

### The capture has to be legible, and as the code stands it would not be

Added because everything above ends in the same instruction — *go and drain each of the three straps
once and record the raw frames* — and the app is currently built so that walk can be spent without
saying what happened. Both gaps below are **measured, not predicted**. Neither is a protocol
claim: nothing here decodes a byte, `docs/BLE_PROTOCOL.md` §7's cheapest-first order still stands, and
this is instrumentation for the walk rather than a substitute for it.

- [ ] **The one diagnostic on this path is one-shot per connection.**
  `hasLoggedProprietaryFrame` is declared at
  [WhoopBLEManager.swift:94](../ios/Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L94), reset on
  connect and disconnect ([602](../ios/Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L602),
  [620](../ios/Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L620)), and it gates the only log
  there is at [line 825](../ios/Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L825) — which prints
  the frame's type, seq, cmd and payload length. So a drain that streams thousands of frames writes
  **one line**: enough to establish that the strap speaks at all, and not enough to say what it sent
- [ ] **`MotionPayloadDecoder` refuses in silence, nine ways.** The file contains **no logging call
  at all** and nine `return nil` paths — the generation lookup at
  [line 64](../ios/Sources/Whoopsy/Data/BLE/Parser/MotionPayloadDecoder.swift#L64), the type test at
  [line 76](../ios/Sources/Whoopsy/Data/BLE/Parser/MotionPayloadDecoder.swift#L76), and the exact-length
  guards at [line 113](../ios/Sources/Whoopsy/Data/BLE/Parser/MotionPayloadDecoder.swift#L113) and
  [line 164](../ios/Sources/Whoopsy/Data/BLE/Parser/MotionPayloadDecoder.swift#L164) among them. So *"the
  strap sent motion records of a length this build does not expect"* and *"the strap never sent
  motion"* produce **identical evidence**, which is nothing. The manager is silent on its own side
  too — a refused decode is a plain `if let` with no `else`
  ([WhoopBLEManager.swift:835](../ios/Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L835)) — so a
  refusal cannot be attributed to either half

**The consequence is specific to this project's situation.** There are three straps in scope and the
references put them on two wire formats, so a walk produces recordings that have to be told apart. A
recording whose only artefact is *one proprietary frame was seen* cannot separate *the 4.0 answered
and the 5.0 did not* from *both answered and this build refused both* — and the second reading sends
the next attempt at the wrong strap, which is the expensive way to be wrong here.

**And the log that does exist may not survive to be read.** The app logs through `os.log`'s unified
logging, where `.debug` and `.info` go to a **memory buffer and not to disk** — only `.notice` and
above persist — and the buffer is small and shared with the whole system. The one-shot diagnostic
above is an `.info`, so after a walk it can already be gone. That is a property of the platform
rather than a defect in this code, and it is the reason a capture log has to be written at `.notice`
or to a file rather than to `.info`.

- [ ] **A `CaptureLog` appending to `Documents/capture.txt`, metadata only.** The content is the
  frame type, the generation, the payload length, and **which guard refused it** — never a health
  value. Written at the four moments that make a walk legible: each `(generation, type,
  payloadLength)` shape seen **for the first time**, so the file opens with the strap's real record
  inventory; each refusal, with the guard named; each enable sequence sent; and each drain sub-type
  (`HISTORY_START` / `HISTORY_END` / `HISTORY_COMPLETE`). Capped and rotating (≈64 KB) so a long walk
  cannot grow it without bound, and written at `.notice` for the retention reason above.
  **The sink exists (2026-10-18)** — `Core/Logging/CaptureLog.swift`, ~64 KB, rotating to
  `<name>.1`, used today only by the oxygen probe below — **but none of the four capture moments is
  wired to it yet**, so `capture.txt` is still empty on a real walk
- [x] **The two `Info.plist` keys, which are what remove the cable.** `UIFileSharingEnabled` and
  `LSSupportsOpeningDocumentsInPlace` expose the app's Documents directory in the Files app under
  *On My iPhone → Whoopsy*, so the recording is read on the phone and shared from there rather than
  pulled off it. Both are in `ios/App/iOS/Info.plist` since 2026-10-18, beside a comment naming the
  capture log they exist for. There is **no API for a third-party app to write into Apple's Notes
  app** — the share sheet with Notes as its destination is the only route to that, and it is a user
  action rather than something this code can perform
- [x] **The oxygen candidate probe, which is instrumentation and not a metric.** `R18` carries a
  candidate SpO₂ percentage at payload `[71]` (frame 82), decompile-sourced from the official app's
  `spo2_pct` and documented in `docs/BLE_PROTOCOL.md` §4. `Spo2CandidateProbe` classifies every
  drained record into 70–100 / bit-7 sentinel / sub-70 diagnostic / absent, and
  `Spo2CandidateAccumulator` emits at most three raw lines and one summary per drain to `.notice`
  and `Documents/spo2-candidate.txt`. **`capture.txt` also opens with an `APP_START` line** carrying the bundle version, the debug
  dylib's byte size and its **Mach-O `LC_UUID`** — added 2026-10-26 after two rounds of diagnosis
  chased a symptom that was really a stale bundle on the phone. Modification times were tried first
  and are useless: a sideloaded bundle carries the zip epoch, so every build claims 1979, and
  Sideloadly's re-signing changes the byte size too. The UUID is the linker's and survives both. A
  capture whose UUID does not match the IPA just installed is a capture of the wrong build. **It writes no row and no screen value**, because the
  validation contradicts itself: +0.99 against the app over eight nights on one strap, the opposite
  direction on another. Promotion needs **≥2 devices × ≥5 paired nights, r ≥ 0.7, MAE ≤ 1.0**, with
  byte 82 still winning the 74–92 offset scan. The 4.0 has no path: raw red/IR scalars, no waveform,
  no calibration

- [ ] **The candidate populated on every night, and only in sleep.** Across five consecutive nights on
      this unit, in-band values appeared **only on records the strap itself marked asleep** — nightly
      means clustered in the 95–96 band and minima in the low 70s–high 80s, with the bit-7 sentinel and
      the sub-70 diagnostic code both present and both excluded from the mean. That is the strongest
      evidence yet that payload `[71]` is a genuine strap-computed percentage rather than a neighbour
      correlated by coincidence — but it is one device, and the existing promotion gate is unchanged:
      **≥2 devices × ≥5 paired nights against a reference oximeter, r ≥ 0.7, MAE ≤ 1.0**, byte 82 still
      winning the 74–92 scan. The MG gives the second device; a fingertip oximeter supplies the
      reference.
      **A nightly minimum is not the minimum of the minute**: one 80 stands in a window whose mean is
      96, and a single low sample is the shape an artifact has. Whatever ships must state which
      statistic it draws — a 5th percentile or a sustained-run rule — rather than printing the raw low.
- [ ] **Still zero network, and this does not change that.** The file is written into the app's own
  sandbox and read by whoever is holding the phone. The repository's guarantee — no `URLSession`, no
  HTTP client, no third-party SDK — is untouched by any of it

None of this is the parser, and it must not be mistaken for progress on the items above: a capture
log makes a walk *readable*, it does not make a drain *work*. The order stays as `docs/BLE_PROTOCOL.md`
§7 has it — capture first, decode second — and this item is what makes the first step produce
evidence rather than an afternoon.

### What this couples to

The R-R series this sync would deliver is the same series the RSA respiratory-rate work needs — a
contiguous, correctly ordered beat-to-beat record. That work is blocked by the fact that a
`biometric_samples` row's `timestamp` is an arrival instant rather than a beat time (`CLAUDE.md`),
and the sync is where that gets fixed or inherited: a drained record arriving with its own unix time
would give the tachogram a real time base, which is more than the live path can offer without
reconstructing beat times by cumulative sum.

---

## 6. Live testing on a sideloaded build — **also not a column, and not covered by the rule above**

The same carve-out as §5, for the same reason: this is the file the project's outstanding work is
recorded in, and what follows is a walk on a phone rather than a column of a CSV. The two sections
are separate because the two paths are: §5 is the strap's **historical** drain, over the proprietary
`0xAA` envelope and its own command characteristic; this is the **live** path, over the standard
`0x2A37` Heart Rate characteristic, and it depends on none of §5's work.

**The simulator cannot settle any of this, and that is measured rather than assumed.** Launched on
the booted iOS 26.5 simulator, the app logs `Central manager state changed to 2` — and `2` is
`CBManagerStateUnsupported` in `CoreBluetooth/CBManager.h`. `centralManagerDidUpdateState` calls
`startScanning()` only on `.poweredOn`, so on a simulator the app never scans, never discovers and
never subscribes. The silence is the platform, not the code. **A sideloaded build on a phone is the
only place the BLE layer can be settled at all**, which is the whole reason this section is here.

### 6.1 The live heart-rate read path

**The code is complete; the strap is the only thing missing from it.** `didDiscoverCharacteristicsFor`
sets `setNotifyValue(true, for:)` on every `.notify` characteristic
([WhoopBLEManager.swift:757](../ios/Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L757)), which
covers `0x2A37`; `didUpdateValueFor` decodes it and yields a sample
([:763](../ios/Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L763), [:787](../ios/Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L787));
`StreamBiometricsUseCase` persists it and `LiveSessionUseCase` feeds it to the session screen. Nothing
in that chain is a stub. **A strap has since been on the other end of it** — the owner's 5.0 has since delivered `0x2A37` live samples with R-R intervals, so `biometric_samples` stopped being empty and
both questions below are answered for that one unit: yes, it exposes the characteristic, and yes, its
frames decode.

So the walk answers exactly two questions, and neither is about the reader:

- **Does the strap expose `0x2A37` at all?** Some generation may put heart rate only in the
  proprietary payload, in which case the work belongs in §5 rather than here.
- **Do its frames decode?** The flags byte says whether the R-R field is populated at all (`k == 0`
  means the strap does not carry intervals), and the interval count is what decides whether a night's
  series can be reconstructed from per-notification arrival instants.

**Both answers are already instrumented, and both lines are one-shot per connection.** The GATT
inventory — every characteristic on the service with its properties, and `0x2A37 Heart Rate
Measurement present: true|false` — is gated on `hasLoggedCharacteristicInventory`
([:709](../ios/Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L709)); the first decoded frame
(`flags`, `bytes`, `hr`, `rrIntervals`) is gated on `hasLoggedHeartRateFrames`
([:774](../ios/Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L774)). **Read them live rather than
after the fact** — both are `AppLogger.ble.info`, and §5's retention note applies here verbatim:
`.info` goes to a memory buffer and not to disk, so by the time the phone is back on the desk the two
lines that answer this can already be gone. That is also the argument for §5's `CaptureLog` being
`.notice` or file-backed, and it is not solved by anything in this section.

**A preview build shows the same screen with numbers on it, and it is not evidence about a strap.**
`WhoopMockBLEManager.liveTelemetryStream` starts a 1 Hz generator on subscription
([WhoopMockBLEManager.swift:59](../ios/Sources/Whoopsy/Data/BLE/Manager/WhoopMockBLEManager.swift#L59)), and
it is reachable by launching with `SIMCTL_CHILD_XCODE_RUNNING_FOR_PREVIEWS=1`, which selects
`DIContainer.preview`. That demonstrates the reading path and says nothing whatever about whether a
strap answers — the distinction §5 opens with, that a chain read off the code is not a measurement of
a device.

### 6.2 What a first run should look like, fixed before the walk

**Every figure the session opens with is `—`, and that is the absence rule rather than an empty
screen.** `LiveSessionAccumulator` holds nothing until the first sample arrives, so there is no heart
rate, no average, no maximum, no strain and no zone time to draw — and each of those renders as a
dash, which is what "nothing measured" looks like everywhere else in this app. **A dash at t = 0 is
the design; a dash that is still there once the strap is connected and streaming is the finding.**

Two figures stay dashed on a first run even with a strap working perfectly, and both are correct:

| Figure | Why it can stay `—` with a strap streaming |
| :--- | :--- |
| `CALORIES` | `estimateCalories` returns `nil` with no weight on file, deliberately. The route to a figure is the **Profile** page (Home's day-bar profile control), which is where `weightKg` is supplied; until then the tile has no body to compute against, and a number there would be a 75 kg default the user never described |
| the five zone bands / `ACTIVITY STRAIN` | `strain` is `nil` until a sample arrives and `0.0` once one arrives that never reached zone 1 — `StrainScore.hasMeasurement`'s own distinction. So a short or easy session legitimately reads `0.0` with no zone time, which is a measurement and not an absence |

Everything else — `HEART RATE`, `AVG HR`, `MAX HR`, the running timer — should populate within a
second or two of connection, because the timer is drawn by the system from the wall clock and needs no
updates at all.

**The waveform's `LIVE TELEMETRY` badge is absent until the first reading**, for the same reason:
`Snapshot.isOnBody` is `nil` before any sample rather than defaulted `true`, so the badge has nothing
to stand on
([LiveSessionAccumulator.swift:85](../ios/Sources/Whoopsy/Core/Math/LiveSessionAccumulator.swift#L85)). A
defaulted `true` is the fabrication class `WhoopDevice.batteryPercentage` already documents.


## 7. The flash recorder and the step counter — **not a column, and not covered by the rule above**

Added 2026-10-23, after the first real-hardware session with the R18 counter. The code side is done and
green; what is open is the strap, and two questions only hardware can answer.

### 7.1 What was wrong, and what is now proven

Two bugs in the drain were found on the owner's 5.0, both in `HistoricalDrainSession`:

- **The continuation token was read four bytes early on the 5.0.** `HISTORY_END`'s token is at
  **payload 10** — frame 17 on the 4.0 (`inner[13:21]`) and frame **21** on the 5.0
  (`data[10:18]`, the community reference's hardware-verified trim). This app read payload 6, so the strap accepted the
  ACKed write and never advanced its trim: every drain replayed the same two August batches forever —
  10,041 ticks at `12:51:13` and 10,222 at `12:57:42`, identical across connections. The community reference calls the
  symptom the "Groundhog Day bug".
- **The live-edge test read the marker and not the records.** `HISTORY_END`'s head is the *drain's*
  clock (the phone's wall time), not the buffer's; the records it closed were two months old. The
  newest record now decides, the drain-wide highest is the fallback for an empty batch, and the marker
  is used only by a session that has seen no record at all. A batch that does not beat the drain-wide
  highest is a **stall**, and three of those end the drain as `.idleTimeout`.

With the token fixed, the drain advanced monotonically through the backlog and read **55,968 records in
990 batches**, from `2026-08-24 12:51` to **`2026-08-26 13:40:29`** — then an empty final marker. A
second sync returned **0 records in 1 batch**, which is the proof the cursor persists: before the fix,
that same sync replayed the two batches.

Also settled in this session:

- **The R18 counter decodes on real hardware**: `value=10041 class=0 source=hardware at
  2026-08-24 12:51:13`. The community reference's offsets are validated; the field is real.
- **The RTC is correct now** (`Motion record clock … drift -0.0 h`). The clock was never the current
  problem, and `SET_CLOCK` has latched at some point.
- The counter ledger is persisted in `StepCounterStateStore` before its row, and writes are throttled
  to **once a second per day** with a trailing flush — a per-record write flooded `cfprefsd` and SQLite
  during the backlog.

### 7.2 The flash recorder: readable since 2026-10-24, and offline capture is full-rate while worn

For weeks the flash appeared to hold roughly **16 hours of wear across 24–26 August** and nothing
later: every drain answered `0 record(s)`, live heart rate and motion worked, and the counter could
not cover a current day. **That reading was wrong about the recorder and right about the drain.** The
strap had been writing history all along; what changed on 2026-10-24 was that a drain could finally
read it. The failed tests and the successful one are recorded below in order, because the conclusion
reverses this section's original premise and it is the failures that make the reversal credible.

**What has been tested, in order.** A drain at **30%** battery and two more at **69%** all answered
`0 record(s) in 1 batch(es)`, and so did a 15-minute Bluetooth-off wear on 2026-10-24 — every one of
them with the strap connected, and the last of them read off the **automatic** drain on reconnect
(`Auto-sync: 0 record(s) in 1 batch(es), ending caughtUpToLiveEdge`) rather than a button press. The
link worked throughout and the cursor did not replay August.

**Then the `0x9A` toggle was sent, and the picture changed completely.** The sequence on 2026-10-24:
`ENABLE PERSISTENT RECORDING` at **08:48:55** (`Sent TOGGLE_PERSISTENT_R21 (0x9A) state=1`, write
acknowledged), then revert → quit → relaunch → enable again, then a drain at **09:05** that read real
records for the first time:

- **Layout `18` — `R18` — at one record per second of history**, ~60 per batch, ~2.5 batches a second:
  `recordsSoFar` 8,804 → 8,864 → 8,924 → 8,984, `newestRecord` advancing minute by minute from
  `2026-10-24 05:13Z` (01:13 EDT).
- The manual sync that followed reported **`422 record(s) in 9 batch(es)`, caught up to now** — the
  first non-zero completion this strap has produced, and a genuine live-edge claim because the drain
  carried records.
- A **10-minute disconnected wear** afterwards produced **`25 record(s) in 2 batch(es)`** — one record
  per ~24 s, not `R18`'s 1 per second (that would have been ~600). The first reading was **"offline
  capture is motion-only"**, which is what the opcode's name suggests — and the rate test below
  overturns the *content* half of it: the sparse offline records are `R18` too, so the flag changes
  how often the strap writes rather than what it writes.
- **Steps switched from the detector to the strap's own counter** at the drain: 1,115 detector →
  501 counter → 733 as the morning went on. That is the designed arbitration (the first counter record
  for a day replaces the detector's total), and a data point for §7.4's comparison.
- The strap's **clock was correct throughout** — a live `R21` record's own unix field read
  `13:11:12Z` against the phone's `13:11:12Z` — so the "invalid RTC stops banking" rule is not the
  cause, and the drained stamps file onto the right days.
- `0x22 GET_DATA_RANGE` stayed **unanswered** on firmware 50.42.1.0 throughout, so the write-page test
  is blocked, not merely unrun.

**What that means.** The strap had been **writing history before the toggle was sent** — the drained
records run back through the previous night and the early hours of the morning, hours before `0x9A`
was first sent. So the flag did not revive a dead recorder; it appears to have made the history
**readable** (gating the read path, or resetting the read pointer). Which of those two it is cannot be
separated from this run, and the two have different consequences — a gate is a setting, a pointer
reset is a one-shot.

**One test left, and everything else settled. Known unknowns — none of them blocking a ship — follow
the closed list at the end of this section.**

- [x] **The night away from the phone, synced without a button — run 2026-10-26.** The strap was
      worn overnight with the radio off; the drain that followed reported
      `DRAIN_END started=2026-10-26T10:46:07Z records=32274 batches=545 oldest=2026-10-26T02:09:42Z
      newest=2026-10-26T10:49:36Z repeats=0 trim=96861 reason=complete` — **8 h 40 m of history, 545
      batches, every declared count matched, no re-sent batch, strap-confirmed ending.** One open
      question is recorded below rather than folded in: the drain's oldest stamp is 02:09, about an
      hour after the previous night's drain ended at 01:11, so either the app was foregrounded in
      between (a drain of its own) or that hour was trimmed unread.

      _The original wording of the test follows._ Airplane mode on,
      strap worn, sleep; in the morning airplane mode off, open the app, and there should be a
      `DRAIN_END` in `Documents/capture.txt` that nobody asked for, with a `first` stamp from the night
      and a full night's records. That single line proves the whole chain in one go — the strap banking
      with no phone (measured at full rate on 2026-10-25), the foreground trigger firing where no
      reconnect happens (a phone connected all night never re-connects), the per-link state reset that
      lets the connect pass re-run after a radio cycle (the community reference's `#2787`), the retry for a strap that
      answers nothing, and the strain refresh fed from the drained range. **Everything below this item
      is closed**; this is the last behaviour no capture has shown.
- [x] **`0x9A` sent, and the first successful drain.** Done 2026-10-24; see above. The flag is still
      **ON**; the battery cost (optical engine across reboots) has not yet been measured.
- [x] **The rate test: run 2026-10-24, and the layout finally read.** A second drain ten minutes later
      answered **`412 record(s) in 8 batch(es)`**, and the device log has every record:
      **`type=0x2F layout=18 payload=109 B`, one per second**, batch boundaries a minute apart
      (`firstRecord` 14:22:51Z, 14:23:36Z, then :36 each minute), the last `HISTORY_END` reporting
      **`liveEdge=true`**. `spo2probe summary r18=412` agrees. So the **multi-batch drain is now
      observed** — the ACK loop, the stall guard and the live-edge rule all ran across eight batches on
      real records — and the earlier "one record per minute" figure needs no exotic explanation:
      **that drain had consumed the disconnected window at ~1 record a minute, and this one started
      exactly where it stopped.** The proof is the start stamp, `14:22:51Z`, which is also
      `SET_CLOCK`'s own event stamp, `Strap event 16 setRTC at 2026-10-24T14:22:51Z` — the reconnect
      instant. **Only the connected half of the rate is captured.** Every one of those 412 records is
      in the log; the disconnected side rests on two things that are not a capture — the app's own
      `30 record(s) in 2 batch(es)` line, and the start stamp above. So "about one record a minute
      while disconnected" is an **estimate from a count**, and the layout of those records **has never
      been seen**; at least one carried the step counter, because the total moved across that drain
      and the pedometer is cumulative. **The next disconnected wear is the capture that makes this
      real**: press sync and have the archive pulled inside two minutes, then read `layout=` off the
      offline records themselves.
- [x] **Offline banking at scale: `825 record(s) in 16 batch(es)`.** Measured 2026-10-25 with the
      phone's Bluetooth **off** for the wear, then one `SYNC HISTORY` on reconnect. Sixteen batches at
      roughly 52 records each, against the **30 records in 2 batches** the earlier 30-minute
      airplane-mode wear produced. Two things follow. **The strap banks while the phone cannot hear it**
      — this is the same conclusion as before with an order of magnitude more data behind it — and
      **the rate is not a constant**: 30 records over half an hour and 825 over a shorter window cannot
      be one fixed cadence. The obvious explanation is that the recorder is **motion-gated** rather
      than fixed-interval, which is what the two earlier still-airplane results and this one's much
      larger count would look like together. **The capture is still missing** — the archive had rolled
      past this drain by the time it was pulled, so `layout=` and the stamps of the offline records
      remain unread. **The window was 22 minutes of Bluetooth-off wear**, which makes the rate
      **~37 records a minute** — 825 in 22 min, against 30 in 30 min on the still airplane-mode wear
      and 25 in ~10 min on the first one. **A fourth window settles the question the other way**:
      10–15 minutes of Bluetooth-off wear on the same morning produced **`15 record(s) in 1 batch`** —
      about one a minute, exactly like the still tests. So the 825 is an **outlier rather than a rate**,
      and the likeliest explanation is that its window was not purely offline: the drain before it had
      consumed up to the live edge at 09:25, and records written **while still connected** between then
      and the moment Bluetooth went off sit in the same read. Ten minutes of connected time at one a
      second is ~600 records on its own, which is most of 825. **The working model is therefore the
      simple one again** — about one a minute disconnected, one a second connected — and it is still
      uncaptured: three of the four windows were read as counts from the app's own message, and the
      stamps that would separate "written offline" from "written while linked" have never been read.
      **The capture exists now, and it settles the connected half exactly.** `CaptureLog.shared`
      writes `DRAIN_BATCH`/`DRAIN_END` lines to `Documents/capture.txt`, visible in iOS Files, so a
      drain is read minutes later instead of inside `/usr/bin/log`'s two-to-four-minute archive —
      five pulls had missed that window. Measured 2026-10-25 14:27Z, four batches then one:

      ```
      first=14:25:06 newest=14:25:50 soFar=45   stalled=0 liveEdge=false
      first=14:25:51 newest=14:26:50 soFar=105  stalled=0 liveEdge=false
      first=14:26:51 newest=14:27:35 soFar=150  stalled=0 liveEdge=false
      first=14:27:36 newest=14:27:42 soFar=157  stalled=0 liveEdge=true
      DRAIN_END records=157 batches=4 reason=liveEdge
      DRAIN_BATCH first=14:27:43 newest=14:28:12 soFar=30  stalled=0 liveEdge=false
      DRAIN_END records=30 batches=1 reason=complete
      ```

      Three facts come out of it. **The stamps are one second apart throughout** — 157 records over
      2 m 36 s, and 30 over 29 s — so **connected recording is one `R18` per second**, captured rather
      than inferred. **The two drains tile the timeline with no gap and no overlap**: one ends at
      `14:27:42`, the next begins at `14:27:43`, which is the ACK/trim cursor doing its job on real
      records. And **a batch is a ~60-second window of the strap's own clock** (boundaries at :50/:51),
      not a fixed record count — hence 45, 60, 45, 7. **What this does not contain is an offline
      window**: the phone was connected throughout, so the disconnected rate is still only the three
      counts above, and counts cannot distinguish 30 records in 30 seconds from 30 in 30 minutes.
      The next test is now trivial — Bluetooth off for 30 minutes, sync, read `capture.txt`: the
      stamps inside that window are the answer, with no archive race.
- [x] **DECISIVE: a 30-minute Bluetooth-off wear came back at full rate.** Captured 2026-10-25 from
      `Documents/capture.txt` — the off window is the long gap between drains:

      ```
      15:34:27 DRAIN_BATCH first=15:34:22 newest=15:34:40  soFar=19    }  ends the 765-record drain
      15:34:31 DRAIN_END   records=765 batches=14 reason=complete
      ...                  (Bluetooth off, ~30 minutes)
      16:06:11 DRAIN_BATCH first=15:34:41 newest=15:35:25  soFar=64
      16:06:12 DRAIN_BATCH first=15:35:26 newest=15:36:25  soFar=124
      ...                  one 60-record batch per minute, unbroken, to 16:06:24
      16:06:26 DRAIN_END   records=2003 batches=36 reason=liveEdge
      ```

      **2,003 records across 32 minutes, every batch a full 60 records per 60 seconds, with no gap in
      the stamps** — so while the strap is *worn* it writes one `R18` per second whether or not the
      phone can hear it, and a phone-free hour returns at full fidelity. That is the answer to the
      question this section opened with, and it retires the "~1 record a minute offline" reading: the
      three sparse windows were **wrist-off** time, not link-off time, since the recorder is what the
      optical engine feeds — and the same capture proves it from the other direction: **the strap was
      taken off for a shower at 16:15 and put back at 16:25**, and the history has a **ten-minute hole
      with no records at all** between `newest=16:15:39` and `first=16:25:42`, inside a drain that was
      otherwise continuous at one a second. Two controlled observations, one rule: worn is full rate,
      off the wrist is nothing. Two smaller things ride with it: a handful of batch
      boundaries overlap by up to ~40 s in this capture (`first=15:43:26` then `first=15:43:27`), so a
      few records are re-sent and the unique count is slightly under 2,003 — harmless, deduped by
      timestamp — and `stalled=0` throughout, so the stall guard never had to fire.
- [x] **Why the rate differs: it does not, by link state — it differs by whether the strap is worn.**
      Answered 2026-10-25 by the Bluetooth-off capture below: 2,003 records across 32 minutes, one per
      second, with no gap in the stamps while the strap was on a wrist and the phone could not hear it.
      The three sparse windows (30 in 30 min, 25 in ~10 min, 15 in 10–15 min) were the strap **off the
      wrist**, where the optical engine has nothing to report and the recorder writes almost nothing.
      Nothing about `0x03` or the handshake is implicated, and a phone-free walk yields usable heart
      rate.
- [x] **The retry fired in the wild, and it is why the link still caught up.** 2026-10-25 from
      `capture.txt`: after a clean 1,140-record drain at 17:24:07, **two consecutive drains ended
      `records=0 batches=0 reason=idleTimeout`** — 17:25:40 and 17:26:45, a minute apart, which is the
      drain's own idle window rather than the five-second retry delay — and the third attempt at
      17:26:51 read **176 records** and ended on a live edge. Without `DrainCoordinator`'s attempts that
      link would have come back with nothing and waited for a manual press. The same capture also shows
      the opposite case behaving: an aborted drain (19 records, `reason=aborted`, 16:34:31) was followed
      by a fresh one starting at the same cursor and reading the window again, so a superseded drain
      loses the session and not the records.
- [x] **A drain can fail with `0 record(s) in 0 batch(es)` and succeed on the next press.**
      2026-10-24 16:57, immediately after a live football session ended: `SYNC HISTORY` reported
      *"The strap stopped responding after 0 record(s) in 0 batch(es)"*. **That is a different failure
      from the `0 record(s) in 1 batch(es)` this section opens with** — one batch is an answer saying
      the buffer is empty, zero batches is no answer at all, and it is the idle timeout rather than a
      read. Pressing the button again on the same link minutes later returned
      **`447 record(s) in 9 batch(es)`**, so the strap was fine and the request was not. The likely
      shape is a request issued while the link was still busy tearing down the live session — worth
      confirming with a log pulled inside the window on the next failure, since the successful retry
      is the only one that leaves a trace (`layout=18`, 60-record batches, `stalled=0`, cursor
      advancing from `13:23:09Z` on 2026-10-25).

**Known unknowns, none of them blocking a ship.**

- **The Gen 5 burst count gate is read and logged, and not enforced.** [reported] The research reference's own write-up
      (`PROTOCOL-GEN5.md` §8) puts `expected_count`, a u32 LE at
      `inner[9]` — payload **6** here — in every `HISTORY_END`, and says a client must count **complete
      frames once each, for types 47, 48, 50, 53, 54 and 55 only** — not 49, not 51/52 — and that
      miscounting the membership makes the band **re-offer the same burst forever**. That is the Gen 5
      analogue of the Groundhog Day bug. The Gen 4 reference puts a record-id / batch counter at the
      same offset, so the read is gated by the envelope. **The premise is now measured**: the
      2026-10-25 capture's per-batch histogram showed `types=2F×45,30×2,31×2,32×8` and
      `2F×30,31×2,32×40` — types 48 and 50 really do ride in bursts, so a 47-only count is short by the
      event and console-log traffic. `HistoricalDrainSession` now counts the six types and logs
      `expected=` / `counted=` on every `DRAIN_BATCH` line, and **still acknowledges success either
      way**. Enforcement — the Gen 5 negative result (`0x17` body `00 00`), re-offer, and `0x14` after
      fifteen consecutive failures — waits on one capture showing the two numbers agreeing on an
      ordinary burst, because a validator with the wrong membership would refuse good bursts forever.
      **What it would fix**: a burst damaged in transit is acknowledged today, and the strap trims past
      records this phone never stored — its ring buffer is the only copy. What it would **not** fix is
      our re-offers. **Measured 2026-10-25: 53 consecutive bursts, `expected == counted` on every one**
      — including `2F×44,30×3,32×20` against 67 and `2F×20,30×1,32×36` against 57 — so the membership
      is right, the gate is **ruled out** as the cause, and the next suspect is the ACK/token cursor:
      the drain now logs the token it echoes (`trim=`/`wrap=`) on every `DRAIN_BATCH` line and sets
      `repeat=true` on any batch beginning at or before the previous one's first record, so the next
      capture reads both — the rewind and whether the trim page moved — **on one line**, without two
      batches that a rotation or a paste can separate. **One drain has since been captured clean: 57 batches, `repeat=false` on all of them, `trim`
      monotone throughout** (`94247` → `94467`), so the rewind is not every drain and the cursor
      advanced exactly as the counts imply. The older drains that did re-send two stretches (`first=23:17:49` twice, then
      `first=23:38:53` followed by `first=23:38:49`), each time with its declared count matching, so the
      rewind is in the trim cursor rather than in the counting. Nothing was lost by it — `soFar`
      advanced on every batch and the records upsert by timestamp — but the duplication is the symptom.
      Enforcement stays off: with zero mismatches a NAK would change nothing today, and a validator
      interacting with a cursor already rewinding could turn a harmless duplicate into a loop.
- **The retention question has an instrument now, and it needs no fortnight.** Event 29
      `STRAP_CONDITION_REPORT` carries a page backlog and an hours figure, and it is decoded into a
      `STRAP_CONDITION` line on every connect (`StrapConditionReport`). The first capture containing
      that line answers "two days or fourteen": if `backlog_hours` sits in the tens after a day of
      wear, the buffer is shallow; if it sits in the hundreds, the 14-day claim is plausible. It stays
      log-only until a capture confirms the offsets — the same rule the oxygen candidate follows.
- **`R26` has appeared and has no decoder.** The first one was read on 2026-10-26 —
      `layout=26 ... expected=8 counted=8 ... types=2F×1,30×1,31×2,32×6`, one record, an 88-byte
      frame the research reference calls the *Pulse Information Packet*. It is **counted** toward its
      burst and **not decoded**, and it is **not allowed to be the clock**: its field at payload 4 is an
      event time, and reading it as a 1 Hz stamp made the stall guard log a stall on a drain that was
      advancing. `HistoricalDrainSession.timestampedLayouts` is that gate now (18/21/24). Whether
      anything in it is worth storing is open — the community reference documents the frame as pulse
      information, and nothing here has looked inside one yet.
- **`0x22 GET_DATA_RANGE` is undecoded** — a `0x22`-bearing frame does exist, and it is not the documented one.
      Two captures are in hand, and both must be read narrowly. At 10:29:42 a
      `type=0x24 seq=41 cmd=0xA payload=11 01 00 00 00` line appears beside the request — that is the
      **first command response on the link**, `logClockReplyCandidate`'s `isFirstResponse` branch, not
      an answer to `0x22`. Then at **10:30:59** a frame arrives as
      **`type=0x28 seq=2 cmd=0x22 payload=C1 DC 6A C2 35 64 00 00 00 00 00 00 00 00 00 01 00`** — inner
      byte `0x22`, **17 bytes**, so it is not the community reference's 65-byte layout either (which begins `0x01`), and
      `WhoopDataRange.decode` refuses it on length, correctly. Two things are therefore still open: the
      app's own `commandResponse` type is `0x24`, so a type-`0x28` frame may be a metadata page rather
      than an answer at all; and its body's first four bytes read as a unix stamp roughly three minutes
      **after** its arrival, so no field offset is claimed. **Next:** take the `0x22` frame twice across
      a disconnected wear and diff the two bodies — a field that moves with the wear is the write page,
      whatever offset it sits at. Do not decode anything from one sample.
- **`0x9A` causality is unproven** — the causal test is revert and repeat. Once a 30-minute wear has recorded, `REVERT` and run the
      same wear again. If drains go back to `0`, the flag is the gate and must stay on (or the battery
      cost must be accepted); if they still record, the first success was the strap's own state and the
      flag is incidental.
- **The automatic drain failed on some reconnects: cause identified and fixed, not yet re-observed.**
      At **08:47 and 09:00** on 2026-10-24 the app connected and nothing drained — no `Auto-sync`, no
      `Drain: asked GET_DATA_RANGE` — while the 09:05 connection drained. The diagnosis is the community reference's
      `#2787`, reported the same week: a radio power-off delivers no `didDisconnectPeripheral`, so the
      per-link flags survive and `hasSentConnectCommands` stays true — discovery then skips the connect
      pass and the strap gets no `SET_CLOCK`, no `GET_DATA_RANGE` and no history request while the screen
      says *connected*. **Fixed on 2026-10-25** by resetting the link state and re-discovering services
      when the radio returns with the strap still attached; the overnight test above is what re-observes
      it.
- **The battery cost of the flag is unmeasured** — watch it. The research reference warns the optical engine can stay running
      across reboots. Compare the hourly drain against the pre-toggle rate; `REVERT` is the undo and
      `REBOOT STRAP` is the recovery if the engine stays on.


**`caught up to now` is not evidence that the buffer is current.** On a zero-record drain that sentence
comes from the marker fallback: with no records in the session there is nothing to compare the marker's
clock against, and the marker's head is the drain's own time. The honest sentence for `recordCount == 0`
is *"no new records"*, and reserving "caught up to now" for a drain that carried records is an
outstanding wording fix rather than a behaviour change.

### 7.3 Questions this session did **not** answer

- [ ] **The 14-day storage claim is still untested, but the buffer is no longer stale.** The
      2026-10-24 drain read records from the **previous night and the hours before the drain**, so the
      recorder holds at least the most recent stretch of wear. Whether it holds 14 days, or drops its
      oldest records first, needs a span longer than one night — §7.2's 30-minute test answers cadence,
      not capacity.
- [x] **The subscription kill-switch hypothesis is dead.** Records were read through 2026-10-24,
      months after the export (and the subscription) ends on 2026-08-22, and the strap kept writing
      throughout. Nothing disables recording at expiry; the `0 record(s)` answers were a read-path
      problem, not an empty buffer.
- [ ] **Watch for a timestamp discontinuity.** A jump in `newestRecord` between consecutive batches
      marks where `SET_CLOCK` took effect; records before it were written under a wrong clock, so their
      apparent span is not elapsed time. The 24–26 August segment advanced smoothly, so it is real.

### 7.4 Validating the two step sources

- [ ] **Detector (today's source).** Walk ~1 mile with the app connected and compare the day's
      increase against the phone's Health step count for the same window. The rhythm gate delays the
      first two steps of every train by design; a mile should read within a few percent of the phone.
      Record the `TrackSteps rate: +N steps in 1 measured min` lines for those minutes.
- [ ] **Counter — now live, and the two sources disagree by more than a stride.** The 2026-10-24 drain
      was the first current `R18` day, and it switched the day's figure from the detector's **1,115** to
      the counter's **501**, then **733** as the morning went on. A gap that size is not stride: either
      the detector over-counts (the rhythm gate admits spurious trains), the counter's delta rule drops
      windows, or both totals are being written to the same day. **Re-run the mile walk with both
      sources logged side by side before trusting either**, and compare each against the phone, not
      against `2k per mile`.
- [ ] **Fit `stepTicksPerStep` only from a capture.** The counter is counted at **1 tick = 1 step**,
      which is the community reference's default; a systematic factor from a real walk is the only justification for a
      divisor, and it should be a measured constant, not a slider guessed at.

### 7.5 Where the code lives, and how to re-run the gate

`HistoricalDrainSession` (token, live edge, stall), `StepCounterPayloadDecoder` (R18 payload 46/52/53,
2020 stamp floor, one-shot `step_counter` diagnostic), `StepCounterAccumulator` (the delta rule),
`StepCounterStateStore` (the ledger), `TrackStepsUseCase` (arbitration and throttling). §16 asserts all
of it; the suite is **25/25 sections, 3,231 assertions** — measured 2026-10-24 after §14's radio-loss
and charging-badge assertions and §16's `0x9A` block were added.

```bash
unset DEVELOPER_DIR && make test SECTIONS=16   # the step/drain block
unset DEVELOPER_DIR && make test              # all 25 sections
make ipa                                      # tmp/whoopsy.ipa for Sideloadly
```

### 7.6 The two test days, once the drain is settled

The 2026-10-23 drain session wrote two recovery rows from **test wear rather than real nights** — the
HRV and resting rate on them are measurements of a test, not of a day — and they sit inside the 30-day
baseline window, so they lift it until they go. **Their dates are deliberately not recorded here.**

- [ ] **Delete the day, not just the row.** A one-off clear has to cover `recoveries`, `sleeps`,
      `strains`, `stepCounts` and the `biometric_samples` / `motionEpochs` underneath them. Deleting
      the strain row alone is futile: `RefreshStrainUseCase` recomputes any day whose newest input is
      later than its watermark, so a surviving sample or epoch re-creates it on the next tick.
      Deleting the samples too is what makes the clear final. The other three tables do not
      regenerate a past day — recovery is scored on today's load only, the night is classified on
      today's sleep-page load only, and steps come from a live stream — so removing their rows is
      enough on its own.
- [ ] **Recomputing is not the fix here.** Unlike a row invalidated by a model change, a test day's
      samples *are* the artifact: `CalculateRecoveryUseCase` would produce the same kind of row from
      them. Delete, do not re-score.
- [ ] **There is no in-app delete**, so this is a temporary startup one-off — a `UserDefaults`-guarded
      block that runs the deletes once — installed, launched, and reverted in the next build. A
      one-off migration would work too (this migrator does not set `eraseDatabaseOnSchemaChange`, so
      removing a registered-and-applied migration later is harmless), but it leaves a row in
      `grdb_migrations` for a change the code no longer contains, which the startup block does not.
