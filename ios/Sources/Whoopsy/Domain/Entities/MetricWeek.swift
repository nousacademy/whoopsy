import Foundation

/// One day of a `MetricWeek`: the daily figures a screen draws from it, each already reduced to the
/// only question that screen asks of it — a number, or nothing.
///
/// Every field is optional because every one of them can genuinely be absent, and each absence has a
/// different mechanism behind it: a day the strap recorded nothing for holds **no row at all**, a
/// night the classifier could not read holds no row either, a resting heart rate or an HRV is only
/// ever written by a path that observed one, and a VO₂ max is **derived on read** from the day's own
/// resting heart rate and an assumed maximal one, so it is absent whenever either is. Collapsing any
/// of them to a `0` here would move that decision into the view, where it has been got wrong before.
///
/// The older mechanism is still live for reads: rows an earlier build wrote as reserved zeros are
/// still on disk, which is what `RecoveryMetric.hasMeasurement` and `StrainScore.hasMeasurement`
/// gate here.
public struct MetricDay: Equatable, Sendable, Identifiable {
    public var id: Date { date }

    /// The day, snapped to its start — the key `recoveries`, `sleeps` and `strains` are all
    /// primary-keyed on.
    public let date: Date

    /// The day's strain, or nil when the day holds no measurement. Deliberately not `0.0` for an
    /// unmeasured day: see `StrainScore.hasMeasurement`.
    public let strain: Double?

    /// The day's recovery score, or nil when the day holds no measurement —
    /// see `RecoveryMetric.hasMeasurement`.
    public let recoveryScore: Int?

    /// The day's resting heart rate in bpm, or nil when nothing recorded one.
    public let restingHeartRate: Int?

    /// The day's respiratory rate in breaths per minute, or nil when nothing recorded one.
    ///
    /// **The one field here with no reserved zero to gate, and so the one with no gate.** A
    /// `recoveries` row stores `respiratory_rate` as a nullable column whose only writers pass
    /// `sleepSession?.respiratoryRate` straight through — so the column holds either a real reading or
    /// nothing, and `hasMeasurement` never enters into it. That is the same shape the RESPIRATORY RATE row on the detail screen reads, and
    /// deliberately so: a gate here would let the chart omit a point the row above it prints.
    ///
    /// A night can carry a respiratory rate without carrying an HRV — the two are independent
    /// measurements — so this can be non-nil on a slot whose `hrvValueMs` is nil, and neither implies
    /// the other.
    public let respiratoryRate: Double?

    /// The day's sleep need in seconds, or nil when the day has no classified night.
    public let sleepNeedSeconds: TimeInterval?

    /// The night's time actually asleep — `SleepSession.totalTimeAsleepSeconds` — or nil when the day
    /// has no classified night.
    ///
    /// **Read off the same `sleeps` row as `sleepNeedSeconds` above, and it exists because the two
    /// durations are compared rather than only divided.** `sleepPerformance` below is their ratio, and
    /// a ratio is lossy in exactly the way that matters here: it is a whole percent of a nine-hour
    /// denominator, so recovering the duration from it lands up to three minutes out — measured over
    /// the reference week, `9:17 × 81%` gives `7:31` where the night is `7:33`. A chart drawing that
    /// derived figure would put a point under this page's own `HOURS OF SLEEP` card contradicting the
    /// figure printed on it, about the same night. So the duration is carried, not reconstructed.
    ///
    /// **Ungated, like `respiratoryRate` and `sleepPerformance` below and unlike the need above it.**
    /// The need's `> 0` guard is about the *denominator* — a row with no need stored cannot be divided
    /// by — and there is no equivalent here: `totalTimeAsleepSeconds` is a sum of stored stage
    /// durations, and a `SleepSession` is only ever built for a night the classifier could read, so a
    /// zero would be a night with no sleep in it rather than a missing column. Over the bundled export
    /// that is unreachable and asserted — all 910 imported nights carry a positive headline.
    public let asleepSeconds: TimeInterval?

    /// The night's slow-wave sleep in seconds, or nil when the day has no classified night.
    ///
    /// **`deepSleepSeconds` and `remSleepSeconds` are the only two fields here carried as a split
    /// rather than as a total, and their total is deliberately not carried beside them.**
    /// `SleepSession.restorativeSleepSeconds` is WHOOP's own sum of the two stages it calls
    /// restorative, and that sum is what the `RESTORATIVE SLEEP (HOURS)` chart's axis is fitted to and
    /// what its columns are labelled with — but the chart also draws the two stages as a stack, so it
    /// needs the parts, and a third stored field holding their total would be a fourth number free to
    /// disagree with the other three. The total is `deep + rem` and nothing else, so the figure above
    /// a column and the two bands inside it cannot describe different nights.
    /// `RestorativeSleepWeek.Point` is where that sum is taken.
    ///
    /// Both are read off the same `sleeps` row as `asleepSeconds` above, so **the two are absent
    /// together** — a day either has a classified night with both stages reported or has neither
    /// field. `SleepSession` stores each as a plain `TimeInterval` defaulted to `0`, so a night of
    /// light sleep and no restorative sleep really does carry a zero here, and that zero is a reading
    /// rather than a missing column: it is a night with no deep and no REM in it.
    ///
    /// **Ungated, like `asleepSeconds` above and unlike the need below it.** These are sums of staged
    /// minutes off a night the classifier could read, so there is no reserved zero to filter — the
    /// need's `> 0` guard is about a *denominator*, and nothing here divides.
    public let deepSleepSeconds: TimeInterval?

    /// The night's REM in seconds, or nil when the day has no classified night. The other half of the
    /// pair described on `deepSleepSeconds` above, and absent with it.
    public let remSleepSeconds: TimeInterval?

    /// When the night began and when it ended, **on the night clock** — `SleepConsistencyMath`'s
    /// noon-pivoted frame, where `0` is noon, `420` is 7 PM and `720` is midnight. Not minutes past
    /// midnight, and the difference is twelve hours rather than a rounding: a reader who took `720`
    /// for noon would place a midnight bedtime at midday. `SleepClockAxis.clockText` is the only
    /// conversion back to a wall clock and must not be inlined.
    ///
    /// **It is the same pair of quantities, in the same frame, as `SleepConsistencyScoring.Bar`'s
    /// `onsetMinutes` / `wakeMinutes`** — a night's two boundaries read off `SleepSession.startTime`
    /// and `.endTime`, carried here as two fields so a week chart can place a night by *when it
    /// happened* rather than by how much of it there was. The prefix is this file's convention for a
    /// sleep field rather than the shorter pair the scoring types use, because beside `asleepSeconds`
    /// a bare `wakeMinutes` would read as a second duration.
    ///
    /// **Absent together, structurally**: both come off one `sleeps` row, and `SleepSession` holds
    /// `startTime` and `endTime` as plain `Date`s with no optional on either, so a day with a
    /// classified night always has both and a day without one has neither.
    ///
    /// **Ungated, like the five fields around it.** There is no reserved zero to filter — nothing here
    /// divides and no column defaults — so a gate could only drop a column the chart still has a
    /// labelled day for. See `hasAnyMeasurement` for why neither field is in that list either.
    public let sleepOnsetMinutes: Double?

    /// When the night ended on the night clock — the other half of the pair described on
    /// `sleepOnsetMinutes` above, and absent with it.
    public let sleepWakeMinutes: Double?

    /// The night's sleep performance toward that need, as a whole percentage, or nil when the day has
    /// no classified night.
    ///
    /// The second field read off the same `sleeps` row as `sleepNeedSeconds` above, so the two are
    /// absent together and a day with a night always has both. It is **not** a column: it is computed
    /// on read by `SleepSession.sleepPerformancePercentage` from the night's staged minutes over its
    /// need, which is why there is nothing here for a reserved zero to hide in.
    ///
    /// **Ungated, like `respiratoryRate` below and unlike every other field here.** There is no stored
    /// zero to filter, and the one way this could state a figure with no measurement behind it is the
    /// `guard targetSleepNeedSeconds > 0 else { return 100 }` inside that property — a hard `100`
    /// standing in for a denominator that was not there, which is a defaulted number rather than a
    /// night well slept. Over the bundled export that path is unreachable: `WhoopExportImporter`
    /// builds a session only for a row carrying a wake onset, and every one of those 910 rows carries
    /// a `Sleep need (min)` too, so no stored night has a zero need. It is one CSV column away from
    /// being reachable and is recorded here for that reason — but it is **not** gated, because the
    /// SLEEP PERFORMANCE row on the Recovery detail screen reads the same property with no gate
    /// either, and a gate here would let this week's chart omit a bar that the row directly above it
    /// prints. The same argument, made for the same reason, as `respiratoryRate`'s.
    public let sleepPerformance: Int?

    /// The day's HRV in milliseconds, or nil when nothing recorded one.
    public let hrvValueMs: Double?

    /// Which quantity `hrvValueMs` holds — and **always nil when `hrvValueMs` is**, so a slot cannot
    /// name a metric it has no reading in. Carried per day rather than once per week because the two
    /// metrics can both appear inside one window: the export's days are RMSSD (an inference — see
    /// `WhoopExportImporter`) and a HealthKit-imported day is SDNN.
    public let hrvMetric: HRVMetric?

    /// The day's estimated VO₂ max in mL/(kg·min), or nil when the day cannot produce one.
    ///
    /// **Derived on read, and stored nowhere.** It is `Vo2MaxMath.heartRateRatioEstimate` applied to
    /// the same day's `restingHeartRate` above and the profile's maximal heart rate, so a day with no
    /// measured resting rate — or a week built with no `maxHeartRate` — has no estimate rather than a
    /// defaulted one. `Vo2MaxMath` carries the model, the constant and its error.
    ///
    /// Because it reads `restingHeartRate` and nothing else, it can never disagree with the RESTING
    /// HEART RATE panel drawn beside it: one day, one rate, one pair of figures. That is structural
    /// rather than a convention — the two fields are computed from one hoisted local in `makeDay`.
    public let vo2MaxMlKgMin: Double?

    public init(
        date: Date,
        strain: Double?,
        recoveryScore: Int?,
        restingHeartRate: Int?,
        sleepNeedSeconds: TimeInterval?,
        asleepSeconds: TimeInterval? = nil,
        deepSleepSeconds: TimeInterval? = nil,
        remSleepSeconds: TimeInterval? = nil,
        sleepOnsetMinutes: Double? = nil,
        sleepWakeMinutes: Double? = nil,
        sleepPerformance: Int? = nil,
        hrvValueMs: Double? = nil,
        hrvMetric: HRVMetric? = nil,
        respiratoryRate: Double? = nil,
        vo2MaxMlKgMin: Double? = nil
    ) {
        self.date = date
        self.strain = strain
        self.recoveryScore = recoveryScore
        self.restingHeartRate = restingHeartRate
        self.sleepNeedSeconds = sleepNeedSeconds
        self.asleepSeconds = asleepSeconds
        self.deepSleepSeconds = deepSleepSeconds
        self.remSleepSeconds = remSleepSeconds
        self.sleepOnsetMinutes = sleepOnsetMinutes
        self.sleepWakeMinutes = sleepWakeMinutes
        self.sleepPerformance = sleepPerformance
        self.hrvValueMs = hrvValueMs
        self.hrvMetric = hrvMetric
        self.respiratoryRate = respiratoryRate
        self.vo2MaxMlKgMin = vo2MaxMlKgMin
    }

    /// Whether this day has anything to plot at all — the chart's per-slot draw test, and the count
    /// the STRAIN & RECOVERY caption prints.
    ///
    /// The two fields behind the HRV and VO₂ MAX panels are deliberately **not** folded in. An HRV is
    /// a no-op here — it is gated on the same `hasMeasurement` as `recoveryScore`, so it can never be
    /// the only field a day has.
    ///
    /// The VO₂ estimate's exclusion is now **provably redundant** rather than merely cautious: the
    /// estimate requires a non-`nil` `restingHeartRate`, and that is already in the list, so a day
    /// carrying one cannot fail this test however the estimate is computed. It is kept because it
    /// states the intent — the STRAIN & RECOVERY chart draws strain and recovery, and a VO₂ max must
    /// never be what makes an otherwise empty week look measured. It used to be load-bearing: while
    /// the value was read through from HealthKit it could exist on a day with no stored row at all,
    /// so counting it could draw the tile's frame and its "1 measured" caption over a week with no
    /// strain and no recovery in it.
    ///
    /// `respiratoryRate` is excluded for the same stated intent, and unlike the VO₂ estimate its
    /// exclusion is **not** redundant — a night can carry a respiratory rate with no HRV, so this is
    /// the one field here that could make an otherwise empty day count. It must not: this is the draw
    /// test for a chart of strain and recovery, and a respiratory rate is drawn by neither.
    ///
    /// `sleepPerformance` is excluded on the same stated intent, and its exclusion is the redundant
    /// kind: it is read off the same night as `sleepNeedSeconds`, which is already in the list, so a
    /// day carrying a performance necessarily carries a need. Kept for the reason the VO₂ estimate's
    /// is — the STRAIN & RECOVERY chart draws strain and recovery, and a sleep performance is drawn by
    /// neither, so it must not be able to justify either the tile's frame or its measured count.
    ///
    /// `deepSleepSeconds` and `remSleepSeconds` are excluded on that same intent and by the same
    /// redundant argument, being read off that same night as well — and the reason is worth stating
    /// rather than leaving to the pattern, because these two are the only fields here that are
    /// *drawn* by a chart on another screen. That chart is `RESTORATIVE SLEEP (HOURS)` on the sleep
    /// detail page, and this test belongs to the STRAIN & RECOVERY chart, which draws neither stage.
    ///
    /// `sleepOnsetMinutes` and `sleepWakeMinutes` join that list on the same intent and by the same
    /// redundant argument — they are read off that same `sleeps` row as the need, so a slot carrying
    /// them necessarily carries a need. They are the third pair here drawn by a chart on another
    /// screen, `TIME IN BED`, and the argument is the deep/REM one restated: this test is the draw
    /// test for a chart of strain and recovery, and two clock times are drawn by neither.
    public var hasAnyMeasurement: Bool {
        strain != nil || recoveryScore != nil || restingHeartRate != nil || sleepNeedSeconds != nil
    }
}

/// A fixed-length window of days, ending on an anchor, with the rolling baselines the Home panels
/// print under their headline values.
///
/// **The invariant that matters is that `days` has exactly `dayCount` entries, always.** The slots
/// are generated from the *calendar*, not from the rows that were handed in, so a day with nothing
/// stored is an empty slot inside a full week rather than a missing element. That is what stops a gap
/// from silently shifting every later point one position to the left and relabelling it with the
/// wrong date — a chart that is wrong about which day it is showing, with nothing on screen to say
/// so. The same reasoning as `StressDay` computing its own aggregate: the shape is structural, not a
/// property a caller is trusted to maintain.
///
/// **There is no `calendar:` parameter, and that is deliberate.** The day keys in the database are
/// snapped with `Calendar.current`, and this type joins rows *by* those keys — so a caller handing in
/// a calendar from another zone would not shift the week, it would fail to match the rows inside it
/// and draw a week of empty slots. `WhoopExportImporter` carries an injectable calendar and documents
/// the same trap for the same reason; here the honest fix is not to offer the parameter at all.
public struct MetricWeek: Equatable, Sendable {
    /// How many days a week holds. Seven is the reference's own window.
    public static let dayCount = 7

    /// How few measured days is not a baseline. Two measured days do have a mean, so this is a
    /// judgement rather than an arithmetic limit — the same judgement `StressMath.minimumBaselineDays`
    /// already makes for the stress baseline, so it **forwards** to that constant rather than
    /// restating `3`. The app then has one answer to "how few days is not a baseline" structurally
    /// rather than by two literals that agree until one is tuned.
    ///
    /// This is not a layer violation, and the sibling types in this directory are the proof:
    /// `StressScore` stores a `StressMath.Band` and calls `StressMath.band(forScore:)`, and
    /// `StressWindow` forwards to it as well. `Domain` importing only `Foundation` is a rule about
    /// *frameworks* — no UIKit, no GRDB, no CoreBluetooth — not about the package's own layers, which
    /// are one module and have no import between them at all.
    public static let minimumBaselineDays = StressMath.minimumBaselineDays

    /// The day the window ends on — the most recent slot, and the one the panels describe.
    public let endingOn: Date

    /// The window's days, oldest first. Always exactly `dayCount` entries.
    public let days: [MetricDay]

    /// The mean resting heart rate over the week's measured days, rounded to a whole bpm, or nil
    /// below `minimumBaselineDays`.
    public let restingHeartRateBaseline: Int?

    /// The mean sleep need over the week's measured nights, or nil below `minimumBaselineDays`.
    public let sleepNeedBaselineSeconds: TimeInterval?

    /// The mean HRV over the week's measured days **in `hrvBaselineMetric` only**, or nil below
    /// `minimumBaselineDays`.
    public let hrvBaselineMs: Double?

    /// The quantity the week's HRV is read in — the newest measured slot's — or nil when no slot in
    /// the week carries a reading at all.
    ///
    /// Exposed so a screen can say which quantity it is printing rather than leaving the number
    /// unlabelled: SDNN and RMSSD are different measurements on different scales, and a week can hold
    /// both (the export's days are RMSSD, a HealthKit-imported day is SDNN).
    ///
    /// **It is not the same condition as `hrvBaselineMs != nil`, and the difference is the floor.**
    /// This names which quantity the week is in and is set as soon as one slot has a reading; the mean
    /// above it additionally requires `minimumBaselineDays` (3) days *in that quantity*, so a
    /// two-day week is `hrvBaselineMs == nil` with `hrvBaselineMetric == .rmssd`. Anything selecting
    /// the days to plot, or narrowing a series, wants this one — it is answering "which quantity",
    /// not "is there a baseline". `MetricWeek.hrvBaselineMs` is the one that answers the latter.
    public let hrvBaselineMetric: HRVMetric?

    /// The mean of the week's estimated VO₂ max values, or nil below `minimumBaselineDays`.
    ///
    /// A mean of estimates, so it is a mean over the days that could produce one at all — the days
    /// with a measured resting heart rate. Those are `nil` together, which is why there is no
    /// separate absence rule to state here.
    public let vo2MaxBaselineMlKgMin: Double?

    /// Joins the three stored histories — and one read-through — onto one calendar week ending on
    /// `endingOn`.
    ///
    /// The histories are the raw repository reads, so their order does not matter and duplicates
    /// cannot occur — all three tables are primary-keyed on the day. A row whose day falls outside
    /// the window is ignored rather than widening it: the window is the anchor's, not the data's.
    ///
    /// `maxHeartRate` is the one input that is not a per-day row: it is the profile's assumed
    /// maximal heart rate, the same field `CalculateStrainUseCase` builds its Karvonen zones from, so
    /// the app has **one** definition of a maximal heart rate rather than one per model. It is `nil`
    /// when no profile could be read, and the week then carries no VO₂ estimate on any day — an
    /// assumption this app does not have is not a reason to print a number.
    ///
    /// The estimate it feeds is computed **per slot, inside this initialiser**, from that slot's own
    /// already-gated `restingHeartRate`. That placement is the point: the day's absence rule for a
    /// resting heart rate is applied once, in `makeDay`, and the VO₂ field inherits it. A caller
    /// assembling the estimate itself would have to restate the `hasMeasurement && > 0` gate, and two
    /// copies of that rule are two chances for a placeholder row's reserved zero to become a reading.
    public init(
        endingOn: Date,
        strain: [StrainScore] = [],
        recovery: [RecoveryMetric] = [],
        sleep: [SleepSession] = [],
        maxHeartRate: Int? = nil
    ) {
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: endingOn)
        self.endingOn = anchor

        let strainByDay = Self.index(strain, by: \.date)
        let recoveryByDay = Self.index(recovery, by: \.date)
        let sleepByDay = Self.index(sleep, by: \.date)

        // Walked backwards from the anchor so the array is built in the order the slots are, then
        // reversed once. The fallback on the day arithmetic is unreachable for a gregorian calendar
        // and exists only so that its impossibility cannot shorten the week and slide every point.
        var slots: [MetricDay] = []
        var day = anchor
        for _ in 0..<Self.dayCount {
            slots.append(
                Self.makeDay(
                    day,
                    strain: strainByDay[day],
                    recovery: recoveryByDay[day],
                    sleep: sleepByDay[day],
                    maxHeartRate: maxHeartRate,
                    calendar: calendar))
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day.addingTimeInterval(-86_400)
        }
        self.days = Array(slots.reversed())

        // Means over the slots that were measured, and nil below the floor. A mean is deliberately
        // all this is: no z-score, no standard deviation, nothing that belongs in `Core/Math` as a
        // model. The panels print it as context for the day's value, not as a score.
        let rates = self.days.compactMap(\.restingHeartRate)
        self.restingHeartRateBaseline =
            rates.count >= Self.minimumBaselineDays
            ? Int((Double(rates.reduce(0, +)) / Double(rates.count)).rounded())
            : nil

        let needs = self.days.compactMap(\.sleepNeedSeconds)
        self.sleepNeedBaselineSeconds =
            needs.count >= Self.minimumBaselineDays
            ? needs.reduce(0, +) / Double(needs.count)
            : nil

        // Narrowed to one metric **before** averaging, which is the never-mix rule — SDNN and RMSSD
        // are different quantities, and their mean is a statistic about neither. The metric is the
        // most recent measured slot's, walking back from the anchor: the anchor's own day when it has
        // a reading, and otherwise the newest day that does, so the baseline belongs to the same
        // quantity as the figure the panel prints above it. A window holding both metrics therefore
        // averages only the days matching the newest one, and can legitimately come back below the
        // floor with readings present — which is the honest answer, not a baseline over a mixture.
        // A local copy for the two closures below: `self` is not fully initialised until the last
        // stored property is set, so a closure reaching through it does not compile.
        let week = self.days
        let newestMetric = week.reversed().first { $0.hrvValueMs != nil }?.hrvMetric
        let hrvValues =
            newestMetric.map { metric in
                week.compactMap { $0.hrvMetric == metric ? $0.hrvValueMs : nil }
            } ?? []
        self.hrvBaselineMetric = newestMetric
        self.hrvBaselineMs =
            hrvValues.count >= Self.minimumBaselineDays
            ? hrvValues.reduce(0, +) / Double(hrvValues.count)
            : nil

        let vo2 = self.days.compactMap(\.vo2MaxMlKgMin)
        self.vo2MaxBaselineMlKgMin =
            vo2.count >= Self.minimumBaselineDays
            ? vo2.reduce(0, +) / Double(vo2.count)
            : nil
    }

    /// The slot for a given day, for a caller holding a date rather than an index.
    ///
    /// Nil for a day outside the window rather than a nearest match: the chart's highlight band
    /// belongs on the day the user selected, and moving it to whichever slot was closest would label
    /// one day's numbers as another's.
    public func day(for date: Date) -> MetricDay? {
        let key = Calendar.current.startOfDay(for: date)
        return days.first { $0.date == key }
    }

    /// How many of the week's days carry anything at all.
    public var measuredDayCount: Int { days.filter(\.hasAnyMeasurement).count }

    /// One slot. This is where each source's absence rule is applied, and the four are not the same
    /// rule — so they are spelled out rather than shared.
    private static func makeDay(
        _ day: Date,
        strain: StrainScore?,
        recovery: RecoveryMetric?,
        sleep: SleepSession?,
        maxHeartRate: Int?,
        calendar: Calendar
    ) -> MetricDay {
        // Two of the six fields come off the one recovery row, so the flag is read once here rather
        // than twice below: an HRV and a resting heart rate are absent together when the row is a
        // placeholder, and present independently when it is not (the strap has no resting-heart-rate
        // sensor either, so a measured row can still carry no rate).
        let measured = recovery?.hasMeasurement == true
        // Gated twice, because the two can disagree: the flag is about the row, and `> 0` is the
        // reserved marker in this column specifically. A measured day whose heart rate was not
        // reported holds a `0` that is not a bpm.
        //
        // Hoisted out of the initialiser call below because **two** fields read it — the RESTING
        // HEART RATE panel prints it and the VO₂ MAX panel is computed from it. Deriving it twice is
        // how those two could come to describe different rates for one day; hoisting makes the
        // estimate reading the printed number structural rather than a coincidence to maintain.
        let restingRate = recovery.flatMap {
            $0.hasMeasurement && $0.restingHeartRate > 0 ? $0.restingHeartRate : nil
        }
        return MetricDay(
            date: day,
            // A measured day and a placeholder are both rows, so the optional says nothing about
            // whether the day was measured — the flag is the whole distinction, and a placeholder's
            // `0.0` must not become a plotted point. `CalculateStrainUseCase` no longer writes one,
            // but rows from an older build are still on disk, which is what the flag is now for.
            strain: strain.flatMap { $0.hasMeasurement ? $0.score : nil },
            // Same reserved-zero convention as strain: `hasMeasurement` is `hrvValueMs > 0`, so a
            // placeholder row's `score: 0` is not a tier, it is the absence of one.
            recoveryScore: recovery.flatMap { $0.hasMeasurement ? $0.score : nil },
            // Gated twice (see `restingRate` above), because the flag is about the row and `> 0` is
            // the reserved marker in this column specifically.
            restingHeartRate: restingRate,
            // Sleep has no placeholder: an unclassifiable night has no row, so the row's presence is
            // the measurement. The `> 0` guard covers the narrower case of a row with no need stored.
            sleepNeedSeconds: sleep.flatMap { $0.targetSleepNeedSeconds > 0 ? $0.targetSleepNeedSeconds : nil },
            // Passed straight through, like the respiratory rate and the performance below it: the
            // night's own staged minutes need no gate, and one here could only drop a point the
            // `HOURS OF SLEEP` card above the chart prints a figure for. See the property's comment.
            asleepSeconds: sleep?.totalTimeAsleepSeconds,
            // The split behind the rest of that same night, passed through the same way and for the
            // same reason: they are two more sums of staged minutes, so a gate could only drop a
            // band the chart on the sleep detail screen draws under a column it labels with their
            // total. Their sum is taken by `RestorativeSleepWeek.Point`, not here — see the
            // properties' comment for why the total is not a third field.
            deepSleepSeconds: sleep?.deepSleepSeconds,
            remSleepSeconds: sleep?.remSleepSeconds,
            // The same night's two boundaries, converted out of the calendar frame and into the
            // model's own on the way in — so the chart that draws them reads a number in the frame
            // its axis is already in, and no view has to know the noon pivot. Passed through with no
            // gate, like the three fields above and below: neither is optional on `SleepSession`, so
            // the pair is whole or absent and a gate could only drop a column the frame still labels.
            sleepOnsetMinutes: sleep.map {
                SleepConsistencyMath.nightClockMinutes($0.startTime, calendar: calendar)
            },
            sleepWakeMinutes: sleep.map {
                SleepConsistencyMath.nightClockMinutes($0.endTime, calendar: calendar)
            },
            // Passed straight through, like the respiratory rate below and unlike the need above it.
            // The `> 0` guard on the need is about *this slot's* denominator, and applying it here as
            // well would drop a bar the SLEEP PERFORMANCE row above the chart still prints — while
            // the case it would guard is unreachable on any stored night. See the property's comment.
            sleepPerformance: sleep?.sleepPerformancePercentage,
            // The same double gate as the heart rate, for the same reason: the flag is about the row
            // and `> 0` is this column's reserved marker, so a placeholder's `0.0` ms never reaches
            // the panel. `hrvMetric` is carried only alongside a value that survived the gate, so the
            // pair can never disagree — a slot with a metric and no reading is not representable.
            hrvValueMs: recovery.flatMap { $0.hasMeasurement && $0.hrvValueMs > 0 ? $0.hrvValueMs : nil },
            hrvMetric: measured && (recovery?.hrvValueMs ?? 0) > 0 ? recovery?.hrvMetric : nil,
            // Passed straight through, unlike every other field here: this column has no reserved
            // zero, so the optional is already the whole rule and a second gate could only disagree
            // with the RESPIRATORY RATE row, which reads the same value through `RecoveryMetric`
            // without one. See the property's own comment.
            respiratoryRate: recovery?.respiratoryRate,
            // Derived, not read: the day's own gated rate over the profile's assumed maximum. It
            // therefore needs no gate of its own — an absent rate, a `0` rate and a `nil`
            // `maxHeartRate` all arrive at `heartRateRatioEstimate` as `nil` and leave as `nil`. It
            // is the one field here that comes off another field of the same slot rather than off a
            // row, which is what makes the two panels beside each other incapable of disagreeing.
            vo2MaxMlKgMin: Vo2MaxMath.heartRateRatioEstimate(
                maxHeartRate: maxHeartRate, restingHeartRate: restingRate))
    }

    /// The rows keyed by their day, snapped here rather than trusting the caller.
    ///
    /// First row wins on a duplicate day. The tables cannot produce one, but a caller assembling
    /// fixtures in memory can, and picking deterministically is better than picking by dictionary
    /// order.
    private static func index<T>(_ rows: [T], by date: (T) -> Date) -> [Date: T] {
        var keyed: [Date: T] = [:]
        for row in rows {
            let key = Calendar.current.startOfDay(for: date(row))
            if keyed[key] == nil { keyed[key] = row }
        }
        return keyed
    }
}
