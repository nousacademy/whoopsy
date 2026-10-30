import Foundation
import Whoopsy

// MARK: - 16. The strain card's two computed figures

/// `StrainDayActivity` — the zone aggregate's producer rule and the strength figure's definition.
///
/// The card draws four rows, and this file pins the two that are computed rather than stored: which
/// producer a day's zone time came from (and therefore whether a comparison may be printed), and what
/// strength activity time means now that the app defines its own list. Both are rules a screenshot
/// cannot see — a measured figure drawn against an imported mean looks exactly like a correct one.
enum StrainDayActivityTests {
    static func run() async throws {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))

        func session(
            name: String? = nil,
            minutes: Double = 60,
            block: [Double]? = nil
        ) -> WorkoutSession {
            WorkoutSession(
                startedAt: day.addingTimeInterval(9 * 3600),
                endedAt: day.addingTimeInterval(9 * 3600 + minutes * 60),
                strain: 5,
                averageHeartRate: 120,
                maxHeartRate: 160,
                route: [],
                splits: [],
                activityName: name,
                hrZonePercents: block)
        }

        /// One session's fold: 60 s in zone 1, 30 in zone 2, 10 in zone 3, 5 in zone 4, 1 in zone 5.
        let folded = ZoneTimeMath.Totals(
            zoneSeconds: [60, 30, 10, 5, 1], measuredSeconds: 120, sampleCount: 120)

        // MARK: The zone rows, one producer per figure

        let measured = session(block: [50, 50, 0, 0, 0])
        let measuredOnly = StrainDayActivity.zoneTime(
            for: [measured], measured: [measured.id: folded])

        assertTest(
            measuredOnly.value?.zone1to3Seconds == 100 && measuredOnly.value?.zone4to5Seconds == 6,
            "A measured session's zone time is the sample fold — 1–3 and 4–5 summed from the five "
                + "bands — and it wins over a block on the same session, because the readings are the "
                + "actual measurement and the block is a rounded share")

        assertTest(
            measuredOnly.isMeasuredOnly,
            "…and the day is marked measured-only, which is what withholds the comparison against a "
                + "baseline built from WHOOP's blocks")

        let imported = session(minutes: 100, block: [10, 20, 30, 25, 5])
        let importedOnly = StrainDayActivity.zoneTime(for: [imported], measured: [:])

        assertTest(
            importedOnly.value?.zone1to3Seconds == imported.zone1to3Seconds
                && importedOnly.value?.zone4to5Seconds == imported.zone4to5Seconds
                && importedOnly.value?.zone1to3Seconds == 3600,
            "A session with no samples falls back to WHOOP's block scaled by its own span "
                + "(\(String(describing: importedOnly.value?.zone1to3Seconds)) s in 1–3)")

        assertTest(
            !importedOnly.isMeasuredOnly,
            "…and that day is *not* measured-only, so its baseline — the same producer — may be drawn")

        let mixed = StrainDayActivity.zoneTime(
            for: [measured, imported], measured: [measured.id: folded])
        assertTest(
            !mixed.isMeasuredOnly && mixed.value != nil,
            "A day holding one measured session and one imported one is not measured-only: a mean "
                + "taken over one producer must not be printed beside a figure built from both")

        assertTest(
            StrainDayActivity.zoneTime(for: [], measured: [:]).value == nil,
            "No sessions is no zone time, not a zero")

        let noProducer = StrainDayActivity.zoneTime(for: [session()], measured: [:])
        assertTest(
            noProducer.value == nil && !noProducer.isMeasuredOnly,
            "A session with neither samples nor a block is an absence — the state a recording made "
                + "before the measured path existed is in, and the state that draws a dash")

        // MARK: Strength activity time

        let lifting = session(name: "Weightlifting", minutes: 45)
        let running = session(name: "Running", minutes: 60)
        let strength = StrainDayActivity.strengthSeconds(for: [lifting, running])

        assertTest(
            strength == 45 * 60,
            "Strength time is the span of the day's strength sessions and nothing else — the run "
                + "contributes none (\(String(describing: strength)) s)")

        assertTest(
            WhoopActivityCatalog.isStrength("weightlifting ") && !WhoopActivityCatalog.isStrength("F45 Training"),
            "The strength test is the catalogue's own name comparison — normalised, so a stray space "
                + "and a different case still match — and a name outside the four is not a strength "
                + "session")

        assertTest(
            StrainDayActivity.strengthSeconds(for: [running]) == 0,
            "…and a day with a workout and no strength session is a real `0`, not a dash: no time was "
                + "spent doing strength work, which is a reading")

        assertTest(
            StrainDayActivity.strengthSeconds(for: []) == nil,
            "…while a day with no workouts at all is `nil`, the same day the whole card is absent on")

        // MARK: The strength baseline

        func dayOffset(_ offset: Int) -> Date {
            calendar.date(byAdding: .day, value: offset, to: day) ?? day
        }
        func session(on offset: Int, name: String?, minutes: Double) -> WorkoutSession {
            let start = dayOffset(offset)
            return WorkoutSession(
                startedAt: start,
                endedAt: start.addingTimeInterval(minutes * 60),
                strain: 5, averageHeartRate: 120, maxHeartRate: 160,
                route: [], splits: [], activityName: name)
        }

        let prior = [
            session(on: -3, name: "Weightlifting", minutes: 10),
            session(on: -2, name: "Running", minutes: 30),
            session(on: -1, name: "Weightlifting", minutes: 20),
        ]

        assertTest(
            StrainDayActivity.strengthBaseline(from: prior, before: day) == (600 + 0 + 1200) / 3.0,
            "The baseline is the window's mean per day, and a day with workouts but no strength "
                + "session contributes its real zero rather than dropping out")

        assertTest(
            StrainDayActivity.strengthBaseline(from: Array(prior.prefix(2)), before: day) == nil,
            "…withheld below `minimumBaselineDays`, the same floor the zone and step means use, so "
                + "the card's three comparisons cannot disagree about how much history a mean needs")
    }
}
