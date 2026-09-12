---
name: ui-data-provenance
description: Use before building or changing any view that shows a number, chart, ring or tile under Sources/Whoopsy/Presentation/ — and whenever a mockup, a reference screenshot or a user request implies a figure this app should display. Establishes from the real data whether that figure has a producer at all, and names the fabrication classes this repo has already shipped.
---

# UI Data Provenance

A mockup is a picture of a value, not evidence that the value exists. This codebase has twice built a
piece of UI against data that was not there: the Stress Monitor chart renders `—` on every imported
day because the export carries no R-R series at all, and the Recovery screen prints "At baseline"
for every stored day because the two delta fields it reads are never written to the database and
never restored from it. Neither is a drawing bug. Both were discoverable before the first line of
view code, and this skill is how.

The rule is that every figure on a screen traces to a producer. A producer is a stored column, a
value computed on read from stored columns, or a live read from the strap or HealthKit. Anything
else — a defaulted parameter, a constant, an `?? 0` — is a number this app wrote down rather than
measured, and it must not reach the screen as a reading.

**Run the check before writing the view, not after.** The cost is one command; the cost of skipping
it is a chart that can only ever be empty for the user's actual data.

## The empirical check

Measured, over the bundled export, with the columns and counts that follow. Never quote a number
from this file without re-running it — the export is a fixed file, but the *readers* change.

```bash
python3 - <<'PY'
import csv
p = "Sources/Whoopsy/Data/Resources/physiological_cycles.csv"
rows = list(csv.DictReader(open(p, newline='')))
print("rows:", len(rows))
for name in rows[0]:
    vals = [r[name] for r in rows if r[name].strip() not in ('', 'NaN')]
    rng = ""
    try:
        nums = [float(v) for v in vals]
        if nums: rng = f"{min(nums):g} .. {max(nums):g}"
    except ValueError:
        rng = "text"
    print(f"{name:<44}{len(vals):>10}   {rng}")
PY
```

A column that is absent from this output **does not exist in the export** — that is the finding, and
it is not something to work around.

## What each source can actually produce

| Source | Measured | Can produce | Cannot produce |
| :--- | :--- | :--- | :--- |
| `physiological_cycles.csv` — `Resting heart rate (bpm)` | **910**/935, 46–98 | RHR for any day with a closed cycle | The 25 rows with no cycle (fragments) |
| … — `Sleep need (min)` | **910**/935, 321–650 | WHOOP's own need, verbatim | A need for a fragment day |
| … — `Day Strain` | **933**/935, **0–19.8** | WHOOP's own score, verbatim | Zone breakdowns, a HR series — the export has neither |
| … — `Recovery score %` | 910/935, 1–99 | *(nothing — see below)* | — |
| … — an R-R interval series | **absent** | — | **Any HRV-derived stress window.** The Stress Monitor is `—` on every imported day by construction |
| … — step counts | **absent** | — | Steps, from any imported day. HealthKit only |
| … — a VO₂ max | **absent** | — | **WHOOP's VO₂ max**, from any imported day. The app computes its own by a different model — see below |
| `sleeps.csv`, `journal_entries.csv`, `workouts.csv` | 918/3403/673 rows | *(nothing — unbundled and read by nothing)* | — |
| `biometric_samples` (strap) | only days the app ran with the strap on | Everything, from a worn day | Any day before the install |
| HealthKit | runtime | Steps (a `dailyTotal` sum), HRV, RHR, respiratory rate | Anything else, without permission — and permission is never disclosed. **No longer VO₂ max**: that read-through was deleted, and the consent prompt no longer asks for it |
| Computed on read | — | Sleep Need (from baseline + yesterday's strain), the stress series, `MetricWeek` baselines, **the VO₂ max estimate** | A value whose inputs are absent |

Two of these are easy to get wrong. `Recovery score %` is present, well-populated, and **written
nowhere**: `WhoopExportImporter` re-scores every imported day through `RecoveryScoring` so one
formula covers all history, which is deliberate and means the export's percentage is not a
producer. And the export **ends 2026-08-22** (latest wake onset `2026-08-22 08:59:43`), so on any
install where "today" is later, every day-keyed screen opens on a day with nothing to show — Home
opens on today, so this is the normal first impression, not an edge case.

The **VO₂ MAX panel** is the case that shows the three verdicts are about a *figure*, not a panel,
and that a verdict can change without the export changing at all. The export has no VO₂ column and
never will, so WHOOP's own VO₂ max is **absent** for every imported day. The panel itself is
**partial**, because the app produces a figure of its own: `Vo2MaxMath.heartRateRatioEstimate`
(`15.3 × HRmax / HRrest`, Uth et al. 2004), derived on read inside `MetricWeek.makeDay` from the
day's own gated resting heart rate and `UserProfile.maxHeartRate`, stored in no table. It is `—`
whenever either input is missing — which, on an imported day, means whenever that day's cycle had no
resting heart rate — and it is labelled `(EST.)` because it is a model's output sitting beside three
measurements. WHOOP's three-tier model is still the one this app declines to reimplement;
`ALGORITHMS.md` §6 records it, this estimate's citation and error bar, and the measurement that
rejected the day's own observed peak as the anchor.

The lesson generalises: **a panel's verdict is a claim about the producer, so it goes stale when the
producer changes, not when the data does.** This one flipped from absent to partial when the
read-through was deleted and a model was added, and nothing in the export moved.

## The three verdicts

Every proposed value gets exactly one, and it is written down **before** the view is built.

| Verdict | Means | What the view does |
| :--- | :--- | :--- |
| **Populated** | A producer exists for the days this screen can show | Render it. State the count in the plan |
| **Partial** | A producer exists under a condition (a closed cycle; a worn strap; a granted permission) | Render it **and** the `—` for the other case. State the condition |
| **Absent** | No producer, and none can be added without an algorithm or a new import | Render `—` with a caption that says why. **Not** `0` |

The third verdict is the one that gets argued with, and the argument is always the same: `0` looks
like a measurement. On this app it is the reserved marker for "nothing was measured", which is why
`RecoveryMetric.hasMeasurement`, `StrainScore.hasMeasurement` and `SleepSession?` exist as three
separate mechanisms for one idea.

## Fabrication classes this repo has actually hit

Each of these was shipped, or nearly was. Check the change against every row.

| Class | Instance | The tell |
| :--- | :--- | :--- |
| **Defaulted field on a stored row** | `WhoopDevice.batteryPercentage` is non-optional and `WhoopBLEManager` writes a literal `100` at discovery | A readout showing a confident "100%" for a strap that is not connected. Gate on `connectionState == .connected` |
| **Computed but never persisted** | `RecoveryMetric.rhrBaselineDeltaBpm` and `.hrvBaselineDeltaMs` are scored by `RecoveryScoring` and passed to the entity, but `RecoveryRecord` has neither column and `makeMetric` maps neither | A delta that exists on a live-computed day and is `nil` on every stored one. `RecoveryDashboardView.zText` rendered that `nil` as "At baseline" — a positive claim about the reading, produced by a field that was never loaded — and now renders a dash instead. The field is still not persisted, so the delta feature is still absent; the false claim is not |
| **Plausible constant for a missing sensor** | `AnalyzeSleepUseCase` once wrote a literal `14.4` rpm; `GRDBSleepRepository` once handed back `respiratoryRate: 14.0` | A number with no measurement behind it. The strap has no respiratory sensor; only HealthKit does |
| **A whole row out of literals** | The four-literal night (`4.2/1.8/1.6/0.4` hours) written when a night could not be classified | Rows of exactly those values in `sleeps`. An unclassifiable night must write **no row** |
| **`?? 0` on an optional column** | `WhoopExportImporter`'s `row.energyKcal ?? 0`, `row.averageHeartRate ?? 0`, `row.maxHeartRate ?? 0` | Unreachable on this export (all three are non-empty on the same 933 rows) but latent. Note the backfill for `v7` tests `source IS NULL` partly because of it |
| **Hard-coded profile constant** | `UserProfile.targetSleepHours` is `8.0`, never editable, never persisted | Anything comparing a real reading against it. Imported nights carry WHOOP's own need and can legitimately fall below it |
| **Carry-forward dressed as a reading** | `HealthKitImporter` fills a day with no RHR by carrying the last measured one forward, then falls back to `profile.restingHeartRate` | A flat RHR across days. Honest as a fallback, but it is not that day's measurement |
| **A reserved zero read as a value** | `CalculateStrainUseCase`'s empty branch once wrote `score: 0.0`, indistinguishable from a measured rest day | A real-looking point at zero on a chart. Now closed at the source: an unmeasured day gets **no row**, so there is nothing to misread. `StrainScore.hasMeasurement` remains as reader tolerance for rows an older build wrote, and the `v7` backfill keys on the *empty branch's whole signature*, because two genuinely measured days also score exactly `0.0` |

## Rules

1. **Name the producer before the view.** "It comes from `MetricWeek`" is not a producer; "`strains.hasMeasurement`, written by `CalculateStrainUseCase`'s measured branch" is.
2. **A reference screenshot is a mockup.** It shows what some other app had, on some other day, from some other data. Re-measure ours.
3. **A domain entity field is not evidence the screen can show it.** Check the read path: the record's columns, and the mapper that builds the entity from them. This is exactly how "At baseline" shipped.
4. **`—`, never `0`.** The dash is the only rendering that distinguishes unmeasured from measured-as-zero.
5. **Say what you could not prove.** If a value's producer is a fallback, a carry-forward or a constant, write that in the plan. If a test cannot reach the path — the `v7` backfill runs before any row exists, and this suite has no renderer for a `Shape` — say that instead of implying coverage.
6. **Never let a screenshot of an empty card stand in for a tested feature.** Home opens on today, and today is past the export's end, so an empty Home is the *expected* first screenshot and proves nothing about whether the chart works. Screenshot a day that has data, or say you did not.
