# Whoopsy Mathematical & Physiological Algorithms Specification

This document details the open mathematical models implemented in Whoopsy for computing **Recovery**, **Strain**, **Heart Rate Variability (HRV)**, **Sleep Staging**, **Sleep Need**, **Stress Monitor** and **VO₂ Max**.

§6 is the exception among them in a different sense than it used to be: it is the only model here whose constant is **not** this app's own and is not fitted to anything this app can see — it is quoted from a published method and cited — and it is the only one whose output the screen labels as an **estimate** rather than a measurement. It also still records WHOOP's own three-tier model and why none of that is implemented.

Three sources feed these models. The **WHOOP strap** supplies high-frequency telemetry over BLE (heart rate, R-R intervals, accelerometer, skin temperature, SpO2). **Apple HealthKit** supplies daily aggregates: SDNN, resting heart rate, staged sleep, and a daily step total — and, since the VO₂ MAX panel began deriving its own figure, no longer a VO₂ max, because this app no longer asks to read one. A **WHOOP data export**, imported once through Settings, supplies three years of the same daily aggregates WHOOP itself computed (HRV, resting heart rate, SpO2, skin temperature, respiratory rate, sleep stage totals) — plus WHOOP's own finished Recovery and Strain scores. Which source can feed which model is a real constraint, not a preference — §2, §4 and §5 state where it binds, and §1 and §3 state what the export does and does not decide.

---

## 1. Heart Rate Variability (HRV)

Whoopsy records two different HRV quantities. Which one a reading is depends entirely on where it came from — the two are **not** interchangeable:

| Metric | Definition | Source | Typical range |
| :--- | :--- | :--- | :--- |
| **RMSSD** | Root mean square of successive differences | Strap R-R intervals over BLE | ~40 – 90 ms |
| **SDNN** | Standard deviation of all N-N intervals | Apple HealthKit (`heartRateVariabilitySDNN`) | ~20 – 60 ms |
| **RMSSD** *(inferred)* | Same quantity, computed by WHOOP | WHOOP data export, `Heart rate variability (ms)` | ~15 – 99 ms observed |

$$\text{RMSSD} = \sqrt{\frac{1}{N-1} \sum_{i=1}^{N-1} (RR_{i+1} - RR_i)^2}$$

$$\text{SDNN} = \sqrt{\frac{1}{N-1} \sum_{i=1}^{N} (RR_i - \overline{RR})^2}$$

HealthKit exposes **no RMSSD type at all** — SDNN is the only HRV quantity it publishes. Apple's SDNN
arrives already computed and is read as published; it is never passed through the filter below.

### The never-mix rule

SDNN and RMSSD measure different things and are systematically offset, so they must never share a
baseline. Every stored reading therefore carries the metric it was measured with (`HRVMetric` on
`RecoveryMetric`, persisted as `recoveries.hrv_metric`), and every consumer filters history to the
matching metric before doing arithmetic on it — see `RecoveryScoring`, which holds the only such
filter. A baseline pooled across both would sit between two distributions and mis-score every day,
silently, because a wrong z-score is still a number in range.

Cold-start baselines are per-metric (`HRVMetric.coldStartMeanMs` / `coldStartStdDevMs`): RMSSD
65.0 ± 12.0 ms, SDNN 40.0 ± 10.0 ms. The SDNN pair is a **placeholder**, unvalidated against real
Apple Watch data; revise it once the import has run on a device for a few weeks.

### Artifact Rejection & Filtering
* **Physiological Range**: R-R intervals outside 300 ms (200 BPM) to 2000 ms (30 BPM) are rejected.
* **Ectopic Beat Filter**: Any $RR_{i+1}$ differing by more than 20% from the local median ($5$-beat window) is flagged as an ectopic/errant beat and filtered out. Clustered anomalies trigger linear interpolation using surrounding valid intervals.

Both apply only to strap R-R intervals, in `Core/Math/HeartRateVariabilityMath.swift`
(`filterRRIntervals`, `calculateRMSSD`, `calculateSDNN`, `calculatePNN50`).

**Coverage, and why it is not yet a contiguous series.** The strap's Heart Rate characteristic sends
several adjacent beats per notification (`BLE_PROTOCOL.md` §4), and `biometric_samples.rrIntervalsMs`
holds that full per-notification list as of `v8`. It held only the first interval before that, so no
stored R-R series predates `v8` and the column is empty in every existing database — nothing has been
backfilled, deliberately, because a one-element series written as if it were the whole notification
would misrepresent the capture. Two consequences stand: RMSSD computed over intervals that survived
that thinning differences beats that were **never adjacent**, and the series is only contiguous within
a notification rather than across the night. Both are open, and both are recorded here rather than
left to look like properties of the model.

### The imported export is RMSSD, and that is an inference

The third row in the table above is the one claim in this document that is **not** a closed fact. The
export does not name the quantity its `Heart rate variability (ms)` column holds. It is classified as
RMSSD because WHOOP publishes its overnight HRV as rMSSD, and because the imported distribution is
consistent with that: mean $52.5$ ms, SD $10.5$ ms, range $15$–$99$ over 910 nights, which sits in
this document's RMSSD band and reaches values SDNN rarely does. The classification is made in exactly
one place — `WhoopExportImporter`, where `todayHrvMetric: .rmssd` is passed to `RecoveryScoring` and
written to `hrv_metric` — so it can be revised in one edit if the evidence changes.

It matters because of the never-mix rule: this is what decides which baselines the imported days
join. Classified as RMSSD, three years of imported history and every future strap night share one
baseline and the app scores them alike. Misclassified as SDNN, they would join the HealthKit baseline
instead and every z-score either side would be computed between two different distributions.

**What would falsify it**, and how to check: a strap night's own RMSSD should be the same order of
magnitude as the imported values for the same period. If strap RMSSD comes out at roughly twice the
imported figure, the export is not RMSSD and the constant above is wrong. `Tests/WhoopsyTestRunner`
§11 pins the imported distribution; the strap side of the comparison needs a device.

### One HealthKit path deliberately not taken

HealthKit also exposes `HKHeartbeatSeriesSample`, which carries true beat-to-beat intervals and could
therefore yield a real RMSSD from Apple data. It is unused on purpose: those series are produced only
by the ECG app and by narrow on-demand watch recordings, so their coverage is far sparser than
overnight SDNN, and sourcing one metric name from two provenances would make a baseline's meaning
ambiguous. Revisit only after the never-mix rule is replaced.

---

## 2. Daily & Activity Strain (0.0 – 21.0 Scale)

Strain is a continuous, non-linear metric reflecting both cardiovascular and muscular load. Whoopsy uses a modified **Borg-scale exponential integration model**:

$$\text{Total Load} = w_{\text{cardio}} \cdot \sum_{z=1}^5 w_z \Delta t_z + w_{\text{muscular}} \cdot V_{\text{normalized}}$$

$$\text{Daily Strain} = 21 \times \left(1 - e^{-k \cdot \text{Total Load}}\right)$$

### Zone Weights ($w_z$)
Heart rate is classified into 5 personalized zones based on Heart Rate Reserve ($\text{HRR} = \text{Max HR} - \text{Resting HR}$):

| Zone | % HRR Range | Multiplier Weight ($w_z$) | Intensity Level |
| :--- | :--- | :--- | :--- |
| **Zone 1** | 50% – 60% | $1.0$ | Active Recovery |
| **Zone 2** | 60% – 70% | $2.0$ | Aerobic Base |
| **Zone 3** | 70% – 80% | $4.5$ | Tempo / Threshold |
| **Zone 4** | 80% – 90% | $9.0$ | Anaerobic Capacity |
| **Zone 5** | 90% – 100% | $16.0$ | Maximal Effort |

Scaling constant $k \approx 0.000045$ is calibrated to bind the asymptotic ceiling cleanly to 21.0.

### Strain is strap-only, and HealthKit must not feed it

The integrator assumes a sample roughly once per second: each step contributes
$\min(5.0, \Delta t)$ seconds of zone time, and the day's duration is taken as `sampleCount / 60`.
Apple Watch heart rate is sampled every **1–5 minutes**, so every interval clamps to the 5-second
ceiling and a full day contributes a few hundred seconds of zone time instead of ~12 hours.

Because $21 \times (1 - e^{-k \cdot \text{Load}})$ saturates, under-integration does not produce an
obviously broken output — it produces a *plausible low number* (a wrong 3.4 rather than an error),
which is worse than no reading at all. HealthKit also has no accelerometer type, so the muscular term
has no input whatsoever. Strain therefore remains strap-driven, and a HealthKit strain path would
require a different algorithm over `HKWorkout` windows rather than this one fed with coarser data.

### Imported strain days are WHOOP's number, not this formula's output

The data export carries **no heart-rate time series at all** — it holds one row per day, so the
integrand above has nothing to integrate. Its `Day Strain` column is WHOOP's own finished score, and
that is what `WhoopExportImporter` writes to `strains.strainScore`.

This is the one place in the app where a stored strain value was **not** produced by
`StrainAccumulatorMath`, and it is stated plainly here because it is otherwise invisible: the column
holds a number in the same $0 \dots 21$ range, and a reader has no way to tell which of the two
produced it. Two consequences follow.

* The imported score is a **different algorithm's output**. It is not comparable term-for-term with a
  strap day's, even though both saturate at 21. Where the two meet in a chart, the older half is
  WHOOP's model and the newer half is this one.
* There is **no zone breakdown**, because a distribution cannot be recovered from a total. The
  imported rows carry `averageHeartRate` and `maxHeartRate` — real measurements from the same row —
  but `StrainScore.zones` is empty for every one of them, and `StrainDashboardView` renders that
  absence rather than a stand-in.

### Days with no measurement

**A day with no samples is not stored.** `CalculateStrainUseCase`'s empty branch returns `nil` and
writes no row, matching Recovery and Sleep; its measured branch writes `hasMeasurement: true`, so a
returned value always reads back as a measurement.

It used to reserve a row — `strainScore` `0.0` with no heart rates — so that a reader could tell a
measured rest day from a day nobody measured. Nothing read it that way, and the row cost two things:
`WhoopExportImporter` saw a row and skipped the day, so WHOOP's genuine `Day Strain` for it was never
imported, and `StrainViewModel` treated it as a settled day. Rows written before this change are still
on disk in that shape, which is why `StrainScore.hasMeasurement` stays — as reader tolerance, not as
a marker any writer sets.

The flag is required, and **the score is not the test**. A `0.0` is representable on a measured path:
`WhoopExportImporter` stores WHOOP's own `Day Strain` verbatim, and the export's column is non-empty
on 933 of its 935 rows while holding exactly `0.0` on **two** of them — 2024-06-05 and 2024-12-31,
both genuinely measured (average heart rate 59 and 80). A rule keyed on `score == 0` would have
marked two real measurements as absences. The measured branch computes `hrSum / samples.count` over
a non-empty sample set, so it can never write `averageHeartRate = 0`; that is what makes the *whole
signature* — `0.0` score, `0` average heart rate, no `source` — identifiable, and it is the predicate
`v7_strain_measurement_marker` backfilled on. Most existing rows are measurements, so the column
defaults to `true` and the migration's `UPDATE` corrects the placeholders; the `source IS NULL` clause
is what keeps a row an importer wrote from ever matching, whatever its heart-rate fields hold.

`StrainDashboardView` gates on the flag rather than on the score, so a legacy placeholder renders `—`
instead of a confident `0.0`. Its zone test is `hasMeasurement && !zones.isEmpty` and is **not
redundant**: the empty branch built all five zones with every duration at zero, so testing emptiness
alone would draw a bar asserting no time in any zone on a day nobody measured.

---

## 3. Recovery Score (0% – 100%)

The Recovery score quantifies physiological readiness as deviations from a personal baseline. The
baseline is a **flat mean and standard deviation over the last 30 days of history** — not an
exponentially weighted moving average, and with no recency weighting. Which thirty days that is, and
which of the resulting means a screen is allowed to print, are the two rules in the subsection
below:

$$\text{Recovery} = 50 + 24 \cdot z_{\text{HRV}} - 18 \cdot z_{\text{RHR}} + \left(\text{clamp}(\text{SleepPerf},\, 0.4,\, 1.2) - 0.70\right) \cdot 20$$

$$\text{result} = \text{round}\left(\max\left(1, \min\left(99,\, \text{Recovery}\right)\right)\right)$$

Where:
* $z_{\text{HRV}} = \frac{\text{HRV}_{\text{today}} - \mu_{\text{HRV}}}{\sigma_{\text{HRV}}}$, computed **within one HRV metric** (§1). Higher HRV increases recovery.
* $z_{\text{RHR}} = \frac{\text{RHR}_{\text{today}} - \mu_{\text{RHR}}}{\sigma_{\text{RHR}}}$. Lower RHR increases recovery. Resting heart rate is metric-independent, so its baseline draws on the whole window.
* $\text{SleepPerf} = \frac{\text{Actual Sleep Duration}}{\text{Target Sleep Need}}$, clamped to $0.4 \dots 1.2$ before use.

There is **no respiratory-rate term**. The model this document previously specified included
$-10 \cdot z_{\text{Resp}}$, but no *measured* input ever existed for it. The strap path has no
respiratory sensor: `SleepSession.respiratoryRate` is `nil` for every night it classifies, and
`HealthKitImporter` is the only source of a real value — and it is not the path this formula scores.
Earlier builds filled the gap with constants (`14.4` written by `AnalyzeSleepUseCase`, `14.0` handed
out by `GRDBSleepRepository`), which is precisely the input a $z_{\text{Resp}}$ baseline would have
been built on: a number with no variance, collapsing to the degenerate-input floor. The term was
removed from the code and from this specification together.

The output range is $1 \dots 99$, never $0$ or $100$: the score is an estimate drawn from a
statistical window, so a perfect or hopeless reading is not claimable.

### The scoring window, and the baseline a screen may print

Two decisions live here rather than at a call site, because both are wrong in a way that looks right.

**The window is the last 30 days that *have rows*, not the last 30 calendar days.**
`RecoveryScoring.baselineWindow(before:in:)` filters to the days strictly before the day being scored
and *then* takes the trailing `baselineWindowDays` (= 30) — the cap is applied after the filter,
because slicing first would take the wrong thirty. Strictly before, so a day never contributes to its
own baseline. The series handed in must be **oldest-first**, which is what the repositories return
(`order(Column("date").asc)`) and what the importer's chronological walk produces.

**"Strictly before" is a comparison of calendar days, not of instants, and that distinction is
load-bearing because the two callers pass different kinds of anchor.** Rows are keyed on
`startOfDay`, but `WhoopExportImporter` hands a snapped day key while the Recovery screen hands the
`Date` it is displaying — an instant, which on any day this app runs is hours after midnight.
Compared raw, that instant is *later* than the day's own midnight row, so the day was counted inside
its own baseline and the printed mean came from a different set of days than the score above it.
Measured on the simulator: 2026-08-17 printed an HRV baseline of 53 ms and a sleep-performance
baseline of 80%, where the strictly-before window gives 52 ms and 78%. Both sides are snapped inside
`baselineWindow` rather than at the call sites, so the rule holds for whatever anchor a caller
passes; the day this was found on was one of the roughly one-in-fifteen where the two windows do not
round to the same printed figure, which is why a screenshot check on an arbitrary day would not have
caught it.

The distinction is not academic, and it is measured rather than assumed. Over the bundled export, on
the 907 days with a comparable predecessor, **391 days (43%) have a calendar-30 window that differs
from the last-30-rows window**. The mean differs by up to **18.03 ms** (p95 5.59, median 0.40), and
104 days differ by more than 1 ms. The worst case reaches back **172 calendar days** to fill thirty
rows; 420 of 910 HRV days have a gap somewhere in the prior thirty. So the two definitions are not
nearly the same number — they are different baselines, and printing one while scoring against the
other would put a figure under a ring that the ring never saw. A reader must therefore fetch far
enough back for the window to fill: `baselineWindowLookbackDays` = 180 covers every day this app has
data for. A short read does not fail loudly; it silently prints a baseline built from fewer days than
the score above it used.

**A mean is not a baseline until the window held observations.**
`BaselineStatisticsMath.baseline` substitutes a **cold-start constant** when it is handed an empty
window — 65 ms RMSSD, 40 ms SDNN, 54 bpm — which is the right thing for scoring a first day and the
wrong thing to print, because a screen showing `65 ms` as "your HRV baseline" would be presenting a
constant as a measurement. `RecoveryScoring.baselines(history:todayHrvMetric:...)` therefore returns
a `Baselines` carrying each mean **and the count it was taken over**, and `Baselines.displayed`
withholds a mean unless its count reached `minimumBaselineDays` (= 3). The counts are the whole
mechanism; a caller that read the means directly would print the cold start.

`RecoveryScoring.score(_:)` is built on `baselines(...)`, so the Recovery detail screen's four rows —
HRV, resting heart rate, respiratory rate, sleep performance — print the numbers the score in the
ring above them was computed from, and cannot drift from it. Two narrowings are applied inside
`baselines` rather than by the screen, because a screen that forgot one would print a mean across two
quantities: the HRV mean is filtered to `todayHrvMetric` (the never-mix rule, §1), and the HRV mean
is taken over **measured** days only — the placeholder filter, since a legacy `score: 0` row would
otherwise drag every mean toward zero. Respiratory rate is a mean over the days carrying one (it is
optional and the strap has no sensor for it, so a window can hold thirty days and no rate at all),
and sleep performance is a mean over the nights handed in, in the **printed** integer percentage —
`SleepSession.sleepPerformancePercentage` is an `Int`, so 5 h of an 8 h need is 63, not 62.5.

### Imported days are scored by this same formula

The data export supplies the *inputs* above — an overnight HRV, a resting heart rate, SpO2, skin
temperature, a respiratory rate, and a night's sleep stages — and `WhoopExportImporter` scores every
one of them through `RecoveryScoring`, in chronological order, against the 30 imported days before
it. This is the whole reason the import recomputes rather than storing what it was given: one formula
covers the entire history, so the chart has no seam and this section stays true for it.

WHOOP's own `Recovery score %` column is **deliberately not stored**. The consequence is a real one
and is not hidden: a historical day's percentage in this app will generally differ from what the
WHOOP app displayed on that day, because the two are different models over the same measurements.
The alternative — storing WHOOP's number for old days and computing this app's for new ones — would
put two incompatible y-axes in one chart and make every trend line across the join meaningless.

Two properties of the walk are worth knowing when reading old scores:

* **The baseline is the imported window, not a warmed-up one.** The first day has no history and lands
  on the cold-start constants above; the 31st day has a full window. Early scores are therefore
  computed against a thinner baseline than later ones, which is inherent to scoring a history
  forward, not an artefact. No minimum-days rule is applied **to the score**:
  `BaselineStatisticsMath.baseline` falls back for an empty window, and the coefficient-of-variation
  floor keeps a 1–3 value window from pinning the score to the $\pm 4$ clamp. That is the deliberate
  difference from `Baselines.displayed` above, which is a *display* gate: a one-day window still
  scores a day, it just is not printed as that day's baseline.
* **A day the app already measured is never overwritten.** Imported rows are written only where no
  measurement exists, so a strap day and an imported day can never disagree about the same date.

Finally, a consequence of the formula's sensitivity rather than of the import: the weights above are
$24$ and $18$ per unit of $z$, so **a day two standard deviations out genuinely reaches the clamp**.
On real imported history, roughly a quarter of 910 days sit at $1$ or $99$. That is this model
behaving as specified, not a defect in the import — the `±4σ` guard exists to stop one wild
observation dominating, and it binds well before that.

### Days with no measurement

**A day the strap recorded nothing for is not stored.** `CalculateRecoveryUseCase` returns `nil` and
writes no row, so a day with no data is absent from `recoveries` rather than present as a reserved
zero. Nothing is substituted from the user profile: the path previously scored such a day from
`UserProfile.baselineHrvRmssd` as though the strap had measured it, which made an unworn night
indistinguishable from an average one and silently overwrote a HealthKit SDNN row for the same day.

The test the writer uses is the test its readers use. `RecoveryMetric.hasMeasurement` is
`hrvValueMs > 0`, and the guard is that same comparison made against the value **as it will be
stored** — rounded to one decimal, because an RMSSD below $0.05$ ms would otherwise pass on the raw
value and still be written as `0.0`. `HeartRateVariabilityMath.calculateRMSSD` returns exactly `0.0`
when `filterRRIntervals` leaves fewer than two beats, so a guard on the *interval count* is not the
same test: one surviving interval produces a `0.0` ms row that every reader calls unmeasured.

Two rules hang off the marker, and a third party does too:

* **A placeholder is not an observation.** `RecoveryScoring` filters history to measured rows before
  computing any mean or standard deviation. Counting a legacy placeholder would put a $0$ ms HRV and
  a $0$ bpm RHR into the window and drag every subsequent baseline toward them — the day would then
  read as a real measurement of zero rather than as the absence of one.
* **A placeholder is not a score.** Presentation renders one as `—` with no ring rather than as a red
  0%.
* **A placeholder does not block an import.** It says the strap had no data, not that the day is
  finished, so `HealthKitImporter` may fill it with SDNN — the day the strap left unworn is exactly
  the day HealthKit can supply. `RecoveryRepository.getLocalRecovery(for:)` is the query both ask,
  and it exists precisely because "a row is stored" and "a measurement is stored" are different
  questions.

**Rows written before this rule are still on disk in the placeholder shape** — `recovery_score` `0`,
`hrv_value_ms` `0`, `resting_heart_rate` `0`, `spo2_percentage` and `respiratory_rate` `NULL` — which
is why `RecoveryMetric.hasMeasurement` stays at all. It is now reader tolerance for those rows, not a
marker any writer sets: no production path can create one. `0` is the reserved value on them because
the formula above cannot produce it (the clamp is $1 \dots 99$), and no HRV or resting heart rate is
ever physiologically zero either. Three independent signals, one meaning.

**All four metrics now report absence the same way: no row, and the optional is the answer.**

| Metric | A day with no measurement is | The test | Where |
| :--- | :--- | :--- | :--- |
| Recovery | **no row** (legacy rows: a row of zeros) | the optional — `RecoveryMetric?`; `hasMeasurement` on a legacy row | this section |
| Strain | **no row** (legacy rows: a row of zeros) | the optional — `StrainScore?`; `hasMeasurement` on a legacy row | §2, *Days with no measurement* |
| Sleep | **no row at all** | the optional — `SleepSession?` | §4, *Nights with no measurement* |
| Stress | **no score and no series** | the optional — `StressDay?` | §5, *Days with no measurement have no score* |

That is deliberate convergence. Recovery and Strain used to reserve a zero so that a keyed table
could tell "nothing stored" from "stored as nothing", at the cost of a row that every second reader
had to remember to exclude — and when one did not, an unworn day imported as a real score or plotted
as a measured `0.0`. An absent row cannot be mistaken for data by a reader that forgot the rule: it
is the same shape Sleep and Stress always had, and a reader that handles one now handles all four.
`MetricWeek` encodes all four side by side, which is what keeps a chart's seven points and a panel's
mean from disagreeing about which days were measured.

### The rolling baseline is a mean, and that is deliberate

The small figure under Home's RHR and Sleep Needed panels is the **7-day mean of that same metric
over the slots that carry a measurement** — not a z-score, not a baseline with a standard deviation,
and not the previous day. It is `nil` below `MetricWeek.minimumBaselineDays` ($3$), the same floor
`StressMath` uses, because a mean of two days is arithmetically defined but is not a baseline.

This is a **display** statistic and nothing scores from it, which is why it is not
`BaselineStatisticsMath` and why the floor is duplicated in `Domain` rather than imported from
`Core`: `Domain` imports only `Foundation` and cannot name `StressMath`. The two constants are
deliberately equal and separately documented for that reason.

The baseline is also **not** `UserProfile.targetSleepHours`. That field is a hard-coded $8.0$ that is
never editable and never persisted, so comparing a real imported night against it would be comparing
WHOOP's own need to a constant this app wrote down.

What a day with **no sleep session** contributes to an otherwise-measured day is the sleep *pivot*,
$0.70$ — the one value of that term which shifts the score by zero. Substituting a plausible night
would turn "we do not know how you slept" into a real adjustment.

### Degenerate-input guards

Both are in `Core/Math/BaselineStatisticsMath.swift` and both exist because their absence produced a
silently wrong score rather than an error:

* **Coefficient-of-variation floor** (`minimumCoefficientOfVariation = 0.05`). A baseline's standard
  deviation is never allowed below 5% of its own mean. Without it, a near-constant history collapses
  the denominator: a series with one repeated value scored a ~500σ deviation from a 0.5 ms
  difference and pinned to the floor while looking like a perfectly ordinary number.
* **Absolute z-score ceiling** (`maximumAbsoluteZScore = 4.0`). One wild observation cannot dominate
  the score.

Cold-start values, used only while the history is empty, live on `HRVMetric` (HRV) and
`RecoveryScoring.coldStartRestingHeartRateStdDev` (resting heart rate).

### Recovery Tiers
* **Green (67% – 100%)**: High readiness, primed for high strain.
* **Yellow (34% – 66%)**: Moderate readiness, maintain baseline volume.
* **Red (0% – 33%)**: Low readiness, focus on active recovery and sleep.

The boundaries are written down once, as the three half-open `Range<Int>` constants on
`RecoveryMetric.RecoveryState` — `greenRange = 67..<101`, `yellowRange = 34..<67`,
`redRange = 0..<34` — which `RecoveryState.init(score:)` is built from. They are ranges rather than
the `case 67...100` literals they replaced because a **view** now prints them: the month calendar's
key reads `<34%`, `34% - 66%` and `>66%` off them (`RecoveryTierLegend.entries`) rather than typing
the numbers a second time, so the key cannot come to disagree with the tier it is describing. The
inclusive bounds the key needs are arithmetic on the range and deliberately not new constants —
`>66%` is `greenRange.lowerBound - 1`, not yellow's lower bound, which is the off-by-one a key that
read both labels as "the same number" would ship.

`RecoveryMetric.state` forwards to the initialiser, and a caller holding a bare score —
`GenerateCoachInsightsUseCase`'s green/not-green message — goes through it too rather than comparing
against `67` itself, which is what that use case used to do. `RecoveryState.color` (in
`Presentation/DesignSystem/`) is the only place a tier becomes a colour: the Recovery tab's gauge,
HRV card and trend chart, Home's recovery ring, and each day of the month calendar's grid all read
through it.

A tier is computed from the **score**, so it is defined only for a measured day: a placeholder row
(`score: 0`, `hrvValueMs: 0`) reports `.red`, and every drawing of it therefore gates on
`hasMeasurement` first, which is why an unmeasured day is `—` with no ring rather than a hard 0% red.

---

## 4. Sleep Staging & Sleep Need

### Sleep Staging (Actigraphy + HR Dips)

This is the model for **strap-only** nights. It reads the accelerometer and heart-rate channels, so
it is only as real as the R-R and accelerometer round-trip is — see the note below.

1. **Awake**: High accelerometer variance (> 0.25g RMS) and HR above baseline.
2. **Light Sleep**: Low movement, HR within $\pm 5\%$ of resting baseline.
3. **Deep / SWS Sleep**: Zero movement, HR lowest of night (> 10% below daytime baseline), minimal autonomic volatility.
4. **REM Sleep**: Minimal physical movement with bursty R-R interval fluctuations and moderate HR elevation.

HealthKit publishes stages directly from `sleepAnalysis` (AASM-derived), which is a measurement
rather than a heuristic and is strictly better where it exists. `HealthSleepStage` already defines
the mapping — `asleepCore` and `asleepUnspecified` → light, `asleepDeep` → deep, `asleepREM` → rem,
`awake` → awake, with the `inBed` envelope excluded from stage totals because it overlaps every
other stage. Nothing writes `sleeps` rows from it yet; the importer in §3's data path covers HRV and
resting heart rate only. Until it does, this actigraphy model is what produces sleep sessions, and
the two must not both claim the same night.

### Imported nights are WHOOP's totals, not this classifier's output

The data export carries stage *totals* — light, deep, REM, awake, asleep and in-bed minutes, plus a
respiratory rate — and one row per night. `WhoopExportImporter` writes them straight through, so an
imported `sleeps` row is a set of measured durations rather than the output of the classifier above.

Two consequences. `SleepSession.sleepStages` is **empty** for every imported night: the export has no
per-epoch timeline, so there is no hypnogram to draw, and `SleepDashboardView` renders "No stages
recorded." rather than a fabricated one. And `disturbanceCount` is `nil`, because the export reports
awake *minutes* — a different measurement — and labelling one as the other is precisely the
fabrication the actigraphy path was emptied of.

The sleep *performance* on such a row is still derived here, not copied: `SleepSession` computes
`asleep / need` itself, and the export's own `Sleep performance %` column is unused. On the imported
history the two disagree on 457 of 910 nights, so this is a visible choice rather than a formality —
and it is the one that keeps a single rule for the number across imported and strap nights alike.

### Nights with no measurement

Actigraphy needs epochs to average, so a night whose window holds fewer than one full 30-second epoch
($30$ samples) is **not classified at all**. `AnalyzeSleepUseCase.execute(for:)` returns `nil` and
writes nothing.

There is no placeholder row here, unlike Recovery: `sleeps` has no reserved marker to write, and a
session invented from literals would be indistinguishable from a measured night in every column.
That is what the removed behaviour did — it assembled an eight-hour night ($4.2$ h light, $1.8$ h
deep, $1.6$ h rem, $0.4$ h awake) and saved it whenever the window was too sparse, so a strap left on
the charger was recorded as a full night's sleep and then scored as one.

Absence is therefore carried by the *absence of a row*: `SleepRepository.getSleepSession(for:)` and
`getSleepHistory(days:)` return `nil` / `[]`, and the callers that read them already accept an
optional. `SleepDashboardView` and the Home ring render it as `—`. Recovery is unaffected — a day
with no sleep session contributes the sleep pivot above, which is a defined value, not a guess.

### Sleep Need Calculation
$$\text{Sleep Need} = \text{Baseline Need} + \text{Previous Day's Strain} \times 6.40 \text{ minutes}$$

Implemented in `Core/Math/SleepNeedMath.swift`, and applied to **strap nights only** — see the last
subsection below. The baseline is `UserProfile.targetSleepHours`, which defaults to 8.0 h.

The *shape* is WHOOP's. Its developer API publishes `sleep_needed` as an additive breakdown —
`baseline_milli` + `need_from_sleep_debt_milli` + `need_from_recent_strain_milli` −
`need_from_recent_nap_milli` — so a personal baseline plus a positive strain term is their published
structure rather than an invention of this app's. What WHOOP does not publish is any of the
constants.

**So the constant is fitted, not cited.** Least squares of WHOOP's own `Sleep need (min)` on its own
`Day Strain`, taken from the *previous* day, over the 909 nights of the bundled export that carry a
preceding strain day, with the intercept pinned to the 8-hour baseline, gives **6.40 minutes of
additional need per strain point**. Leaving the intercept free puts it at 478 minutes — within two
minutes of the profile's 8 hours — which is why pinning it costs nothing.

Scored by 5-fold cross-validation — the model fitted on four fifths of the series and its error
measured on the held-out fifth, five times over — against the sleep performance WHOOP's *own* need
implies (`asleep / their need`), so the figure isolates error in the need rather than in the
four-component performance composite this app does not reproduce:

| model | mean sleep-performance error |
|---|---|
| flat 480 min, no strain term | 10.06 |
| $480 + 4.5 \times \text{strain}$ | 4.64 |
| $480 + 6.40 \times \text{strain}$ — **implemented** | **3.77** |
| refitting the coefficient on each fold's own four fifths | 3.87 |
| … plus a fitted 7-night deficit term | 3.41 |
| the previous version of this section, written out | 18.44 |

The curve is flat between 6.4 and 7.0 (3.77, 3.76, 3.78), so the fitted value is shipped rather than
the marginally luckier one — a constant reproducible from the export in one line is worth more than
0.01 of a point.

Three inputs WHOOP names that this model deliberately does **not** use:

- **Accumulated Sleep Debt.** A fitted 7-night deficit term does help — 3.77 → 3.41 — and WHOOP's own
  `Sleep debt (min)` column, lagged a night so it cannot contain the night being predicted, does no
  better (3.43), so a reconstruction of the debt series has no hidden headroom to find. It is left
  out as a judgement rather than a measurement: 0.35 of a point on a 0–100 scale, for a second fitted
  constant and seven nights of history to read. The strain coefficient absorbs what the debt term
  would carry — it falls from 6.40 to about 2.9 when the term is present — so the two are
  near-substitutes, not independent inputs. WHOOP's patent confirms a capped carryover term exists
  and publishes neither its size nor its window; its own column here ranges 0–127 minutes (mean 79),
  far below any simple sum of nightly shortfalls.
- **Naps.** WHOOP's API shows naps *subtract* from need. The export's `Nap` column lives only in
  `sleeps.csv`, which is not bundled, and all 8 nap records collide with a night on the same day key
  that `sleeps` is primary-keyed on — so they need a table of their own, not a column. Deferred.
- **Sleep Stress.** WHOOP's fourth component, quantified in prose only. It is not a column in any of
  the four export CSVs and not a field in the WHOOP API, so it is unobtainable from this data.

### Why the formula above is not the one this document used to state

This section previously specified $\text{Baseline} (8.0\text{ h}) + \text{Strain Debt} +
\text{Sleep Debt Carryover} \times 0.20$ with $\text{Strain Debt} = \text{Daily Strain} \times 4.5$.
**Nothing implemented it, and it should not have been implemented.** Written out as specified, with a
7-night deficit as the carryover, it scores **18.44** — nearly twice the flat 480 min it would have
replaced — because a 7-night deficit averages about 1000 minutes, so a fifth of it swamps the
baseline instead of adjusting it. (The `4.5` alone, without the carryover, is a reasonable but
under-fitted coefficient: it scores 4.64 where the fitted 6.40 scores 3.77.)

The **lag**, by contrast, was right and is the part worth keeping from that formulation: across those
909 nights the previous day's strain fits need at $R^2 = 0.366$ against the same day's $0.161$, and
WHOOP's own wording names the previous day. The app reads the previous day's row for exactly this
reason — `strains` is keyed on `startOfDay(wakeOnset)`, so the cycle that preceded the night ending
on morning D is keyed D.

### What the coefficient is, and is not

It is **effective**, not WHOOP's own $f(\text{strain})$. It is fitted against a *fixed* baseline, so
it also absorbs whatever drift in WHOOP's learned baseline correlates with strain, and WHOOP's own
API example shows its strain term contributing single-digit minutes where 6.40 implies far more. It
is a calibration that reproduces WHOOP's need — which is the goal — not a recovery of their function.

The model consequently under-disperses: predicted need spans 491–613 min against WHOOP's actual
321–650 ($\sigma$ 26.0 against 42.5), so it captures roughly 60% of the variation. The remainder is
the components not modelled above.

Two rules the code enforces, and they are this document's no-fabrication rule applied to an *input*
rather than an output:

- **No strain row means the baseline, exactly.** An absent row says yesterday is unmeasured; a
  substituted strain would turn "we do not know how hard yesterday was" into a real change in
  tonight's target.
- **The strain input is clamped to $0 \ldots 21$, not the output.** Strain is *defined* on that
  scale, so a value outside it is a corrupt row rather than a hard day. At the maximum the term is
  worth 134 minutes, which keeps the need inside the band WHOOP's own figures occupy.

### An imported night's need is WHOOP's number, not the formula above

An imported night's `targetSleepNeedSeconds` is **not** this formula's output either — it is the
export's own `Sleep need (min)` column, in minutes, converted to seconds. WHOOP computed it from the
same inputs but its own coefficients, and recomputing a need for a 2023 night would require that
night's strain debt and carryover, which the export does not carry row-by-row. The need is stored as
measured so the performance figure above derives from a real denominator.

That is also why the need is a *stored* field rather than a computed one: two models would otherwise
meet on one chart. The test suite asserts it directly — every imported night carries a whole number
of minutes, and 53 of the 910 needed *less* than the 8-hour baseline, which the formula above cannot
produce because its floor is the baseline.

---

## 5. Stress Monitor (0.0 – 3.0 Scale)

WHOOP's Stress Monitor estimates **daytime physiological activation** from heart rate variability,
heart rate and motion, and reports it on a 0–3 scale:

| Band | Range | WHOOP's description |
| :--- | :--- | :--- |
| **Low** | 0 – 1 | calm, relaxed |
| **Medium** | 1 – 2 | alert, focused |
| **High** | 2 – 3 | highly activated, stressed |

High stress is what invites the guided breathwork protocols (the physiological sigh, developed with
Dr. Andrew Huberman). Implemented in `Core/Math/StressMath.swift` and driven by
`Domain/UseCases/AnalyzeStressUseCase.swift`.

### This is a calibration, not a recovery of WHOOP's function

WHOOP publishes this model's **shape** and none of its constants. The published shape is: the three
inputs above; a comparison against a personal baseline drawn from the previous **14 days**; that
comparison being what separates physical exertion from mental or emotional stress; and the 0–3 output
with its three bands. Nothing else is published — not the window length, not the weights, not the
exact band edges.

Every constant below is therefore **this app's own**, chosen to reproduce the behaviour that is
described. **This app's number will not agree with the WHOOP app's.** That is the same bargain §4
records for `SleepNeedMath`, and it is stated in `StressMath`'s own doc comment so the caveat travels
with the code rather than living only here.

### Eligibility: motion is the discriminator

Samples are bucketed into consecutive **300-second windows**, anchored on the first sample's
timestamp rather than on the clock. A window is scored only if:

1. it holds at least **20 R-R intervals**, and
2. the mean accelerometer magnitude over it is **≤ 1.25 G**, and
3. at least one of its samples carries a heart rate above zero.

The second gate is the whole distinction between this model and §2's Strain model. A raised heart
rate with the arm moving is work; a raised heart rate with the arm still is activation. Gravity is
inside the accelerometer magnitude, so a motionless strap reads ~1.0 G rather than 0 — which is why
the line sits just above 1 instead of near zero, and it is the same line `AnalyzeSleepUseCase` already
draws between an awake and a sleeping epoch, reused rather than re-derived.

The first gate is load-bearing rather than tidy. `HeartRateVariabilityMath.calculateRMSSD` returns
**0.0** when it has fewer than two usable intervals, and a zero RMSSD is not "no reading" — it
describes a perfectly metronomic heart, which this model scores as **maximum stress**. A window
without enough beats must never reach the scorer, and `StressMath.minimumRRIntervals` is the only
thing standing between a missing measurement and a fabricated worst case.

### Activation and score

Each eligible window contributes two z-scores against the personal baseline. HRV is **negated**,
because it falls under stress; heart rate is taken as-is, because it rises:

$$a = \frac{-\left(\dfrac{\text{RMSSD} - \overline{\text{RMSSD}}}{\sigma_{\text{RMSSD}}}\right) + \left(\dfrac{\text{HR} - \overline{\text{HR}}}{\sigma_{\text{HR}}}\right)}{2}$$

$$\text{score} = \text{clamp}(1.0 + a,\ 0,\ 3)$$

Negating HRV is what makes the average of the two terms meaningful rather than a cancellation: both
now point the same way, and up means *more activated*.

The `1.0` offset is what gives the scale its meaning. It puts sitting at your own baseline **exactly
on the low/medium edge**, one standard deviation above it on medium/high, and anything below it in
the low band. Both terms are clamped to ±4σ by `BaselineStatisticsMath.zScore`, so the outer clamp at
3.0 is a defence rather than an everyday occurrence.

`StressScore.averageScore` is the mean across the day's eligible windows and is what the band derives
from. `peakScore` is the day's highest-scoring window and is kept separately, because the product
behaviour WHOOP describes keys off the high-stress *moment*, not the day's average — the two answer
different questions and neither is derived from the other.

### Constants

| Constant | Value | Site |
| :--- | :--- | :--- |
| Baseline window | 14 days | `StressMath.baselineDays` |
| Minimum baseline days | 3 | `StressMath.minimumBaselineDays` |
| Scored window length | 300 s | `StressMath.windowSeconds` |
| Minimum R-R intervals per window | 20 | `StressMath.minimumRRIntervals` |
| Motion ceiling | 1.25 G | `StressMath.motionCeiling` |
| Score at zero activation | 1.0 | `StressMath.activationOffset` |
| Scale ceiling | 3.0 | `StressMath.maximumScore` |
| Waking window | 06:00 – 22:00 local | `StressMath.wakingWindowStartHour` / `.wakingWindowEndHour` |
| Band edges | 1.0, 2.0 | `StressMath.lowMediumBandEdge` / `.mediumHighBandEdge` (named so the chart's colour gradient is stopped on the same two numbers `band(forScore:)` branches at) |

Two of these are conventions rather than measurements, and are marked as such in the code. The **14
days** is WHOOP's own published figure, but it is deliberately *not* `RecoveryScoring`'s 30 — these
are separate models with separate baselines, and a shared constant would invite one to be tuned for
the other's reasons. The **waking window** is a product decision: the Stress Monitor is a daytime
metric, and scoring the whole day would fold sleep in — where HRV is high and heart rate low,
correctly scoring as calm — and drag the day's average down with it. A night-shift wearer gets a
window that does not match their day.

### The baseline is built from days, not windows

`AnalyzeStressUseCase` reads one range — the waking hours of the preceding 14 days — and reduces
**each baseline day to a single point** (the mean of its eligible windows) before building the
baseline. Weighting by windows instead would let one heavily-worn day outvote a fortnight.

The day being scored is never part of the baseline it is scored against: the baseline range ends
where that day's waking window begins.

### Days with no measurement have no score

`AnalyzeStressUseCase.executeDay(for:)` returns `StressDay?`, and returns `nil` — computing nothing —
in three situations it cannot tell apart from the data it holds:

- the day has no samples at all (the common case on an imported day, and always on a strap-less
  install — see the coverage note below);
- its samples contain no still window with enough beats;
- fewer than 3 days of history exist to build a baseline from.

Each is "no measurement", not a low score, so all three report the same way. `StressScore` has no
zero that could be mistaken for one: a `0.0` would read as *perfectly calm*, which is a claim, and
the absence of a measurement is not one. The Home tile renders `—`.

Three is the floor because it is the smallest number a sample standard deviation exists for, and
because this model is defined **relative to a personal baseline** — a score against a default would
be a different quantity wearing this one's name. It sits below the 14-day window on purpose: the
window is what the baseline is drawn *from*, and demanding fourteen consecutive days of strap data
before showing anything would leave the tile blank for a fortnight.

`execute(for:) -> StressScore?` is a **forwarder** to `executeDay(for:)`, not a second implementation:
it returns `executeDay(for:)?.score`. That is what keeps the aggregate's `nil` semantics identical to
the series' by construction, and what stops the two entry points from ever disagreeing about whether
a day has anything on it. One call reads the samples once and builds one baseline.

### The day's series, and the chart that draws it

The model's product surface is a *line*, so the day is returned as a pair: `StressDay` holds the
day's `StressScore` and the `[StressWindow]` behind it — each window carrying its `start` (the bucket's
anchor) and its score.

The aggregate is **computed inside `StressDay.init(date:windows:)`** rather than passed in beside the
series. That makes `windows.count == score.windowCount` structural instead of a convention: there is no
parameter a caller could put a foreign day's score into. A tile showing 1.4 above a chart of a
different day's windows would be one number describing one measurement and a line describing another,
with nothing on screen to say so.

Bucket anchors are the day's **first in-window sample** plus whole `windowSeconds` steps, so a day
whose samples begin at 09:03 has windows at :03, :08, :13. The plotted x is that anchor unrounded —
rounding to the hour would move a measurement to a time nobody took it.

`Presentation/Screens/Home/StressMonitorChartView.swift` draws it, under four rules:

- **A full-day x-axis, with the unscored hours shaded.** The model only scores 06:00–22:00, so on a
  24-hour axis the two ends are empty on *every* day, a fully-worn one included. Empty reads as
  *calm*, which is the opposite of the truth, so 00:00–06:00 and 22:00–24:00 are drawn in a faint
  `Theme.ringTrack`. This is the one addition beyond WHOOP's own rendering.
- **A fixed 0–3 y-axis, never auto-scaled.** Scaling to the data would draw a calm day and a wired day
  as the same picture, which is the one thing the chart exists to distinguish. The fill's gradient
  stops are the band edges divided by the scale, so it changes colour at exactly the score where
  `band(forScore:)` changes band. The fill is a `Shape`, not a `Path` built in the view: `path(in:)`
  receives the frame, so the stops land on the scale — a `Path` in a `ZStack` would be graded over its
  own bounding box and the bands would move with the data.
- **Gaps are breaks, not interpolations.** A run ends when the next window starts more than
  `windowSeconds × 1.5` later. An ineligible window is *unmeasured*; joining across it would draw a
  reading nobody took. A run of one window is drawn as a dot, because a polyline through one point
  draws nothing and the value was still measured.
- **No windows ⇒ no chart at all.** Not an empty frame, not a zero line. A flat line at zero is the
  strongest possible claim of calm, and it is the one thing this model must never say about a day it
  did not measure. Since `executeDay` returns `nil` rather than an empty `StressDay`, "no series" and
  "no score" are the same condition, and the tile's caption carries the absence in words.

### What this model cannot do

**A still-armed activity reads as stress.** The motion gate is the only exertion filter, so cycling,
a rowing machine, or carrying something heavy with the arm still produces a raised heart rate that is
not distinguishable from activation using only HRV, heart rate and motion. This is a limitation of
the published input set, not of this implementation.

### Coverage: this tile is a dash more often than not

Samples are persisted only while the app is open with the strap connected (`StreamBiometricsUseCase`'s
batching write), plus whatever `requestHistoricalSync` backfills. The export carries **no R-R series
at all**, so every imported day has none.

In practice this means: on a strap-less install the tile renders `—` always; on a strap worn
inconsistently it renders `—` on most past days; and it only produces a number for a day the app was
running through. That is a data-coverage fact and not a bug, but it is a product fact worth knowing
before reading anything into an empty tile.

### Why this is derived on read and not stored

`StressDay` — the score and the series alike — is a function of `biometric_samples` and nothing else.
Persisting it would create a second copy that can disagree with the samples it came from, and would
need invalidating every time a sample was backfilled. Nothing is written, which also makes this the
one Analyze use case that is safe to point at any date — the calculate use cases overwrite whatever a
day already holds.

---

## 6. VO₂ Max (mL/(kg·min)) — the one estimate this app computes

Home has a VO₂ MAX panel, so "where does that number come from" has to have an answer. Until this
change the answer was "nowhere in this app": the panel read a HealthKit sample through and was `—`
otherwise, so it was empty on **every one of the export's 910 days** and on every day no other app had
written Apple a reading. It now carries an estimate this app derives itself, and this section is the
record of that model, its constant, its error bar, and why it is labelled as an estimate.

WHOOP's own three-tier model is still **not** implemented, for the reasons at the end of this
section — those have not changed. What changed is that "read somebody else's number or print nothing"
is no longer the only pair of options available for a user with three years of imported history and no
Apple Watch.

### What the panel shows

An estimate computed **on read, per day, and stored nowhere** — `Vo2MaxMath.heartRateRatioEstimate`,
applied inside `MetricWeek.makeDay` to that slot's own already-gated resting heart rate and the
profile's maximal heart rate. It is derived rather than read, so:

- **There is no column and no table.** Like `StressDay`, it is a function of what is already stored,
  so a persisted copy could only ever be a second number that disagrees with its own inputs.
- **It is `nil` — never `0` — whenever it cannot be computed.** That is a day with no measured resting
  heart rate, or a week built with no `maxHeartRate` because no profile could be read. Both arrive at
  the model as `nil` and leave as `nil`; the panel draws `—`.
- **It is the one figure on Home whose label says `(EST.)`.** The other three panels print
  measurements. This one prints a model's output, and the whole of the next two subsections is why
  that distinction is worth a label.

Because the estimate reads the slot's resting heart rate and nothing else, it **cannot disagree with
the RHR panel drawn beside it** — one day, one rate, one pair of figures. That is
structural, not a convention: `makeDay` hoists the gated rate into one local and both fields read it.

The HealthKit read-through that used to back this panel is **gone** — `vo2MaxReadings(days:endingOn:)`
is removed from `HealthKitSyncing`, and `HealthKitQuantityMetric.vo2Max` with it, which also drops
`HKQuantityTypeIdentifierVO2Max` from the consent prompt's `readTypes`. This app no longer asks for
permission to read a quantity it does not use.

### The model: the Heart Rate Ratio Method

    VO₂max (mL·kg⁻¹·min⁻¹) = 15.3 × HRmax / HRrest

Uth, Sørensen, Overgaard & Pedersen (2004), *Estimation of V̇O₂max from the ratio between HRmax and
HRrest — the Heart Rate Ratio Method*, Eur J Appl Physiol 91(1):111–115,
[doi:10.1007/s00421-003-0988-y](https://doi.org/10.1007/s00421-003-0988-y) (erratum: 93:508–509).

The coefficient is **not fitted to anything this app can see**, which is the property that makes it
worth shipping. The paper derives it from the Fick equation as the product of the maximal-to-rest
ratios of stroke volume (≈1.3) and of the arterio-venous O₂ difference (≈3.4) — 1.3 × 3.4 × 3.4 ≈ 15 —
and then measures it in a subgroup of 10 of its 46 subjects as **15.26 (0.72)**, which is where `15.3`
comes from. Nothing in this repo was tuned to make the number come out a particular way.

**The error bar is the part that matters, and it is not the study's headline figure.** The paper quotes
its standard error of estimate twice, and the two differ by roughly a factor of two:

| `HRmax` used | SEE | as % |
| :--- | :--- | :--- |
| a **measured** maximal heart rate | 2.7 mL·kg⁻¹·min⁻¹ | ~4.5% |
| an **age-predicted** maximal heart rate | 4.7 mL·kg⁻¹·min⁻¹ | ~7.8% |

**This app is in the second row.** Nothing here performs a graded exercise test, so the anchor is
never a measured `HRmax` — it is a stored profile field. Anyone quoting the 4.5% figure for this
panel would be quoting the half of the paper that does not apply to it.

### The coefficient's two known limits, and why no newer equation replaces it

The 2004 paper is the current standard for this method rather than an ageing one — it is still cited
as the original plus its 2005 erratum, and no later study has re-validated the heart-rate ratio
directly. What does exist is a follow-up that qualifies the **constant**, and a body of newer methods
that this app cannot feed. Both are recorded here because both bound what the panel can claim.

**The coefficient is sex-specific and this app uses the male value for everyone.** Uth published a
second paper on the proportionality factor itself — *Gender difference in the proportionality factor
between the mass specific V̇O₂max and the ratio between HRmax and HRrest*, Int J Sports Med
2005;26(9):763–767, [doi:10.1055/s-2005-837443](https://doi.org/10.1055/s-2005-837443) — measuring
**PF = 14.5 mL·kg⁻¹·min⁻¹ in 27 trained women** against the 15.3 already established in men. The
difference disappears when **lean** body mass replaces body mass, which is the paper's own
explanation: the factor carries mass-specific resting oxygen uptake, and that differs by sex in a way
total mass does not. `UserProfile` has no sex field, so `heartRateRatioCoefficient` is a single
`15.3` and a female user's estimate is biased high by **15.3/14.5 ≈ 5.5%** — real, systematic, and
smaller than the 4.7 SEE, but a bias rather than scatter, so averaging does not remove it.

**The 4.7 is this method at its best, and the general population does worse.** The 2004 validation
was 46 well-trained men aged 21–51. Outside that group the ratio method's correlation with measured
V̇O₂max falls to roughly **r ≈ 0.50–0.70 with an SEE of 7–10 mL·kg⁻¹·min⁻¹** — two to four times the
error bar documented above, and comparable to the spread between individuals the panel is being read
as a ranking of. Nothing in this app's data says which of those two regimes a given user is in, so
the honest bar for a general user is the wider one, and the narrow 4.7 is quoted here as the model's
own figure rather than as a claim about this app's accuracy.

Neither limit is fixable with a newer equation, and that is the finding. The alternatives all need
inputs this app does not hold. The non-exercise equations — Polar OwnIndex, and the seismocardiography
and FRIEND/WASSERMAN regressions — each take **sex**, and several take a **self-rated activity level**
whose effect on the output is 5–10 mL·kg⁻¹·min⁻¹ on its own; the machine-learning approaches over
wearable data need **accelerometer-derived activity classification** and long-window HRV such as
**SDANN over 24 hours**, where this app has overnight RMSSD only. Replacing the equation would
therefore mean adding a profile field before it meant changing a formula. A `sex` field on
`UserProfile` is the prerequisite for the sex-specific factor *and* for any of those equations, and it
is a larger change than it looks — it is a persisted column, a migration, and an onboarding question —
so it is named here as the upgrade path rather than folded into this one.

### The anchor: why `HRmax` is never the day's observed peak

`HRmax` is `UserProfile.maxHeartRate` — the same field `CalculateStrainUseCase` builds its Karvonen
zones from, so this app has **one** definition of a maximal heart rate rather than one per model.

The obvious per-day alternative is the `Max HR (bpm)` that the strap or the export recorded for that
day, and it is rejected on a measurement rather than a preference. Over the bundled export's **909 days
carrying both a Max HR and a resting heart rate**, the per-day estimate spans **25.9 to 62.2
mL·kg⁻¹·min⁻¹** — a 2.4× spread, CV 12% — and correlates **+0.49 with that day's `Day Strain`**.

That correlation is the disqualifier. A day's peak heart rate records how hard the day was, not the
heart's ceiling, so an estimate anchored on it reports *effort* and calls it *fitness* — the panel
would read 62 on a hard training day and 42 on a rest day, which is not a thing VO₂ max does. The
section below already argues the panel must carry no day-to-day arrow because this quantity moves on a
scale of years; an anchor that swings it 2.4× with the day's training contradicts the quantity's own
definition. Anchoring on a stable `HRmax` leaves a day's estimate varying only with its resting heart
rate, which *is* the genuine fitness signal in this ratio.

Two further candidates were rejected for the same family of reasons. **The highest `Max HR` ever
observed** is 206 bpm on this export, and the ten days carrying the highest values all also carry
ordinary average heart rates (67–87 bpm against a dataset mean of 72.4) — the signature of an optical
artifact rather than a maximal effort. **The exported RHR spread** is real and is what the estimate
responds to, but it is a measurement, not an anchor, so it belongs in the denominator where it is.

### What the quantity is

VO₂ max is the maximum capacity to transport and utilise oxygen, and by the **Fick equation** it is
maximal cardiac output multiplied by the arterio-venous O₂ difference. That is the whole of the
definition this app relies on, and it is also why nothing a wearable measures *is* it: resting heart
rate, HRV, respiratory rate, sleep quality and time-in-zone are all **surrogates** for one of those
two factors, and none of them is either factor.

The reference measurement is **indirect calorimetry** during a graded exercise test — breath-by-breath
gas exchange, with maximality confirmed rather than assumed (a plateau in oxygen uptake, or two of:
heart rate above 90% of age-predicted maximum, RPE ≥ 18/20, RER ≥ 1.15). A number produced without a
mask and a maximal effort is an estimate of that quantity, whatever its precision suggests.

### WHOOP's model, and why none of it is implemented here

WHOOP states that its VO₂ max is a **proprietary three-tier algorithm**, validated against 248
laboratory tests using indirect calorimetry, updating **weekly** rather than per day. The three tiers
are:

| Tier | Inputs |
| :--- | :--- |
| **Passive** (default) | 24/7 resting heart rate, HRV, respiratory rate, sleep quality, time in specific heart-rate zones — plus age, biological sex, height and weight |
| **GPS-augmented** | The passive model plus pace and heart rate from outdoor runs tracked by phone |
| **Ground-truth calibrated** | Anchored to a known lab-measured value |

WHOOP states that **≥ 14 recoveries within the previous 21 days** are required before the passive
estimate unlocks, and quotes a mean absolute error of **3.3–3.7 mL/(kg·min)** and a mean absolute
percentage error under **8%**.

This app implements none of the three tiers, and the reasons are the ones §5 already gives for the
Stress Monitor, sharpened. WHOOP publishes the model's **input set and none of its constants** — so a
substitute would be this app's own fitted guess wearing WHOOP's name. Every input the passive tier
names is a quantity this app *does* hold for a strap day, which makes the temptation concrete and the
answer no clearer: fitting a VO₂ max to them would put a **fourth** estimate of one quantity on a
single screen (the lab's, WHOOP's, Apple's, and this app's) with nothing on any of them to say which
was which. And unlike Sleep Need — where a fitted coefficient was defensible because the fit could be
scored against 909 nights of WHOOP's own output (§4) — there is **no ground truth to fit against
here**: the export carries no VO₂ max column at all, so a fitted model could not be validated on the
only dataset this project has.

The choice this app makes is therefore **not** a substitute for WHOOP's model and must not be read as
one. It does not attempt WHOOP's input set, it is not fitted to anything, and it would not agree with
WHOOP's figure if both were shown side by side. It is a published, cited, independently-derived
estimate that this app can compute from two numbers it already stores, labelled on screen as an
estimate — which is a different thing from a reconstruction wearing WHOOP's name. The read-through to
Apple's number is gone rather than kept alongside it, because a panel holding two different estimates
on different days with nothing to say which was which is the outcome the paragraph above rejects.

### Why the panel prints whole numbers and no direction

Two properties of the quantity, neither of them a drawing choice.

**It moves on a scale of years.** VO₂ max declines by roughly **10% per decade** after age 25 — about
15% between 50 and 75 — and the per-year decline quoted for the study behind this section is
**0.35–0.62 mL/(kg·min) per year** depending on training status. A day's reading against a 7-day mean
is comparing two points inside that noise, so an arrow on it would be reporting measurement scatter as
a physiological movement.

**Its mode of measurement moves it further than a year of ageing does.** In the same study, rowing
VO₂ max exceeded cycling VO₂ max by **10%** in older subjects and **16.7%** in younger ones — a single
change of exercise modality is several times the annual decline. A reading is therefore partly a
reading of *how* the oxygen was consumed, which is a second reason not to colour it as a verdict.

**So the panel deliberately has no change marker**, unlike the three beside it, and prints whole
numbers: the estimate's own error is quoted in whole mL/(kg·min) — this app's 4.7 from Uth, WHOOP's
3.3–3.7 — so a decimal place would claim a precision below the error bar. The `(EST.)` label and the
absent arrow are the same decision reached from two directions: the first says the number is a model's
output, the second declines to read a trend into it.

### What this section is not evidence for

The physiological figures here — the maximal-test criteria, the decadal and per-year decline, and the
cycling-versus-rowing difference — come from a single study of 11 older and 11 younger rowers
([PMC4968829](https://pmc.ncbi.nlm.nih.gov/articles/PMC4968829/)). It is not a normative reference:
it contains **no** age- or sex-stratified classification table and **no** error statistics for
estimated (as opposed to measured) VO₂ max, so nothing above should be read as either. WHOOP's figures
are WHOOP's own published claims, quoted and not independently verified. This app takes no position
on whether WHOOP's estimate is accurate — only on the fact that it is WHOOP's and not this app's.

Two limits on the model this app *does* now ship, stated here so they are not discovered later:

- **The validation population is not this app's users.** Uth et al. tested 46 **well-trained men aged
  21–51**, and the paper itself says applicability to other groups requires direct validation. That
  validation has not been done here, and this app has no ground truth to do it with — the export
  carries no VO₂ max column, which is the same absence that rules out fitting WHOOP's model.
- **`UserProfile.maxHeartRate` is not a calibrated value.** `GRDBUserProfileRepository` answers
  `190` when no profile row exists, and `UserProfile`'s own default is `195`; neither is derived from
  the user. So for anyone who has not edited their profile, the numerator is a constant this app wrote
  down, and the estimate inherits that. The honest reading is that this panel is an estimate of an
  estimate, which is the second reason it is labelled rather than presented as a measurement. Making
  that field a real calibrated input — a measured `HRmax`, or `UserProfile.estimatedMaxHeartRate(age:)`
  (Gellish), which exists and currently has no callers — is a separate change: it would move every
  Karvonen zone boundary and therefore every strain score, so it needs its own measurement and its own
  guard rather than being folded in here.