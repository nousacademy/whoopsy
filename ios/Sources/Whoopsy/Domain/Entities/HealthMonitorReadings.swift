import Foundation

/// The five vitals on the Health Monitor page: each night's reading, the band this app can defend, and
/// where the reading sits in it.
///
/// **This is the type `HealthMonitorCard` said did not exist yet.** The card counts *readings* and says
/// `ALL MEASURED`, because the reference's `WITHIN RANGE` was a verdict nothing here could support. The
/// page draws five of those verdicts, so the bands are built here — from the same `recoveries` history
/// every other "typical" figure on the app is taken over, and by the same arithmetic
/// (`BaselineStatisticsMath`), so a band on this page and a band on the Recovery page cannot disagree.
///
/// **The band is the mean ± one standard deviation of the prior measured days** — the same window
/// (`RecoveryScoring.baselineWindow`), the same floor (`RecoveryScoring.minimumBaselineDays`) and the
/// same spread floor (`BaselineStatisticsMath.minimumCoefficientOfVariation`) the recovery baseline
/// uses. It is *this app's* band and not WHOOP's: the reference's chips quote ranges this app cannot
/// reproduce (its own history is shorter and its own sensor is a different one), so the words say what
/// the arithmetic says rather than copying the mock's numbers.
///
/// **Blood oxygen is the exception, and it is a clinical band rather than a personal one** — 95–100 %,
/// which is the figure the reference uses too. A ±1 SD band on a metric whose whole observed range is
/// 88–100 % would call a normal 96 % "low" because the user's own nights happen to sit at 97.
public struct HealthMonitorReadings: Equatable, Sendable {

    /// One vital's reading for the night.
    public struct Reading: Equatable, Sendable, Identifiable {
        public let vital: HealthMonitorSummary.Vital

        /// The figure as the card prints it — already formatted, already signed where it is a delta.
        public let valueText: String

        /// `rpm`, `%`, `bpm`, `ms`, `°C` — the unit beside the figure.
        public let unit: String

        /// The chip: what the figure is being read against.
        public let chipText: String

        /// Whether the reading sits inside its band. **The tick is drawn from this, not from the text**,
        /// so a chip cannot read "within" on an out-of-range value.
        public let isWithin: Bool

        public var id: HealthMonitorSummary.Vital { vital }
    }

    /// The readings that could be produced, in the monitor's own order.
    public let readings: [Reading]

    /// How many prior nights the bands were taken over — what the page's footnote states.
    public let baselineNights: Int

    public init(readings: [Reading], baselineNights: Int) {
        self.readings = readings
        self.baselineNights = baselineNights
    }

    /// One night against the nights before it, or an empty set when there is no row for the night.
    ///
    /// `prior` is expected to be the stored rows *before* the night — `BaselineStatistics` is a
    /// statement about history, and a band that included the value being judged would move toward it.
    public init(recovery: RecoveryMetric?, prior: [RecoveryMetric], calendar: Calendar = .current) {
        guard let recovery else {
            self.init(readings: [], baselineNights: 0)
            return
        }

        let night = recovery.date.startOfDay
        // **The app's one window, not a second one**: strictly before the night, then capped at the
        // last `baselineWindowDays` days that have rows. A plain `filter` would have banded against
        // whatever the read returned — 118 nights on an imported history — while the Recovery page's
        // bands beside it were taken over thirty.
        let history = RecoveryScoring.baselineWindow(before: night, in: prior)
        var readings: [Reading] = []

        // HRV — milliseconds, whole.
        if recovery.hrvValueMs > 0 {
            readings.append(
                Self.personal(
                    .heartRateVariability,
                    value: recovery.hrvValueMs,
                    history: history.compactMap { $0.hrvValueMs > 0 ? $0.hrvValueMs : nil },
                    unit: "ms",
                    format: { String(format: "%.0f", $0) }))
        }

        // Resting heart rate — bpm, whole.
        if recovery.restingHeartRate > 0 {
            readings.append(
                Self.personal(
                    .restingHeartRate,
                    value: Double(recovery.restingHeartRate),
                    history: history.compactMap {
                        $0.restingHeartRate > 0 ? Double($0.restingHeartRate) : nil
                    },
                    unit: "bpm",
                    format: { String(format: "%.0f", $0) }))
        }

        // Respiratory rate — rpm, to a tenth (the two units a week spans).
        if let rate = recovery.respiratoryRate {
            readings.append(
                Self.personal(
                    .respiratoryRate,
                    value: rate,
                    history: history.compactMap(\.respiratoryRate),
                    unit: "rpm",
                    format: { String(format: "%.1f", $0) }))
        }

        // Blood oxygen — the clinical band, not a personal one. See the type's doc.
        if let oxygen = recovery.spO2Percentage {
            readings.append(Self.oxygen(oxygen))
        }

        // Skin temperature — the **delta from the personal mean**, which is the figure the reference
        // prints (`SKIN TEMP (FROM BASELINE)`), against the spread of the prior nights' own values.
        if let temperature = recovery.skinTemperatureCelsius {
            readings.append(
                Self.skinTemperature(temperature, history: history.compactMap(\.skinTemperatureCelsius)))
        }

        self.init(readings: readings, baselineNights: Self.usableNights(history))
    }

    // MARK: - One vital

    /// A personal band: mean ± one standard deviation of the prior measured days, floor three nights.
    private static func personal(
        _ vital: HealthMonitorSummary.Vital,
        value: Double,
        history: [Double],
        unit: String,
        format: @escaping (Double) -> String
    ) -> Reading {
        let stats = BaselineStatisticsMath.baseline(history, fallbackMean: 0, fallbackStdDev: 0)
        let usable = history.count >= RecoveryScoring.minimumBaselineDays
        let low = stats.mean - stats.stdDev
        let high = stats.mean + stats.stdDev

        let chipText: String
        let isWithin: Bool
        if !usable {
            // No band is a different answer from a band the night missed — the same rule every
            // "typical" figure on this app follows.
            chipText = "no typical range yet"
            isWithin = false
        } else if value < low {
            chipText = "below \(format(low)) – \(format(high))"
            isWithin = false
        } else if value > high {
            chipText = "above \(format(low)) – \(format(high))"
            isWithin = false
        } else {
            chipText = "within \(format(low)) – \(format(high))"
            isWithin = true
        }

        return Reading(
            vital: vital, valueText: format(value), unit: unit, chipText: chipText,
            isWithin: isWithin)
    }

    /// Blood oxygen against the clinical 95–100 % band, which is the one figure the reference quotes
    /// as a fixed range rather than a personal one.
    private static func oxygen(_ value: Double) -> Reading {
        let isWithin = value >= Self.oxygenFloor && value <= 100
        return Reading(
            vital: .bloodOxygen,
            valueText: String(format: "%.0f", value),
            unit: "%",
            chipText: isWithin
                ? "near \(Int(oxygenFloor))% – 100%"
                : "below \(Int(oxygenFloor))%",
            isWithin: isWithin)
    }

    /// The clinical floor, as a constant so the chip and the verdict cannot be written twice.
    public static let oxygenFloor: Double = 95

    /// The narrowest skin-temperature band the card will draw, in °C — see `skinTemperature`.
    public static let minimumSkinTemperatureBand: Double = 0.1

    /// Skin temperature as a **delta from the personal mean**, which is what the reference's
    /// `SKIN TEMP (FROM BASELINE)` card prints.
    ///
    /// **The band is the plain spread of the prior nights, floored at a tenth of a degree — not
    /// `BaselineStatisticsMath.baseline`.** That helper's coefficient-of-variation floor is 5 % of the
    /// mean, which is right for a quantity on a ratio scale (HRV in ms, heart rate in bpm) and wrong
    /// for one on an offset scale: 5 % of 34.5 °C is 1.7 °C, a band wide enough to swallow every real
    /// night-to-night movement the card exists to show. The floor here is the thermometer's own
    /// resolution instead, so a flat history still yields a band a deviation can fall outside of.
    private static func skinTemperature(_ value: Double, history: [Double]) -> Reading {
        let mean = BaselineStatisticsMath.mean(history)
        let usable = history.count >= RecoveryScoring.minimumBaselineDays
        let delta = value - mean
        let band = max(BaselineStatisticsMath.standardDeviation(history), minimumSkinTemperatureBand)
        // **Signed, except at zero.** `%+.1f` prints `-0.0` for a delta that rounds to nothing, which
        // reads as a deviation that is not there.
        let format: (Double) -> String = { value in
            let rounded = (value * 10).rounded() / 10
            return String(format: rounded == 0 ? "%.1f" : "%+.1f", rounded)
        }

        let chipText: String
        let isWithin: Bool
        if !usable {
            chipText = "no typical range yet"
            isWithin = false
        } else if delta < -band {
            chipText = "below −\(String(format: "%.1f", band))"
            isWithin = false
        } else if delta > band {
            chipText = "above +\(String(format: "%.1f", band))"
            isWithin = false
        } else {
            chipText = "within ±\(String(format: "%.1f", band))"
            isWithin = true
        }

        return Reading(
            vital: .skinTemperature, valueText: format(delta), unit: "°C", chipText: chipText,
            isWithin: isWithin)
    }

    /// Nights that carry at least one of the three optional vitals — the count the footnote states.
    ///
    /// A night with only HRV and resting rate is still a night the bands were taken over, so the count
    /// is of nights rather than of readings: five bands, one history.
    private static func usableNights(_ history: [RecoveryMetric]) -> Int {
        history.filter {
            $0.respiratoryRate != nil || $0.spO2Percentage != nil || $0.skinTemperatureCelsius != nil
        }.count
    }
}
