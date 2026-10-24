import Foundation
import Whoopsy

// MARK: - 16. Steps from the strap

/// The pedometer, both motion layouts, the accumulator, the day-keyed store, the two opcodes that must
/// never be transmitted, and the strain page's panel.
///
/// **Nothing here is evidence about hardware, and a passing run must not be described as the path
/// working.** `biometric_samples` holds 0 rows in every database on this machine and no motion batch
/// has ever been decoded from a strap, so this section proves the arithmetic, the two layouts, the
/// storage rules and the panel — and it says nothing about whether a 4.0 accepts an enable sequence,
/// whether a 5.0 completes the command characteristic's bond, or whether a wrist's motion produces a
/// count that matches a pedometer. `docs/BLE_PROTOCOL.md` §7 is the capture plan that would settle those.

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
///
/// The blocks live in sibling files, one per topic, cut at this section's own `// MARK:`
/// boundaries and moved verbatim — so the counterpart of each app file sits beside this one
/// and this file says only which of them run, and in what order.
enum StepTests {
    static func run() async throws {
        try await StepDetectionMathTests.run()
        try await MotionPayloadDecoderTests.run()
        try await HeartRatePayloadDecoderTests.run()
        try await StepCounterPayloadDecoderTests.run()
        try await Spo2CandidateProbeTests.run()
        try await StrapEventDecoderTests.run()
        try await DiagnosticsTests.run()
        try await DeviceInformationPayloadTests.run()
        try await StepAccumulatorTests.run()
        try await StepCounterAccumulatorTests.run()
        try await StepCountPersistenceTests.run()
        try await StepCounterStatePersistenceTests.run()
        try await WhoopProtocolProfileTests.run()
        try await StrainPanelTests.run()
        try await WhoopPacketEncoder5Tests.run()
        try await HistoricalDrainSessionTests.run()
        // Appended rather than slotted in beside `StepCountPersistenceTests`: every block above was
        // moved into its file from this section's original body and their order is that body's, while
        // this one is new. It takes the store's shape for granted, so it belongs after all of them.
        try await TrackStepsUseCaseTests.run()
        // The other consumer of the same stream. It is new rather than moved, like the block above,
        // and it sits beside it because both are about what the motion stream is used for.
        try await RecordMotionUseCaseTests.run()
    }

    // MARK: The builders the section shares across its files

    /// §15's `TypicalRangeTests.breakdown` precedent: a fixture more than one topic file needs
    /// lives as a namespace static on the section's own dispatcher enum, so there is one
    /// definition of it rather than one per caller. These five are the ones §16 needs across a
    /// file boundary — both generations' frame builders, because the motion decoder and the
    /// heart-rate decoder each hand-build one — while the three `write…` helpers are read by one
    /// file alone and stay inside it.
    ///
    /// **None of the three is state.** They are pure functions of their arguments, so a call
    /// from another file produces exactly what the declaring file would have got. §6.2's rule
    /// about not recreating shared things is about *accumulating* state — a database, an
    /// accumulator, a session — which these are not.

    /// A walking waveform: `leadInSeconds` of a still wrist, then `bumps` acceleration transients on
    /// the x axis `periodSeconds` apart, then a tail long enough for the last peak's falling edge.
    ///
    /// **A bump train rather than a sine, and the count is why.** `|sin|` at 2 Hz peaks four times a
    /// second, and the 1/3 s refractory rejects every other one, so a sine's count is an artefact of
    /// that interaction rather than a property of the detector. Isolated Gaussian bumps 0.5 s apart are
    /// one unambiguous local maximum each — σ is 4 samples, so the separation is 6σ of the bump and the
    /// peaks never merge.
    ///
    /// **The lead-in is not decoration either.** `Detector` judges a peak against a threshold window
    /// that *includes the sample under test* and appends after the verdict, so a bump arriving into an
    /// empty window faces a level of ≈0.9–0.99 × its own peak and passes by a few percent, whatever the
    /// threshold rule is — an assertion that asserts nothing. Two seconds of still wrist fills the 2 s
    /// window first, which drops the level to the 0.05 g floor.
    ///
    /// The x axis reads `1.0 + the bump` and the gravity window also holds the previous bump, so a
    /// peak arrives at ≈0.85 × `amplitudeG` rather than at `amplitudeG`. That factor is why the two
    /// floor fixtures are 0.1 g and 0.02 g and not 0.06 g: the pair has to straddle 0.05 g with room on
    /// both sides rather than sit on it.
    static func bumpTrain(
        bumps: Int, amplitudeG: Double, periodSeconds: Double = 0.5
    ) -> [StepDetectionMath.Sample] {
        bumpTrain(
            offsets: (0..<bumps).map { Double($0) * periodSeconds },
            amplitudeG: amplitudeG)
    }

    /// A bump train at explicit offsets from the end of the lead-in, for the refractory and rhythm
    /// fixtures where even spacing is exactly what must not be assumed.
    static func bumpTrain(
        offsets: [Double], amplitudeG: Double
    ) -> [StepDetectionMath.Sample] {
        let interval = 0.01
        let leadInSeconds = 2.0
        let sigma = 0.04
        let lastOffset = offsets.max() ?? 0
        let total = leadInSeconds + lastOffset + 0.4
        let count = Int((total / interval).rounded()) + 1
        return (0..<count).map { index in
            let seconds = Double(index) * interval
            var x = 1.0
            for offset in offsets {
                let distance = seconds - (leadInSeconds + offset)
                x += amplitudeG * exp(-(distance * distance) / (2 * sigma * sigma))
            }
            return StepDetectionMath.Sample(seconds: seconds, xG: x, yG: 0, zG: 0)
        }
    }

    /// A 5.0 frame of `payloadBytes` bytes carrying `type`, hand-built to §2's envelope.
    ///
    /// **Written in frame coordinates on purpose.** A helper that derived its payload origin from
    /// `WhoopProtocolProfile` would share that arithmetic with the decoder, so a wrong
    /// `innerPrefixBytes` would move both and the fixture would pass — the self-referential assertion
    /// this runner has already been burned by once. The origin is asserted against the profile
    /// separately below, and the decoder stays the only side that subtracts it.
    static func fiveFrame(type: UInt8, payloadBytes: Int) -> [UInt8] {
        // What the declared length counts: the three inner-record prefix bytes, the payload, and the
        // four-byte CRC32 trailer.
        let declared = 3 + payloadBytes + 4
        var frame = [UInt8](repeating: 0, count: 8 + declared)
        frame[0] = 0xAA
        frame[1] = 0x01
        frame[2] = UInt8(declared & 0xFF)
        frame[3] = UInt8((declared >> 8) & 0xFF)
        frame[4] = 0x00   // the two header bytes §2 labels and does not specify; `00 01` is what the
        frame[5] = 0x01   // one published 5.0 frame carries, and the crc16 below covers them anyway
        frame[8] = type
        frame[9] = 0x42   // seq
        frame[10] = 0x00  // cmd
        return frame
    }

    /// A 4.0 frame of `payloadBytes` bytes carrying `type`, hand-built to §2's envelope.
    ///
    /// Written in frame coordinates for `fiveFrame`'s reason: a helper that asked
    /// `WhoopProtocolProfile` for the payload origin would share that arithmetic with the decoder,
    /// so a wrong `innerOrigin` would move both and the fixture would pass.
    static func fourFrame(type: UInt8, payloadBytes: Int) -> [UInt8] {
        let declared = 3 + payloadBytes + 4
        var frame = [UInt8](repeating: 0, count: 4 + declared)
        frame[0] = 0xAA
        frame[1] = UInt8(declared & 0xFF)
        frame[2] = UInt8((declared >> 8) & 0xFF)
        frame[3] = CRCUtils.crc8(Data([frame[1], frame[2]]))
        frame[4] = type
        frame[5] = 0x11   // seq
        frame[6] = 0x00   // cmd
        return frame
    }

    /// The trailer CRC32 alone — the 4.0's header CRC8 is set when the frame is made.
    static func sealFour(_ frame: inout [UInt8]) {
        let innerEnd = frame.count - 4
        let crc32 = CRCUtils.crc32(Data(frame[4..<innerEnd]))
        frame[innerEnd] = UInt8(crc32 & 0xFF)
        frame[innerEnd + 1] = UInt8((crc32 >> 8) & 0xFF)
        frame[innerEnd + 2] = UInt8((crc32 >> 16) & 0xFF)
        frame[innerEnd + 3] = UInt8((crc32 >> 24) & 0xFF)
    }

    /// The header CRC16 over `[0..<6)` and the trailer CRC32 over the inner record.
    static func sealFive(_ frame: inout [UInt8]) {
        let crc16 = CRCUtils.crc16Modbus(Data(frame[0..<6]))
        frame[6] = UInt8(crc16 & 0xFF)
        frame[7] = UInt8((crc16 >> 8) & 0xFF)
        let innerEnd = frame.count - 4
        let crc32 = CRCUtils.crc32(Data(frame[8..<innerEnd]))
        frame[innerEnd] = UInt8(crc32 & 0xFF)
        frame[innerEnd + 1] = UInt8((crc32 >> 8) & 0xFF)
        frame[innerEnd + 2] = UInt8((crc32 >> 16) & 0xFF)
        frame[innerEnd + 3] = UInt8((crc32 >> 24) & 0xFF)
    }
}

// MARK: - 16. The pedometer

/// A file of §16's body, cut at the section's own `// MARK:` topic boundary and moved
/// verbatim. `StepTests.run()` calls it, in the order the section ran it in.

enum StepDetectionMathTests {
    static func run() async throws {
        // MARK: The pedometer

        // Rebuilt from the shared builder rather than carried over from the pedometer block:
        // `bumpTrain` is a pure function, so this is the same waveform sample for sample, and
        // §6.2's rule against recreating shared things is about accumulating state, which a
        // waveform is not.
        let walking = StepTests.bumpTrain(bumps: 20, amplitudeG: 0.3)
        assertTest(
            StepDetectionMath.countSteps(in: walking, sampleRateHz: 100) == 20,
            "Twenty 0.3 g bumps half a second apart count twenty steps — one per peak, none merged and "
                + "none rejected by the 1/3 s refractory")
        assertTest(
            StepDetectionMath.countSteps(in: StepTests.bumpTrain(bumps: 20, amplitudeG: 6.0), sampleRateHz: 100) == 20,
            "The same waveform at 20× the amplitude counts the same twenty, because the level is adaptive "
                + "— a fixed threshold would count all of them here and none of them at 0.3 g")
        assertTest(
            StepDetectionMath.countSteps(in: StepTests.bumpTrain(bumps: 20, amplitudeG: 0.1), sampleRateHz: 100) == 20,
            "At 0.1 g the smoothed peaks are ≈0.067 g and `mean + 1σ` has fallen under "
                + "`minimumPeakAmplitudeG`, so the floor is what admits them — this is the assertion a "
                + "floor raised too high fails, and the reason `smoothingWindowSeconds` is not longer")
        assertTest(
            StepDetectionMath.countSteps(in: StepTests.bumpTrain(bumps: 20, amplitudeG: 0.02), sampleRateHz: 100) == 0,
            "At 0.02 g the same waveform counts nothing, and the adaptive term alone would admit it: "
                + "`mean + 1σ` scales with the signal and sits near 0.007 g there, so this is "
                + "`minimumPeakAmplitudeG` refusing the peaks rather than the spread")
        let still = (0..<1000).map {
            StepDetectionMath.Sample(seconds: Double($0) * 0.01, xG: 1.0, yG: 0, zG: 0)
        }
        assertTest(
            StepDetectionMath.countSteps(in: still, sampleRateHz: 100) == 0,
            "A still wrist counts nothing: gravity is removed per axis, so a constant 1.0 g leaves a zero "
                + "residual rather than a signal sitting at the ±1 g full scale")
        assertTest(
            StepDetectionMath.countSteps(
                in: StepTests.bumpTrain(
                    offsets: [0, 0.5, 0.7, 1.2, 1.7], amplitudeG: 0.3),
                sampleRateHz: 100) == 4,
            "Five peaks at 0, 0.5, 0.7, 1.2 and 1.7 count four — the 0.7 one is inside "
                + "`minimumStepIntervalSeconds` from the 0.5 one and is rejected by the refractory, "
                + "while the remaining four are regular enough to be a train")
        assertTest(
            StepDetectionMath.countSteps(
                in: StepTests.bumpTrain(offsets: [0], amplitudeG: 0.3), sampleRateHz: 100) == 0,
            "A single genuine peak counts nothing: the rhythm gate cannot confirm a train from one "
                + "transient, which is the gesture this gate exists to refuse")
        assertTest(
            StepDetectionMath.countSteps(
                in: StepTests.bumpTrain(offsets: [0, 0.5], amplitudeG: 0.3), sampleRateHz: 100) == 0,
            "Two regular peaks count nothing either — a wrist moved once and put down is exactly two "
                + "transients, and `minimumRhythmicPeaks` is what refuses it")
        assertTest(
            StepDetectionMath.countSteps(
                in: StepTests.bumpTrain(offsets: [0, 0.5, 1.0], amplitudeG: 0.3), sampleRateHz: 100) == 3,
            "Three regular peaks count three, and the third is the sample on which all three are "
                + "deposited — the train is confirmed retroactively rather than losing its first two")
        assertTest(
            StepDetectionMath.countSteps(
                in: StepTests.bumpTrain(offsets: [0, 0.5, 1.0, 5.5, 6.0], amplitudeG: 0.3),
                sampleRateHz: 100) == 3,
            "Two gestures five seconds apart do not join the first train: a gap longer than "
                + "`maximumIntervalSeconds` closes it, and the pair counts nothing on its own")
        assertTest(
            StepDetectionMath.countSteps(
                in: StepTests.bumpTrain(offsets: [0, 0.5, 1.6], amplitudeG: 0.3), sampleRateHz: 100) == 0,
            "Three peaks whose intervals differ by more than `intervalRatioTolerance` count nothing — "
                + "a 0.5 s step followed by a 1.1 s one is a hand moving to a task, not a stride")
        assertTest(
            StepDetectionMath.countSteps(
                in: StepTests.bumpTrain(
                    offsets: Array(stride(from: 0.0, to: 4.0, by: 0.5)), amplitudeG: 0.3),
                sampleRateHz: 100) == 8,
            "An open train keeps counting: once the first three confirm, every later peak in the walk "
                + "is a step, so a steady train is not delayed by two steps per stride")
        assertTest(
            StepDetectionMath.minimumStepIntervalSeconds == 1.0 / 3.0,
            "The refractory interval is 1/3 s, a 180 step-per-minute ceiling")
        assertTest(
            StepDetectionMath.minimumStepIntervalSeconds
                == 1.0 / StepDetectionMath.cadenceBandHz.upperBound,
            "…and it is derived from the band's upper edge (3.0 Hz) rather than written down beside it, so "
                + "a cadence the band admits cannot be rejected by an interval outside it")
        assertTest(
            StepDetectionMath.thresholdWindowSeconds == 2.0
                && StepDetectionMath.thresholdWindowSeconds
                    == 1.0 / StepDetectionMath.cadenceBandHz.lowerBound,
            "The adaptive threshold's window is 2 s — one period of the band's lower edge (0.5 Hz), so it "
                + "always spans a complete stride at any cadence the band admits")
        assertTest(
            StepDetectionMath.gravityWindowSeconds == 1.0,
            "The gravity estimate is a one-second trailing mean — long enough to average out a stride, "
                + "short enough to follow a turning arm")
        assertTest(
            StepDetectionMath.minimumPeakAmplitudeG == 0.05 && StepDetectionMath.thresholdSigmas == 1.0,
            "The two constants a capture would fit are 0.05 g and 1σ — this app's own calibration, since "
                + "WHOOP publishes no step model, so they are the pair the fixtures above straddle")
        assertTest(
            StepDetectionMath.smoothingWindowSeconds == 0.1,
            "The magnitude is smoothed over 0.1 s before it is judged — a ten-sample low-pass at the "
                + "strap's 100 Hz, long enough to remove the sample-scale ripple and short enough to "
                + "leave the 0.1 g fixture above the floor")
        assertTest(
            StepDetectionMath.minimumRhythmicPeaks == 3
                && StepDetectionMath.rhythmWindowSeconds == 3.0,
            "A train is three peaks within three seconds: one peak or two are a gesture, and three "
                + "give the two intervals a rhythm can be tested from")
        assertTest(
            StepDetectionMath.maximumIntervalSeconds == 1.0 / StepDetectionMath.cadenceBandHz.lowerBound,
            "The longest interval a train may contain is 2 s — one period of the band's lower edge, "
                + "derived rather than written down beside it, so the band is the only place a cadence "
                + "is excluded")
        assertTest(
            StepDetectionMath.intervalRatioTolerance == 2.0,
            "Two consecutive intervals may differ by at most a factor of two — a walk's cadence "
                + "drifts, a hand moving to a task does not repeat")
    }
}
