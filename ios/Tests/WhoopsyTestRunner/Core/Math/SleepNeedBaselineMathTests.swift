import Foundation
import Whoopsy

/// The age bands behind the baseline `AnalyzeSleepUseCase` hands to `SleepNeedMath`.
enum SleepNeedBaselineMathTests {
    static func run() async throws {
        // Both boundaries, because an off-by-one here changes a user's nightly target by half an hour
        // and nothing on screen would say which side of the boundary they fell on.
        assertTest(
            SleepNeedBaselineMath.baselineHours(forAge: 17) == 9.0,
            "17 is the last adolescent year and takes the 9-hour midpoint")
        assertTest(
            SleepNeedBaselineMath.baselineHours(forAge: 18) == 8.0,
            "18 is an adult and takes the 8-hour midpoint")
        assertTest(
            SleepNeedBaselineMath.baselineHours(forAge: 64) == 8.0,
            "64 is the last adult year and stays on the 8-hour midpoint")
        assertTest(
            SleepNeedBaselineMath.baselineHours(forAge: 65) == 7.5,
            "65 takes the older-adult 7.5-hour midpoint")
        assertTest(
            SleepNeedBaselineMath.baselineHours(forAge: nil) == 8.0,
            "An absent birth date falls back to the adult midpoint, not a guessed age")
        assertTest(
            SleepNeedBaselineMath.baselineSeconds(forAge: 65) == 7.5 * 3600,
            "The seconds form is the hours form, not a second table")

        assertTest(
            SleepNeedBaselineMath.bandHours(forAge: 17) == 8.0 ... 10.0,
            "17 reads the teen band")
        assertTest(
            SleepNeedBaselineMath.bandHours(forAge: 30) == 7.0 ... 9.0,
            "30 reads the adult band")
        assertTest(
            SleepNeedBaselineMath.bandHours(forAge: 70) == 7.0 ... 8.0,
            "70 reads the older-adult band")
        assertTest(
            SleepNeedBaselineMath.bandHours(forAge: nil) == 7.0 ... 9.0,
            "An absent age reads the same adult band its point value came from")

        // ── The personal baseline ────────────────────────────────────────────────────────────────
        // Age is population context: it supplies the cold-start value, the floor and the cap. The
        // individual's own stored needs decide once there are seven of them.

        func night(needHours: Double, strain: Double? = 0) -> SleepNeedBaselineMath.NeedNight {
            SleepNeedBaselineMath.NeedNight(
                needSeconds: needHours * 3600, previousDayStrain: strain)
        }

        assertTest(
            SleepNeedBaselineMath.personalBaselineSeconds(for: [], age: nil) == 8 * 3600,
            "No history falls back to the adult population midpoint")
        assertTest(
            SleepNeedBaselineMath.personalBaselineSeconds(
                for: (0 ..< 6).map { _ in night(needHours: 9) }, age: 65) == 7.5 * 3600,
            "Six nights is below the floor and still the population midpoint")

        let nineHourNights = (0 ..< 7).map { _ in night(needHours: 9) }
        assertTest(
            SleepNeedBaselineMath.personalBaselineSeconds(
                for: nineHourNights, age: nil) == 9 * 3600,
            "Seven nights whose implied baseline is 9 h learn 9 h, above the adult midpoint")

        let shortNights = (0 ..< 7).map { _ in night(needHours: 6) }
        assertTest(
            SleepNeedBaselineMath.personalBaselineSeconds(
                for: shortNights, age: nil) == 7 * 3600,
            "A learned baseline below the population floor is raised to 7 h")
        assertTest(
            SleepNeedBaselineMath.personalBaselineSeconds(
                for: shortNights, age: 17) == 8 * 3600,
            "…and a teenager's floor is 8 h, not the adult 7")

        let longNights = (0 ..< 7).map { _ in night(needHours: 12) }
        assertTest(
            SleepNeedBaselineMath.personalBaselineSeconds(
                for: longNights, age: nil) == 9.5 * 3600,
            "A learned baseline above the cap is held at 9.5 h")

        // A prior night with no strain row cannot be inverted, so it is excluded rather than read
        // as a bare baseline.
        let mixedNights = (0 ..< 7).map { index in
            night(needHours: 9, strain: index == 0 ? nil : 0)
        }
        assertTest(
            SleepNeedBaselineMath.personalBaselineSeconds(
                for: mixedNights, age: nil) == 8 * 3600,
            "Six invertible nights out of seven is below the floor and falls back")

        // Only the last 28 records are read; an old 12-hour night cannot hold the median above the
        // current pattern.
        let oldHigh = [night(needHours: 12)] + (0 ..< 28).map { _ in night(needHours: 8) }
        assertTest(
            SleepNeedBaselineMath.personalBaselineSeconds(
                for: oldHigh, age: nil) == 8 * 3600,
            "The window takes the most recent 28 nights, not the whole history")
    }
}
