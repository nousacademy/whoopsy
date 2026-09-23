import Foundation

/// Incremental Strain, heart-rate and calorie accumulation for **one live session**.
///
/// This is what the deleted workout HUD should have been, and a `Core/Math` value rather than logic in
/// a `View`'s body for the reason `DayBarRules`, `MonthGrid` and `ActivityGlyph` are separate types:
/// the test runner has no renderer, so a rule written into a view is a rule nothing can assert.
///
/// **It deliberately does not reuse `CalculateStrainUseCase`.** That type reads a whole calendar day
/// out of `BiometricRepository`, recomputes the zone table from `UserProfileRepository` on every call,
/// and writes a `strains` row. Called once per sample it would hammer SQLite, write a row keyed on an
/// instant rather than on `startOfDay` — which no keyed read could then find — and score a different
/// population from the one on the screen. It uses `StrainAccumulatorMath`'s own functions instead, so
/// no zone weight, HRR boundary or value of `k` is restated here.
///
/// ### The two conventions inherited from the day model
///
/// Both are choices rather than measurements, and both exist so that the figure on this screen and the
/// figure `CalculateStrainUseCase` later writes for the same span agree:

/// 1. **The first sample's duration is exactly `1.0` second.** `CalculateStrainUseCase` writes
///    `(i > 0) ? min(5.0, Δt) : 1.0`, because the first sample in its array has no predecessor to
///    difference against. Differencing the first sample against the session's own start instant
///    instead would be *more* defensible in isolation and would make the live figure disagree with the
///    stored day figure by that one term — so the convention is copied, not improved on.
/// 2. **A gap longer than five seconds counts as five.** A strap that stopped notifying has not been
///    measuring, but the body it was on did not stop existing; five seconds is the day model's answer
///    and is not re-derived here.
///
/// ### What this figure will *not* equal
///
/// It converges exactly with `CalculateStrainUseCase` over the same span of samples, but it will not
/// equal the day's stored `strains.score`, for three reasons that are not defects: the day's read
/// includes samples from before the session started, a session crossing midnight belongs to two day
/// rows, and the day's first sample differences against the previous *stored* sample while this one's
/// takes the `1.0` above.
///
/// ### Absence
///
/// `strain` is `nil` until a sample arrives and exactly `0.0` once one arrives that never reached
/// zone 1 — the same distinction `StrainScore.hasMeasurement` draws and the same one the day model
/// makes. `calories` is `nil` whenever no body weight is on file, because the calorie estimate refuses
/// to substitute one (`UserProfile.weightKg`); a `0.0` there is a real reading of a session that never
/// rose above resting.
public struct LiveSessionAccumulator: Sendable {

    /// Everything a session screen draws, resolved once from the accumulated state.
    public struct Snapshot: Sendable, Equatable {
        /// `nil` before any sample; `0.0` once a sample has been accepted that never reached zone 1.
        public let strain: Double?
        /// The most recent accepted reading — what the `HEART RATE` figure shows.
        public let latestHeartRate: Int?
        public let averageHeartRate: Int?
        public let maxHeartRate: Int?
        /// `nil` when no body weight has been supplied. See the type's note on absence.
        public let calories: Double?
        /// Where `latestHeartRate` falls on the five-band reserve scale, as a `0…1` fraction of the
        /// scale's width — or `nil` before any reading, which is what keeps a mark off a scale that has
        /// nothing to place on it.
        ///
        /// **It is resolved here rather than in the view** for the reason the zone percentages are: the
        /// scale is the session's own zone table, and a view that rebuilt it from the profile would be
        /// a second definition of the bands. It is `nil` exactly when `latestHeartRate` is, so a caller
        /// unwraps both together and neither can be drawn without the other.
        public let bandScalePosition: Double?

        /// Seconds spent in each of the five zones, in `HeartRateZoneIndex` order.
        ///
        /// **It has no screen reader, and that is deliberate rather than an oversight.** The live
        /// session screen's bar is a *position* scale — where the current heart rate sits — and not a
        /// distribution of the session's time, so the two quantities are drawn differently and this one
        /// is drawn nowhere. It is kept, and asserted, because it is the only observable form of
        /// `zoneDurations` and therefore the only thing holding the two denominator rules below.
        public let zoneSeconds: [Double]
        /// Each zone as a whole percent of `measuredSeconds`. No screen draws this either — see
        /// `zoneSeconds`.
        ///
        /// **These sum to at most 100, never exactly 100.** Time below zone 1 is a real part of a
        /// session that belongs to no zone, which is why `WholePercentMath.wholePercents(ofSeconds:)`
        /// must not be used here: that helper makes a column sum to exactly 100, which is right when
        /// the parts partition the whole and would here claim the five bands covered the session. It is
        /// the same rule the bundled `workouts.csv` follows — its five `HR Zone n %` columns sum to at
        /// most 100, and 45 of its 673 rows read `0` in every band.
        public let zonePercents: [Double]
        public let measuredSeconds: Double
        public let sampleCount: Int

        /// The most recent readings, oldest first, capped at `LiveSessionAccumulator.recentHeartRateCapacity`.
        ///
        /// **It currently has no screen reader**, which is a state rather than a design: the live
        /// session screen's heart-rate block draws the current reading against the reserve scale and no
        /// trace, because that is the arrangement the reference shows. The buffer is kept — and
        /// asserted — because it is session state rather than screen state: it lives here rather than
        /// in a `@State` so that it survives the reader backing out and returning, which is the user's
        /// stated requirement that pressing back leaves the session recording. A screen that draws a
        /// trace again reads it with no change to this type.
        public let recentHeartRates: [Int]

        /// Whether the strap was on a body at the most recent reading, or `nil` before any reading.
        ///
        /// `nil` rather than `true`, because before a sample arrives this app knows nothing about the
        /// strap and the waveform draws a `LIVE TELEMETRY` badge off exactly this. A defaulted `true`
        /// here is the fabrication class `WhoopDevice.batteryPercentage` already documents. It is
        /// carried through from `BiometricSample.isOnBody` and is not derived from anything here.
        public let isOnBody: Bool?
    }

    /// How many readings the waveform trace keeps — one minute at the live stream's usual one per
    /// second. A bound rather than a growing array because a session is open-ended: an hour-long one
    /// at 1 Hz would otherwise hold 3,600 points that the 54-point-tall trace cannot distinguish, and
    /// it would be re-allocated on every redraw.
    public static let recentHeartRateCapacity = 60

    private let zones: [HeartRateZone]
    private let restingHeartRate: Int
    private let weightKg: Double?

    private var accumulatedLoad: Double = 0
    private var measuredSeconds: Double = 0
    private var heartRateSum: Int = 0
    private var sampleCount: Int = 0
    private var maxObservedHeartRate: Int = 0
    private var latestHeartRate: Int?
    private var latestIsOnBody: Bool?
    private var recentHeartRates: [Int] = []
    private var previousTimestamp: Date?
    private var zoneDurations: [HeartRateZoneIndex: Double] = [:]

    /// - Parameters:
    ///   - zones: the Karvonen table from `StrainAccumulatorMath.computeZones(maxHR:restHR:)`, computed
    ///     **once at session start** rather than per sample — the profile cannot change mid-session in
    ///     a way that should retroactively re-score the minutes already recorded.
    ///   - restingHeartRate: the profile's, for the calorie term only. The zones already carry it.
    ///   - weightKg: `nil` when the user has supplied none, which makes `calories` `nil` rather than `0`.
    public init(zones: [HeartRateZone], restingHeartRate: Int, weightKg: Double?) {
        self.zones = zones
        self.restingHeartRate = restingHeartRate
        self.weightKg = weightKg
    }

    /// Folds one heart-rate reading into the session.
    ///
    /// A reading of `0` or less is **refused rather than recorded**: no strap reports a zero heart
    /// rate, so such a value is a decode artefact, and admitting it would drag the average down and
    /// add a sample to `measuredSeconds` that no sensor produced. Same rule
    /// `HoursOfSleepChartSeries` applies to a `0` bpm point.
    ///
    /// - Parameter isOnBody: taken from the sample and **required, with no default**. It reaches the
    ///   screen as a badge reading either `LIVE TELEMETRY` or `STRAP OFF BODY`, so a call site that
    ///   passed a literal would be asserting something about the strap rather than reporting it —
    ///   and a default would let that happen without anyone writing it.
    public mutating func accept(heartRate: Int, at timestamp: Date, isOnBody: Bool) {
        guard heartRate > 0 else { return }

        // Convention 1 and 2 above; see the type's documentation before changing either.
        let duration: TimeInterval = previousTimestamp
            .map { min(5.0, timestamp.timeIntervalSince($0)) } ?? 1.0

        let (zoneIndex, load) = StrainAccumulatorMath.loadDelta(
            for: heartRate, zones: zones, durationSeconds: duration)

        if let zoneIndex {
            accumulatedLoad += load
            zoneDurations[zoneIndex, default: 0] += duration
        }

        measuredSeconds += duration
        heartRateSum += heartRate
        sampleCount += 1
        maxObservedHeartRate = max(maxObservedHeartRate, heartRate)
        latestHeartRate = heartRate
        latestIsOnBody = isOnBody
        previousTimestamp = timestamp

        // Drop from the front rather than truncating at read time, so the array is never longer than
        // the cap and a long session cannot grow it between redraws.
        recentHeartRates.append(heartRate)
        if recentHeartRates.count > Self.recentHeartRateCapacity {
            recentHeartRates.removeFirst(recentHeartRates.count - Self.recentHeartRateCapacity)
        }
    }

    public var snapshot: Snapshot {
        let average = sampleCount > 0 ? heartRateSum / sampleCount : nil

        return Snapshot(
            // `nil` before any sample, then a real `0.0` for a measured session that never left zone 1
            // — `calculateStrainScore` returns `0.0` for a zero load and that is the correct answer
            // here, because a sample was taken.
            strain: sampleCount > 0
                ? StrainAccumulatorMath.calculateStrainScore(from: accumulatedLoad)
                : nil,
            latestHeartRate: latestHeartRate,
            averageHeartRate: average,
            maxHeartRate: sampleCount > 0 ? maxObservedHeartRate : nil,
            calories: calories(averageHeartRate: average),
            bandScalePosition: latestHeartRate.map {
                StrainAccumulatorMath.bandScalePosition(forHeartRate: $0, zones: zones)
            },
            zoneSeconds: HeartRateZoneIndex.allCases.map { zoneDurations[$0] ?? 0 },
            zonePercents: HeartRateZoneIndex.allCases.map { percent(in: $0) },
            measuredSeconds: measuredSeconds,
            sampleCount: sampleCount,
            recentHeartRates: recentHeartRates,
            isOnBody: latestIsOnBody
        )
    }

    /// The session's calorie estimate, read through the same function the day model uses so the two
    /// cannot drift. Averaged over the session rather than integrated per sample: `CalculateStrainUseCase`
    /// passes its own average, and matching it is what makes the two comparable.
    ///
    /// `nil` — not `0` — when there is no weight or no elapsed time to divide by. `measuredSeconds == 0`
    /// is the no-samples case, where a `0.0` would read as a session that burned nothing.
    private func calories(averageHeartRate: Int?) -> Double? {
        guard let averageHeartRate, measuredSeconds > 0 else { return nil }
        return StrainAccumulatorMath.estimateCalories(
            heartRate: averageHeartRate,
            durationMinutes: measuredSeconds / 60.0,
            weightKg: weightKg,
            restingHR: restingHeartRate
        )
    }

    /// One zone as a whole percent of the session's measured span.
    ///
    /// The denominator is `measuredSeconds` and not a fabricateable sample count: a strap delivering
    /// one notification per second and one delivering one per ten seconds have measured the same
    /// *time*, and only the first would give a count that happens to look like seconds.
    private func percent(in zone: HeartRateZoneIndex) -> Double {
        guard measuredSeconds > 0 else { return 0 }
        return ((zoneDurations[zone] ?? 0) / measuredSeconds * 100).rounded()
    }
}
