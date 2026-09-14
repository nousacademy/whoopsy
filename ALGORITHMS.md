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

There is **no respiratory-rate term**, and since the strap path gained a respiratory estimator the
reason has changed rather than the decision. It used to be that no *measured* input existed: the
strap has no respiratory *sensor*, `SleepSession.respiratoryRate` was `nil` for every night the strap
classified, and earlier builds filled the gap with constants (`14.4` written by
`AnalyzeSleepUseCase`, `14.0` handed out by `GRDBSleepRepository`) — precisely the input a
$z_{\text{Resp}}$ baseline would have been built on, a number with no variance collapsing to the
degenerate-input floor. That is no longer true: `RespiratoryRateMath` derives a rate from the R-R
series on the strap path (see **Respiratory Rate (RSA)** in §4). The reason the term stays out is now
**scope, not absence**: the great majority of days in this app's database are imported nights carrying
WHOOP's own stored rate, so introducing the term would re-score all 910 of them through a model none
of them was scored by, changing every historical Recovery figure on the strength of an estimator this
document describes as unvalidatable. A measured input existing on one path is not a reason to move
every number on another.

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
optional and only now produced on both paths, so a window can hold thirty days and no rate at all),
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
`asleep / need` itself, and the export's own `Sleep performance %` column is unused. What that costs
is not one number, because **the export's column changes meaning partway through the file.**

The export carries a **137-day recording gap, 2024-12-31 → 2025-05-17**, and WHOOP's score either
side of it is a different function. Before the gap the column **is** `round(asleep / need × 100)`:
423 of 451 nights match exactly, the other 28 are off by one from rounding, MAE **0.062**, worst case
**1** — and a least-squares fit over that era's own rows returns `asleep/need` with a coefficient of
**+100.04**, an intercept of 1.7, and every other candidate feature at zero. That is the app's
expression, recovered from the data rather than assumed — and it is not a coincidence, because
WHOOP's own API specification still defines `sleep_performance_percentage` as *"a percentage (0-100%)
of the time a user is asleep over the amount of sleep the user needed."* After the gap the same
expression matches **33 of 459** nights, at MAE **7.05** and a worst case of **51**: the column is no
longer a ratio, though the published definition was never updated to say so.

So the whole-file figure — 454 disagreements in 910 nights — is 28 plus 426, and quoting it alone
says the app's formula is a poor approximation of WHOOP's when over the older half **it is WHOOP's**.
The honest statement is era-dependent: identical before 2025, a different quantity on the 459 nights
since. The same gap and the same boundary already appear in `SleepConsistencyMath`'s fit, where the
pre-gap scores are scattered relative to their own timestamps and the post-gap ones are not — one
event with two symptoms.

After the gap the column is a **composite**, and WHOOP names its four components while publishing no
weights: *"Quality of sleep based on efficiency, sufficiency, sleep stress, and consistency."* Two of
those this page already derives, the third is `SleepConsistencyMath`, and the fourth is sleep stress,
for which this app has no producer at all. **That missing term is what the
residual is.** A least-squares fit on the three visible components, trained on the earlier 70% of the
era and tested forward, reaches MAE **3.61** and R² **0.796** against the expression's 12.75 on the
same split, and its failures are not noise: on **38 of the 455** post-gap nights carrying all three,
WHOOP's score sits below *every one* of them, which no weighted average of those three can produce —
and the residual tracks exactly the inputs sleep stress is built from (resting heart rate r = −0.415,
HRV +0.346, recovery score +0.374) while lying flat against skin temperature (+0.000) and day strain
(+0.003). The pinned 2026-08-19 night is the shape of it: 4th-percentile HRV, 97th-percentile
resting heart rate, 5th-percentile recovery, and a score 20 points under its own ratio.

So the gap is a **missing input, not a recoverable non-linearity** — and it is not one this app can
supply, because neither the export nor the `SleepScore` object in WHOOP's published API carries a
sleep-stress field at all. Do not fit a substitute for it and ship that as WHOOP's formula; the fit
above predicts the number without explaining it, and its intercept of −32 is the signature of a
linearisation rather than a set of weights anyone wrote down.

One property of the app's expression is load-bearing at both eras. The `min(100, …)` clamp matters
because fifteen nights on this export carry more stage time than need at all — the worst is
2024-12-10 at `940 / 415` minutes. Dropping it moves the whole-file disagreement count from 454 to
**457**, and the three nights in between are 2026-07-22 (`485 / 463`), 2026-02-21 (`490 / 476`) and
2024-12-10, which WHOOP scores exactly `100` and an unclamped ratio rounds to `105`, `103` and `227`.
Re-measure through `SleepSession.sleepPerformancePercentage` when this changes, not by re-deriving the
ratio — the clamp is part of the answer, and the era decides what the answer is being compared to.

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
- **Naps.** WHOOP's API shows naps *subtract* from need — `need_from_recent_nap_milli` carries a
  minus sign — and the export's eight nap records are the one thing `sleeps.csv` holds that the
  bundled cycle file does not. They are now **stored** (`naps`, `v11`; see `ARCHITECTURE.md` §2.B),
  so the term is measurable rather than merely unobtainable, and measuring it changed the verdict's
  reason without changing the verdict.

  **The term is real.** Looked up at the night that *follows* each nap — the night a nap should
  shorten — the shipped model's residual runs 24 to 228 minutes *below* prediction, and it tracks
  nap length: over the **7 naps with a following scorable night** the fit is
  $-1.035$ min of need per min of nap with $R^2 = 0.881$. On the whole file, refitting with the term
  free gives $-0.434 \pm 0.076$ min/min, $t = -5.74$. An earlier reading of this column as
  *unrelated* to need came from looking the nap up on its own day rather than at the night it
  precedes, which is the arithmetic this paragraph exists to correct.

  **And the term still is not shipped, for a reason that is now measured rather than assumed.** The
  coefficient is fit on **14 nights out of 882** — eight naps, each reaching at most two following
  nights — and it is significant in sample while being *harmful* out of it: under 5-fold
  cross-validation on those 882 nights, scored as the sleep-performance error WHOOP's own need
  implies, the formula with the term scores **3.634** against **3.588** without it. A second free
  constant that improves the fit it was fitted to and worsens the fit it was not is the signature of
  a term carried by fourteen points, and the shortest nap in the file (33 minutes) shows no
  reduction at all while the longest (237) shows 228. So the coefficient stays out of
  `SleepNeedMath`, and the reason is sample size rather than absence of signal — which is a
  different claim from the one this section used to make, and the one a future export with more naps
  should be re-measured against.
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

### Sleep Consistency

Sleep Consistency scores how closely a night's **timing** matches the nights before it, on a 0–100%
scale, independently of how long the night was. Implemented in
`Core/Math/SleepConsistencyMath.swift`.

WHOOP's developer documentation describes the mechanism as timepoint concordance — "the percentage
of time you are in the same state (asleep vs. awake) at specific clock times across consecutive
nights" — with comparisons further apart weighted less. That description is right about the
mechanism and wrong about the window by one night, and both halves of that were measured rather than
assumed.

**The described mechanism is a boundary-shift model.** For two nights reduced to an onset and a
wake, the fraction of the day spent in the same state is exactly $1 - (|\Delta\text{onset}| +
|\Delta\text{wake}|)/1440$. The concordance description and a boundary-shift model are therefore the
same quantity written two ways; the shift form is used here because it is what the exported column
actually tracks.

$$\begin{aligned}
\Delta\text{onset}_j,\ \Delta\text{wake}_j &= \text{circular minute distance (mod 1440, } \min(d,\ 1440-d)\text{)} \\
&\quad \text{between tonight and the night } j \text{ records earlier} \\[4pt]
P &= \frac{4|\Delta\text{onset}_1| + 3|\Delta\text{onset}_2| + 2|\Delta\text{onset}_3| + 1|\Delta\text{onset}_4|
+ 4|\Delta\text{wake}_1| + 3|\Delta\text{wake}_2| + 2|\Delta\text{wake}_3| + 1|\Delta\text{wake}_4|}{10} \\[4pt]
C &= \operatorname{clip}\left(\operatorname{round}\left(107.4883 - 1.81848 \cdot P^{\,0.60}\right),\ 0,\ 100\right)
\end{aligned}$$

**The window is four prior nights, not the three the description names.** Free per-lag coefficients
on the twelve boundary features are significant at lags 1–4 and collapse at lag 5 ($t = +0.44$), and
refitting the whole model at each window size peaks sharply at four:

| Prior nights | 1 | 2 | 3 | **4** | 5 | 6 |
| :--- | --- | --- | --- | --- | --- | --- |
| MAE | 5.317 | 3.935 | 3.119 | **2.749** | 2.935 | 3.247 |

Below four priors there is **no partial rendering**: `consistency(for:history:)` returns `nil`. At
one prior the model's MAE is 6.547, which is worse than saying nothing, and the row renders `—` —
the same gate `SleepNeedMath` and `BaselineStatisticsMath` apply to insufficient history.

**The link is concave, and that was the finding that mattered.** The score is not linear in the mean
boundary shift: $P^{0.60}$ fits and a linear link does not. Fitted linearly the model reports a
spurious 1.8:1 onset-to-wake asymmetry; that asymmetry vanishes once the exponent is right, which is
how the concavity was identified rather than chosen.

**Recency weighting is real but gentle.** 4:3:2:1 sits inside the noise of the fitted exponential,
and a flat 1:1:1:1 is measurably worse. It is kept because it is the direction the documentation
describes and it costs nothing in accuracy.

Agreement against WHOOP's own `Sleep consistency %` on the export's 891 scorable nights, in sample:
**MAE 2.749, median error 1.379, R² 0.728, 79.0% within ±3 points, 86.6% within ±5.** A forward time
split — fitted on 2023-07 → 2025-11, tested on 2025-11 → 2026-08 — is *better*, not worse: **MAE
1.978, 88.8% within ±3.** The constants were re-derived independently of the ones first written
down and land in the same place (MAE 2.732, R² 0.726, 81.6% within ±3), so they are a fit rather
than a transcription.

**The error is period-dependent, and that ships as a caveat rather than being hidden.** Every
60-night window ending on or after 2025-05-23 sits at MAE 1.23–2.13 (455 nights, **MAE 1.190,
R² 0.927, 91.0% within ±3**); every window ending before 2024-12-08 sits at 2.25–5.42 (436 nights,
MAE 4.238). The discontinuity coincides exactly with a 137-day recording gap, and the lag structure
is *identical* on both sides of it — so this is not an algorithm change. The 2023–24 exports carry a
consistency score that is scattered relative to the timestamps in the same file, and no model
applied to those timestamps can fix that.

Three implementation properties are load-bearing, each of which the data demonstrates:

- **Records, not calendar days.** The window is the four most recent *rows* for that night, whatever
  their dates. Deriving it by subtracting days from the onset is what the export's 137-day gap
  breaks: the span to the fourth prior exceeds five calendar days on 17 of 891 nights and reaches
  140. The caller narrows the read to `SleepConsistencyMath.historyLookbackDays` (12) and the model
  then truncates to four records; the eight nights whose fourth predecessor is 13–148 days back
  render `—`, which is the honest answer for a night scored across a recording gap.
- **Night-clock minutes, noon-pivoted.** All arithmetic is on $(\text{minutesOfDay} - 720) \bmod
  1440$ with circular distance. **297 of the 910 nights have an onset before midnight**, and a naive
  minute-of-day difference breaks across midnight for 613 of them — worst exactly where a schedule
  is most regular. The pivot is also why the model never has to decide which day an onset "belongs"
  to: `SleepConsistencyMath.Night` carries a `day` for ordering and two `Date`s of which only the
  clock time is read.
- **Ordering is the model's, not the caller's.** `consistency(for:history:)` filters to nights
  strictly before the one being scored and sorts newest-first itself, so the repositories'
  oldest-first order and the importer's file order both work. The strict-before filter is what keeps
  a forward-dated row — a time-zone artefact, a clock change — from being taken as the nearest prior
  and given the heaviest weight.

**A strap night is computed; an imported night is WHOOP's.** Like the need above, the export's
`Sleep consistency %` column is stored verbatim for imported rows, and `SleepViewModel` reads the
stored value first and falls through to this formula only when it is absent. `sleeps.sleep_consistency`
is nullable for exactly that reason: NULL means "not scored" and `0` means "scored as badly as the
scale allows", and both are reachable. The test suite's guard is disagreement — the model reproduces
WHOOP's figure closely but not exactly, so a column that had been recomputed rather than read would
agree on *every* night, and the suite asserts that a large number of nights disagree by more than the
model's own error bar.

### Sleep bands, and the rows that take no band

The Sleep detail screen draws **up to four rows, and they are two kinds of thing**: three banded
readings, and one unbanded one that is absent more often than it is present.

| Row | Source | Rendered |
| :--- | :--- | :--- |
| Hours vs. Needed | `SleepSession.sleepPerformancePercentage` | banded |
| Sleep Consistency | `sleeps.sleep_consistency`, else `SleepConsistencyMath` | banded |
| Sleep Efficiency | `SleepSession.sleepEfficiencyPercentage` | banded |
| Nap | `naps`, when the day holds one | plain, and the row is **absent** when it does not |

**Three rows this table used to carry were removed, and the producers were not.** `Respiratory Rate`
and `Sleep Debt` printed `sleeps.respiratory_rate` and `sleeps.sleep_debt`; `High Sleep Stress` printed
nothing at all and carried a caption explaining that no path here produces the reading — that
discussion is below and it is why the row was not worth its line. The two readings are still written,
by `RespiratoryRateMath` and `SleepDebtMath` on the strap path and by the import verbatim, and they are
not left in the same position afterwards: the respiratory rate still reaches a screen, because
`CalculateRecoveryUseCase` copies it onto the `recoveries` row the Recovery detail page draws, while
**`sleeps.sleep_debt` is now read by no screen at all**. `TODO.md` §1 records that as a stored value
with no reader rather than a broken producer.

The three banded rows take their colours from one rule, `SleepBand.band(for:metric:)`.
Thresholds are this app's own calibration, anchored on WHOOP's published numbers where they exist:

| Band | Hours vs. Needed | Consistency | Efficiency |
| :--- | :--- | :--- | :--- |
| Poor | $< 70$ | $< 60$ | $< 80$ |
| Sufficient | $70$–$94$ | $60$–$89$ | $80$–$89$ |
| Optimal | $\geq 95$ | $\geq 90$ | $\geq 90$ |

Hours vs. Needed's anchors are WHOOP's: the metric is $(\text{Actual Sleep} / \text{Sleep Need})
\times 100$, with "95–100% fully met" and "below 70% significant deficits". Consistency's are
WHOOP's too: "90% or higher indicates a highly consistent schedule, while scores below 60% suggest
significant drift". **Efficiency's 80/90 has no published anchor and is this app's own**, like every
constant in §5's stress model. The three rows of the reference screen's card — 55, 73, 94 — fall
poor / sufficient / optimal under it, which is a validation rather than a coincidence and is why one
rule covers all three rather than three tuned per row.

One calibration note belongs with the table rather than being discovered later: over the export's
**892 scored nights the anchors put 62 in Poor, 805 in Sufficient and 25 in Optimal**. The bands are
heavily lopsided, because WHOOP's own "90%+ is highly consistent" is genuinely rare. That is a
property of the anchors, not a fault to tune away — but a rule that places 90% of nights in one band
discriminates weakly, and saying so is better than leaving it to be found.

**The three unbanded rows are readings, and none of them is an oversight.** Respiratory rate is a *reading* — the
same column `RecoveryDetailView` draws, at one decimal in `rpm` — and WHOOP publishes no anchor for
it, so any threshold would be this app's invention dressed as a scale. It is also not monotone in the
direction the three banded rows share: hours, consistency and efficiency are all better high, while a
respiratory rate has a normal range and both its extremes are notable. Sleep debt is not
monotone at all — it is a *running* deficit, the one quantity on this card that is about more than
the night that carries it, and it therefore has no per-night band to take. Both render as plain
figures in `Theme.textPrimary`, which is why the card needed a two-case `Figure` rather than one
optional: an unbanded value drawn in `Theme.textMuted` would be indistinguishable from the dash
below it.

**Both of those rows are now two-producer columns**, which is the same arrangement
`sleeps.sleep_consistency` already has and is worth stating where the card is described rather than
only in the sections that own the models. An imported night's figure is WHOOP's own, stored verbatim;
a strap night's is `RespiratoryRateMath`'s or `SleepDebtMath`'s, computed by `AnalyzeSleepUseCase` and
stored beside it. **Nothing but the `source` column tells them apart** — they are the same `Double?`
in the same nullable column, and a strap night that produced no figure is `nil` exactly as an imported
fragment is. That is the same bargain `Sleep Need` strikes a few paragraphs above, and it is the
reason neither model is ever allowed to run over an imported row: a recomputed value would be
indistinguishable from the one WHOOP supplied, and the screen would have no way to say so.

**The nap row is absent rather than a dash when the day holds no nap**, which is a different
rendering from every other row on the card. Not napping is an ordinary answer about a day, not an
unmeasured one, and the two are exactly what this app's dash convention exists to keep apart. A nap
itself is drawn as its asleep duration and nothing else, for the reason §4's nap paragraph gives: a
nap's own `Sleep performance %` is 6–43 on WHOOP's own rows, because its denominator is a night's
need, so printing it as a performance would file a deliberate 33-minute nap as a 6% night.

**Sleep stress is not measured, and no screen draws it any more.** WHOOP reads it from heart rate, HRV
and respiratory rate sampled *during* the night against a personal baseline, and this app has no
producer for it. `SleepDetailView` used to carry it as a `HIGH SLEEP STRESS` row rendering `—`, with a
caption beneath the card naming what was missing; the row and the caption were both removed, so the
finding below is now recorded here and nowhere on a screen. The rejection that follows is unaffected —
no row is needed for a model not to be built.

Two candidates were examined and both were rejected, on measurement rather than taste. The export
carries HRV, resting heart rate and respiratory rate per night and all three are stored, so a 14-day
z-composite is buildable — but it is not independent information. Z-scored against a strictly-before
14-day window and summed with HRV negative and the other two positive, over the export's **905
scorable days it correlates with WHOOP's own `Recovery score %` at $r = -0.747$ ($r^2 = 55.8\%$)**;
the magnitude is insensitive to the window variant, a 13-day inclusive window giving $r = -0.760$.
More to the point, §3's recovery score is $50 + 24 z_{\text{HRV}} - 18 z_{\text{RHR}} +
20(\text{sleepPerformance} - 0.70)$, so such a composite is *the same two z-scores that already carry
42 of the recovery score's weight*, sign-flipped. A fourth row built from them would restate the
Recovery screen's HRV and RHR rows under a third name, on a screen whose premise is that its four
rows are four different things.

`satayutata/geniemax-core`, examined as a reference, does not implement sleep stress either: none of
the 61 files under `Sources/GenieMax/`, its 55 test files or its JSON fixtures contain a sleep-path
occurrence of "stress". What it has is `Monitors.stressHRHRV` — a windowless live 0–3 reading scored
against *daytime* resting baselines, which is the same shape as §5's model and not a within-night
quantity at all. Its own source notes that the daytime baselines are kept separate from the sleeping
ones because "awake-resting HR ≠ sleeping RHR".

WHOOP's real quantity is a within-night measure, and this app has never captured a beat-to-beat
series to build one from: `biometric_samples.rrIntervalsMs` exists as of `v8` and is empty in every
database on this machine, because the app has never run against a strap. This is the second
WHOOP-named quantity this app declines to reconstruct, beside §6's VO₂ max.

### The typical range, and the one thing on that screen with no producer

Below the band legend, the same screen draws a fourth block: the night's four stages as shares of the
sleep period, each over a bar that marks the band that share is normally in. It is
`SleepStageRangeScoring.summary(for:priorNights:)` drawn by `SleepTypicalRangeCard`, and it is the
second calibration in this document's sleep half — the same bargain §5's stress model and
`SleepNeedMath` each record, stated here so it is not mistaken for a recovery of WHOOP's function.

**WHOOP publishes no stage boundaries at all.** What it publishes is a *comparison*: its charts quote
a stage's duration as a mean with a 25th–75th percentile range. So the band's **shape** follows that
and every number in it is this app's own.

| Element | Definition | Basis |
| :--- | :--- | :--- |
| Window | the last 30 days **that have nights**, strictly before the day, capped after the filter | `RecoveryScoring.baselineWindowDays` |
| Minimum | 3 usable nights, or no band is drawn | `RecoveryScoring.minimumBaselineDays` |
| Lower bound | 25th percentile of prior nights' shares for that stage | type-7 interpolation |
| Upper bound | 75th percentile of the same | type-7 interpolation |
| Restorative | mean of prior nights' (SWS + REM), **not** a band | — |

Two of those rows are *reused* rather than invented, and that is the point of naming them: they are the
identical constants the Recovery screen's baselines are built from, so the two screens cannot come to
disagree about how much history a baseline needs. Everything else is a choice made here.

**The band is in percentage points of the night, and WHOOP quotes its own REM range in minutes.** That
is forced rather than chosen: the bar's track is a 0–100% scale so that the four rows are comparable
with each other, which means the band drawn on that track has to be on the same scale. A reader
comparing this app's figure with the WHOOP app's should expect a different unit and not a bug.

**Restorative sleep is a mean and not a band**, which is why its footer row carries a number and no
bar. It is a *sum of two stages* — a different quantity on a different denominator — and a band of a
sum drawn on the same scale as four bands of shares would be a second kind of mark on one card, which
is how a reader comes to compare two things that are not comparable. It is compared with
`MetricChange` at `higherIsBetter: true`, the one judgement this card makes about direction: SWS and
REM are the stages the sleep literature associates with restoration, which is why WHOOP groups them
and why the same marker is deliberately **not** put on the four rows above, where a larger share of any
one stage is not better news.

**One identity the whole card rests on, and the suite re-verifies it against the real file**: the four
shares are of `sleepPeriodSeconds`, which is awake + light + deep + REM — the same four fields the rows
print. Over the bundled export, 910 of 910 nights have a four-percent column summing to exactly 100 and
a `DURATION` equal to their own sleep period. The column needs largest-remainder rounding to get there,
because the export stores whole minutes and the exact shares land on fractions: the eight-hour night
this app used to fabricate — `4.2 / 1.8 / 1.6 / 0.4` hours, rows of which are still in `sleeps` — is
$52.5 / 22.5 / 20 / 5$, which naive rounding prints as $53 + 23 + 20 + 5 = 101$, a column
contradicting the total printed above it.

**The heart-rate-during-sleep line chart the reference puts above this block is not built, and must not
be faked.** It is the largest element of that screen's mockup and it has no producer on any path this
app has: the export carries no HR series (only a per-cycle `Average HR (bpm)` / `Max HR (bpm)`, one
figure for a whole day), `biometric_samples` is empty in every database on this machine, and the
obvious fallback — a hypnogram — is dead too, because `SleepRecord` has no column for stage segments, so
`session.sleepStages` returns `[]` from every stored read. A strap night could one day yield a series
and nothing else on this screen could. `TODO.md` carries the gap.

### Respiratory Rate (RSA)

Respiration modulates the R-R interval — inhalation shortens it, exhalation lengthens it — so a
tachogram carries the breathing waveform as a slow modulation, and a peak in its 0.1–0.4 Hz band
**is** the breathing rate. This is WHOOP's own documented mechanism (they derive the figure from PPG
during the main sleep period) and the standard ECG-derived-respiration family.

`RespiratoryRateMath.respiratoryRate(from:asleepIntervals:)` produces it, `AnalyzeSleepUseCase` calls
it once per night beside the staging it already does, and the result is **stored** on
`sleeps.respiratory_rate` rather than recomputed on read — the same precedent `SleepNeedMath` sets.
An imported night's value is WHOOP's own and the model is never run over one; the two are told apart
only by `source`. **`SleepDetailView` no longer draws the row** — it was removed along with the sleep
debt row — but this value still reaches a screen: `CalculateRecoveryUseCase` copies it onto the
`recoveries` row, which `RecoveryDetailView`'s breakdown and `WeekLineSeries(respiratoryRateWeek:)`
both read. The sleep debt has no such second reader.

**The contiguity problem is the whole of the difficulty.** `BiometricSample.rrIntervalsMs` holds one
notification's beats — adjacent, in order, by definition — and **across** notifications they are not,
because `timestamp` is when the app decoded the packet rather than when the beats happened. One
notification is also far shorter than the 32 s a window needs, so packets must be chained, and chained
only where the beats really are continuous. The test uses the only two quantities that exist. The SIG
Heart Rate Measurement characteristic's R-R field carries the intervals *since the previous
notification*, so packet $i+1$'s intervals span from packet $i$'s last beat to its own last beat:

$$\text{span} = \frac{\sum \text{rr of packet } i+1}{1000} \qquad dt = t_{i+1} - t_i
\qquad \text{seam} = dt - \text{span}$$

Contiguous iff $|\text{seam}| \leq$ `seamToleranceSeconds` (= 0.20 s). **Pairing the seam against the
later packet's span is not arbitrary**, and the earlier packet's span is the tempting wrong answer:
the two agree whenever the heart rate is steady and differ by exactly one beat otherwise. The 0.20 s
is derived rather than tuned — R-R quantization at 1/1024 s over a 60-beat packet is 58.6 ms, BLE and
decode latency is budgeted at 100 ms, and the total is ~0.16 s — and it is a *test* rather than a
tolerance because it sits well under `minValidRRMs` (300 ms), so one dropped beat can never hide
inside it.

**Rejection is at packet granularity, and deliberately not `filterRRIntervals`.** That function
deletes intervals, which costs its RMSSD callers nothing because they read only the surviving values;
a tachogram is a series in time, so a deleted interval removes real elapsed time and draws the beats
either side of it as adjacent. A packet carrying any interval outside `minValidRRMs`/`maxValidRRMs`
is dropped whole instead — one definition of a plausible interval, failing in the safe direction,
since a dropped packet breaks the run at the seam test.

| Constant | Value | Basis |
| :--- | :--- | :--- |
| `bandLowHz` / `bandHighHz` | 0.1 / 0.4 | 6–24 bpm, the standard adult respiratory band |
| `windowSeconds` / `windowStepSeconds` | 32 / 5 | Charlton 2016 validates adjacent 32 s windows; 60 s is better and below ~20 s is indefensible |
| `minimumRunSeconds` | 32 | one window's worth of chained beats |
| `minimumWindows` | 3 | two values have no middle |
| `resampleHz` | 4.0 | well above twice the band's top edge |
| `frequencyStepHz` | 0.005 | 0.3 bpm, refined below the bin by parabolic interpolation |
| `nyquistMargin` / `bandTopHeartRateBpm` | 0.9 / 48 | the band's top edge needs 48 bpm of beats to exist at all; below it the ceiling narrows rather than the night failing |
| `minimumPeakToMeanRatio` | 5.5 | see below |
| `edgeGuardBins` | 2 | see below |
| `awakeBeatRatioCeiling` | 0.5 | WHOOP's figure is a sleep-period figure |

Per window the tachogram is reconstructed onto the uniform grid by **cubic** Lagrange, detrended,
Hann-tapered, and swept with a naive DFT over the band. The window is accepted only if its peak bin
holds `minimumPeakToMeanRatio` times the band's **mean** power, and only if it is at least
`edgeGuardBins` from either end; the night's answer is the median over the accepted windows, at one
decimal, or `nil` below `minimumWindows`.

**The flatness statistic is against the mean, not a share of the total, and that is a correction.**
A share of the summed band power reads as a property of the signal and is not one: the probe grid is
six times finer than a 32 s window can resolve, so refining `frequencyStepHz` moves the figure without
changing the tachogram — the ratio is proportional to the probe spacing. Dividing by the mean removes
the dependence. The floor is then arithmetic: the band holds about ten independent resolution cells
(0.3 Hz against the 1/32 s a 32 s window resolves), so the largest of ten noise bins sits at
$H_{10} \approx 2.93$ times the mean, and the measured noise floor is 2.88. What matters is the
**night**-level rate, not the per-window one, because a night is scored if `minimumWindows` of its
windows clear the bar and a 400 s run holds ~74 of them. Measured over 40 synthetic noise-only nights
per model (white at 40 ms and 60 ms, and a pink series of four AR(1) processes), the fraction of
nights reported at all is **0.80 at 4.5, 0.03 at 5.0, and 0 of 120 at 5.5**.

The cost is sensitivity and it is real: at 5.5 a 40 ms modulation on 25 ms of broadband variability is
still reported in every night, but a 30 ms modulation on 40 ms is reported in one night in five and a
20 ms modulation on 50 ms never. Those nights draw `—`. That is the deliberate direction of the
trade — a narrow estimator that dashes beats a wide one that invents a rate — and every figure in this
paragraph is synthetic, because the export carries no R-R series.

**`edgeGuardBins` is two because one is not enough, and the measurement is the reason.** The in-band
maximum of an out-of-band modulation sits *near* the edge, not necessarily *on* it: a 30 bpm (0.5 Hz)
modulation at a 100 bpm heart rate peaks on bin 59 of 61 — one inside the top — at 5.61× the mean,
which clears the flatness gate and was reported as a confident **23.6 bpm** for a signal with no
in-band component at all. The guard is symmetric because a below-band modulation leaks downward just
as far: a 34 bpm (0.567 Hz) modulation peaks on bin 1 at 8.81× the mean. With the guard, 30 bpm is
declined in all 40 seeds and nothing else in the sweep moves. The cost is the top of the band — the
effective range becomes 6.4–23.4 bpm at a normal heart rate rather than 6.3–23.7 — which is 0.3 bpm
off each end of a range the export's own column shows no night occupying (p05 14.5, p95 17.1).

**Cubic reconstruction rather than linear, and it is an aliasing fix rather than refinement.** A
tachogram is sampled at the beat rate, under 2 Hz asleep, and linear interpolation of a series sampled
that coarsely does not merely attenuate a component near the beat rate — it **generates harmonics** of
it, and a harmonic above the beat-rate Nyquist folds back **into the band**. Worked: a 30 bpm
modulation (0.5 Hz) reconstructed linearly puts its third harmonic at 1.5 Hz, which folds to
$1.667 - 1.5 = 0.167$ Hz and is reported as roughly 10 bpm. Cubic moves that peak up out of the band's
interior. The defect is invisible in a plot of the ideal waveform, which is why it survived until the
band-edge assertions were run.

**There is no harmonic rule, and its absence is a measurement.** The second harmonic of a 0.1–0.2 Hz
fundamental lands inside the same band, so a waveform whose harmonic outweighs its fundamental would
report twice the true rate. A rule promoting a peak whose sub-harmonic is comparable was implemented
and then removed, because it can never fire: admitting a window requires the peak to clear
`minimumPeakToMeanRatio`, and a comparable second tone raises the band's mean as much as the peak —
a two-tone 9 bpm-plus-18 bpm tachogram scores **3.38** where the same 18 bpm tone alone scores
**6.51**. Any threshold that rejects noise has therefore already declined every window such a rule
could act on. A doubling is not corrected, it is **declined**: a slow sleeper whose waveform carries
two comparable in-band components draws `—`, the same answer this model gives any window with no
dominant period.

**What this cannot do, and what it cannot be validated against.**

The export carries **no R-R series at all** — `biometric_samples.rrIntervalsMs` is empty in every
database on this machine, because the app has never run against a strap — so this estimator **cannot
be validated against any ground truth for this user's data**. It is a calibration in the same bargain
§5's stress model and `SleepNeedMath` document. Charlton's published ±4.7 bpm 95% limits of agreement
apply *if* the implementation is faithful, and one older-adult cohort saw 6 of 10 subjects err by
6–17 bpm; the suite's assertions validate the plumbing (a known modulation is recovered, a gapped
series is refused), **not** the accuracy.

One residual is worth stating because no rule above reaches it: **folding**. A 40 bpm modulation
(0.667 Hz) puts its second harmonic at 1.333 Hz, which the beat-rate sampling folds to 0.333 Hz and
reports as **~20 bpm** at 6.52× the mean. The peak is nowhere near a band edge, so `edgeGuardBins`
cannot see it, and it is a property of the tachogram's own sampling rather than of the band. Out-of-
band respiratory rates that high are not physiological at rest, but the mechanism is general and the
figure here is measured rather than bounded.

### Sleep Debt

WHOOP publishes the *shape* of this term and none of its constants: its API shows
`need_from_sleep_debt_milli` as one additive component of `sleep_needed`, and patent US20250288255A1
describes it as "scaled and capped at a maximum". Its own `Sleep debt (min)` column is therefore **not
accumulated minutes**: it runs 0–127 (mean 78.9, sd 33.9) while a plain sum of nightly shortfalls runs
352–1939 minutes. It is a scaled, bounded quantity at roughly a sixth of the accumulated shortfall,
and `SleepDebtMath` is fitted to reproduce *that* quantity so a strap night and an imported night
print on one scale.

**The lag is measured, and it is the whole design.** On the export's 910 labelled nights,
$\text{corr}(\text{debt}_n, \text{shortfall}_n) = 0.506$ against
$\text{corr}(\text{debt}_n, \text{shortfall}_{n-1}) = 0.891$, and the regression
$\text{debt}_n = 15.85 + 0.068\,\text{shortfall}_n + 0.352\,\text{shortfall}_{n-1}$ puts a **5.2×**
larger coefficient on the prior night. The shortfalls are only 0.42 autocorrelated, so this is not
collinearity — it is what the quantity is. A night's debt therefore accumulates the shortfalls
**strictly before** it:

$$\text{shortfall}_k = \max(0, \text{need}_k - \text{asleep}_k) \qquad
D_n = \sum_{k=1}^{W} \text{carryover}^{\,k-1} \cdot \text{shortfall}_{n-k} \qquad
\text{debt}_n = \min(C,\; s \cdot D_n)$$

| Constant | Value | Basis |
| :--- | :--- | :--- |
| `carryover` | 0.15 | argmin of a 0.00–1.00 sweep at 0.05 steps; 0.00 scores 8.72 and 0.30 scores 9.26, so the basin 0.10–0.25 sits within 0.08 of the minimum |
| `debtPerAccumulatedMinute` | 0.4293 | through-origin least squares, so zero accumulation is exactly zero debt |
| `priorNightCount` | 5 | the truncation tail is worth at most **0.02 minutes** against the export's largest shortfall, and the error is identical at 5, 7, 10, 14 and 20 |
| `maximumDebtMinutes` | 127 | the export's column maxes at exactly 127 with **105 of 910 rows** on that single value; load-bearing, since **8.5%** of the model's own predictions exceed it uncapped, reaching 254 |
| `historyLookbackDays` | 30 | the window is calendar days and the model consumes records, so a gap makes the span far longer than the night count; only 15 of 910 nights have fewer than five priors inside 30 days |

The fit, on the export's 910 labelled nights:

| Model | MAE (min) | corr | R² |
| :--- | ---: | ---: | ---: |
| **lagged, carryover 0.15 — shipped** | **8.31** | 0.900 | **0.767** |
| lagged, carryover 0.00 (prior night only) | 8.72 | 0.891 | 0.705 |
| same-night, carryover 0.70 | 16.03 | 0.785 | 0.611 |
| weighted mean, 14 nights (Oura's taper) | 19.61 | 0.670 | 0.450 |
| predicting the mean | 27.70 | — | — |

Three things belong in the reader's head beside it. The alignment is **not a free parameter**: a
same-night model scores 16.03 deployed, but the larger point is that it would put a differently-
defined number on the column the importer fills, which is the inconsistency this model exists to
remove. The model is **written as a closed form over an explicit sort, never as a walk**, because a
recurrence has loop-carried state and reading the export in its own newest-first file order moves MAE
from 8.31 to **22.69**. And the ceiling is modest — MAE 8.3 against a column whose own standard
deviation is 33.9 — so this reproduces the shape and scale of WHOOP's quantity, not its value.

**The gate is one prior record, not a fixed count**, and that follows from the lagged form: the
accumulation is a strictly-earlier-only quantity, so a night with one predecessor has a complete, if
short-memoried, answer, and the terms it cannot see are worth at most 0.02 minutes.
`SleepConsistencyMath` gates at four because its quantity *is* a mean over four and has no partial
rendering; this one has a base case. With nothing before it there is genuinely nothing to accumulate
and the row draws `—`. **A negative result is also recorded**: a repayment term
$D \leftarrow \text{carryover} \cdot D + \text{shortfall} - \rho \cdot \text{surplus}$ was swept from
$\rho = 0$ to a full minute-for-minute repayment of every surplus, and moves deployed MAE from 8.31 to
8.24 — four seconds. "Sleeping more pays the debt off" is the first thing a reader will want to add;
this is the measurement that says not to.

**`0` is a legitimate answer here, uniquely among the numbers this app computes.** WHOOP's own column
bottoms out at 0, and "no accumulated deficit" is a measurement rather than an absence. It is `nil`
that means *not scored*, which is the distinction `sleeps.sleep_debt`'s nullable column already
draws and the reason a writer uses `map` and never `?? 0`.

**Sleep debt is not an input to `Sleep Need`.** §4's need model deliberately omits the accumulated
term WHOOP names, and that decision is unchanged: a fitted 7-night deficit was measured at 0.35 of a
point on the need, for a second fitted constant and seven nights of history. This section gives the
debt a **reader**, not a new role.

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