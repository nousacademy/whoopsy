import Foundation
import Whoopsy

/// The composite ring score: weights, renormalization, absence, and the two timing sources.
enum SleepScoreScoringTests {
    static let calendar = Calendar.current
    static let day = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))

    /// A night on a fixed day. `onsetHour` is relative to the wake day's midnight, so `-4` is 20:00
    /// the evening before and `0.5` is 00:30 on the wake day itself.
    static func session(
        dayOffset: Int = 0,
        light: TimeInterval = 0,
        deep: TimeInterval = 0,
        rem: TimeInterval = 0,
        awake: TimeInterval = 0,
        need: TimeInterval = 8 * 3600,
        onsetHour: Double = -4,
        consistency: Int? = nil
    ) -> SleepSession {
        let date = calendar.date(byAdding: .day, value: -dayOffset, to: day)!
        let onset = date.addingTimeInterval(onsetHour * 3600)
        let total = light + deep + rem + awake
        return SleepSession(
            date: date,
            startTime: onset,
            endTime: onset.addingTimeInterval(total),
            targetSleepNeedSeconds: need,
            lightSleepSeconds: light,
            deepSleepSeconds: deep,
            remSleepSeconds: rem,
            awakeSeconds: awake,
            sleepConsistency: consistency)
    }

    static func run() async throws {
        // 100 / 100 / 100 / 100. Restorative is 5 h of 8 h asleep, which normalizes past the 50%
        // target and is therefore capped, not allowed to lift the score above 100.
        let perfect = session(
            light: 3 * 3600, deep: 2 * 3600, rem: 3 * 3600, need: 8 * 3600, consistency: 100)
        let perfectScore = SleepScoreScoring.score(
            for: perfect, consistency: perfect.sleepConsistency, age: nil)
        assertTest(perfectScore?.value == 100, "A night at full marks on all four terms scores 100")

        // 80 sufficiency, 50 efficiency, 40 restorative, 20 timing.
        // (45×80 + 20×50 + 20×40 + 15×20) / 100 = 57.
        let known = session(
            light: 6.4 * 3600, deep: 0.8 * 3600, rem: 0.8 * 3600, awake: 8 * 3600,
            need: 10 * 3600, consistency: 20)
        let knownScore = SleepScoreScoring.score(
            for: known, consistency: known.sleepConsistency, age: nil)
        assertTest(knownScore?.value == 57, "The four weights produce the hand-computed 57")
        assertTest(knownScore?.components[.sufficiency] == 80, "Sufficiency is asleep over need")
        assertTest(knownScore?.components[.efficiency] == 50, "Efficiency is asleep over sleep period")
        assertTest(knownScore?.components[.restorative] == 40, "A 20% restorative share is 40 against 50%")
        assertTest(knownScore?.components[.timing] == 20, "Timing carries the consistency figure")
        assertTest(knownScore?.timingSource == .consistency, "Stored consistency is the timing source")

        // Swapping the sufficiency and timing values must move the result; this fails if the weights
        // are transposed.
        let swapped = session(
            light: 6.4 * 3600, deep: 0.8 * 3600, rem: 0.8 * 3600, awake: 8 * 3600,
            need: 40 * 3600, consistency: 80)
        let swappedScore = SleepScoreScoring.score(
            for: swapped, consistency: swapped.sleepConsistency, age: nil)
        assertTest(
            swappedScore?.value == 39,
            "20 sufficiency and 80 timing score 39, not the 57 of the reverse pair")

        // Renormalization: no timing, no age. The denominator is 85, not 100.
        let noTiming = SleepScoreScoring.score(
            for: known, consistency: nil, age: nil)
        assertTest(noTiming?.value == 64, "Missing timing renormalizes to an 85 denominator")
        assertTest(noTiming?.coverage.weightCovered == 85, "Coverage reports the 85 points it used")
        assertTest(noTiming?.coverage.missing == [.timing], "Coverage names the missing term")
        assertTest(noTiming?.coverage.isComplete == false, "Three of four is not complete")

        // Zero need: sufficiency is absent, and the legacy property's 100 is not what the composite
        // uses. The two are pinned together so the divergence is a fact rather than a surprise.
        let noNeed = session(
            light: 6.4 * 3600, deep: 0.8 * 3600, rem: 0.8 * 3600, awake: 8 * 3600,
            need: 0, consistency: 20)
        let noNeedScore = SleepScoreScoring.score(
            for: noNeed, consistency: noNeed.sleepConsistency, age: nil)
        assertTest(noNeed.sleepSufficiencyPercentage == 100, "The legacy row still answers 100 for zero need")
        assertTest(noNeedScore?.components[.sufficiency] == nil, "The composite treats zero need as absent")
        assertTest(noNeedScore?.coverage.weightCovered == 55, "Three remaining terms cover 55 points")
        assertTest(noNeedScore?.value == 38, "The zero-need night renormalizes to 38")

        // One term is not a composite. A different day, so the score-map assertion below is about
        // the absence of this night rather than an overwrite of another day's key.
        let noData = session(dayOffset: 10, light: 0, deep: 0, rem: 0, awake: 0, need: 8 * 3600)
        assertTest(
            SleepScoreScoring.score(for: noData, consistency: nil, age: nil) == nil,
            "A single available term produces no score")

        // A stored figure wins over the model, even when the priors would score very differently.
        let priors = (1 ... 4).map { offset in
            session(dayOffset: offset, light: 8 * 3600, onsetHour: -8, consistency: nil)
        }
        let imported = session(light: 8 * 3600, onsetHour: -1, consistency: 90)
        assertTest(
            SleepScoreScoring.resolveConsistency(for: imported, history: priors) == 90,
            "An imported night's stored consistency is not recomputed")

        // A strap night with four aligned priors is scored by the model.
        let aligned = (1 ... 4).map { offset in
            session(dayOffset: offset, light: 8 * 3600, onsetHour: -1, consistency: nil)
        }
        let strap = session(light: 8 * 3600, onsetHour: -1, consistency: nil)
        let strapConsistency = SleepScoreScoring.resolveConsistency(for: strap, history: aligned)
        assertTest(strapConsistency != nil, "Four priors produce a model consistency")
        assertTest(
            (strapConsistency ?? 0) >= 90,
            "A night aligned with its four priors scores high consistency")

        // The age fallback is used only when consistency is absent. This night is centred on 4:30,
        // the age-20 target, so timing is 100 — and the source says it was the prior, not the model.
        let ageNight = session(
            light: 8 * 3600, need: 8 * 3600, onsetHour: 0.5, consistency: nil)
        let ageScore = SleepScoreScoring.score(for: ageNight, consistency: nil, age: 20)
        assertTest(ageScore?.components[.timing] == 100, "A night on the age target scores full timing")
        assertTest(ageScore?.timingSource == .agePrior, "The timing source is the age prior")
        assertTest(
            SleepScoreScoring.score(for: ageNight, consistency: nil, age: nil)?.components[.timing] == nil,
            "Without an age the fallback is absent, not neutral")

        // Clamping at both ends.
        let over = session(light: 10 * 3600, need: 8 * 3600, onsetHour: -3, consistency: 100)
        assertTest(
            SleepScoreScoring.score(for: over, consistency: 100, age: nil)?.components[.sufficiency] == 100,
            "Oversleeping is capped at 100 sufficiency, not allowed above it")

        // The per-day map keys the score by the wake day and leaves a night with one term out.
        let map = SleepScoreScoring.scores(
            for: [known, noData], age: nil, calendar: calendar)
        assertTest(
            map[calendar.startOfDay(for: known.date)]?.value == 57,
            "The score map keys the known night by its start-of-day")
        assertTest(
            map[calendar.startOfDay(for: noData.date)] == nil,
            "A night with one term is absent from the score map")

        // The week's slots and the scorer agree, including the oldest slot's timing, which needs
        // priors from before the seven-day window. The week is handed nineteen days for exactly this
        // reason; a seven-day read would leave that slot without a consistency term.
        let weekDays = (0 ..< 7).map { offset in
            session(
                dayOffset: offset, light: 4 * 3600, deep: 2 * 3600, rem: 2 * 3600,
                need: 8 * 3600, onsetHour: -1)
        }
        let weekPriors = (7 ..< 19).map { offset in
            session(
                dayOffset: offset, light: 4 * 3600, deep: 2 * 3600, rem: 2 * 3600,
                need: 8 * 3600, onsetHour: -1)
        }
        let allNights = weekDays + weekPriors
        let week = MetricWeek(endingOn: day, sleep: allNights, age: nil)

        let newest = weekDays[0]
        let newestExpected = SleepScoreScoring.score(
            for: newest,
            consistency: SleepScoreScoring.resolveConsistency(for: newest, history: allNights),
            age: nil)
        assertTest(
            week.days.last?.sleepScore == newestExpected?.value,
            "The week's newest slot carries the scorer's value for that night")

        let oldest = weekDays[6]
        let oldestExpected = SleepScoreScoring.score(
            for: oldest,
            consistency: SleepScoreScoring.resolveConsistency(for: oldest, history: allNights),
            age: nil)
        assertTest(
            week.days.first?.sleepScore == oldestExpected?.value,
            "The week's oldest slot carries the scorer's value too")
        assertTest(
            oldestExpected?.timingSource == .consistency,
            "The oldest slot's timing comes from priors before the seven-day window")
    }
}
