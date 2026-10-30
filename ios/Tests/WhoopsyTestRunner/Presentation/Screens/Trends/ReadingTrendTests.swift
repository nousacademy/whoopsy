import Foundation
import Whoopsy

// MARK: - 14. The reading trend pages' series

/// `ReadingTrend` — the never-mix rule, the comparison, the typical band and the axis, for both
/// readings the dashboard pushes (`HRV` and `RHR`).
///
/// The three things a screenshot cannot show: which metric an HRV page full of numbers is in, that
/// the comparison window is the one **before** the plotted one, and that a missing day is a gap
/// rather than a zero on the line. The last block is the RHR half, where the same arithmetic meets a
/// different extraction and the opposite direction of "better".
enum ReadingTrendTests {
    static func run() async throws {
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_790_000_000))

        func day(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: anchor) ?? anchor
        }
        func row(
            _ offset: Int,
            hrv: Double = 20,
            metric: HRVMetric = .rmssd,
            restingRate: Int = 55,
            measured: Bool = true
        ) -> RecoveryMetric {
            RecoveryMetric(
                date: day(offset),
                score: 50,
                hrvValueMs: measured ? hrv : 0,
                hrvMetric: metric,
                restingHeartRate: measured ? restingRate : 0)
        }
        func make(
            _ rows: [RecoveryMetric],
            _ period: ReadingTrend.Period,
            kind: ReadingTrend.Kind = .hrv,
            metric: HRVMetric? = nil,
            maxHeartRate: Int? = nil
        ) -> ReadingTrend {
            ReadingTrend.make(
                rows: rows, anchor: anchor, period: period, kind: kind, hrvMetric: metric,
                maxHeartRate: maxHeartRate, calendar: calendar)
        }

        // MARK: One HRV metric, decided before anything is averaged

        let mixed = make(
            [row(-2, hrv: 18, metric: .sdnn), row(-1, hrv: 60, metric: .rmssd), row(0, hrv: 20, metric: .sdnn)],
            .week)

        assertTest(
            mixed.hrvMetric == .sdnn,
            "An HRV page narrows to the metric the newest measured row carries — SDNN here — which is "
                + "`RecoveryViewModel.displayedHrvMetric`'s rule, applied before a single mean")

        assertTest(
            mixed.average == 19 && mixed.measuredDays == 2,
            "…so the RMSSD day is absent rather than mixed in: the mean is 19 over the two SDNN days, "
                + "not 32.7 over three of two different quantities "
                + "(\(String(describing: mixed.average)) over \(mixed.measuredDays))")

        assertTest(
            mixed.points.filter { $0.value != nil }.count == 2,
            "…and its day is a gap on the line, not a point on the wrong axis")

        let forced = make(
            [row(-2, hrv: 18, metric: .sdnn), row(-1, hrv: 60, metric: .rmssd)], .week, metric: .rmssd)
        assertTest(
            forced.hrvMetric == .rmssd && forced.average == 60,
            "A caller may name the metric, which is what keeps the page's own choice testable")

        // MARK: The comparison, and the band, from the window before

        let compared = make(
            [row(-9, hrv: 18), row(-8, hrv: 18), row(-7, hrv: 18), row(-6, hrv: 18), row(-1, hrv: 20)],
            .week)

        assertTest(
            compared.average == 19 && compared.previousAverage == 18,
            "The comparison is against the seven days **before** the plotted week, not against rows "
                + "inside it")
        assertTest(
            compared.percentChange == 6,
            "…rounded to the whole percent the pill prints: (19 − 18) / 18 is 6%")
        assertTest(
            compared.typicalRange != nil
                && abs((compared.typicalRange?.lowerBound ?? 0) - 18) < 0.01
                && abs((compared.typicalRange?.upperBound ?? 0) - 18) < 0.01,
            "The band is the prior window's mean ± one sample standard deviation — three identical "
                + "days give a band of 18, not a fabricated range around today's 19")

        let tooThin = make([row(-8, hrv: 18), row(-7, hrv: 17)], .week)
        assertTest(
            tooThin.typicalRange == nil,
            "…and below `minimumBaselineDays` priors there is no band at all, rather than one drawn "
                + "over two observations")

        let lone = make([row(-1, hrv: 20)], .week)
        assertTest(
            lone.average == 20 && lone.previousAverage == nil && lone.percentChange == nil,
            "A window with no measured predecessor shows its own average and no pill: a comparison "
                + "with nothing is a claim this page cannot make")

        // MARK: The axis, the gaps and the labels

        let empty = make([], .month)
        assertTest(
            empty.points.count == 30 && empty.average == nil && empty.measuredDays == 0,
            "A month is thirty slots ending on the anchor, with no average when nothing was measured")
        assertTest(
            empty.axisMaximum - empty.axisMinimum >= ReadingTrend.minimumAxisSpan,
            "…and an axis wide enough to draw, so an empty window keeps the page's shape")

        assertTest(
            compared.axisTicks.count == 5
                && compared.axisTicks == compared.axisTicks.sorted()
                && compared.axisTicks.first == compared.axisMinimum
                && compared.axisTicks.last == compared.axisMaximum,
            "Five ascending gridlines covering the axis exactly (\(compared.axisTicks))")

        assertTest(
            compared.axisMinimum <= 18 && compared.axisMaximum >= 20
                && compared.axisMinimum <= Int((compared.typicalRange?.lowerBound ?? 0).rounded(.down)),
            "The axis covers the readings **and** the band — a band clipped off the plot cannot be "
                + "read against anything")

        assertTest(
            empty.labelIndices.count == 5 && empty.labelIndices.first == 0
                && empty.labelIndices.last == 29,
            "Five dates under a thirty-day window, first and last included "
                + "(\(empty.labelIndices))")

        // MARK: The other reading: resting heart rate

        let rhr = make(
            [row(-8, restingRate: 52), row(-7, restingRate: 54), row(-6, restingRate: 50),
             row(-5, restingRate: 0, measured: false), row(0, restingRate: 56)],
            .week, kind: .restingHeartRate)

        assertTest(
            rhr.kind == .restingHeartRate && rhr.hrvMetric == nil,
            "The same type plots the resting rate, and it narrows to no HRV metric — there is only "
                + "one quantity to draw")
        assertTest(
            rhr.average == 53 && rhr.measuredDays == 2,
            "…reading `restingHeartRate` rather than the HRV column, and dropping a row that measured "
                + "nothing — whose zero is a placeholder, not a rate "
                + "(\(String(describing: rhr.average)) over \(rhr.measuredDays))")
        assertTest(
            rhr.previousAverage == 53,
            "…and its comparison window is the week before, read the same way — 52 and 54 average to "
                + "53 (\(String(describing: rhr.previousAverage)))")
        assertTest(
            ReadingTrend.Kind.restingHeartRate.higherIsBetter == false
                && ReadingTrend.Kind.hrv.higherIsBetter == true,
            "A resting-rate rise is not the good direction — the one thing the two pages must not "
                + "share, and what colours the pill")
        assertTest(
            ReadingTrend.Kind.restingHeartRate.unit == "bpm" && ReadingTrend.Kind.hrv.unit == "ms",
            "…and each page names its own unit, so a figure is never read as the other's quantity")

        // MARK: VO₂ max — the one estimate

        let vo2 = make(
            [row(-8, restingRate: 52), row(-7, restingRate: 60), row(-6, restingRate: 0, measured: false),
             row(0, restingRate: 52)],
            .week, kind: .vo2Max, maxHeartRate: 190)

        let expected = 15.3 * 190.0 / 52.0
        assertTest(
            abs((vo2.points.last?.value ?? 0) - expected) < 0.001,
            "The VO₂ page derives each day exactly as `MetricWeek` derives the panel's figure — "
                + "15.3 × the profile's maximum over the day's resting rate "
                + "(got \(String(describing: vo2.points.last?.value)), expected \(expected))")

        assertTest(
            vo2.measuredDays == 1 && vo2.average != nil,
            "…over the days that produced one, dropping the placeholder row in the window "
                + "(\(vo2.measuredDays) day)")

        let priorMean = (15.3 * 190.0 / 52.0 + 15.3 * 190.0 / 60.0) / 2
        assertTest(
            abs((vo2.previousAverage ?? 0) - priorMean) < 0.001,
            "…and its comparison window is the same seven days before, in the same estimate — "
                + "(\(String(describing: vo2.previousAverage)), expected \(priorMean))")

        let noMaximum = make([row(-1, restingRate: 52)], .week, kind: .vo2Max, maxHeartRate: nil)
        assertTest(
            noMaximum.average == nil && noMaximum.measuredDays == 0,
            "A profile this app could not read leaves the page empty rather than anchored to an "
                + "invented maximum — the panel's own rule, applied to the trend")

        assertTest(
            ReadingTrend.Kind.vo2Max.isEstimate
                && !ReadingTrend.Kind.hrv.isEstimate
                && !ReadingTrend.Kind.restingHeartRate.isEstimate,
            "…and only VO₂ max is flagged an estimate, which is what makes the page state its "
                + "derivation and error bar instead of presenting it as a reading")
        assertTest(
            ReadingTrend.Kind.vo2Max.unit == "mL/kg/min"
                && ReadingTrend.Kind.vo2Max.higherIsBetter,
            "The VO₂ unit is the model's own, and a rise is the good direction")
    }
}
