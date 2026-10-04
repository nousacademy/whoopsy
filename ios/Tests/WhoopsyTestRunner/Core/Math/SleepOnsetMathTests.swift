import Foundation
import Whoopsy

// MARK: - 13. Sleep Need — where a strap night begins and ends

/// A file of §13's body, cut at the section's own `── Title` boundary and moved verbatim.
/// `SleepNeedTests.run()` calls it, in the order the section ran it in.
enum SleepOnsetMathTests {
    static func run() async throws {
        // ── Where a strap night begins and ends ──────────────────────────────────────────────────────
        //
        // `AnalyzeSleepUseCase` took a session's boundaries from its first and last sample, which are the
        // edges of the 9 PM → 10 AM **read window** — when the strap might have been worn — and not the
        // night. `SleepOnsetMath` is the detector that replaced it, and these are the assertions that fail
        // if it is removed or bypassed.
        //
        // Every fixture is built so the **untrimmed** answer is a different number, because a rule that is
        // not applied and a rule that trims nothing produce the same session. The edge epochs are made
        // unmistakably awake — a 2.0 G accelerometer magnitude against the classifier's 1.25 threshold —
        // and they are the majority of the window, so a span taken from `samples.first`/`samples.last`
        // would be five hours wider than the night and carry 600 seconds of awake time the trim must
        // delete. A fixture whose awake edges were brief, or whose stages happened to be uniform, would
        // pass whether or not the rule ran.
        //
        // The stage kinds are read off the default profile's 54 bpm resting rate, which puts the
        // classifier's edges at 49.68 (deep), 56.7 (rem) and 67.5 (awake). So 45 bpm with a still strap is
        // deep, and 54 would be *light* — the stage this rule is least able to see, and the reason
        // `SleepOnsetMath` documents quiet wakefulness as a blind spot rather than a rounding error.
        do {
            // Thirty samples to an epoch, `spacing` seconds apart. Note that an epoch is a stride of
            // *samples*, not of seconds: at a minute apart one epoch spans 29 minutes of wall clock. The
            // run is measured in that wall clock and never in epochs, which is what lets the two §13
            // fixtures above — 3,540 s and 1,305 s of sleep in one and two epochs — still classify.
            func night(
                _ kinds: [(heartRate: Int, accel: Double)], from base: Date, spacing: Double
            ) -> [BiometricSample] {
                kinds.enumerated().flatMap { epoch, kind in
                    (0..<30).map { offset in
                        BiometricSample(
                            timestamp: base.addingTimeInterval(Double(epoch * 30 + offset) * spacing),
                            heartRate: kind.heartRate,
                            // The triplet, because the magnitude is `nil` unless all three axes are
                            // present — the strap sends them together and a partial one is not a state
                            // any producer can be in.
                            accelerometerX: kind.accel, accelerometerY: 0, accelerometerZ: 0)
                    }
                }
            }

            // `deep` carries **1.0 G and not 0.0**, which is the assertion this fixture makes about the
            // sensor rather than about the classifier: gravity is inside the magnitude, so a motionless
            // worn strap reads ≈1.0 and a `0.0` is free fall, unreachable on a body. The stage is `deep`
            // either way — both values are below the 1.05 quiet line — so reverting this to `0.0` is
            // invisible in `deepSleepSeconds` and visible only in the two assertions below, which are the
            // one place in the suite that states what a still strap actually reads. Nothing here is
            // day-keyed, so the anchor is any instant.
            let deep = (heartRate: 45, accel: 1.0)
            let awake = (heartRate: 80, accel: 2.0)
            let gravityBase = Date()

            assertTest(
                abs((night([deep], from: gravityBase, spacing: 60).first?.accelerationMagnitude ?? -1) - 1.0)
                    < 0.0001,
                "A still epoch's magnitude is its gravity shell — ≈1.0 G, not the free-fall 0.0 the "
                    + "entity's initialiser used to supply (got "
                    + "\(night([deep], from: gravityBase, spacing: 60).first?.accelerationMagnitude ?? -1))")
            assertTest(
                BiometricSample(timestamp: gravityBase, heartRate: 50).accelerationMagnitude == nil,
                "…and a sample that carried no accelerometer has no magnitude at all, rather than a "
                    + "magnitude of zero — which is a measurement of stillness no sensor made")

            // ── The rule itself, with no classifier in the way ───────────────────────────────────────
            //
            // `sleepPeriod` is pure: epochs in, a span or `nil` out. The boundary case is the one worth
            // pinning, because it is the only one a comparison operator can get wrong — twenty 30-second
            // epochs is 600 seconds exactly and the rule is `>=`.
            do {
                let start = Date()
                func epochs(_ asleep: [Bool], seconds: Double = 30) -> [SleepOnsetMath.Epoch] {
                    asleep.enumerated().map { index, isAsleep in
                        SleepOnsetMath.Epoch(
                            start: start.addingTimeInterval(Double(index) * seconds),
                            end: start.addingTimeInterval(Double(index + 1) * seconds),
                            isAsleep: isAsleep)
                    }
                }

                assertTest(
                    SleepOnsetMath.minimumSleepRunSeconds == 600,
                    "The run a night must sustain is the actigraphy standard ten minutes — `SO10`, the most "
                        + "commonly applied operational definition, which Busa et al. 2022 found moves no "
                        + "sleep variable against PSG. Changing it means deleting this sentence "
                        + "(got \(SleepOnsetMath.minimumSleepRunSeconds)) s")

                let allNight = SleepOnsetMath.sleepPeriod(of: epochs(Array(repeating: true, count: 40)))
                assertTest(
                    allNight?.onset == start && allNight?.wake == start.addingTimeInterval(1200),
                    "A window that is asleep throughout is its own span: the rule must not move a night "
                        + "that has no edge awake in it")

                let trimmed = SleepOnsetMath.sleepPeriod(
                    of: epochs(
                        Array(repeating: false, count: 10)
                            + Array(repeating: true, count: 40)
                            + Array(repeating: false, count: 10)))
                assertTest(
                    trimmed?.onset == start.addingTimeInterval(300)
                        && trimmed?.wake == start.addingTimeInterval(1500),
                    "…and a night inside an awake window is the sleep and only the sleep — ten awake epochs "
                        + "either side come off both ends, which is the trim itself")

                assertTest(
                    SleepOnsetMath.sleepPeriod(of: epochs(Array(repeating: true, count: 19))) == nil,
                    "Nineteen epochs is 570 s of unbroken sleep and is **not** a night, so the threshold "
                        + "bites below it")
                assertTest(
                    SleepOnsetMath.sleepPeriod(of: epochs(Array(repeating: true, count: 20))) != nil,
                    "…and twenty is 600 s exactly, which qualifies: the rule is `>=`, so a run landing on "
                        + "the threshold is a night rather than a near miss")

                assertTest(
                    SleepOnsetMath.sleepPeriod(of: []) == nil,
                    "No epochs is no night, and not an empty span")
                assertTest(
                    SleepOnsetMath.sleepPeriod(of: epochs(Array(repeating: false, count: 40))) == nil,
                    "…and neither is a worn strap that never slept, which is the case the caller turns "
                        + "into an absent row rather than a night of zero")

                let gapped = SleepOnsetMath.sleepPeriod(
                    of: epochs(
                        Array(repeating: true, count: 20)
                            + [false]
                            + Array(repeating: true, count: 20)))
                assertTest(
                    gapped?.onset == start && gapped?.wake == start.addingTimeInterval(1230),
                    "A single awakening in the middle neither splits the night nor ends it early: the span "
                        + "runs from the first run's start to the last run's end, so the gap sits inside it "
                        + "and is counted as wake rather than trimmed")
            }

            // ── The trim, through the real use case ──────────────────────────────────────────────────
            do {
                let calendar = Calendar.current
                let morning = calendar.startOfDay(for: Date())
                let db = LocalDatabaseManager(inMemory: true)
                let sleepRepository = GRDBSleepRepository(db: db)

                // Ten awake epochs, four asleep, ten awake — one minute apart, so the window is twelve
                // hours and the night inside it is two. Epoch k spans samples [30k, 30k+29], which puts
                // the first asleep epoch's start at +18,000 s and the last one's end at +25,140 s; the
                // untrimmed span would have been 0 → +43,140.
                let base = morning.addingTimeInterval(-10 * 3600)
                let samples = night(
                    Array(repeating: awake, count: 10)
                        + Array(repeating: deep, count: 4)
                        + Array(repeating: awake, count: 10),
                    from: base, spacing: 60)

                let session = try await AnalyzeSleepUseCase(
                    biometricRepository: OvernightBiometricStore(samples: samples),
                    sleepRepository: sleepRepository,
                    strainRepository: GRDBStrainRepository(db: db),
                    userProfileRepository: GRDBUserProfileRepository(db: db)
                ).execute(for: morning)

                assertTest(
                    session?.startTime == base.addingTimeInterval(18_000),
                    "A strap night begins where its first sustained run of sleep begins, not where the "
                        + "read window opened — five hours of an awake strap at the front are not part of "
                        + "the night (got \(session.map { "\($0.startTime.timeIntervalSince(base))" } ?? "nil") s in)")
                assertTest(
                    session?.endTime == base.addingTimeInterval(25_140),
                    "…and it ends where its last run closed, not where the samples ran out "
                        + "(got \(session.map { "\($0.endTime.timeIntervalSince(base))" } ?? "nil") s in)")
                assertTest(
                    session?.deepSleepSeconds == 120,
                    "…so the four epochs inside the span are the whole of what is counted — four 30-second "
                        + "epochs is 120 s, against the 600 s of awake time that stood beside them in the "
                        + "untrimmed sum (got \(session.map { "\($0.deepSleepSeconds)" } ?? "nil") s)")
                assertTest(
                    session?.awakeSeconds == 0 && session?.disturbanceCount == 0,
                    "…and the twenty awake epochs outside the span contribute **nothing**, to the awake "
                        + "total or to the disturbance count — which is one guard and not two, since a "
                        + "disturbance is a counted awake epoch and one that was never in the night cannot "
                        + "disturb it (got \(session.map { "\($0.awakeSeconds) s, \($0.disturbanceCount ?? -1) events" } ?? "nil"))")
                assertTest(
                    session.map {
                        $0.lightSleepSeconds + $0.deepSleepSeconds + $0.remSleepSeconds + $0.awakeSeconds
                            == 4 * 30
                    } ?? false,
                    "…and the four sums account for exactly the four retained epochs, once each. This is "
                        + "the assertion that fails if the span is trimmed and the sums are not: the "
                        + "`asleep + awake = DURATION` identity the sleep detail screen prints is built on "
                        + "those two moving together")
            } catch {
                assertTest(false, "The onset trim threw: \(error)")
            }

            // ── The same night, with no accelerometer at all ─────────────────────────────────────────
            //
            // Every sample the live `0x2A37` path constructs carries no motion, so this is the shape of a
            // real strap night rather than a hypothetical one — and the classifier must stage it exactly
            // as it staged the fixture above. **That equality is the whole assertion**, because the
            // entity's old `0.0` default was already satisfying both motion tests by accident: a
            // fabricated free-fall reading is below the 1.05 quiet line, so the heart-rate bands have
            // been deciding these nights all along. What changed is that the absence is now stated rather
            // than spelled as a physically impossible measurement — so if the two fixtures ever disagree,
            // the degradation broke rather than the model.
            do {
                let calendar = Calendar.current
                let morning = calendar.startOfDay(for: Date())
                let db = LocalDatabaseManager(inMemory: true)
                let base = morning.addingTimeInterval(-10 * 3600)

                // The same ten/four/ten shape, built with no `accelerometer*` argument at all.
                let withoutMotion: [BiometricSample] = [awake, awake, awake, awake, awake, awake, awake,
                    awake, awake, awake, deep, deep, deep, deep, awake, awake, awake, awake, awake, awake,
                    awake, awake, awake, awake]
                    .enumerated()
                    .flatMap { epoch, kind in
                        (0..<30).map { offset in
                            BiometricSample(
                                timestamp: base.addingTimeInterval(
                                    Double(epoch * 30 + offset) * 60),
                                heartRate: kind.heartRate)
                        }
                    }
                assertTest(
                    withoutMotion.allSatisfy { $0.accelerationMagnitude == nil },
                    "The fixture really carries no accelerometer on any sample, so what follows is about "
                        + "the absence and not about a value that happens to be still")

                let session = try await AnalyzeSleepUseCase(
                    biometricRepository: OvernightBiometricStore(samples: withoutMotion),
                    sleepRepository: GRDBSleepRepository(db: db),
                    strainRepository: GRDBStrainRepository(db: db),
                    userProfileRepository: GRDBUserProfileRepository(db: db)
                ).execute(for: morning)

                assertTest(
                    session?.startTime == base.addingTimeInterval(18_000)
                        && session?.endTime == base.addingTimeInterval(25_140),
                    "A night with no motion is still detected where its heart rate says it is: the "
                        + "motionless-epoch test cannot be made, so the elevated-heart-rate test and the "
                        + "heart-rate bands decide the staging alone (got "
                        + "\(session.map { "\($0.startTime.timeIntervalSince(base))–\($0.endTime.timeIntervalSince(base))" } ?? "nil") s)")
                assertTest(
                    session?.deepSleepSeconds == 120 && session?.awakeSeconds == 0,
                    "…and it stages **identically** to the same night carrying a real gravity shell — the "
                        + "calibration the fabricated `0.0` had been producing by accident, kept while the "
                        + "fabrication is removed (got "
                        + "\(session.map { "\($0.deepSleepSeconds) s deep, \($0.awakeSeconds) s awake" } ?? "nil"))")
            } catch {
                assertTest(false, "The motionless-night fixture threw: \(error)")
            }

            // ── A window with no sustained run is absent, and writes nothing ─────────────────────────
            //
            // The user's ruling for the strap path: a night the classifier never saw a run in is
            // **stored as nothing**, matching the shape `minimumEpochSamples` already establishes. Both
            // fixtures below are near misses rather than empty windows, so they test the threshold and
            // not the absence of samples — and each gets its own database, because a shared one would let
            // the previous block's row answer the read.
            do {
                let calendar = Calendar.current
                let morning = calendar.startOfDay(for: Date())
                let base = morning.addingTimeInterval(-10 * 3600)

                func store(_ samples: [BiometricSample]) async throws -> SleepSession? {
                    let db = LocalDatabaseManager(inMemory: true)
                    let sleepRepository = GRDBSleepRepository(db: db)
                    let session = try await AnalyzeSleepUseCase(
                        biometricRepository: OvernightBiometricStore(samples: samples),
                        sleepRepository: sleepRepository,
                        strainRepository: GRDBStrainRepository(db: db),
                        userProfileRepository: GRDBUserProfileRepository(db: db)
                    ).execute(for: morning)
                    // Read back rather than trusting the return value: "wrote nothing" is a claim about
                    // the table, and the optional is only a claim about the call.
                    let stored = try await sleepRepository.getSleepSession(for: morning)
                    assertTest(
                        (session == nil) == (stored == nil),
                        "A refused night's return value and its row agree — no session is returned and "
                            + "nothing is written, so no reader can find a night the classifier denied")
                    return session
                }

                // Three single-epoch doze-offs ten seconds apart, so each spans 290 s against the 600 a
                // run needs. Separated by awake epochs, so none of them chains into a longer run.
                let dozeOffs: [(heartRate: Int, accel: Double)] = [
                    awake, awake, deep, awake, awake, deep, awake, awake, deep, awake, awake, awake,
                ]
                assertTest(
                    try await store(night(dozeOffs, from: base, spacing: 10)) == nil,
                    "A window holding three separate 290-second doze-offs holds no run a night can be "
                        + "built from, so the strap reports no night at all rather than one spanning them")
                assertTest(
                    try await store(night(Array(repeating: awake, count: 12), from: base, spacing: 60))
                        == nil,
                    "…and a strap worn all evening without sleeping is absent for the same reason, which "
                        + "is the case a boundary taken from the samples would have called a twelve-hour "
                        + "night of wake")
            } catch {
                assertTest(false, "The onset absence rule threw: \(error)")
            }
        }
    }
}
