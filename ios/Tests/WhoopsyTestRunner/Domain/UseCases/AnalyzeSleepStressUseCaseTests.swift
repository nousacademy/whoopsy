import Foundation
import Whoopsy

enum AnalyzeSleepStressUseCaseTests {
    static func run() async throws {
        // ── 12. The night's activation ───────────────────────────────────────────────────────────────
        //
        // `AnalyzeSleepStressUseCase` reads `biometric_samples.rrIntervalsMs`, and on this machine that
        // table holds no rows in any database: no strap has ever been connected, and the export carries no
        // R-R series at all. So there is no night in this app's possession where a known activation and
        // the beats that produced it are both present, and every fixture below is **synthetic** — §13's
        // RSA block's shape and its reason. What is asserted is the model's plumbing and its rules; none
        // of it is evidence that a real strap's beats produce a meaningful figure.
        //
        // The heart rates are set explicitly rather than derived from the intervals. A real notification's
        // `heartRate` is `60000 / rr` and would move with the beat pattern, so the contiguity fixture
        // below — which deliberately puts two different beat levels inside one window — would move two
        // variables at once. The model reads the column, so pinning it isolates the R-R handling, which is
        // the thing under test.
        do {
            let window = StressMath.windowSeconds
            let origin = Date(timeIntervalSinceReferenceDate: 0)

            func session(onset: Date, buckets: Int) -> SleepSession {
                SleepSession(
                    date: onset,
                    startTime: onset,
                    endTime: onset.addingTimeInterval(Double(buckets) * window))
            }

            /// `count` R-R intervals alternating about `level`, so RMSSD is exactly `modulation`.
            ///
            /// Every successive difference is ±`modulation`, so the mean of their squares is
            /// `modulation²`. Alternating rather than random because the value has to be a number this
            /// file can name: `filterRRIntervals`' ectopic check compares each interval with the local
            /// median, and a ±6.7% alternation clears it with room to spare, where a random series would
            /// drop some intervals and give an RMSSD that depends on the seed.
            func beats(level: Double = 600, modulation: Double = 40, count: Int = 25) -> [Double] {
                (0..<count).map { $0.isMultiple(of: 2) ? level : level + modulation }
            }

            /// One notification: one arrival instant, one pulse reading, one contiguous run of beats.
            ///
            /// `motion` is the **magnitude**, so it is carried on one axis with the other two at zero —
            /// and it defaults to 1.0 rather than 0, because 0 G is free fall and a fixture that meant "a
            /// strap lying still" must say so with the gravity shell it really has. That default was 0.0
            /// until the accel fields became optional, and it was doing the same job through the
            /// fabricated free-fall value: this fixture is a *resting* strap unless it says otherwise.
            /// The triplet is all-or-nothing, so a partial one would leave the magnitude `nil` and every
            /// window here would be refused as unmeasured — the gate would be what the block measured.
            func notification(
                at time: Date,
                heartRate: Int,
                intervals: [Double],
                motion: Double = 1.0
            ) -> BiometricSample {
                BiometricSample(
                    timestamp: time,
                    heartRate: heartRate,
                    rrIntervalsMs: intervals,
                    accelerometerX: motion, accelerometerY: 0, accelerometerZ: 0)
            }

            // ── The arithmetic, which needs no use case at all ───────────────────────────────────────

            let arithmeticSpan = origin..<origin.addingTimeInterval(Double(200) * window)

            /// A night built from hand-made windows. The scores sit squarely inside their bands rather
            /// than on an edge, so this fixture is about the share column and not about
            /// `band(forScore:)`'s exclusive-bottom rule as well.
            func night(high: Int, medium: Int, low: Int) -> SleepStressNight? {
                var windows: [StressWindow] = []
                for _ in 0..<high { windows.append(StressWindow(start: origin, score: 2.5)) }
                for _ in 0..<medium { windows.append(StressWindow(start: origin, score: 1.5)) }
                for _ in 0..<low { windows.append(StressWindow(start: origin, score: 0.5)) }
                return SleepStressNight(
                    date: origin, span: arithmeticSpan, windows: windows, baselineNightCount: 14)
            }

            // The discriminating split. 67/67/66 of 200 is 33.5/33.5/33, which naive rounding prints as
            // 34/34/33 — a column summing to 101 under a header that names a total. Largest-remainder
            // gives the spare point to the first of the two .5 remainders.
            let split = night(high: 67, medium: 67, low: 66)
            assertTest(
                split?.bands.map(\.percent) == [34, 33, 33],
                "A 67/67/66 split prints 34/33/33 and not naive rounding's 34/34/33, which sums to 101 "
                    + "(got \(String(describing: split?.bands.map(\.percent))))")
            assertTest(
                split?.bands.map(\.percent).reduce(0, +) == 100,
                "…and the three shares the card prints add up to the 100% they are shares of")
            assertTest(
                split?.highPercent == 34,
                "…and the headline is the high row's own figure rather than a second computation of it")

            assertTest(
                split?.bands.map(\.durationSeconds) == [67 * window, 67 * window, 66 * window],
                "Each band's duration is the windows it scored times the model's own window length — not a "
                    + "span reverse-engineered to match a figure this model never computed")
            assertTest(
                split?.scoredSeconds == 200 * window,
                "…and the scored span those shares are of is the whole windows the night divided into")
            assertTest(
                split?.bands.reduce(0) { $0 + $1.durationSeconds } == split?.scoredSeconds,
                "The three durations add up to the `SCORED` figure the card's header names, which is the "
                    + "identity a reader checking the column on screen would find")
            assertTest(
                split?.score.windowCount == split?.windows.count,
                "The aggregate's window count is the series' own, so the two cannot be handed in disagreeing")

            assertTest(
                night(high: 0, medium: 1, low: 1)?.bands.map(\.percent) == [0, 50, 50],
                "A band the night never entered is a real 0% — the one place in this app where a zero is "
                    + "the reading rather than a reserved placeholder")

            assertTest(
                SleepStressNight(date: origin, span: arithmeticSpan, windows: [], baselineNightCount: 14)
                    == nil,
                "A night with no scored window has no card at all, rather than three 0% rows over an "
                    + "unnamed total — which is the strongest possible claim of calm")
            assertTest(
                SleepStressNight(
                    date: origin, span: origin..<origin,
                    windows: [StressWindow(start: origin, score: 1)], baselineNightCount: 14) == nil,
                "…and a zero-length span is refused, because the shares are a division")

            // The series, which is what the chart is drawn from.
            let splitSeries = split.flatMap { SleepStressChartSeries(night: $0) }
            assertTest(
                splitSeries?.runs.count == 1,
                "Windows one window apart are one run — the line is unbroken where the record is "
                    + "(got \(String(describing: splitSeries?.runs.count)) runs)")

            let gapped = SleepStressNight(
                date: origin,
                span: origin..<origin.addingTimeInterval(20 * window),
                windows: [
                    StressWindow(start: origin, score: 1.5),
                    StressWindow(start: origin.addingTimeInterval(window), score: 1.5),
                    StressWindow(start: origin.addingTimeInterval(5 * window), score: 1.5),
                ],
                baselineNightCount: 14)
            let gappedSeries = gapped.flatMap { SleepStressChartSeries(night: $0) }
            assertTest(
                gappedSeries?.runs.map(\.points.count) == [2, 1],
                "A window missing in between ends the run and starts another, because an ineligible "
                    + "window is unmeasured and joining across it draws a reading nobody took "
                    + "(got \(String(describing: gappedSeries?.runs.map(\.points.count))))")
            assertTest(
                gappedSeries?.runs.last?.points.first?.timeFraction == 0.25,
                "…and the axis is the night's own span: a window a quarter of the way in sits at 0.25, "
                    + "not at a clock position on a 24-hour day")

            // ── The use case, against synthetic tachograms ───────────────────────────────────────────

            let baselineValues: [(modulation: Double, heartRate: Int)] = [(30, 54), (40, 60), (50, 66)]
            let baselineOnsets = (1...3).map { origin.addingTimeInterval(-Double($0) * 86400) }
            let baselineNights = baselineOnsets.map { session(onset: $0, buckets: 1) }
            let baselineSamples = zip(baselineOnsets, baselineValues).map { onset, value in
                notification(
                    at: onset.addingTimeInterval(10),
                    heartRate: value.heartRate,
                    intervals: beats(modulation: value.modulation))
            }
            // The three nights give RMSSD 30/40/50 and a pulse of 54/60/66, so the baseline is a mean of
            // 40 ms and 60 bpm with a sample spread of 10 and 6 — real numbers rather than a flat series.
            //
            // **The pulse spread is 6 and not 2, and that is the fixture's one non-obvious choice.**
            // `BaselineStatisticsMath.baseline` floors a spread at
            // `minimumCoefficientOfVariation × the mean`, so a three-night pulse spread of 2 bpm around a
            // mean of 60 is below the 3 bpm floor and the *floor* becomes the denominator. Every z-score
            // below would then be taken against 3 rather than 2, and the window that should score 2.0
            // scores 1.667 — which is what this fixture asserted before the floor was accounted for.
            // A spread of 6 clears the floor, so the arithmetic below is the model's own.

            /// One waking afternoon per baseline night, an hour past the night's own end.
            ///
            /// This is the population the **daytime** model scores and this one must not: a night's
            /// baseline is drawn from prior nights, so these exist to be folded in by a read that reaches
            /// wider than a night's own in-bed span — the calendar day, or the whole fourteen-night range
            /// in one go — and to move the baseline when it does.
            let decoys = baselineOnsets.map {
                notification(
                    at: $0.addingTimeInterval(3600), heartRate: 120, intervals: beats(modulation: 5))
            }

            let tonight = session(onset: origin, buckets: 2)
            let tonightSamples = [
                notification(
                    at: origin.addingTimeInterval(10), heartRate: 60, intervals: beats(modulation: 40)),
                // Two notifications in one window, at two different beat levels. The join between them is
                // 300 ms of unaccounted time — the beats either side were never adjacent — and RMSSD has
                // to be taken within each run rather than across it.
                notification(
                    at: origin.addingTimeInterval(310), heartRate: 72,
                    intervals: beats(level: 600, modulation: 40)),
                notification(
                    at: origin.addingTimeInterval(400), heartRate: 72,
                    intervals: beats(level: 900, modulation: 40)),
            ]

            func run(
                _ night: SleepSession, _ priors: [SleepSession], _ samples: [BiometricSample]
            ) async -> SleepStressNight? {
                do {
                    return try await AnalyzeSleepStressUseCase(
                        biometricRepository: OvernightBiometricStore(samples: samples)
                    ).execute(for: night, priorNights: priors)
                } catch {
                    assertTest(false, "The night model threw: \(error)")
                    return nil
                }
            }

            let scored = await run(
                tonight, baselineNights, tonightSamples + baselineSamples + decoys)

            assertTest(
                scored?.windows.count == 2,
                "Both of a two-window night's windows are scored "
                    + "(got \(String(describing: scored?.windows.count)))")
            assertTest(
                scored?.windows.first?.score == 1.0,
                "A window sitting exactly on the personal baseline scores 1.0 — the low/medium edge, "
                    + "which is what makes the baseline relative (got "
                    + "\(String(describing: scored?.windows.first?.score)))")

            // The contiguity rule, driven from both ends. The pair below is the fixture's own control:
            // it proves the two arrangements really do differ before the night asserts that they do not.
            let runA = beats(level: 600, modulation: 40)
            let runB = beats(level: 900, modulation: 40)
            let perRun = HeartRateVariabilityMath.calculateRMSSD(fromRuns: [runA, runB])
            let pooled = HeartRateVariabilityMath.calculateRMSSD(fromRuns: [runA + runB])
            assertTest(
                abs(perRun - 40) < 1e-9,
                "Two runs of beats alternating ±40 ms have an RMSSD of 40 ms when each run is differenced "
                    + "on its own (got \(perRun))")
            assertTest(
                pooled > 50,
                "…and \(pooled) ms when the seam between them is differenced as though the beats were "
                    + "adjacent, which is the defect `AnalyzeStressUseCase` still has and this model must "
                    + "not inherit")
            assertTest(
                scored?.windows.last?.score == 2.0,
                "…so the second window scores its own 2.0 — 40 ms of HRV at 72 bpm against a baseline of "
                    + "40 ms at 60 — rather than the lower figure the pooled 58 ms would give it (got "
                    + "\(String(describing: scored?.windows.last?.score)))")
            assertTest(
                scored?.windows.first?.score != scored?.windows.last?.score,
                "…which is a different figure from the first window's, so the assertion above is not "
                    + "satisfied by a model that returns one constant for every window")

            assertTest(
                scored?.windows.allSatisfy {
                    $0.start >= tonight.startTime && $0.start < tonight.endTime
                } == true,
                "Every window is anchored inside the night's own in-bed span, which is what the night "
                    + "bucketing buys over the day model's first-sample anchor")
            assertTest(
                scored?.bands.map(\.percent) == [50, 50, 0],
                "The night's two windows split evenly across the high and medium bands "
                    + "(got \(String(describing: scored?.bands.map(\.percent))))")

            // ── The baseline is drawn from nights, and from their in-bed spans ────────────────────────

            let dayWide = try? await OvernightBiometricStore(samples: decoys).getSamples(
                from: baselineNights[0].startTime,
                to: baselineNights[0].startTime.addingTimeInterval(7200))
            assertTest(
                dayWide?.count == 1,
                "The decoys are really there: a read two hours wide around a baseline night returns one "
                    + "(got \(String(describing: dayWide?.count)))")

            let withoutDecoys = await run(tonight, baselineNights, tonightSamples + baselineSamples)
            assertTest(
                withoutDecoys?.windows.map(\.score) == scored?.windows.map(\.score),
                "…and an hour of waking samples sitting just outside each baseline night's own span "
                    + "moves nothing, so the baseline is drawn from those nights rather than from the "
                    + "days they fall in")

            // ── The gates, one window each ───────────────────────────────────────────────────────────

            let gatedOnset = origin.addingTimeInterval(86400 * 10)
            let gated = session(onset: gatedOnset, buckets: 5)
            let gatedSamples = [
                notification(
                    at: gatedOnset.addingTimeInterval(10), heartRate: 60,
                    intervals: beats(count: 10)),
                notification(
                    at: gatedOnset.addingTimeInterval(310), heartRate: 60,
                    intervals: Array(repeating: 600, count: 25)),
                notification(
                    at: gatedOnset.addingTimeInterval(610), heartRate: 60,
                    intervals: beats(modulation: 40), motion: 2.0),
                notification(
                    at: gatedOnset.addingTimeInterval(910), heartRate: 0,
                    intervals: beats(modulation: 40)),
                notification(
                    at: gatedOnset.addingTimeInterval(1210), heartRate: 60,
                    intervals: beats(modulation: 40)),
            ]

            let gatedNight = await run(gated, baselineNights, gatedSamples + baselineSamples)
            assertTest(
                gatedNight?.windows.count == 1,
                "Of five windows only the control is scored: ten intervals is under "
                    + "`minimumRRIntervals`, a metronomic run is a zero RMSSD and is refused because a "
                    + "zero scores as *maximum* stress, a moving strap is not still, and a sample with no "
                    + "pulse reading contributes no heart rate "
                    + "(got \(String(describing: gatedNight?.windows.count)))")
            assertTest(
                gatedNight?.windows.first?.start == gatedOnset.addingTimeInterval(4 * window),
                "…and it is the fifth bucket, so each gate refused exactly its own window rather than "
                    + "the window after it")

            let everyWindowRefused = await run(
                gated, baselineNights, Array(gatedSamples.prefix(4)) + baselineSamples)
            assertTest(
                everyWindowRefused == nil,
                "A night whose every window is ineligible is the same absent answer as one with no "
                    + "samples at all, and not a flat line at zero")

            // ── The span, at both edges and in both directions ────────────────────────────────────────

            let capped = session(onset: origin, buckets: 192)
            assertTest(
                capped.endTime.timeIntervalSince(capped.startTime)
                    == AnalyzeSleepStressUseCase.maximumNightSpanSeconds,
                "The fixture below is a night of exactly `maximumNightSpanSeconds`")
            assertTest(
                await run(capped, baselineNights, tonightSamples + baselineSamples) != nil,
                "A night of exactly sixteen hours is scored")
            let overCap = SleepSession(
                date: origin, startTime: origin,
                endTime: origin.addingTimeInterval(
                    AnalyzeSleepStressUseCase.maximumNightSpanSeconds + 3600))
            assertTest(
                await run(overCap, baselineNights, tonightSamples + baselineSamples) == nil,
                "…and one an hour past it is skipped rather than clamped. Its samples are inside the "
                    + "span, so this `nil` is the length guard and not an empty read: clamping would "
                    + "describe the first sixteen hours of something that is not a night and print the "
                    + "result as one")

            let backwards = SleepSession(
                date: origin, startTime: origin.addingTimeInterval(600), endTime: origin)
            assertTest(
                await run(backwards, baselineNights, tonightSamples + baselineSamples) == nil,
                "A session that ends before it begins has no span to score")

            // The span is the night's own and cannot be the day's: `StressMath.wakingWindow` is
            // 06:00–22:00 and exists to *exclude* sleep, which is the whole reason this model exists
            // beside the Stress Monitor.
            let localDay = Calendar.current.startOfDay(for: origin)
            let evening = Calendar.current.date(byAdding: .hour, value: 22, to: localDay)
                ?? localDay.addingTimeInterval(22 * 3600)
            let overnight = session(onset: evening, buckets: 32)
            let overnightSamples = [
                notification(
                    at: evening.addingTimeInterval(10), heartRate: 60, intervals: beats(modulation: 40))
            ]
            assertTest(
                await run(overnight, baselineNights, overnightSamples + baselineSamples) != nil,
                "A night beginning at 22:00 is scored — the sleep period the daytime model's own window "
                    + "cannot express, since it returns a range within one calendar day")
            assertTest(
                StressMath.wakingWindow(on: localDay)
                    .map { $0.contains(evening.addingTimeInterval(10)) } == false,
                "…and that instant is outside 06:00–22:00, so this card scores the hours the Stress "
                    + "Monitor throws away rather than a second reading of the ones it keeps")

            // ── The baseline floor, at both edges ─────────────────────────────────────────────────────

            assertTest(
                await run(
                    tonight, Array(baselineNights.prefix(2)), tonightSamples + baselineSamples) == nil,
                "Two prior nights is below `StressMath.minimumBaselineDays`. A score here is a z-score "
                    + "and a z-score is defined relative to a personal baseline, so below the floor the "
                    + "honest answer is no score rather than one against a default")
            assertTest(
                scored != nil,
                "…and three prior nights is the first night that produces one, which is the other edge "
                    + "of the same floor")

            // ── Absence ──────────────────────────────────────────────────────────────────────────────

            assertTest(
                await run(tonight, baselineNights, baselineSamples) == nil,
                "A night the strap recorded nothing for is absent — no card rather than a 0% one")

            // ── The card's own words ─────────────────────────────────────────────────────────────────
            //
            // The runner has no renderer, so the card's drawing is unasserted; its strings are statics
            // for this reason and are asserted here.

            if let scored {
                assertTest(
                    SleepStressCard.spokenHeading(night: scored)
                        == "Sleep stress, 50 percent of the scored night in the high band, 0h 10m scored",
                    "The card's spoken heading names the figure, the band it is the share of, and the "
                        + "denominator the shares are of (got "
                        + "\"\(SleepStressCard.spokenHeading(night: scored))\")")
                assertTest(
                    SleepStressCard.spokenBandRow(scored.bands[0])
                        == "High, 50 percent of the scored night, 0h 5m",
                    "…and a row names its own band, says what the share is a share *of*, and gives its "
                        + "duration in the spoken form rather than the compact one printed on screen "
                        + "(got \"\(SleepStressCard.spokenBandRow(scored.bands[0]))\")")
            }
            assertTest(
                SleepStressCard.baselineNote(baselineNightCount: 14) == "Baseline: 14 prior nights",
                "…and the footer says how much history the score above it rests on, which is the "
                    + "difference between a 0% read against three nights and the same 0% against fourteen")
            assertTest(
                SleepStressCard.baselineNote(baselineNightCount: 1) == "Baseline: 1 prior night",
                "…in the singular at one, which the floor makes unreachable through the use case and "
                    + "which is stated anyway so the sentence is right at every input")

        }
    }
}
