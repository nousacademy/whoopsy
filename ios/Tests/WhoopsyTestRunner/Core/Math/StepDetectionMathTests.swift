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
        try await StepAccumulatorTests.run()
        try await StepCountPersistenceTests.run()
        try await WhoopProtocolProfileTests.run()
        try await StrainPanelTests.run()
        try await WhoopPacketEncoder5Tests.run()
        try await HistoricalDrainSessionTests.run()
    }

    // MARK: The builders the section shares across its files

    /// §15's `TypicalRangeTests.breakdown` precedent: a fixture more than one topic file needs
    /// lives as a namespace static on the section's own dispatcher enum, so there is one
    /// definition of it rather than one per caller. These three are the only ones §16 needs
    /// across a file boundary — `fourFrame`, `sealFour` and the three `write…` helpers are read
    /// by one file alone and stay inside it.
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
        let interval = 0.01
        let leadInSeconds = 2.0
        let sigma = 0.04
        let total = leadInSeconds + Double(max(bumps - 1, 0)) * periodSeconds + 0.4
        let count = Int((total / interval).rounded()) + 1
        return (0..<count).map { index in
            let seconds = Double(index) * interval
            var x = 1.0
            for bump in 0..<bumps {
                let distance = seconds - (leadInSeconds + Double(bump) * periodSeconds)
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
            "At 0.1 g the peaks are ≈0.085 g and `mean + 1σ` has fallen under `minimumPeakAmplitudeG`, so "
                + "the floor is what admits them — this is the assertion a floor raised too high fails")
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
                in: StepTests.bumpTrain(bumps: 2, amplitudeG: 0.3, periodSeconds: 0.2), sampleRateHz: 100) == 1,
            "Two genuine peaks 0.2 s apart count once — the second is inside "
                + "`minimumStepIntervalSeconds`, so this is the refractory rejecting it rather than two "
                + "maxima merging into one")
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
    }
}
