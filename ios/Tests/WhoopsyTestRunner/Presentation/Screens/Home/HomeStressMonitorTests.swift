import Foundation
import SwiftUI
import Whoopsy

// MARK: - 14. The Stress Monitor — contract, series and use case

/// A file of §14's body, cut at the section's own `// ---- Title ----` boundary and
/// moved verbatim. `HomeSourceTests.run()` calls it, in the order the section ran it in.

enum HomeStressMonitorTests {
    static func run() async throws {
        // Re-declared per file rather than threaded: `Calendar.current` is a pure value,
        // so a fresh one here is the same value the section's other files hold.
        let calendar = Calendar.current

        // ---- Stress: the pure contract ----

        assertTest(StressMath.band(forScore: 0.0) == .low, "0.0 is the low band")
        assertTest(StressMath.band(forScore: 1.0) == .medium, "1.0 is the low/medium edge, in medium")
        assertTest(StressMath.band(forScore: 2.0) == .high, "2.0 is the medium/high edge, in high")
        assertTest(StressMath.band(forScore: 3.0) == .high, "3.0 is the top of the scale")

        assertTest(StressMath.score(fromActivation: -99) == 0.0, "A far-below-baseline window clamps to 0")
        assertTest(StressMath.score(fromActivation: 99) == 3.0, "A far-above-baseline window clamps to 3")
        assertTest(
            StressMath.score(fromActivation: 0) == StressMath.activationOffset,
            "Sitting exactly on the personal baseline lands on the low/medium edge")

        assertTest(
            StressMath.isResting(motionMagnitude: 1.0)
                && !StressMath.isResting(motionMagnitude: 2.0),
            "Motion separates a still window from a moving one at \(StressMath.motionCeiling) G")

        // **An unmeasured window is not a resting one, and this is the assertion that says so.** The
        // tempting reading of a missing accelerometer is "no evidence of movement, so score it" — which
        // is what the entity's old `0.0` default produced, and why a window the strap never measured
        // motion for used to pass the model's only exertion filter. `false` is the answer that costs a
        // reading instead of filing a workout as stress.
        assertTest(
            !StressMath.isResting(motionMagnitude: nil),
            "A window with no accelerometer reading is **refused**, not assumed still — the gate exists "
                + "to assert stillness and an unmeasured window has none to assert")
        assertTest(
            !StressMath.isResting(magnitudes: []),
            "…and a window holding no samples at all is refused for the same reason: nothing was "
                + "measured, so nothing was shown to be still")
        assertTest(
            !StressMath.isResting(magnitudes: [nil, nil, nil]),
            "…including a window whose samples are all present and none of which carries a magnitude")
        assertTest(
            StressMath.isResting(magnitudes: [1.0, 1.0, nil])
                && !StressMath.isResting(magnitudes: [1.0, 2.0, nil]),
            "…and the mean is taken over the samples that did measure motion, so a partial reading "
                + "neither dilutes a still window toward zero nor drags a moving one toward it")

        // The same input must score the same. Nothing here is derived from `Date()` or from a sample
        // order that the caller could vary.
        let baseline = BaselineStatisticsMath.baseline(
            [44, 47, 50, 53, 56], fallbackMean: 0, fallbackStdDev: 0)
        let heartRateBaseline = BaselineStatisticsMath.baseline(
            [58, 59, 60, 61, 62], fallbackMean: 0, fallbackStdDev: 0)
        let activated = StressMath.activation(
            rmssdMs: 30, meanHeartRate: 68,
            rmssdBaseline: baseline, heartRateBaseline: heartRateBaseline)
        let calm = StressMath.activation(
            rmssdMs: 56, meanHeartRate: 58,
            rmssdBaseline: baseline, heartRateBaseline: heartRateBaseline)
        assertTest(
            StressMath.activation(
                rmssdMs: 30, meanHeartRate: 68,
                rmssdBaseline: baseline, heartRateBaseline: heartRateBaseline) == activated,
            "The same window scores identically on every call")
        assertTest(
            activated > calm,
            "HRV below baseline with heart rate above it scores higher than the reverse — the sign "
                + "convention that makes this a stress model and not a re-skin of Strain "
                + "(\(String(format: "%.2f", activated)) vs \(String(format: "%.2f", calm)))")

        // The load-bearing guard. `calculateRMSSD` answers 0.0 for a window it cannot measure, and 0 ms
        // is not "no reading" — it is a perfectly metronomic heart, which scores as maximum stress. If
        // `AnalyzeStressUseCase` ever stops checking `minimumRRIntervals` before scoring, this is the
        // failure it would ship, and this pair of assertions is what documents it.
        assertTest(
            HeartRateVariabilityMath.calculateRMSSD(from: [800]) == 0.0,
            "RMSSD of a single interval is 0.0 — the sentinel, not a measurement")
        assertTest(
            StressMath.score(fromActivation: StressMath.activation(
                rmssdMs: 0, meanHeartRate: 60,
                rmssdBaseline: baseline, heartRateBaseline: heartRateBaseline)) == 3.0,
            "…and scoring that 0.0 reads as maximum stress, which is why a window must clear "
                + "\(StressMath.minimumRRIntervals) R-R intervals before it reaches the scorer")

        // ---- Stress: a day's series and its aggregate come out of one initialiser ----
        //
        // `StressDay` takes the windows and *derives* the figure, rather than taking both. There is no
        // parameter into which a caller could put a score belonging to another day's series — which is the
        // whole reason the Home tile's number and the Home chart's line cannot come to disagree.
        do {
            let dayStart = Date().startOfDay
            let built = StressDay(
                date: dayStart,
                windows: [
                    StressWindow(start: dayStart.addingTimeInterval(9 * 3600), score: 0.4),
                    StressWindow(start: dayStart.addingTimeInterval(10 * 3600), score: 1.8),
                    StressWindow(start: dayStart.addingTimeInterval(11 * 3600), score: 2.6),
                ])

            assertTest(
                built.score.windowCount == built.windows.count,
                "A day's window count *is* the length of its series, not a second field to keep in step")
            assertTest(
                abs(built.score.averageScore - 1.6) < 0.0000001,
                "…and its average is their mean, computed here rather than handed in "
                    + "(\(built.score.averageScore.formattedOneDecimal()))")
            assertTest(built.score.peakScore == 2.6, "…and its peak is their maximum")
            assertTest(built.score.date == dayStart, "…and it describes the day it was given")
            assertTest(
                built.windows.map(\.band) == [.low, .medium, .high],
                "…and each window bands on its own score: 0.4 low, 1.8 medium, 2.6 high — the same "
                    + "scale the chart's colour gradient is stopped on")
        }

        // ---- Stress: the use case, end to end ----

        do {
            let empty = AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore())
            let none = try await empty.execute(for: Date())
            assertTest(
                none == nil,
                "A day with no samples has no score — `nil`, because `StressScore`'s zero would read as "
                    + "perfectly calm, and this app cannot tell that from having measured nothing")

            // `AnalyzeStressUseCase` bounds its windows to waking hours in local time and keys days on
            // `Calendar.current`, so the fixture is built in the same calendar rather than in UTC. The
            // imported export's UTC-vs-device-zone hazard does not apply here: nothing is stored, so
            // there is no day key to split.
            // One five-minute window's worth of samples: 40 beats at one-second spacing, which is one
            // `StressMath.windowSeconds` bucket and therefore one scored window. `hour` is what lets a
            // fixture put several windows in one day — windows an hour apart land in different buckets,
            // windows minutes apart would not.
            func window(on offset: Int, atHour hour: Int = 9, rmssd: Double, heartRate: Int) -> [BiometricSample] {
                let day = calendar.date(byAdding: .day, value: offset, to: Date().startOfDay)!
                guard let start = calendar.date(byAdding: .hour, value: hour, to: day) else { return [] }
                // Alternating around 800 ms so the successive differences — and therefore the RMSSD —
                // are this window's `rmssd` exactly, while staying inside the 20% ectopic filter.
                let low = 800 - rmssd / 2
                let high = 800 + rmssd / 2
                return (0..<40).map { index in
                    BiometricSample(
                        timestamp: start.addingTimeInterval(Double(index)),
                        heartRate: heartRate,
                        rrIntervalMs: index.isMultiple(of: 2) ? low : high,
                        // The whole triplet: a partial one leaves the magnitude `nil` and the window is
                        // refused as unmeasured, which would make every assertion below about the motion
                        // gate instead of about the model. `Z` alone carries the gravity shell.
                        accelerometerX: 0, accelerometerY: 0, accelerometerZ: 1.0)
                }
            }

            // Five baseline days with a real spread, so the standard deviation is not zero.
            var samples: [BiometricSample] = []
            for (offset, rmssd) in [(-5, 44.0), (-4, 47.0), (-3, 50.0), (-2, 53.0), (-1, 56.0)] {
                samples += window(on: offset, rmssd: rmssd, heartRate: 60)
            }

            let activatedStore = DaytimeBiometricStore(
                samples: samples + window(on: 0, rmssd: 30.0, heartRate: 68))
            let activatedDay = try await AnalyzeStressUseCase(biometricRepository: activatedStore)
                .execute(for: Date())

            assertTest(activatedDay != nil, "A day with enough history and a still window produces a score")
            assertTest(
                activatedDay?.band == .high,
                "…and a day whose HRV fell 20 ms below baseline with heart rate 8 bpm above it is high "
                    + "(\(activatedDay.map { $0.averageScore.formattedOneDecimal() } ?? "nil"))")
            assertTest(
                (activatedDay?.windowCount ?? 0) > 0,
                "…with the number of windows that stood behind it recorded")

            // The same day, but with the day's own window removed and only the history left. The
            // baseline is still there; there is simply nothing today to score.
            let historyOnly = DaytimeBiometricStore(samples: samples)
            let noWindow = try await AnalyzeStressUseCase(biometricRepository: historyOnly)
                .execute(for: Date())
            assertTest(
                noWindow == nil,
                "A day whose samples hold no still window scores nothing, even with a full baseline")

            // ── The same day, with no accelerometer on any sample ────────────────────────────────────
            //
            // This is the live `0x2A37` path's permanent shape: the BLE layer decodes a heart rate and
            // its R-R series and no motion payload at all, so `accelerationMagnitude` is `nil` on every
            // sample a real strap produces today. The model's one exertion filter cannot be satisfied by
            // a window nothing measured, so **the day scores nothing** — the tile renders `—`, and the
            // chart draws no series.
            //
            // That is a visible consequence and it is the honest one: without motion the model cannot
            // separate a raised heart rate from work, so a number produced anyway would be a reading
            // missing its only discriminating input. Note it is the **opposite** answer to the one the
            // sleep classifier gives the same absence, and deliberately so — there the missing motion
            // test sits beside a heart-rate band that can decide alone, here the gate *is* the decision.
            func motionlessWindow(on offset: Int, atHour hour: Int = 9, rmssd: Double, heartRate: Int)
                -> [BiometricSample]
            {
                let day = calendar.date(byAdding: .day, value: offset, to: Date().startOfDay)!
                guard let start = calendar.date(byAdding: .hour, value: hour, to: day) else { return [] }
                let low = 800 - rmssd / 2
                let high = 800 + rmssd / 2
                return (0..<40).map { index in
                    BiometricSample(
                        timestamp: start.addingTimeInterval(Double(index)),
                        heartRate: heartRate,
                        rrIntervalMs: index.isMultiple(of: 2) ? low : high)
                }
            }

            var motionlessSamples: [BiometricSample] = []
            for (offset, rmssd) in [(-5, 44.0), (-4, 47.0), (-3, 50.0), (-2, 53.0), (-1, 56.0)] {
                motionlessSamples += motionlessWindow(on: offset, rmssd: rmssd, heartRate: 60)
            }
            assertTest(
                motionlessSamples.allSatisfy { $0.accelerationMagnitude == nil },
                "The fixture really carries no accelerometer on any sample, so the assertion below is "
                    + "about the absence rather than about a window that happens to be still")

            let motionlessDay = try await AnalyzeStressUseCase(
                biometricRepository: DaytimeBiometricStore(
                    samples: motionlessSamples + motionlessWindow(on: 0, rmssd: 30.0, heartRate: 68))
            ).execute(for: Date())
            assertTest(
                motionlessDay == nil,
                "…and a day that would otherwise score high produces **nothing** — no eligible window, no "
                    + "series, no chart — because the motion gate cannot be passed by a window nothing "
                    + "measured (got \(motionlessDay.map { $0.averageScore.formattedOneDecimal() } ?? "nil"))")

            // Three baseline days is the floor; two must not produce a score. Read from a day far enough
            // back that only part of the fixture's history falls inside the 14-day baseline window.
            var twoDays: [BiometricSample] = []
            for (offset, rmssd) in [(-2, 50.0), (-1, 53.0)] {
                twoDays += window(on: offset, rmssd: rmssd, heartRate: 60)
            }
            let shortHistory = DaytimeBiometricStore(
                samples: twoDays + window(on: 0, rmssd: 30.0, heartRate: 68))
            let belowFloor = try await AnalyzeStressUseCase(biometricRepository: shortHistory)
                .execute(for: Date())
            assertTest(
                belowFloor == nil,
                "Two days of history produce no score: the model is defined relative to a personal "
                    + "baseline, and \(StressMath.minimumBaselineDays) days is the fewest that has one")

            // ---- Stress: the series behind the number, which is what the Home chart draws ----
            //
            // The tile and the chart are one evaluation or they are two claims about one day, so what is
            // asserted here is the *pairing*: the aggregate is the mean of exactly the windows returned
            // beside it, and a day with no windows has neither. Nothing in this section can prove the
            // chart's drawing — that is a `Shape`, and the runner has no renderer — so what it proves is
            // the series the drawing is made of.

            let threeWindowStore = DaytimeBiometricStore(
                samples: samples
                    + window(on: 0, atHour: 9, rmssd: 30.0, heartRate: 68)
                    + window(on: 0, atHour: 10, rmssd: 40.0, heartRate: 62)
                    + window(on: 0, atHour: 11, rmssd: 52.0, heartRate: 58))
            let stressUseCase = AnalyzeStressUseCase(biometricRepository: threeWindowStore)
            let stressDay = try await stressUseCase.executeDay(for: Date())

            assertTest(
                (stressDay?.windows.count ?? 0) > 1,
                "A day with three separated still windows reports a series, not one number "
                    + "(\(stressDay?.windows.count ?? 0) windows)")

            if let stressDay {
                // The invariant `StressDay` exists to make structural: its initialiser builds the
                // aggregate *from* the windows, so the count cannot be a second opinion. A chart that drew
                // `windows` beside a `windowCount` from anywhere else is the drift this asserts against.
                assertTest(
                    stressDay.windows.count == stressDay.score.windowCount,
                    "The series and the aggregate count the same windows "
                        + "(\(stressDay.windows.count) plotted, \(stressDay.score.windowCount) counted)")

                assertTest(
                    stressDay.windows.map(\.start) == stressDay.windows.map(\.start).sorted(),
                    "…earliest first, so the line is drawn left to right")

                assertTest(
                    stressDay.windows.allSatisfy { $0.score >= 0 && $0.score <= StressMath.maximumScore },
                    "…every window inside the 0–\(StressMath.maximumScore) scale, which is the chart's "
                        + "fixed y-axis and the reason it cannot auto-scale")

                assertTest(
                    stressDay.windows.allSatisfy { $0.band == StressMath.band(forScore: $0.score) },
                    "…each window banded by the one definition, which is what colours the fill under it")

                let scores = stressDay.windows.map(\.score)
                let mean = scores.reduce(0, +) / Double(scores.count)
                assertTest(
                    abs(stressDay.score.averageScore - mean) < 0.0000001,
                    "The tile's average is the mean of the plotted windows "
                        + "(\(stressDay.score.averageScore.formattedOneDecimal()) vs "
                        + "\(mean.formattedOneDecimal()))")
                assertTest(
                    stressDay.score.peakScore == scores.max(),
                    "…and its peak is their maximum, so the caption cannot describe another day's line")
                assertTest(
                    stressDay.score.peakScore >= stressDay.score.averageScore,
                    "…and the peak is never below the average")

                // The waking window is a *domain* rule the chart has to know about, because it is what
                // decides which hours of a full-day axis can carry a line at all. Read from
                // `StressMath` rather than restated here.
                if let waking = StressMath.wakingWindow(on: Date().startOfDay) {
                    assertTest(
                        stressDay.windows.allSatisfy { waking.contains($0.start) },
                        "…and every window lands inside the waking hours this model scores, which are the "
                            + "hours the chart does not shade")
                } else {
                    assertTest(false, "The waking window could not be built for today")
                }
            } else {
                assertTest(false, "A day with three still windows produced no series")
            }

            // `execute(for:)` is a forwarder to `executeDay(for:)`, and this is the assertion that fails
            // if anyone re-implements the aggregate separately: the same fixture, read both ways, has to
            // produce the identical figure. Compared as whole `StressScore` values rather than by score,
            // so `windowCount` and `date` are covered too.
            let aggregate = try await stressUseCase.execute(for: Date())
            assertTest(
                stressDay?.score == aggregate,
                "`execute(for:)` returns exactly the aggregate of the series `executeDay(for:)` returns — "
                    + "one evaluation, two entry points")

            // A single window is the degenerate case the chart has to survive: a polyline through one
            // point draws nothing, so it is drawn as a dot, and the day's peak and average are the same
            // number by arithmetic rather than by coincidence.
            let singleDay = try await AnalyzeStressUseCase(biometricRepository: activatedStore)
                .executeDay(for: Date())
            assertTest(singleDay?.windows.count == 1, "A one-window day has a series of one")
            assertTest(
                singleDay.map { $0.score.peakScore == $0.score.averageScore } ?? false,
                "…whose peak and average are the same number, because there is only one window to "
                    + "average")

            // The anti-flat-line assertion. A day whose samples hold no eligible window must produce no
            // series at all, not an empty one — a chart handed `[]` draws nothing, but a chart handed a
            // `StressDay` with a `0.0` average would draw a flat line at zero, which is the strongest
            // possible claim of calm and the one thing this model must never say about an unmeasured day.
            let noWindowDay = try await AnalyzeStressUseCase(biometricRepository: historyOnly)
                .executeDay(for: Date())
            assertTest(
                noWindowDay == nil && noWindow == nil,
                "A day with a full baseline and no eligible window has no series *and* no score — neither "
                    + "entry point can produce a flat line at zero")
            let nothingAtAll = try await AnalyzeStressUseCase(biometricRepository: EmptyBiometricStore())
                .executeDay(for: Date())
            assertTest(
                nothingAtAll == nil,
                "…and a day with no samples at all is the same answer, which is every imported day")
        } catch {
            assertTest(false, "The stress use case threw: \(error)")
        }
    }
}
