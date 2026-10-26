import Foundation
import Whoopsy

// MARK: - 25. The Strain model: motion, provenance and the refresh

/// The Strain day model with its motion term, the watermark that keeps it current, the formula every
/// row now records, and the session-RPE rating.
///
/// **Nothing in this section is evidence about hardware.** `biometric_samples` holds no rows in any
/// database on this machine, so the day model is exercised from fixtures here; what is proved is the
/// arithmetic, the partition rule, the persistence shape and the refresh's decisions.

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
///
/// The blocks live in sibling files, one per topic, cut at this section's own `// MARK:` boundaries.
enum StrainTests {
    static func run() async throws {
        try await MotionEpochGridTests.run()
        try await MotionLoadMathTests.run()
        try await StrainDayMathTests.run()
        try await CalculateStrainUseCaseTests.run()
        try await RefreshStrainUseCaseTests.run()
        try await StrainProvenancePersistenceTests.run()
        try await StrainWireMapperTests.run()
        try await WorkoutRPETests.run()
        try await ActivityEditDraftRPETests.run()
    }
}

// MARK: - Shared fixtures

extension StrainTests {
    /// The day every block anchors on, snapped so a day key and a stored instant agree.
    static var day: Date { Date(timeIntervalSince1970: 1_790_000_000).startOfDay }

    /// A day of one-second samples at a constant rate, starting at `start`.
    static func samples(
        from start: Date,
        count: Int,
        heartRate: Int,
        interval: TimeInterval = 1
    ) -> [BiometricSample] {
        (0..<count).map { index in
            BiometricSample(
                timestamp: start.addingTimeInterval(Double(index) * interval),
                heartRate: heartRate)
        }
    }

    /// A full 30-second window at one magnitude, on the grid.
    static func epoch(at start: Date, magnitude: Double) -> MotionEpoch {
        MotionEpoch(
            start: MotionEpochGrid.start(for: start),
            end: MotionEpochGrid.start(for: start).addingTimeInterval(30),
            meanMagnitudeG: magnitude,
            maxMagnitudeG: magnitude,
            sampleCount: 3_000)
    }
}

// MARK: - The day model

enum StrainDayMathTests {
    /// The profile every block scores against: 190 max, 60 resting, so the five reserve bands land on
    /// 125 / 138 / 151 / 164 / 177 bpm boundaries. A rate of 170 is zone 4 (weight 9) and 70 is above
    /// resting but under zone 1 (the weight-1 low band).
    static let maxHeartRate = 190
    static let restingHeartRate = 60

    static func run() async throws {
        let start = StrainTests.day.addingTimeInterval(9 * 3600)

        // ---- The refactor pin: no epochs must be bit-identical to the old algorithm ----
        var samples = StrainTests.samples(from: start, count: 3_600, heartRate: 70)
        samples += StrainTests.samples(
            from: start.addingTimeInterval(3_600), count: 300, heartRate: 170)

        guard let hrOnly = StrainDayMath.compute(
            samples: samples, epochs: [], maxHeartRate: maxHeartRate,
            restingHeartRate: restingHeartRate)
        else {
            assertTest(false, "A day with samples produces a result")
            return
        }
        let legacy = legacyLoad(samples: samples)
        assertTest(
            hrOnly.rawAccumulatedLoad == legacy,
            "A day with no motion epochs integrates bit-identically to the pre-motion algorithm "
                + "(\(hrOnly.rawAccumulatedLoad) vs \(legacy))")
        assertTest(
            hrOnly.score == StrainAccumulatorMath.calculateStrainScore(from: legacy),
            "…and scores on the same curve, got \(hrOnly.score)")
        assertTest(
            hrOnly.motionLoad == 0,
            "…with a motion term of exactly zero rather than an invented figure")
        // The zone block is the same interval rule expressed a second way here, so it needs its own
        // pin: 3,600 one-second samples at 70 bpm earn the low band and no zone, and the 300 at 170
        // are zone 4. Without this a delegation regression in the fold would move no assertion.
        assertTest(
            hrOnly.zones.first(where: { $0.index == .zone4 })?.durationSeconds == 300
                && hrOnly.zones.filter { $0.index != .zone4 }
                    .allSatisfy { $0.durationSeconds == 0 },
            "…and the day's zone times are the same fold: 300 seconds in zone 4 and nothing in the "
                + "other four, because the first 3,600 samples sat above resting but under zone 1 "
                + "(\(hrOnly.zones.map(\.durationSeconds)))")

        // ---- An elevated window is scored by heart rate, not by heart rate plus motion ----
        let burst = StrainTests.samples(from: start, count: 60, heartRate: 170)
        let alongside = StrainTests.epoch(at: start, magnitude: 1.07)   // walking weight, 60 load
        guard let dominated = StrainDayMath.compute(
            samples: burst, epochs: [alongside], maxHeartRate: maxHeartRate,
            restingHeartRate: restingHeartRate),
            let burstAlone = StrainDayMath.compute(
                samples: burst, epochs: [], maxHeartRate: maxHeartRate,
                restingHeartRate: restingHeartRate)
        else {
            assertTest(false, "A day with an epoch produces a result")
            return
        }
        assertTest(
            dominated.rawAccumulatedLoad == burstAlone.rawAccumulatedLoad,
            "A window whose heart-rate load beats its motion load is unchanged by the epoch "
                + "(\(dominated.rawAccumulatedLoad) vs \(burstAlone.rawAccumulatedLoad))")
        assertTest(
            dominated.motionLoad > 0,
            "…and the motion term is still recorded, so the audit figure says what was measured")

        // ---- Motion fills a window the heart rate did not ----
        //
        // Ten minutes of resting heart rate against ten minutes of vigorous motion: every window's
        // heart-rate load is zero, so the whole day is the wrist's 20 × 120 weighted seconds.
        let resting = StrainTests.samples(from: start, count: 600, heartRate: 60)
        let vigorousWindows = (0..<20).map { index in
            StrainTests.epoch(at: start.addingTimeInterval(Double(index) * 30), magnitude: 1.30)
        }
        guard let filled = StrainDayMath.compute(
            samples: resting, epochs: vigorousWindows, maxHeartRate: maxHeartRate,
            restingHeartRate: restingHeartRate)
        else {
            assertTest(false, "A resting day with motion still produces a result")
            return
        }
        assertTest(
            filled.rawAccumulatedLoad == 2_400,
            "Ten resting minutes take the motion's 20 × 120 weighted seconds, got "
                + "\(filled.rawAccumulatedLoad)")
        assertTest(
            filled.score > 0,
            "…so a day of manual work under the HR bands scores above zero, got \(filled.score)")

        // ---- A partition, not two sums ----
        //
        // Window A: four samples at zone-4 rate (36 HR load) against 60 motion load → 60.
        // Window B: four samples at the low band (3 HR load, plus 5 s of the gap credited to A)
        //           against 120 motion load → 120.
        // The partition is 180; adding the two terms would give 220 and double-count every moving
        // minute of exercise.
        var partitioned = StrainTests.samples(from: start, count: 4, heartRate: 170)
        partitioned += StrainTests.samples(
            from: start.addingTimeInterval(60), count: 4, heartRate: 70)
        let partitionedEpochs = [
            StrainTests.epoch(at: start, magnitude: 1.07),
            StrainTests.epoch(at: start.addingTimeInterval(60), magnitude: 1.30),
        ]
        guard let partition = StrainDayMath.compute(
            samples: partitioned, epochs: partitionedEpochs, maxHeartRate: maxHeartRate,
            restingHeartRate: restingHeartRate)
        else {
            assertTest(false, "The partition fixture produces a result")
            return
        }
        assertTest(
            partition.rawAccumulatedLoad == 180,
            "The day is the sum of per-window maxima (180), not the sum of the two terms (220), got "
                + "\(partition.rawAccumulatedLoad)")

        // ---- A window with no epoch contributes its heart rate unchanged ----
        let hrWindow = StrainTests.samples(from: start, count: 4, heartRate: 170)
        let otherWindow = StrainTests.epoch(at: start.addingTimeInterval(3600), magnitude: 1.30)
        guard let mixed = StrainDayMath.compute(
            samples: hrWindow, epochs: [otherWindow], maxHeartRate: maxHeartRate,
            restingHeartRate: restingHeartRate)
        else {
            assertTest(false, "A day with an epoch in another window produces a result")
            return
        }
        assertTest(
            mixed.rawAccumulatedLoad == 156,
            "A window with no epoch adds its heart-rate load (36) and the epoch's window adds its "
                + "own (120), got \(mixed.rawAccumulatedLoad)")

        // ---- No heart rate is no day ----
        assertTest(
            StrainDayMath.compute(
                samples: [], epochs: vigorousWindows, maxHeartRate: maxHeartRate,
                restingHeartRate: restingHeartRate) == nil,
            "Motion without a single heart-rate sample is not a day — the model refuses to invent a rate")

        // ---- The pathological ceiling ----
        //
        // Every window of a full day at running weight: 2,880 × 4 × 30 = 345,600 weighted seconds,
        // which the day curve takes to 20.5. This is the bound the weight table can reach; the
        // weight-1 light-movement day (86,400) is 12.8.
        let allDay = (0..<(86_400 / 30)).map { index in
            StrainTests.epoch(at: start.addingTimeInterval(Double(index) * 30), magnitude: 1.30)
        }
        let oneRestingSample = StrainTests.samples(from: start, count: 1, heartRate: 60)
        guard let ceiling = StrainDayMath.compute(
            samples: oneRestingSample, epochs: allDay, maxHeartRate: maxHeartRate,
            restingHeartRate: restingHeartRate)
        else {
            assertTest(false, "The ceiling fixture produces a result")
            return
        }
        assertTest(
            ceiling.rawAccumulatedLoad == 345_600,
            "A whole day of vigorous motion is 345,600 weighted seconds, got "
                + "\(ceiling.rawAccumulatedLoad)")
        assertTest(
            ceiling.score == 20.5,
            "…and the day curve takes that to 20.5 of 21, got \(ceiling.score)")

        // ---- The watermark ----
        let newestSample = start.addingTimeInterval(3_599)
        let lastEpoch = StrainTests.epoch(at: start.addingTimeInterval(3_600), magnitude: 1.30)
        guard let stamped = StrainDayMath.compute(
            samples: StrainTests.samples(from: start, count: 3_600, heartRate: 70),
            epochs: [lastEpoch],
            maxHeartRate: maxHeartRate,
            restingHeartRate: restingHeartRate)
        else {
            assertTest(false, "The watermark fixture produces a result")
            return
        }
        assertTest(
            stamped.scoredThrough == lastEpoch.start.addingTimeInterval(30),
            "The watermark is the newest input instant — the epoch's own measured edge, not the "
                + "newest sample")
        assertTest(
            stamped.scoredThrough > newestSample,
            "…which is later than the newest sample here, so both halves are considered")
    }

    /// The pre-motion day algorithm, copied verbatim as the reference the refactor is pinned against.
    ///
    /// **A copy is the point.** Asserting against a hand-computed constant would pass for a different
    /// summation order that happens to round the same; this compares the two Doubles bit for bit, which
    /// is what "the refactor moved nothing" means.
    private static func legacyLoad(samples: [BiometricSample]) -> Double {
        let zones = StrainAccumulatorMath.computeZones(
            maxHR: maxHeartRate, restHR: restingHeartRate)
        var total = 0.0
        for i in 0..<samples.count {
            let duration: TimeInterval = (i > 0)
                ? min(5.0, samples[i].timestamp.timeIntervalSince(samples[i - 1].timestamp))
                : 1.0
            let (_, load) = StrainAccumulatorMath.loadDelta(
                for: samples[i].heartRate,
                zones: zones,
                restingHeartRate: restingHeartRate,
                durationSeconds: duration)
            total += load
        }
        return total
    }
}
