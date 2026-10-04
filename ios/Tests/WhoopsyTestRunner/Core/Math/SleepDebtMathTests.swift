import Foundation
import Whoopsy

// MARK: - 13. Sleep Need — the debt, and the end-to-end night

/// A file of §13's body, cut at the section's own `── Title` boundary and moved verbatim.
/// `SleepNeedTests.run()` calls it, in the order the section ran it in.
///
/// Its end-to-end block drives the real `AnalyzeSleepUseCase` over a synthetic tachogram, so it
/// reaches `SleepNeedTests.syntheticPackets` — the one builder §13 shares across two files.
enum SleepDebtMathTests {
    static func run() async throws {
        // ── Sleep debt ───────────────────────────────────────────────────────────────────────────
        //
        // The accumulation is **lagged**: a night's debt is built from the nights before it and never
        // from its own shortfall. That is measured, not assumed — WHOOP's own `Sleep debt (min)`
        // column correlates 0.891 with the *previous* night's shortfall and 0.506 with its own, and
        // the shortfalls are only 0.42 autocorrelated, so it is not collinearity. A same-night model
        // is the tempting wrong answer and it scores MAE 16.03 against the lagged 8.31; the assertion
        // that catches it is the one below where the target's own shortfall is 479 minutes and the
        // answer is 2177 seconds.
        let day = Calendar.current.startOfDay(for: Date())
        let need: TimeInterval = 480 * 60

        func night(_ nightsAgo: Int, asleepMinutes: Double) -> SleepDebtMath.Night {
            SleepDebtMath.Night(
                day: day.addingTimeInterval(-Double(nightsAgo) * 86_400),
                needSeconds: need,
                asleepSeconds: asleepMinutes * 60)
        }

        let target = SleepDebtMath.Night(day: day, needSeconds: need, asleepSeconds: 480 * 60)

        // Shortfalls, newest first: 100, 200, 0, 50, 300 minutes.
        //   D = 100 + 0.15×200 + 0.15²×0 + 0.15³×50 + 0.15⁴×300 = 130.320625 min
        //   debt = 0.4293 × 130.320625 = 55.9466 min = 3356.8 s
        let history = [
            night(1, asleepMinutes: 380),
            night(2, asleepMinutes: 280),
            night(3, asleepMinutes: 480),
            night(4, asleepMinutes: 430),
            night(5, asleepMinutes: 180),
        ]
        let debt = SleepDebtMath.sleepDebtSeconds(for: target, history: history)
        assertTest(
            debt.map { abs($0 - 3357) <= 2 } ?? false,
            "Five nights short by 100/200/0/50/300 min accumulate "
                + "0.4293 × 130.320625 min and store 3357 s "
                + "(got \(debt.map { "\($0)" } ?? "nil"))")

        // The closed form, not a walk. A recurrence has loop-carried state, so the order the history
        // arrives in changes the answer — walking the export in its own newest-first file order moves
        // MAE from 8.31 to 22.69. Sorting the priors explicitly makes that unrepresentable.
        assertTest(
            SleepDebtMath.sleepDebtSeconds(for: target, history: history.reversed()) == debt,
            "The same priors in reverse order give the same answer, because the window is sorted "
                + "rather than walked")

        // The gate: the lagged form has a base case, so one prior night is a complete answer. This is
        // deliberately *not* `SleepConsistencyMath`'s four, whose quantity is a mean over four and has
        // no partial rendering.
        assertTest(
            SleepDebtMath.sleepDebtSeconds(for: target, history: []) == nil,
            "A night with nothing before it has nothing to accumulate and draws a dash")
        let onePrior = SleepDebtMath.sleepDebtSeconds(
            for: target, history: [night(1, asleepMinutes: 380)])
        assertTest(
            onePrior.map { abs($0 - 2576) <= 2 } ?? false,
            "…and a single prior night short by 100 min is enough — 0.4293 × 100 min = 2576 s "
                + "(got \(onePrior.map { "\($0)" } ?? "nil"))")

        // Strictly earlier only. A forward-dated row is a corrupt row, not a heavier prior.
        let future = SleepDebtMath.Night(
            day: day.addingTimeInterval(86_400), needSeconds: need, asleepSeconds: 0)
        assertTest(
            SleepDebtMath.sleepDebtSeconds(for: target, history: history + [future]) == debt,
            "A night dated after the target contributes nothing to it — the window is "
                + "strictly-earlier, so the lag cannot be undone by a stray row")

        // The truncation is non-binding: the sixth prior is beyond `priorNightCount`, and the tail it
        // drops is worth at most 0.0005 × the export's largest single-night shortfall.
        assertTest(
            SleepDebtMath.sleepDebtSeconds(
                for: target, history: history + [night(6, asleepMinutes: 380)]) == debt,
            "A sixth prior night is outside the five-night window and changes nothing")

        // The ceiling is load-bearing rather than cosmetic: 8.5% of the model's own predictions on the
        // export exceed it before clamping, and WHOOP's own column has 105 of 910 rows stacked on it.
        let capped = SleepDebtMath.sleepDebtSeconds(
            for: target, history: (1...5).map { night($0, asleepMinutes: 0) })
        assertTest(
            capped == SleepDebtMath.maximumDebtMinutes * 60,
            "An accumulated shortfall past the ceiling reports the ceiling exactly — "
                + "\(Int(SleepDebtMath.maximumDebtMinutes)) min, got "
                + "\(capped.map { "\($0)" } ?? "nil") s")

        // `0` is a real answer here, and the distinction from `nil` is the whole reason the column is
        // nullable: WHOOP's own figure bottoms out at 0, so a night in credit is measured, not absent.
        let rested = SleepDebtMath.sleepDebtSeconds(
            for: target, history: (1...5).map { night($0, asleepMinutes: 480) })
        assertTest(
            rested == 0,
            "Five nights that each met their own need accumulate nothing, and that is `0` rather than "
                + "`nil` (got \(rested.map { "\($0)" } ?? "nil"))")

        // Each night against its own need — the property that lets an imported night, which carries
        // WHOOP's need, and a strap night, which carries this app's, share one column.
        assertTest(
            SleepDebtMath.shortfallMinutes(
                of: SleepDebtMath.Night(day: day, needSeconds: 400 * 60, asleepSeconds: 480 * 60)) == 0,
            "A night that slept past its own need contributes no negative shortfall")
        assertTest(
            SleepDebtMath.shortfallMinutes(
                of: SleepDebtMath.Night(day: day, needSeconds: 500 * 60, asleepSeconds: 450 * 60)) == 50,
            "…and a night is measured against its own need, so a 500 min need against 450 min asleep "
                + "is a 50 min shortfall")

        // ── End to end: the real use case, writing both values ───────────────────────────────────
        do {
            let calendar = Calendar.current
            let morning = calendar.startOfDay(for: Date())
            let db = LocalDatabaseManager(inMemory: true)
            let sleepRepository = GRDBSleepRepository(db: db)
            let strainRepository = GRDBStrainRepository(db: db)
            let profileRepository = GRDBUserProfileRepository(db: db)

            // Three prior nights with hand-set needs and durations, written through the repository so
            // the read path is the real one. Their shortfalls are 80, 30 and 0 minutes.
            //   D = 80 + 0.15×30 + 0.15²×0 = 84.5 min;  debt = 0.4293 × 84.5 = 36.2759 min = 2177 s
            let priorShortfalls: [Double] = [80, 30, 0]
            for (offset, shortfall) in priorShortfalls.enumerated() {
                guard let priorDay = calendar.date(byAdding: .day, value: -(offset + 1), to: morning)
                else { continue }
                try await sleepRepository.saveSleepSession(
                    SleepSession(
                        date: priorDay,
                        startTime: priorDay.addingTimeInterval(-8 * 3600),
                        endTime: priorDay,
                        targetSleepNeedSeconds: need,
                        lightSleepSeconds: (480 - shortfall) * 60))
            }

            // A night whose samples carry a real R-R series, at a 900 ms mean (67 bpm — a plausible
            // sleeping rate, and above the 48 bpm the band's top edge needs) modulated at 15 bpm.
            // Packets of 50 intervals span 45 s and arrive 45 s apart, so the series is continuous.
            // Anchored inside the use case's own window rather than at the reference date, and 30
            // packets cover 22.5 minutes — over `minimumRunSeconds` with room for many windows.
            let beats = SleepNeedTests.syntheticPackets(
                [(bpm: 15, amplitudeMs: 40)],
                meanRRMs: 900, intervalsPerPacket: 50, packetCount: 30,
                anchor: morning.addingTimeInterval(-6 * 3600))
            let night = OvernightBiometricStore(samples: beats.map { packet in
                BiometricSample(
                    timestamp: packet.arrival,
                    heartRate: 67,
                    rrIntervalsMs: packet.intervals)
            })

            let session = try await AnalyzeSleepUseCase(
                biometricRepository: night,
                sleepRepository: sleepRepository,
                strainRepository: strainRepository,
                userProfileRepository: profileRepository
            ).execute(for: morning)

            assertTest(session != nil, "A night whose samples carry an R-R series is still classified")
            let stored = try await sleepRepository.getSleepSession(for: morning)

            let rate = stored?.respiratoryRate
            assertTest(
                rate.map { abs($0 - 15) <= 1 } ?? false,
                "A strap night now stores its own respiratory rate, read off its own beats — the "
                    + "literal `14.4` that stood here reached the Recovery screen as a measurement "
                    + "(got \(rate.map { "\($0)" } ?? "nil")) bpm")

            // 2177 s, and *not* the capped 7620 a same-night model would produce from the target's own
            // 479-minute shortfall. That gap is what this assertion is for.
            let storedDebt = stored?.sleepDebtSeconds
            assertTest(
                storedDebt.map { abs($0 - 2177) <= 2 } ?? false,
                "…and stores its own sleep debt, accumulated from the three nights before it and "
                    + "never from its own shortfall (got \(storedDebt.map { "\($0)" } ?? "nil")) s, "
                    + "against the 7620 a same-night model would cap at")
        } catch {
            assertTest(false, "The respiratory-rate and sleep-debt integration threw: \(error)")
        }
    }
}
