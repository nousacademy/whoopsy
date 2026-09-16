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
| `physiological_cycles.csv` | 935 | 26 | **20** | yes | `WhoopExportParser` → `WhoopExportImporter` |
| `sleeps.csv` | 918 | 18 | **1** | yes | `WhoopExportParser.parseNaps` → `WhoopExportImporter.importNaps` |
| `journal_entries.csv` | 3403 | 6 | **0** | no | nothing |
| `workouts.csv` | 673 | 17 | **0** | no | nothing |

Two files are in `Package.swift`'s `resources:` — `physiological_cycles.csv`, and `sleeps.csv` for
its eight nap rows alone. `journal_entries.csv` and `workouts.csv` are on disk in the repo, in no
bundle, and read by nothing. See `CLAUDE.md`.

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
- [ ] **`Sleep performance %`** — 910 (5–100) — parsed, consumed by nothing. **Decision — do not cover.** `SleepSession.sleepPerformancePercentage` derives asleep-over-need ([SleepSession.swift:119](Sources/Whoopsy/Domain/Entities/SleepSession.swift#L119)); the two disagree on **454 of 910 nights** — but that total hides a regime change and must not be quoted alone: across the export's **137-day gap (2024-12-31 → 2025-05-17)** WHOOP's column becomes a different function, matching the app's expression on **423 of 451** pre-gap nights (MAE 0.062) and only **33 of 459** after it (MAE 7.05). So on the older half the app's derivation *is* WHOOP's, and the disagreement is entirely a post-2025 phenomenon. Re-measure era by era and by driving `sleepPerformancePercentage`, not by re-deriving the ratio — the clamp is part of the answer (dropping `min(100, …)` reports 457), and one rule is the point. **The column stays uncovered, but the derivation is now drawn**: it is the SLEEP PERFORMANCE breakdown row on the Recovery screen and, below it, the sleep-performance week chart (`MetricDay.sleepPerformance` → `WeekBarSeries(sleepPerformanceWeek:)`), and it is the ring plus the HOURS VS. NEEDED row on the sleep-performance screen Home's sleep ring pushes. So this line reads as "the export's number is not used", not "the quantity is absent from the app" — the figure on all of those is this app's own, and it will not match WHOOP's for the same night
- [x] **`Respiratory rate (rpm)`** — 910 (13.5–20.2) — → `sleeps.respiratory_rate`, `recoveries.respiratory_rate` and `MetricDay.respiratoryRate` → the Recovery screen's RESPIRATORY RATE breakdown row and the Respiratory Rate week chart under it. Read to **one decimal** there, because a week spans about two units — the reference week is 14.8…16.5, which whole numbers flatten to six `15`s. **Now a two-producer column**, the same shape as `Sleep consistency %` below: stored verbatim for an imported night, computed by `RespiratoryRateMath` ([RespiratoryRateMath.swift](Sources/Whoopsy/Core/Math/RespiratoryRateMath.swift)) for a strap night, and the two are told apart only by `source`. The model is respiratory sinus arrhythmia off the R-R series — `ALGORITHMS.md` §4 — and it is **unvalidatable against this app's data**, because the export carries no R-R series at all
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
does not make a covered column count twice. `ALGORITHMS.md` §4 carries the band's definition and the
explicit note that WHOOP publishes no stage boundaries, so every threshold in it is this app's own.
- [x] **`Sleep need (min)`** — 910 (321–650) — → `sleeps.target_sleep_need_seconds` → Home's SLEEP NEEDED panel, **and the SLEEP NEEDED figure of the `HOURS VS. NEEDED` card on the Sleep detail screen**. Stored verbatim; imported and strap nights must not be crossed
- [x] **`Sleep debt (min)`** — 910 (0–127) — → `sleeps.sleep_debt` (× 60, seconds like every duration on that table) → the **`Sleep Debt` row of the `HOURS VS. NEEDED` card's breakdown box**, which is also the column's second consumer of `Sleep need (min)` above: the card's other row is that need minus this debt. Stored verbatim for an imported night, computed by `SleepDebtMath` ([SleepDebtMath.swift](Sources/Whoopsy/Core/Math/SleepDebtMath.swift)) for a strap night — **a two-producer column**, distinguished by `source`, like `Sleep consistency %` below. **The two producers' values are not the same quantity and the card may only use one of them**: WHOOP's need is a total containing its debt term, so `need − debt` is WHOOP's own base-plus-strain, while `SleepNeedMath`'s need deliberately omits any debt term — so the box is gated on `SleepSession.hasWhoopSleepNeed` and is not drawn at all on a strap night, where both of its rows would sum to the printed total and both be mislabelled. The card is gated on the *pair*, so a night with no stored debt and a night whose debt exceeds its need draw no box either. The row carries no band, which it did not when it was drawn either, because a running deficit is not monotone the way the three banded rows are. The model is lagged (WHOOP's column correlates 0.891 with the *prior* night's shortfall against 0.506 with its own) and fitted, MAE 8.31 against a column of sd 33.9 — `ALGORITHMS.md` §4. **It stays out of `SleepNeedMath`**, and that is a separate decision from covering the column: the 7-night deficit term buys 0.35 of a point for a second fitted constant, and the nap term that the newly-stored `naps` table makes measurable is significant in sample (t = −5.74) and harmful out of it (3.634 against 3.588). Both measurements are in `ALGORITHMS.md` §4
- [ ] **`Sleep efficiency %`** — 910 (59–99) — not parsed. **Decision — do not cover, and the reason is measured.** `sleepEfficiencyPercentage` is the standard TST-over-TIB and matches this column on 826 of 910 rows. On 83 of the other 84 the mismatch is **not** a denominator problem: the export's own `In bed duration` equals asleep + awake on those rows, and the column still reads 2–5 points higher, so **WHOOP's efficiency is not a function of the two durations WHOOP publishes beside it**. There is no input to store that would reproduce it — see the efficiency section below
- [x] **`Sleep consistency %`** — 892 (7–94) — → `sleeps.sleep_consistency` → the **SLEEP CONSISTENCY** row of the Sleep detail screen **and the card of the same name that closes the page**, which is the column's second consumer and the reason the row is no longer its only reader. `SleepConsistencyScoring.summary(for:history:score:typicalScore:)` reads the stored value for the anchor night (stored-first, `session.sleepConsistency`), scores the four priors through `SleepConsistencyMath` when they carry none, and hands the pair to `SleepViewModel.consistencySummary` for `SleepConsistencyCard`; the card's headline is the figure the row prints two elements up, and the window mean the card used to print under it is a mean over this column. That mean is **computed and spoken but no longer drawn**: `SleepConsistencyCard.headline` passes `change: nil`, so a sighted reader sees the figure alone and the mean reaches only the card's `spoken(for:)` description — the column is not orphaned, it simply no longer surfaces as a second figure on the card. **The mean skips nights the model cannot score rather than counting them as zero**: `typicalScore` maps each window night stored-first and `compactMap`s the ones that still produce nothing, so two stored values beside two unscoreable nights average the two, and the mean is withheld below `RecoveryScoring.minimumBaselineDays`. The chart's five columns are all imported nights on a real device, so the stored value is what every one of them is drawn from. Stored verbatim for an imported night; a strap night is computed by `SleepConsistencyMath` ([SleepConsistencyMath.swift](Sources/Whoopsy/Core/Math/SleepConsistencyMath.swift)), a four-prior boundary-shift fit — `ALGORITHMS.md` §4. The column is nullable because the two producers must stay distinguishable: NULL is "not scored", `0` is "scored as badly as the scale allows"

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
> deferred.** The strap records motion and heart rate but produces no step counts, and the evidence
> against a pure-actigraphy detector is specificity rather than sensitivity. The only general-purpose
> open-source pipeline (GGIR/wristpy) is accelerometer-only, ships nap detection **off by default**,
> and warns that nonwear may itself be detected as a nap. The one PSG-validated pure-actigraphy
> threshold (Kanady 2011, ≥ 40 min) reaches sensitivity 92–96 % but **specificity 40–67 %**, and
> Fitbit's discriminator needs the step counts this strap does not produce. On this screen a nap is
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

**The table now has a reader, and that is new.** The sleep detail screen's `HOURS OF SLEEP` card draws
the night's heart rate out of `biometric_samples` (`HoursOfSleepChartSeries`, read in
`SleepViewModel.resolveHoursOfSleepSeries`), so an empty table is no longer latent — it is the `No
Data` state on a screen a user can open, on every night the export can show. Nothing below changes
because of it: the read path landing does not drain anything, and the four gaps in this section are
exactly what still stands between the strap's cache and that chart. It is recorded here so the next
person to read a screenshot of that chart knows the absence is this section's, not a chart bug.

### The chain that exists

Settings → `DeviceViewModel.syncNow()` ([DeviceViewModel.swift:10](Sources/Whoopsy/Presentation/Screens/Device/DeviceViewModel.swift#L10)) →
`SyncHistoricalDataUseCase.execute()` → `WhoopPacketEncoder.requestHistoricalSync`
([WhoopPacketEncoder.swift:109](Sources/Whoopsy/Data/BLE/Parser/WhoopPacketEncoder.swift#L109)) →
`WhoopPacketDecoder.decodeProprietaryFrame` ([WhoopPacketDecoder.swift:124](Sources/Whoopsy/Data/BLE/Parser/WhoopPacketDecoder.swift#L124)) →
`WhoopRawFrame` → `yieldTelemetry` → `StreamBiometricsUseCase` → `biometric_samples`.

**The pipe is connected end to end, and it now stops one step earlier than it used to — on purpose.**
The decoder validates the envelope and hands up a `WhoopRawFrame` whose payload it does not decode:
start-of-frame, declared length, header checksum and payload checksum are all checked, and the bytes
are passed through undecoded. The three payload decoders that used to sit here are **deleted**, not
fixed, and that is the change that matters most in this section — see the record-walk item below for
why. Both the encoder and the decoder take a `WhoopProtocolProfile`, and both refuse rather than guess
when handed a generation this build cannot frame, so **a 5.0 or 5.0 MG strap gets no command at all**
(there is no profile for it) and the strap page says so in as many words. What remains below is what
stops the drain working.

### The shape of the protocol, from the open-source references

Added after a survey of the two public reverse-engineering projects (`BLE_PROTOCOL.md` §Sources).
**This changes the status of several items below from "unknown" to "documented but unverified"** —
it does not make any of them measured. Three straps are in scope and they do not share a wire
format: **4.0, 5.0 and 5.0 MG**, with two envelopes, two header CRCs and two non-overlapping
packet-type numberings.

- **The record layout is known for 4.0.** The flash record is type 24, packet type `0x2F`, one per
  second of wear, with a **96-byte header** carrying a u32 UNIX timestamp at `[7:11]` and
  sub-seconds at `[11:13]`. Heart rate is at `[17]`, R-R intervals at `[18:19+2n]`. Marked verified
  by the source, and tested by it on 4.0 only.
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

- [ ] **No handshake is implemented at all.** `BLE_PROTOCOL.md` §3 specifies a strict eight-step
  sequence a freshly bonded strap must be walked through before it will serve a historical sync.
  `grep -rn "0x23\|0x16\|0x17\|handshake" Sources/` returns **nothing** — the command is sent cold to
  a strap that has not been opened
- [ ] **The ACK loop is absent, and it is the gate.** No `0x17` reply, no token echo, no cursor
  advance — `grep -rn "batchAck\|0x17" Sources/` returns nothing. Every other item here is downstream
  of this one: a drain that is never acknowledged does not advance, so nothing else can be tested
  until it is
- [ ] **The request opcode disagrees with both references.** They put the historical request at `0x16`
  (4.0) / 22 (5.0) and the record type at `0x2F` (4.0) / 47 (5.0); this document's own §2 assigns
  `0x30` to **Asynchronous Event / Heartbeat**. So an outbound `0x30` is asking for an event rather
  than a drain. The inbound half of this is gone with the payload decoders — there is no longer a
  `case 0x30` parsing an event frame as a record batch — and **the outbound byte is deliberately not
  corrected yet**: the drain is a loop that needs the per-batch `0x17` ACK, and §4 records that
  without a correct ACK **the strap re-sends the same batch forever**. Starting a drain this app
  cannot acknowledge is worse than sending a command a strap ignores. The opcode moves when the ACK
  loop lands, not before it
- [ ] **No record walk exists at all, and that is now the honest state rather than a wrong one.**
  The decoder used to walk the payload as 16-byte chunks through the *live* offsets; §4 gives a
  **96-byte** record header, so the walk read the wrong bytes at the wrong stride — and on a real
  drain it would have read a byte of the record counter as a heart rate and written it to
  `biometric_samples`. That walk and its two helper decoders (`decodeHistoricalSyncPayload`,
  `decodeLiveTelemetryPayload`) are **deleted**. What replaces them is `WhoopRawFrame`: a validated
  envelope and its bytes, undecoded. The record parser is written against a capture, which is the
  order §6 sets out — and the frame this hands up is the evidence that capture needs
- [ ] **Which 4.0 base UUID is real is unresolved.** `BLE_PROTOCOL.md` §1 and `WhoopGATTConstants`
  disagree (`…82b8-614a-1c8cb0f8dcc6` against `…82A5-4E40-1CA360B95B30`). This does not present as a
  decode error — it presents as **no device found**, which is why it is worth settling with a service
  scan before anything else

### Not blocked — true whatever the strap turns out to say

- [ ] **A drained batch will be filed under today unless the record parser reads the record's own
  time, and the field is the deliverable rather than a nicety.** The decoder that used to stamp every
  record with `Date()` is deleted, so nothing writes a wrong instant any more — and nothing writes a
  right one either, because there is no walk. When there is one, the per-record time is **not missing
  from the strap**: 4.0 carries a u32 unix time at `[7:11]` of the 96-byte header, so the parser reads
  the field rather than reconstructing one. This matters beyond this section: `recoveries`, `sleeps`
  and `strains` are all keyed on `startOfDay`, and the app's whole day model cannot represent a batch
  that spans fourteen of them, so a batch collapsed onto one instant would corrupt three screens at
  once. That is true for 4.0; 5.0 may need a session-clock correlation instead, which is an open
  question for that strap (see below). **One caveat sits on top of it and it is a real one**: an
  absolute timestamp is only as good as the clock that stamped it. The strap's RTC is set by
  `0x0A SET_CLOCK` — which this app never sends — and the reference's event enum has **type 13
  `RTC_LOST`, "battery fully died (clock reset)"**. So on a strap that has been flat, every drained
  record is wrong by an unknown offset with nothing in the record to show it, and the failure is
  *silent*: it files history onto a **wrong day** rather than onto no day, which is exactly the class
  of fabrication the day-key rule exists to prevent. Check a drained record's `[7:11]` against wall
  time on each of the three straps before trusting it
- [ ] **The window asked for is one day, not fourteen.** `SyncHistoricalDataUseCase` starts from
  `getLatestSample()`, which is `nil` on an empty `biometric_samples`, so it falls back to
  `now − 1 day` ([SyncHistoricalDataUseCase.swift:17](Sources/Whoopsy/Domain/UseCases/SyncHistoricalDataUseCase.swift#L17)).
  The stated goal — the band's full retained cache — is not what the code requests. `GET_DATA_RANGE`
  is the command that would answer "what does the strap actually hold", and it is unimplemented
- [ ] **Nothing owns the persistence.** `StreamBiometricsUseCase` is the **only** writer to
  `biometric_samples` ([line 35](Sources/Whoopsy/Domain/UseCases/StreamBiometricsUseCase.swift#L35))
  and its writer *is* its stream consumer. `syncNow()` sends the command and returns; if no screen
  holds `liveTelemetryStream` open, a decoded batch is yielded to zero continuations and dropped with
  no error. The sync must persist on its own rather than depend on a screen being on
- [ ] **`syncNow()` reports the send, not the result.** It sets `"History sync complete."` whenever
  `execute()` does not throw ([DeviceViewModel.swift:10](Sources/Whoopsy/Presentation/Screens/Device/DeviceViewModel.swift#L10)) —
  and in mock mode `requestHistoricalSync` is `if !isMockMode { … }`
  ([WhoopBLEDeviceRepositoryImpl.swift:79](Sources/Whoopsy/Data/BLE/Repositories/WhoopBLEDeviceRepositoryImpl.swift#L79)),
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
behaviour. `BLE_PROTOCOL.md` §6 orders the questions cheapest-first; the service scan that settles
the 4.0 base UUID is first because a wrong UUID reads as *no device at all*.

### What this couples to

The R-R series this sync would deliver is the same series the RSA respiratory-rate work needs — a
contiguous, correctly ordered beat-to-beat record. That work is blocked by the fact that a
`biometric_samples` row's `timestamp` is an arrival instant rather than a beat time (`CLAUDE.md`),
and the sync is where that gets fixed or inherited: a drained record arriving with its own unix time
would give the tachogram a real time base, which is more than the live path can offer without
reconstructing beat times by cumulative sum.
