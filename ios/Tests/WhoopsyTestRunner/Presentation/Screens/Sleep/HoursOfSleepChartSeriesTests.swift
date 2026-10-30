import Foundation
import SwiftUI
import Whoopsy

enum HoursOfSleepChartSeriesTests {
    static func run() async throws {
        // ── 8. The night's heart rate ────────────────────────────────────────────────────────────────
        //
        // The chart's whole substance is a value rather than a shape in a `body`, for the reason this file
        // exists at all: nothing in this runner has a renderer, so a line's rules are only assertable if
        // they are arithmetic. Skipped on a night the app never wrote a sample for — which is every night
        // on this machine — these are the assertions that would have said so.
        let hrDay = Calendar.current.startOfDay(for: Date())
        let hrOnset = hrDay
        let hrWake = hrDay.addingTimeInterval(7 * 3600)

        func hrSample(at seconds: TimeInterval, bpm: Int) -> BiometricSample {
            BiometricSample(timestamp: hrOnset.addingTimeInterval(seconds), heartRate: bpm)
        }

        // Two absences the screen draws as one `No Data`, and both are `nil` rather than an empty series.
        assertTest(
            HoursOfSleepChartSeries(samples: [], start: hrOnset, end: hrWake) == nil,
            "A night with no samples has no series — `nil` is the card's `No Data`, not an empty frame")
        assertTest(
            HoursOfSleepChartSeries(samples: [hrSample(at: 600, bpm: 0)], start: hrOnset, end: hrWake) == nil,
            "…nor does a night whose only samples carry a `0`: an absent reading is not a reading of zero, "
                + "which is the rule `hasMeasurement` enforces on every other metric in this app")
        assertTest(
            HoursOfSleepChartSeries(samples: [hrSample(at: 0, bpm: 60)], start: hrWake, end: hrOnset) == nil,
            "A window that is not a window is `nil` rather than a division by a negative length")
        assertTest(
            HoursOfSleepChartSeries(
                samples: [hrSample(at: 60, bpm: 50)], start: hrOnset, end: hrWake)?.runs.count == 1,
            "A night the app heard from once is one run of one point — it was measured, and refusing to "
                + "draw it would be the same fabrication as a dash over a stored reading")

        let mixed = [
            hrSample(at: 1200, bpm: 58),
            hrSample(at: 0, bpm: 54),
            hrSample(at: 600, bpm: 61),
            hrSample(at: -600, bpm: 99),
            hrSample(at: 9 * 3600, bpm: 99),
        ]
        guard let hrSeries = HoursOfSleepChartSeries(samples: mixed, start: hrOnset, end: hrWake) else {
            assertTest(false, "Three in-window samples produced no series")
            return
        }
        assertTest(
            hrSeries.points.map(\.bpm) == [54, 61, 58],
            "The points come back in time order whatever order the read handed them in "
                + "(got \(hrSeries.points.map(\.bpm)))")
        assertTest(
            hrSeries.points.count == 3,
            "…and the two samples outside the night's window are dropped rather than clamped onto its "
                + "edges, which would place a reading at a time it was not taken")

        // The gap rule, asserted as a **pair**: either half alone passes on a wrong constant. A stream
        // that never splits looks right until the day it spans a dropout, and a stream split at a
        // threshold far below the constant still splits at the constant.
        let justInside = HoursOfSleepChartSeries(
            samples: [
                hrSample(at: 0, bpm: 55),
                hrSample(at: HoursOfSleepChartSeries.maximumGapSeconds, bpm: 57),
            ],
            start: hrOnset, end: hrWake)
        assertTest(
            justInside?.runs.count == 1,
            "Two readings exactly `maximumGapSeconds` apart are one run — the boundary is inclusive, so a "
                + "live stream's own sampling interval cannot split a night that was recorded throughout")
        let justOutside = HoursOfSleepChartSeries(
            samples: [
                hrSample(at: 0, bpm: 55),
                hrSample(at: HoursOfSleepChartSeries.maximumGapSeconds + 1, bpm: 57),
            ],
            start: hrOnset, end: hrWake)
        assertTest(
            justOutside?.runs.count == 2,
            "…and one second further apart is two runs: a segment drawn across that hole is a curve "
                + "through five minutes nothing measured")
        assertTest(
            justOutside?.runs.flatMap { $0 }.count == justOutside?.points.count,
            "…and a split loses no reading — the runs partition the points rather than filtering them")

        // The axis. Fixed, never fitted to the night: the same argument `StressMonitorChartView` makes
        // for pinning its 0–3 scale, and it holds here night to night.
        assertTest(
            hrSeries.axis == .standard && HoursOfSleepChartAxis.standard.gridLines == [30, 50, 70, 90],
            "A night inside the standard bounds carries the reference's own four labels on a fixed "
                + "30–110 scale")
        assertTest(
            hrSeries.axis.fraction(30) == 0 && hrSeries.axis.fraction(110) == 1
                && TypicalRangeTests.near(hrSeries.axis.fraction(70), 0.5),
            "The scale's ends map to 0 and 1 and its midpoint to 0.5 — the mapping every shape draws "
                + "through, in one place")

        // Widening rather than clamping, in whole steps, only as far as it must — and re-anchoring the
        // labels, since a widened axis that kept the old ones would print numbers it is no longer on.
        assertTest(
            HoursOfSleepChartAxis.fit([120]).upperBound == 120
                && HoursOfSleepChartAxis.fit([120]).lowerBound == 30,
            "A peak above the standard ceiling raises the ceiling to it and leaves the floor alone")
        assertTest(
            HoursOfSleepChartAxis.fit([125]).upperBound == 130,
            "…rounding up to the next 10 bpm step rather than to the nearest, so the bound always "
                + "contains the value that forced it")
        assertTest(
            HoursOfSleepChartAxis.fit([18]).lowerBound == 10
                && HoursOfSleepChartAxis.fit([18]).gridLines.first == 10,
            "…and a trough below the floor lowers it the same way, moving the labels with it")
        assertTest(
            HoursOfSleepChartAxis.fit([]) == .standard
                && HoursOfSleepChartAxis.fit([.nan, .infinity]) == .standard,
            "Nothing finite to fit leaves the standard axis rather than an unbounded one")

        // The band mark's two rules. `BandEdges` is a `Shape`, and a `Shape`'s path is a value, so the one
        // part of the mark that is arithmetic is assertable: the rules are inset so they sit inside the
        // span they describe, a rect too small to inset draws nothing rather than inverting, and — the
        // assertion that matters most, because it is the whole of the shape — there are exactly two
        // subpaths, one at each side, and neither of them is horizontal.
        //
        // A path's elements are readable, so the count is not inferred from the bounding rect: a closed
        // rectangle inset by `(0.75, 0)` has the *same* bounding rect as these two lines do, and an
        // assertion on the rect alone would pass on the box this mark replaced.
        let field = CGRect(x: 0, y: 0, width: 40, height: 12)
        let edges = BandEdges(inset: 0.75).path(in: field)
        assertTest(
            edges.boundingRect == field.insetBy(dx: 0.75, dy: 0),
            "The typical-range band's rules are drawn inside the band's own span, so a band's edge is "
                + "painted on the band's edge rather than half a stroke outside it — and they run the "
                + "full height, because the height is the caller's overhang and not the stroke's")
        var moves = 0
        var lines = 0
        var others = 0
        edges.forEach { element in
            switch element {
            case .move: moves += 1
            case .line: lines += 1
            default: others += 1
            }
        }
        assertTest(
            moves == 2 && lines == 2 && others == 0,
            "…and it is two straight rules and nothing else — two moves, two lines, no closing segment "
                + "(got \(moves) moves, \(lines) lines, \(others) others). A top and a bottom stroke would "
                + "close the mark into a box, which is the shape this replaced, and the bounding rect "
                + "cannot tell the two apart")
        assertTest(
            BandEdges(inset: 0.75).path(in: CGRect(x: 0, y: 0, width: 1, height: 1)).isEmpty,
            "…and a rect narrower than twice its inset is empty — the guard that keeps a degenerate band "
                + "from being drawn as two rules crossed over each other")

        // ---- The draggable cursor's axis ----
        //
        // The cursor's rule is a `Shape` and its label is a `Text`; neither can be asserted. What *can*
        // be is the mapping between where the finger is and the instant the label prints, which lives on
        // the series for exactly that reason.
        if let series = HoursOfSleepChartSeries(
            samples: [hrSample(at: 0, bpm: 60), hrSample(at: 7 * 3600, bpm: 50)],
            start: hrOnset,
            end: hrWake)
        {
            assertTest(
                series.time(atFraction: 0) == hrOnset && series.time(atFraction: 1) == hrWake,
                "The cursor reads the night's own bounds at the plot's two ends — the same two instants "
                    + "the axis labels beneath print")
            assertTest(
                series.time(atFraction: 0.5) == hrOnset.addingTimeInterval(3.5 * 3600),
                "…and half way along the plot is half way through the night")
            assertTest(
                series.time(atFraction: -0.4) == hrOnset && series.time(atFraction: 1.7) == hrWake,
                "…a finger that leaves the plot is clamped rather than naming an instant the chart never "
                    + "drew — the label at the edge says the night's end, which is what the edge is")
            assertTest(
                abs(series.fraction(at: series.time(atFraction: 0.31)) - 0.31) < 0.0000001,
                "…and the inverse round-trips, so a cursor placed at a measured instant reads that "
                    + "instant back")
            assertTest(
                series.fraction(at: hrOnset.addingTimeInterval(-3600)) == 0
                    && series.fraction(at: hrWake.addingTimeInterval(3600)) == 1,
                "…clamping on the way in as well as on the way out")

            // The reading at the cursor, which is drawn at the opposite end of the rule from the
            // clock. Two properties matter and both are arithmetic: it is the *nearest* measured
            // reading, and a cursor in a hole gets none rather than one from the far side of it.
            let sparse = [
                hrSample(at: 1 * 3600, bpm: 51),
                hrSample(at: 2 * 3600, bpm: 63),
                hrSample(at: 5 * 3600, bpm: 72),
            ]
            if let sparseSeries = HoursOfSleepChartSeries(
                samples: sparse, start: hrOnset, end: hrWake)
            {
                assertTest(
                    sparseSeries.value(atFraction: 1.0 / 7.0) == 51,
                    "A cursor on a measured instant prints that reading")
                assertTest(
                    sparseSeries.value(
                        atFraction: (1.0 * 3600 + 240) / (7.0 * 3600)) == 51,
                    "…and one four minutes past it still prints it: the cursor answers with the "
                        + "nearest reading inside `maximumGapSeconds`, not with an interpolation the "
                        + "app never measured")
                assertTest(
                    sparseSeries.value(
                        atFraction: (1.0 * 3600 + 1800) / (7.0 * 3600)) == nil,
                    "…while a cursor half an hour into a hole prints **nothing**, rather than the "
                        + "nearest reading from the far side of a stretch the strap did not measure")
                assertTest(
                    sparseSeries.value(atFraction: 0) == nil
                        && sparseSeries.value(atFraction: 1) == nil,
                    "…and the night's first and last half-hour, which no sample covers, are holes too")
            } else {
                assertTest(false, "The sparse cursor fixture did not build a series")
            }
        } else {
            assertTest(false, "The cursor's fixture did not build a series")
        }
    }
}
