# docs/TODO.md — every CSV column, and whether this app reads it

The bundled WHOOP export is four files. **Three of them are read** — `physiological_cycles.csv` in
full, `sleeps.csv` for its eight nap rows alone, and `workouts.csv` for the 673 workouts. This file
is the inventory of what each column is worth and what it would take to use the rest.

**Two sections at the end are not a column inventory** — §5, the strap's own historical sync, which
is a wire-protocol task rather than an export one, and §6, the walk to run on a sideloaded build,
which is a device task rather than an export one. Both are here because this is the file the
project's outstanding work is recorded in, and both are marked as sitting outside the per-column rule
so that the invariant below still holds for everything above them.

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
| `physiological_cycles.csv` | 935 | 26 | **20** | yes | `WhoopExportParser` → `WhoopExportImporter` |
| `sleeps.csv` | 918 | 18 | **1** | yes | `WhoopExportParser.parseNaps` → `WhoopExportImporter.importNaps` |
| `journal_entries.csv` | 3403 | 6 | **0** | no | nothing |
| `workouts.csv` | 673 | 17 | **12** | yes | `WhoopExportParser.parseWorkouts` → `WhoopExportImporter.importWorkouts` |

Three files are in `Package.swift`'s `resources:` — `physiological_cycles.csv`, `sleeps.csv` for its
eight nap rows alone, and `workouts.csv` for its zone block and its `Activity name` column, neither of
which is in any other file. `journal_entries.csv` is on disk in the repo, in no bundle, and read by
nothing. See `CLAUDE.md`.

---

## 1. `physiological_cycles.csv` — 26 columns · 935 rows

The day key is `startOfDay(Wake onset)`. 910 rows carry one; the other 25 are fragments that never
closed. **24** of those carry a `Day Strain` and **22** of the 24 become `strains`-only rows — two land
on a day a closed cycle already claims, which is `CLAUDE.md`'s 23:30/23:48 boundary pair (2024-02-11,
2024-03-20), and the 25th fragment carries neither a wake onset nor a strain, so it produces no row at
all. That is the whole arithmetic behind the export's **931** `strains` rows from 933 `Day Strain`
values: 909 measured wake days plus 22 fragment days.

### Cycle identity

- [x] **`Cycle start time`** — 935/935 — parsed to `WhoopExportRow.cycleStart` ([WhoopExportParser.swift:18](../Sources/Whoopsy/Data/Import/WhoopExportParser.swift#L18)); the **day-key fallback** for a row with no wake onset ([WhoopExportImporter.swift:139](../Sources/Whoopsy/Data/Import/WhoopExportImporter.swift#L139))
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
- [ ] **`Sleep performance %`** — 910 (5–100) — parsed, consumed by nothing. **Decision — do not cover.** `SleepSession.sleepPerformancePercentage` derives asleep-over-need ([SleepSession.swift:193](../Sources/Whoopsy/Domain/Entities/SleepSession.swift#L193)); the two disagree on **454 of 910 nights** — but that total hides a regime change and must not be quoted alone: across the export's **137-day gap (2024-12-31 → 2025-05-17)** WHOOP's column becomes a different function, matching the app's expression on **423 of 451** pre-gap nights (MAE 0.062) and only **33 of 459** after it (MAE 7.05). So on the older half the app's derivation *is* WHOOP's, and the disagreement is entirely a post-2025 phenomenon. Re-measure era by era and by driving `sleepPerformancePercentage`, not by re-deriving the ratio — the clamp is part of the answer (dropping `min(100, …)` reports 457), and one rule is the point. **The column stays uncovered, but the derivation is now drawn**: it is the SLEEP PERFORMANCE breakdown row on the Recovery screen and, below it, the sleep-performance week chart (`MetricDay.sleepPerformance` → `WeekBarSeries(sleepPerformanceWeek:)`), and it is the ring plus the HOURS VS. NEEDED row on the sleep-performance screen Home's sleep ring pushes. So this line reads as "the export's number is not used", not "the quantity is absent from the app" — the figure on all of those is this app's own, and it will not match WHOOP's for the same night
- [x] **`Respiratory rate (rpm)`** — 910 (13.5–20.2) — → `sleeps.respiratory_rate`, `recoveries.respiratory_rate` and `MetricDay.respiratoryRate` → the Recovery screen's RESPIRATORY RATE breakdown row and the Respiratory Rate week chart under it. Read to **one decimal** there, because a week spans about two units — the reference week is 14.8…16.5, which whole numbers flatten to six `15`s. **Now a two-producer column**, the same shape as `Sleep consistency %` below: stored verbatim for an imported night, computed by `RespiratoryRateMath` ([RespiratoryRateMath.swift](../Sources/Whoopsy/Core/Math/RespiratoryRateMath.swift)) for a strap night, and the two are told apart only by `source`. The model is respiratory sinus arrhythmia off the R-R series — `docs/ALGORITHMS.md` §4 — and it is **unvalidatable against this app's data**, because the export carries no R-R series at all
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
- [x] **`Sleep debt (min)`** — 910 (0–127) — → `sleeps.sleep_debt` (× 60, seconds like every duration on that table) → the **`Sleep Debt` row of the `HOURS VS. NEEDED` card's breakdown box**, which is also the column's second consumer of `Sleep need (min)` above: the card's other row is that need minus this debt. Stored verbatim for an imported night, computed by `SleepDebtMath` ([SleepDebtMath.swift](../Sources/Whoopsy/Core/Math/SleepDebtMath.swift)) for a strap night — **a two-producer column**, distinguished by `source`, like `Sleep consistency %` below. **The two producers' values are not the same quantity and the card may only use one of them**: WHOOP's need is a total containing its debt term, so `need − debt` is WHOOP's own base-plus-strain, while `SleepNeedMath`'s need deliberately omits any debt term — so the box is gated on `SleepSession.hasWhoopSleepNeed` and is not drawn at all on a strap night, where both of its rows would sum to the printed total and both be mislabelled. The card is gated on the *pair*, so a night with no stored debt and a night whose debt exceeds its need draw no box either. The row carries no band, because a running deficit is not monotone the way the three banded rows are. The model is lagged (WHOOP's column correlates 0.891 with the *prior* night's shortfall against 0.506 with its own) and fitted, MAE 8.31 against a column of sd 33.9 — `docs/ALGORITHMS.md` §4. **It stays out of `SleepNeedMath`**, and that is a separate decision from covering the column: the 7-night deficit term buys 0.35 of a point for a second fitted constant, and the nap term that the newly-stored `naps` table makes measurable is significant in sample (t = −5.74) and harmful out of it (3.634 against 3.588). Both measurements are in `docs/ALGORITHMS.md` §4
- [ ] **`Sleep efficiency %`** — 910 (59–99) — not parsed. **Decision — do not cover, and the reason is measured.** `sleepEfficiencyPercentage` is the standard TST-over-TIB and matches this column on 826 of 910 rows. On 83 of the other 84 the mismatch is **not** a denominator problem: the export's own `In bed duration` equals asleep + awake on those rows, and the column still reads 2–5 points higher, so **WHOOP's efficiency is not a function of the two durations WHOOP publishes beside it**. There is no input to store that would reproduce it — see the efficiency section below
- [x] **`Sleep consistency %`** — 892 (7–94) — → `sleeps.sleep_consistency` → the **SLEEP CONSISTENCY** row of the Sleep detail screen **and the card of the same name that closes the page**. `SleepConsistencyScoring.summary(for:history:score:typicalScore:)` reads the stored value for the anchor night (stored-first, `session.sleepConsistency`), scores the four priors through `SleepConsistencyMath` when they carry none, and hands the pair to `SleepViewModel.consistencySummary` for `SleepConsistencyCard`; the card's headline is the figure the row prints two elements up, and the window mean it carries is a mean over this column. That mean is **computed and spoken but not drawn**: `SleepConsistencyCard.headline` passes `change: nil`, so a sighted reader sees the figure alone and the mean reaches only the card's `spoken(for:)` description. **The mean skips nights the model cannot score rather than counting them as zero**: `typicalScore` maps each window night stored-first and `compactMap`s the ones that still produce nothing, so two stored values beside two unscoreable nights average the two, and the mean is withheld below `RecoveryScoring.minimumBaselineDays`. The chart's five columns are all imported nights on a real device, so the stored value is what every one of them is drawn from. Stored verbatim for an imported night; a strap night is computed by `SleepConsistencyMath` ([SleepConsistencyMath.swift](../Sources/Whoopsy/Core/Math/SleepConsistencyMath.swift)), a four-prior boundary-shift fit — `docs/ALGORITHMS.md` §4. The column is nullable because the two producers must stay distinguishable: NULL is "not scored", `0` is "scored as badly as the scale allows"

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
is `WhoopExportParser.parseWorkouts` → `WhoopExportImporter.importWorkouts`, called from
`importBundledExport()` beside the naps. What it buys is the strain page's two `HEART RATE ZONES` rows
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
- [x] **`Workout start time`** — 673 (all distinct) — → `WorkoutSession.startedAt`, and half of the **derived id** ([WhoopExportImporter.workoutID](../Sources/Whoopsy/Data/Import/WhoopExportImporter.swift)): the two unix seconds are packed as big-endian 64-bit halves into a `UUID`. Distinct on all 673 rows' starts and on all 673 start+end pairs, which is what makes the id collision-free — and a **derived** id rather than a `UUID()` is what makes a second press of the import button update the same 673 rows instead of writing 673 more, since GRDB's `save` is INSERT-or-UPDATE *by primary key*
- [x] **`Workout end time`** — 673 — → `WorkoutSession.endedAt`. A row whose end is not after its start is refused rather than stored
- [ ] **`Duration (min)`** — 673 (1–458) — not parsed. **Redundancy, and measured**: it equals `floor((end − start) / 60)` on **670 of 673** rows and exceeds the span on **0**, so it is the stored pair with a minute's truncation and nothing more. Zone seconds are therefore `percent/100 × (end − start)`, which is strictly finer than going through this column

### Activity and intensity

- [x] **`Activity name`** — 673/673 non-empty (**21 distinct**; `Walking` 222, `Activity` 197, `Yoga` 89, `Dance` 34, `Basketball` 28, `Manual Labor` 18, …) — → `WhoopExportRow.activityName` → `WorkoutSession.activityName` → `workouts.activity_name` (`v15`) → the row's label in Home's `ACTIVITIES` card, uppercased at the drawing by `HomeDashboardView.activityRow`, and its glyph by [ActivityGlyph](../Sources/Whoopsy/Presentation/DesignSystem/ActivityGlyph.swift). Read **without being required** — the one field on the workout row that is, because a name has a natural absence while a measurement does not — so a file without the column imports and every row falls back, rather than throwing. `Activity` (197 rows) and `Other` (11) are deliberately unmapped: they are WHOOP's own words for an activity it did not categorise, so they draw the `figure.run` fallback and print `ACTIVITY` like every other unmapped name
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
integrate, `biometric_samples` holds no rows on any database here, and the drain's type-24 record has
no reader (§5). `docs/ALGORITHMS.md` §2 carries the conversion.

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
([SleepSession.swift:189](../Sources/Whoopsy/Domain/Entities/SleepSession.swift#L189)), and its doc comment carries the three
measurements above so the next reader does not try `endTime − startTime` again.

---

## 5. Strap historical sync — **not a column, and not covered by the rule above**

**This section is not part of the per-column inventory.** Every `[ ]` above is a CSV column; every
`[ ]` here is a work item, and all of them are **work** — none is a decision and none is a
redundancy. The section exists because the strap holds **a backlog of cached data** that this app is
supposed to pull down on sync, and it currently cannot. **How far back that backlog reaches is
unmeasured and the sources disagree by a factor of five** — two reverse-engineering projects say ~14
days and neither measured it, while WHOOP's own user-facing guidance says ~72 hours — so plan for a
drain that does not assume a depth. `docs/BLE_PROTOCOL.md` §4 carries the disagreement.

**Sequencing: this is not started until the screens are considered done.** The gate is deliberate,
not a technical dependency — the strap feeds the screens, so building the sync first would mean
writing interfaces around a data shape that was still moving. Nothing below should be picked up
while UI work is open, however urgent the list reads.

Unlike every other section in this file, **this one has never run against its source.** Signing is
not functional (`CLAUDE.md` §Building for iOS) and the app has never executed against a strap, so
`biometric_samples` is empty in the dev database and in both simulator containers. Every claim below
is read off the code and the spec; none is a measurement of a device. Read it as a list of what is
wrong on paper, not as a list of observed failures.

**The table has a reader, and the four gaps below are what stand between the strap's cache and it.**
The sleep detail screen's `HOURS OF SLEEP` card draws the night's heart rate out of
`biometric_samples` (`HoursOfSleepChartSeries`, read in
`SleepViewModel.resolveHoursOfSleepSeries`), so an empty table is not latent — it is the `No
Data` state on a screen a user can open, on every night the export can show. Nothing below changes
because of it: a read path does not drain anything, and the four gaps in this section are exactly what
still stands between the strap's cache and that chart. It is recorded here so the next person to read
a screenshot of that chart knows the absence is this section's, not a chart bug.

### The chain that exists

More → Device → `DeviceViewModel.syncNow()` ([DeviceViewModel.swift:22](../Sources/Whoopsy/Presentation/Screens/Device/DeviceViewModel.swift#L22)) →
`SyncHistoricalDataUseCase.execute()` ([SyncHistoricalDataUseCase.swift:23](../Sources/Whoopsy/Domain/UseCases/SyncHistoricalDataUseCase.swift#L23)), which returns a `HistoricalSyncOutcome` →
`WhoopBLEDeviceRepositoryImpl.requestHistoricalSync` ([line 107](../Sources/Whoopsy/Data/BLE/Repositories/WhoopBLEDeviceRepositoryImpl.swift#L107)) →
`WhoopCommandFrames.historicalSyncRequest` ([line 43](../Sources/Whoopsy/Data/BLE/Parser/WhoopCommandFrames.swift#L43)) →
the profile's own builder (`WhoopPacketEncoder` or `WhoopPacketEncoder5`) → `WhoopBLEManager.drainHistoricalData` → `HistoricalDrainSession`.

**Inbound frames do not continue that line.** A frame reaches `WhoopPacketDecoder.decodeProprietaryFrame`
([WhoopPacketDecoder.swift:147](../Sources/Whoopsy/Data/BLE/Parser/WhoopPacketDecoder.swift#L147)) and
comes back a `WhoopRawFrame`, which is where the decoder stops; the manager then routes by what the
frame *is* — metadata to the drain session, a motion record to `MotionPayloadDecoder` and on to
`StepAccumulator` → `stepCounts`. `yieldTelemetry` → `StreamBiometricsUseCase` →
`biometric_samples` is the **live** path and not this one, and the drain's own heart-rate records
have no walk at all. So a drain's result is what `HistoricalSyncOutcome` says it is, and the rows it
writes arrive through the motion path or not at all.

**The pipe is connected end to end, and it stops one step short of a heart rate — on purpose.** The
decoder validates the envelope and hands up a `WhoopRawFrame`: start-of-frame, declared length,
header checksum and payload checksum are all checked. **No payload decoder for the drain's records
exists**, and one must not be restored from the deleted shape — see the record-walk item below.

**There is one decoded record type, and it is not this chain's.** `MotionPayloadDecoder` reads the
strap's accelerometer out of the two motion layouts (R21 for the 5.0/MG, R10 for the 4.0, dispatched
by **generation** rather than by trying one and falling back) and `TrackStepsUseCase` accumulates a
day's steps from it into `stepCounts`. So the drain's *transport* gap and its *record walk* gap are
not the same gap: steps have a walk, heart rate does not, and the item below is about the second.
That decode changes nothing here — motion and heart rate are different record types on the same
envelope, and a step count is not a beat.

Both the encoder and the decoder take a `WhoopProtocolProfile`, and both refuse rather than guess when
handed a generation this build cannot frame. **All three WHOOP models now carry a transmitted opcode
table** — the 4.0's `commandOpcodes` and the 5.0/MG's `syncOpcodes`, which are separate types because
the two generations share only part of their numbering — so a 5.0 or 5.0 MG is not refused a
command on the grounds that this build cannot frame one. **What is unproven on that generation is
whether it will answer**: its command characteristic needs an authenticated SMP bond that no project
here establishes a third-party iOS app can create (`docs/BLE_PROTOCOL.md` §7 Q6), and the strap page says
so in as many words rather than in a generic sentence. What remains below is what stops the drain
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
  same map at a measured scale**: OpenStrap's `parse_r24` reads these fields at these offsets and
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

- [ ] **No handshake is implemented at all, and the 5.0's hello is built and never sent.**
  `docs/BLE_PROTOCOL.md` §3 specifies a strict eight-step sequence a freshly bonded strap must be walked
  through before it will serve a historical sync, and it is 4.0-only and unverified. The one part of
  it that exists is the 5.0's static `CLIENT_HELLO`, constructed by `WhoopPacketEncoder5.hello`
  ([WhoopPacketEncoder5.swift:130](../Sources/Whoopsy/Data/BLE/Parser/WhoopPacketEncoder5.swift#L130))
  — whose only callers anywhere are §16's byte-for-byte assertions against the published frame. The
  one seam the manager actually sends through, `WhoopCommandFrames`, carries six builders (motion
  enable, history request, data ACK, abort, set clock, clock read-back) and **no hello**. So the
  command is still sent cold to a strap that has not been opened
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
- [ ] **No *heart-rate* record walk exists.**
  The record header is **96 bytes** (§4), so a walk at 16-byte chunks through the *live* offsets reads
  the wrong bytes at the wrong stride — on a real drain it would read a byte of the record counter as a
  heart rate and write it to `biometric_samples`. `decodeHistoricalSyncPayload` and
  `decodeLiveTelemetryPayload` are **deleted** and must not be restored. What replaces them for the
  type-24 record is
  `WhoopRawFrame`: a validated envelope and its bytes, undecoded. The record parser is written against
  a capture, which is the order §7 sets out — and the frame this hands up is the evidence that capture
  needs. **The motion layouts are the exception and they are the proof the shape works**: `MotionPayloadDecoder`
  reads R21 and R10 at their frame-absolute offsets, requires an exact payload length for each, and
  keys a batch on the strap's own clock where the record carries one — so what is missing here is
  neither a technique nor a field map: **the map exists above and a running parser has confirmed it
  across 127,971 records**, and what is absent is the decoder itself and the drain that would deliver
  a record to walk.
### Not blocked — true whatever the strap turns out to say

- [ ] **A drained batch will be filed under today unless the record parser reads the record's own
  time, and the field is the deliverable rather than a nicety.** Nothing writes a wrong instant, and
  nothing writes a right one either, because there is no walk for this record type. **The motion path
  is where that rule is already implemented, and it is the shape to copy**: an R21 batch carries its
  own instant
  (`seconds + fraction / 32768`, frame-absolute) and `TrackStepsUseCase` keys the day on that rather
  than on arrival, refusing a record whose own stamp falls outside the window it asked for — which is
  what turns the `RTC_LOST` caveat below from a silent wrong day into no row. When there is a walk for
  the type-24 record the per-record time is **not missing from the strap**: 4.0 carries a u32 unix time
  at `[7:11]` of the 96-byte header, so the parser reads
  the field rather than reconstructing one. This matters beyond this section: `recoveries`, `sleeps`
  and `strains` are all keyed on `startOfDay`, and the app's whole day model cannot represent a batch
  that spans fourteen of them, so a batch collapsed onto one instant would corrupt three screens at
  once. That is true for 4.0; 5.0 may need a session-clock correlation instead, which is an open
  question for that strap (see below). **One caveat sits on top of it and it is a real one**: an
  absolute timestamp is only as good as the clock that stamped it. The strap's RTC is set by
  `0x0A SET_CLOCK`, and the reference's event enum has **type 13 `RTC_LOST`, "battery fully died
  (clock reset)"**. So on a strap that has been flat, every drained record is wrong by an unknown
  offset with nothing in the record to show it, and the failure is *silent*: it files history onto a
  **wrong day** rather than onto no day, which is exactly the class of fabrication the day-key rule
  exists to prevent. **This app now sends the clock set** — `WhoopCommandFrames.setClockFrames`, both
  of the 4.0's firmware lengths and the 5.0's single `0x92`, because a wrong-length set is
  acknowledged but not latched — **and sending it is not the same as its having latched.** The 5.0's
  `0x93 GET_CLOCK` is the only read-back either generation offers, it is sent, and nothing in this app
  decodes the reply. So check a drained record's `[7:11]` against wall time on each of the three
  straps before trusting it, and do not treat a clock set having been written as evidence about it
- [ ] **The window asked for is one day, not fourteen.** `SyncHistoricalDataUseCase` starts from
  `getLatestSample()`, which is `nil` on an empty `biometric_samples`, so it falls back to
  `now − 1 day` ([SyncHistoricalDataUseCase.swift:25](../Sources/Whoopsy/Domain/UseCases/SyncHistoricalDataUseCase.swift#L25)).
  The stated goal — the band's full retained cache — is not what the code requests. `GET_DATA_RANGE`
  is the command that would answer "what does the strap actually hold", and it is unimplemented
- [ ] **Nothing owns the persistence.** `StreamBiometricsUseCase` is the **only** writer to
  `biometric_samples` ([line 35](../Sources/Whoopsy/Domain/UseCases/StreamBiometricsUseCase.swift#L35))
  and its writer *is* its stream consumer. `syncNow()` sends the command and returns; if no screen
  holds `liveTelemetryStream` open, a decoded batch is yielded to zero continuations and dropped with
  no error. The sync must persist on its own rather than depend on a screen being on
- [ ] **`syncNow()` reports the send, not the result.** It sets `"History sync complete."` whenever
  `execute()` does not throw ([DeviceViewModel.swift:22](../Sources/Whoopsy/Presentation/Screens/Device/DeviceViewModel.swift#L22)) —
  and in mock mode `requestHistoricalSync` is a `guard !isMockMode`
  ([WhoopBLEDeviceRepositoryImpl.swift:108](../Sources/Whoopsy/Data/BLE/Repositories/WhoopBLEDeviceRepositoryImpl.swift#L108)),
  a silent no-op under the same banner. "Complete" should mean rows written
- [ ] **`biometric_samples` has no retention.** No pruning exists anywhere in `Sources/` —
  `grep -rn "deleteOlderThan\|prune\|retention\|purge"` returns nothing. Fourteen days of beat-to-beat
  R-R is a large number of rows, so the retention policy is a decision to take *before* the first
  successful sync rather than after

### Capture first, decode second

The findings above come from public references, and the two disagree on record numbering and on
whether 5.0 times its records. **They are a reason to go and capture, not a reason to start
coding.** The first task is to drain each of the three straps once and record the raw frames; the
parser is then written against the recording. Decoding a live drain with a parser built from these
notes is the specific mistake to avoid — the `0xAA`-in-payload trap above makes a wrong parser look
like a working one, and its bugs would be tuned to the source's errors rather than to the strap's
behaviour. `docs/BLE_PROTOCOL.md` §7 orders the questions cheapest-first. The 4.0 base UUID sat first
while it was open; it was settled from the references rather than from a scan and the constant now
carries it, so the first capture is the envelope question.

### The capture has to be legible, and as the code stands it would not be

Added because everything above ends in the same instruction — *go and drain each of the three straps
once and record the raw frames* — and the app is currently built so that walk can be spent without
saying what happened. Both gaps below are **measured, not predicted**. Neither is a protocol
claim: nothing here decodes a byte, `docs/BLE_PROTOCOL.md` §7's cheapest-first order still stands, and
this is instrumentation for the walk rather than a substitute for it.

- [ ] **The one diagnostic on this path is one-shot per connection.**
  `hasLoggedProprietaryFrame` is declared at
  [WhoopBLEManager.swift:94](../Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L94), reset on
  connect and disconnect ([602](../Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L602),
  [620](../Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L620)), and it gates the only log
  there is at [line 825](../Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L825) — which prints
  the frame's type, seq, cmd and payload length. So a drain that streams thousands of frames writes
  **one line**: enough to establish that the strap speaks at all, and not enough to say what it sent
- [ ] **`MotionPayloadDecoder` refuses in silence, nine ways.** The file contains **no logging call
  at all** and nine `return nil` paths — the generation lookup at
  [line 64](../Sources/Whoopsy/Data/BLE/Parser/MotionPayloadDecoder.swift#L64), the type test at
  [line 76](../Sources/Whoopsy/Data/BLE/Parser/MotionPayloadDecoder.swift#L76), and the exact-length
  guards at [line 113](../Sources/Whoopsy/Data/BLE/Parser/MotionPayloadDecoder.swift#L113) and
  [line 164](../Sources/Whoopsy/Data/BLE/Parser/MotionPayloadDecoder.swift#L164) among them. So *"the
  strap sent motion records of a length this build does not expect"* and *"the strap never sent
  motion"* produce **identical evidence**, which is nothing. The manager is silent on its own side
  too — a refused decode is a plain `if let` with no `else`
  ([WhoopBLEManager.swift:835](../Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L835)) — so a
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
  cannot grow it without bound, and written at `.notice` for the retention reason above
- [ ] **The two `Info.plist` keys, which are what remove the cable.** `UIFileSharingEnabled` and
  `LSSupportsOpeningDocumentsInPlace` expose the app's Documents directory in the Files app under
  *On My iPhone → Whoopsy*, so the recording is read on the phone and shared from there rather than
  pulled off it. **Neither key is in `App/iOS/Info.plist` today**, and no such mechanism exists
  without them. There is **no API for a third-party app to write into Apple's Notes app** — the share
  sheet with Notes as its destination is the only route to that, and it is a user action rather than
  something this code can perform
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
([WhoopBLEManager.swift:757](../Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L757)), which
covers `0x2A37`; `didUpdateValueFor` decodes it and yields a sample
([:763](../Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L763), [:787](../Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L787));
`StreamBiometricsUseCase` persists it and `LiveSessionUseCase` feeds it to the session screen. Nothing
in that chain is a stub. What has never happened is a strap on the other end of it: `biometric_samples`
holds **0 rows** in every database on this machine.

So the walk answers exactly two questions, and neither is about the reader:

- **Does the strap expose `0x2A37` at all?** Some generation may put heart rate only in the
  proprietary payload, in which case the work belongs in §5 rather than here.
- **Do its frames decode?** The flags byte says whether the R-R field is populated at all (`k == 0`
  means the strap does not carry intervals), and the interval count is what decides whether a night's
  series can be reconstructed from per-notification arrival instants.

**Both answers are already instrumented, and both lines are one-shot per connection.** The GATT
inventory — every characteristic on the service with its properties, and `0x2A37 Heart Rate
Measurement present: true|false` — is gated on `hasLoggedCharacteristicInventory`
([:709](../Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L709)); the first decoded frame
(`flags`, `bytes`, `hr`, `rrIntervals`) is gated on `hasLoggedHeartRateFrames`
([:774](../Sources/Whoopsy/Data/BLE/Manager/WhoopBLEManager.swift#L774)). **Read them live rather than
after the fact** — both are `AppLogger.ble.info`, and §5's retention note applies here verbatim:
`.info` goes to a memory buffer and not to disk, so by the time the phone is back on the desk the two
lines that answer this can already be gone. That is also the argument for §5's `CaptureLog` being
`.notice` or file-backed, and it is not solved by anything in this section.

**A preview build shows the same screen with numbers on it, and it is not evidence about a strap.**
`WhoopMockBLEManager.liveTelemetryStream` starts a 1 Hz generator on subscription
([WhoopMockBLEManager.swift:59](../Sources/Whoopsy/Data/BLE/Manager/WhoopMockBLEManager.swift#L59)), and
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
| `CALORIES` | `estimateCalories` returns `nil` with no weight on file, deliberately. The route to a figure is the **Profile** page (More → Profile), which is where `weightKg` is supplied; until then the tile has no body to compute against, and a number there would be a 75 kg default the user never described |
| the five zone bands / `ACTIVITY STRAIN` | `strain` is `nil` until a sample arrives and `0.0` once one arrives that never reached zone 1 — `StrainScore.hasMeasurement`'s own distinction. So a short or easy session legitimately reads `0.0` with no zone time, which is a measurement and not an absence |

Everything else — `HEART RATE`, `AVG HR`, `MAX HR`, the running timer — should populate within a
second or two of connection, because the timer is drawn by the system from the wall clock and needs no
updates at all.

**The waveform's `LIVE TELEMETRY` badge is absent until the first reading**, for the same reason:
`Snapshot.isOnBody` is `nil` before any sample rather than defaulted `true`, so the badge has nothing
to stand on
([LiveSessionAccumulator.swift:85](../Sources/Whoopsy/Core/Math/LiveSessionAccumulator.swift#L85)). A
defaulted `true` is the fabrication class `WhoopDevice.batteryPercentage` already documents.

