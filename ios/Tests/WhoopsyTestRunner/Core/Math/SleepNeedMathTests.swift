import Foundation
import Whoopsy

// MARK: - 13. Sleep Need

/// The night a strap recorded is the only night whose Sleep Need this app computes, so it is the only
/// night any of this can be wrong about. Imported nights already carry WHOOP's own figure, and the
/// last third of this section is the guard that keeps them that way.

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
///
/// The blocks live in sibling files, one per topic, cut at this section's own `── Title`
/// boundaries and moved verbatim — so the counterpart of each app file sits beside this one, and
/// this file says only which of them run, and in what order.
///
/// **The need's own blocks are the exception**: they are the section's own subject, so they sit in
/// the second enum below rather than in a file of their own.
enum SleepNeedTests {
    static func run() async throws {
        try await SleepNeedMathTests.run()
        try await SleepOnsetMathTests.run()
        try await SleepConsistencyTests.run()
        try await SleepExportProvenanceTests.run()
        try await RespiratoryRateMathTests.run()
        try await SleepDebtMathTests.run()
    }

    // MARK: The synthetic tachogram, shared between the respiratory and the debt files

    /// The instant an un-anchored synthetic series is pinned to.
    ///
    /// Hoisted out of the respiratory body for `syntheticPackets`' sake and for no other reason: the
    /// builder reads it, the builder is called from the debt file, and a value captured by a hoisted
    /// function has to be hoisted with it. It is a pure value — a literal instant — so a reader on
    /// the dispatcher and a reader in the respiratory file hold provably the same instant.
    static let start = Date(timeIntervalSinceReferenceDate: 0)

    /// A synthetic tachogram: beats whose R-R intervals are modulated by one or two sinusoids of
    /// known rate, chopped into packets whose arrival instants are exactly one packet-span apart.
    ///
    /// That last part is the whole point. The arrivals are the *generated* beat times, so the seam
    /// between consecutive packets carries no residual and the series is perfectly continuous —
    /// exactly the series a strap would produce if it never dropped a beat. `arrivalSpacing:`
    /// overrides it to produce the discontinuous case the estimator has to refuse.
    static func syntheticPackets(
        _ components: [(bpm: Double, amplitudeMs: Double)],
        meanRRMs: Double = 600,
        intervalsPerPacket: Int = 10,
        packetCount: Int = 20,
        arrivalSpacing: Double? = nil,
        anchor: Date? = nil
    ) -> [(arrival: Date, intervals: [Double])] {
        let total = intervalsPerPacket * packetCount
        var times: [Double] = [0]
        var intervals: [Double] = []
        intervals.reserveCapacity(total)
        for _ in 0..<total {
            let t = times[times.count - 1]
            let modulation = components.reduce(0.0) { sum, component in
                sum + component.amplitudeMs
                    * sin(2 * Double.pi * (component.bpm / 60) * t)
            }
            let rr = meanRRMs + modulation
            intervals.append(rr)
            times.append(t + rr / 1000)
        }

        // `anchor` matters only for the end-to-end block: `AnalyzeSleepUseCase` reads its samples
        // over `[morning − 11 h, morning + 10 h]`, so a series pinned at the reference date is
        // filtered away before it is ever classified — the store returns nothing and the night is
        // `nil` for a reason that has nothing to do with the R-R series under test.
        return (0..<packetCount).map { packet in
            let lower = packet * intervalsPerPacket
            let arrival = (anchor ?? start).addingTimeInterval(
                arrivalSpacing.map { Double(packet + 1) * $0 }
                    ?? times[lower + intervalsPerPacket])
            return (arrival, Array(intervals[lower..<(lower + intervalsPerPacket)]))
        }
    }
}

// MARK: - The need's own blocks

/// The pure function's contract, and the night it is computed for — §13's own subject, so the two
/// blocks stay here rather than moving to files of their own beside the dispatcher above.
enum SleepNeedMathTests {
    static func run() async throws {
        // ── The pure function's contract ─────────────────────────────────────────────────────────────
        let baseline: TimeInterval = 8 * 3600

        // The no-fabrication rule, applied to an input. An absent strain row means yesterday is
        // unmeasured; a substituted strain would turn "we do not know how hard yesterday was" into a real
        // change in tonight's target.
        assertTest(
            SleepNeedMath.sleepNeedSeconds(baselineSeconds: baseline, previousDayStrain: nil) == baseline,
            "No strain row means the baseline exactly, not a substituted strain")
        assertTest(
            SleepNeedMath.sleepNeedSeconds(baselineSeconds: baseline, previousDayStrain: 0) == baseline,
            "A measured zero-strain day needs nothing beyond the baseline")
        assertTest(
            SleepNeedMath.sleepNeedSeconds(baselineSeconds: baseline, previousDayStrain: -5) == baseline,
            "A negative strain — a corrupt row — cannot subtract from the need")

        var previous = -1.0
        var firstFall: Double?
        for tenth in 0...210 {
            let strain = Double(tenth) / 10.0
            let need = SleepNeedMath.sleepNeedSeconds(baselineSeconds: baseline, previousDayStrain: strain)
            if need < previous, firstFall == nil { firstFall = strain }
            previous = need
        }
        let firstFallReport = firstFall.map { "\($0)" } ?? "none"
        assertTest(
            firstFall == nil,
            "The need never falls as strain rises, over 0.0–21.0 in 0.1 steps "
                + "(first fall at \(firstFallReport))")

        // Clamping the *input* rather than the output: strain is defined on 0–21, so a value outside that
        // is a corrupt row, not a hard day. At the maximum the term is worth 134 minutes, which keeps the
        // need inside the 321–650 min band WHOOP's own figures occupy.
        assertTest(
            SleepNeedMath.sleepNeedSeconds(baselineSeconds: baseline, previousDayStrain: 40)
                == SleepNeedMath.sleepNeedSeconds(baselineSeconds: baseline, previousDayStrain: 21),
            "Strain above the documented scale clamps rather than extrapolating")

        // ── The coefficient, pinned with its basis ───────────────────────────────────────────────────
        //
        // WHOOP publishes this model's shape and none of its constants, so 6.40 is fitted rather than
        // cited: least squares of WHOOP's own `Sleep need (min)` on its own previous-day `Day Strain`
        // across the 909 nights of the bundled export that carry a preceding strain day, intercept
        // pinned to the 8-hour baseline. Scored by 5-fold cross-validation against the performance
        // WHOOP's *own* need implies, that scores 3.77 where a flat 480 scores 10.06, `docs/ALGORITHMS.md`
        // §4's 4.5 scores 4.64, and refitting per fold scores 3.87.
        //
        // This assertion is deliberately a bare equality with the basis in the message: changing the
        // constant means deleting a sentence that says where it came from.
        assertTest(
            SleepNeedMath.strainMinutesPerPoint == 6.40,
            "The strain coefficient is the fitted 6.40 min/point (got \(SleepNeedMath.strainMinutesPerPoint))")
        assertTest(
            SleepNeedMath.maximumStrain == 21.0,
            "The clamp is the documented 0–21 strain scale (got \(SleepNeedMath.maximumStrain))")

        do {
            // ── The integration: the real use case, a real night, a real strain row ──────────────────
            let calendar = Calendar.current
            let morning = calendar.startOfDay(for: Date())
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: morning) else {
                assertTest(false, "Could not build the previous day")
                return
            }

            // 23:00 the previous evening to 23:59, one minute apart — inside the use case's window
            // (which opens 11 hours before `startOfDay(morning)` and closes 10 hours after it).
            let night = OvernightBiometricStore(samples: (0..<60).map { index in
                BiometricSample(
                    timestamp: morning.addingTimeInterval(-3600 + Double(index) * 60),
                    heartRate: 52)
            })

            let strain = 14.0
            let db = LocalDatabaseManager(inMemory: true)
            let sleepRepository = GRDBSleepRepository(db: db)
            let strainRepository = GRDBStrainRepository(db: db)
            let profileRepository = GRDBUserProfileRepository(db: db)

            try await strainRepository.saveStrain(
                StrainScore(date: previousDay, score: strain, hasMeasurement: true))

            let session = try await AnalyzeSleepUseCase(
                biometricRepository: night,
                sleepRepository: sleepRepository,
                strainRepository: strainRepository,
                userProfileRepository: profileRepository
            ).execute(for: morning)

            assertTest(session != nil, "A night with enough samples is classified and stored")

            let profile = try await profileRepository.getUserProfile()
            assertTest(
                profile.targetSleepHours * 3600 == baseline,
                "The night's baseline is the profile's 8 hours (got \(profile.targetSleepHours) h)")

            // Read back through the repository rather than trusting the returned session: the stored
            // value is what every later reader — sleep performance, the Recovery sleep term — consumes.
            let stored = try await sleepRepository.getSleepSession(for: morning)
            let expected = profile.targetSleepHours * 3600 + strain * SleepNeedMath.strainMinutesPerPoint * 60
            assertTest(
                stored?.targetSleepNeedSeconds == expected,
                "A strain of \(strain) on the previous day stores "
                    + "\(Int(expected / 60)) min of need, not a flat 480 "
                    + "(got \(Int((stored?.targetSleepNeedSeconds ?? 0) / 60)) min)")

            // The same night, for the two values this turn gave a strap producer. The fixture's samples
            // carry no R-R series at all, so neither has anything to be computed from and both must be
            // **absent**. `respiratoryRate` is the one the strap has no sensor for, and a `0` there would
            // read as a stopped breath; `sleepDebtSeconds` is absent because this is the first night, and
            // a `0` would claim the user is in perfect sleep credit.
            assertTest(
                stored?.respiratoryRate == nil,
                "A night whose samples carry no R-R series stores no respiratory rate — the R-R series is "
                    + "the only thing on the strap path that can produce one")
            assertTest(
                stored?.sleepDebtSeconds == nil,
                "…and no sleep debt, because there is no earlier night to accumulate from and `0` is a "
                    + "measurement this app has not made")

            // ── Whose need it is, which is the one thing the two producers' rows do not show ─────────
            //
            // This night carries a need and no debt, but the debt is absent for the *incidental* reason
            // above — a first night has no priors — and not because this path cannot produce one.
            // `SleepDebtMath` gives it one from the second night onward, so a stored row is not evidence
            // of which producer wrote it and nothing in the two figures is either. The flag is: WHOOP's
            // need is a total containing its debt term and this app's is not, and the need card's box is
            // drawn on that difference alone.
            assertTest(
                stored?.hasWhoopSleepNeed == false,
                "A classified night reads back as **this app's** need rather than WHOOP's, so the need "
                    + "card draws its bars and no breakdown box for it")

            // The `?? true` is deliberate and is the shape that makes this assertion bite: were the flag
            // ever lost from the entity, the fallback would hand the split the value that *permits* it and
            // this would fail alongside the assertion above rather than passing for want of a value.
            assertTest(
                SleepNeedBreakdown.breakdown(
                    needSeconds: expected,
                    debtSeconds: 3600,
                    hasWhoopNeed: stored?.hasWhoopSleepNeed ?? true) == nil,
                "…and that night's own need with an hour of debt produces no split, because a debt on a "
                    + "`SleepNeedMath` need is not a part of it — the box's first row would be labelled "
                    + "for two of WHOOP's terms over a figure holding neither")

            // The strain is keyed on the day *before* the night. `strains` is keyed on
            // `startOfDay(wakeOnset)`, so the cycle ending on morning D is keyed D — a night keyed D+1
            // follows it. Same-day strain is a different, weaker signal: it fits at R²=0.161 against the
            // previous day's 0.385, which is why `docs/ALGORITHMS.md` §4's same-day coefficient was the wrong
            // constant for a formula about the previous day.
            let nextMorning = calendar.date(byAdding: .day, value: 1, to: morning)!
            let nextStored = try await sleepRepository.getSleepSession(for: nextMorning)
            assertTest(
                nextStored == nil || nextStored?.targetSleepNeedSeconds != expected,
                "…and last night's strain is not read as this morning's")

            // ── The absence rule, end to end ─────────────────────────────────────────────────────────
            let bareDB = LocalDatabaseManager(inMemory: true)
            let bareSleepRepository = GRDBSleepRepository(db: bareDB)
            _ = try await AnalyzeSleepUseCase(
                biometricRepository: night,
                sleepRepository: bareSleepRepository,
                strainRepository: GRDBStrainRepository(db: bareDB),
                userProfileRepository: GRDBUserProfileRepository(db: bareDB)
            ).execute(for: morning)

            let bareStored = try await bareSleepRepository.getSleepSession(for: morning)
            assertTest(
                bareStored?.targetSleepNeedSeconds == baseline,
                "The same night with no previous-day strain row stores the baseline unchanged — "
                    + "no strain is invented (got \(Int((bareStored?.targetSleepNeedSeconds ?? 0) / 60)) min)")
        } catch {
            assertTest(false, "The Sleep Need integration threw: \(error)")
        }
    }
}
