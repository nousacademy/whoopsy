import Foundation
import Whoopsy

enum SleepEfficiencyCardTests {
    static func run() async throws {
        // ── 11. The efficiency card ──────────────────────────────────────────────────────────────────
        //
        // Two things here have no renderer and so are asserted as words: the card's two slots carry a
        // note rather than a reading, and the note is the whole of what they currently say. The third is
        // the window mean's filter, which is the assertion that would silently pass a wrong rule — a
        // night with no sleep period reports `100%` through the entity's own guard, so a mean that
        // counted it would be averaging a fabricated perfect night.
        do {
            let calendar = Calendar.current
            let base = calendar.startOfDay(for: Date())

            /// A night whose efficiency is exactly `asleep / (asleep + awake)`.
            func effNight(_ dayOffset: Int, asleep: TimeInterval, awake: TimeInterval) -> SleepSession {
                SleepSession(
                    date: calendar.date(byAdding: .day, value: -dayOffset, to: base)!,
                    startTime: base,
                    endTime: base,
                    lightSleepSeconds: asleep,
                    awakeSeconds: awake)
            }

            func near(_ left: Double, _ right: Double) -> Bool { abs(left - right) < 0.0001 }

            // Four nights at 100% and one at 50% is 90 — a literal a reader can check by hand.
            let full = effNight(1, asleep: 3600, awake: 0)
            let half = effNight(2, asleep: 1800, awake: 1800)
            assertTest(
                SleepEfficiencyScoring.typicalEfficiency(in: [full, full, full, full, half])
                    .map { near($0, 90) } == true,
                "Four nights at 100 percent and one at 50 average to 90 "
                    + "(got \(String(describing: SleepEfficiencyScoring.typicalEfficiency(in: [full, full, full, full, half]))))")

            // The discriminating pair. `SleepSession.sleepEfficiencyPercentage` guards a zero sleep
            // period by returning 100, so an empty night that is *not* filtered enters the mean as a
            // perfect one: the correct answer is 83.33 and the unfiltered one is 87.5.
            let empty = effNight(3, asleep: 0, awake: 0)
            assertTest(
                SleepEfficiencyScoring.typicalEfficiency(in: [full, full, half, empty])
                    .map { near($0, 250.0 / 3.0) } == true,
                "A night with no sleep period is filtered out of the window before the mean is taken. "
                    + "Counting it would print 87.5 by averaging in the `100` the entity's own guard "
                    + "returns for a night with nothing to divide "
                    + "(got \(String(describing: SleepEfficiencyScoring.typicalEfficiency(in: [full, full, half, empty]))))")

            // …and the floor counts the nights that survived the filter, not the ones in the window.
            assertTest(
                SleepEfficiencyScoring.typicalEfficiency(in: [full, full, empty]) == nil,
                "Two scored nights beside an empty one is still below `minimumBaselineDays`: the floor "
                    + "is a count of measured nights, and a night with no sleep period is not one")

            // Efficiency and performance are different quantities, and the two cards print both.
            let short = SleepSession(
                date: base, startTime: base, endTime: base,
                targetSleepNeedSeconds: 7200,
                lightSleepSeconds: 3600,
                awakeSeconds: 0)
            assertTest(
                short.sleepEfficiencyPercentage == 100 && short.sleepPerformancePercentage == 50,
                "An hour slept through against a two-hour need is 100 percent efficiency and 50 percent "
                    + "performance — asleep over the sleep period, and asleep over the need "
                    + "(got \(short.sleepEfficiencyPercentage) and \(short.sleepPerformancePercentage))")

            // The card's words, because there is no renderer here to look at the slots.
            assertTest(
                SleepEfficiencyCard.strapDataNote == "Strap data not available."
                    && SleepEfficiencyCard.strapMarker == "✱"
                    && SleepEfficiencyCard.strapMarker != "—",
                "A slot with no producer says `Strap data not available.` under an asterisk, and the "
                    + "marker is not this app's dash — a dash is a figure that was measured and came "
                    + "back absent, and efficiency is measured on every night this app can show "
                    + "(got \(SleepEfficiencyCard.strapMarker))")

            let noCount = SleepEfficiencyCard.spoken(
                efficiencyPercent: 94, asleepSeconds: 27180, awakeSeconds: 1740,
                typicalEfficiencyPercent: 87.4, disturbanceCount: nil, timelineLanes: nil)
            assertTest(
                noCount.contains("Sleep Efficiency, 94 percent")
                    && noCount.contains("typical 87 percent")
                    && noCount.contains("Asleep, 7h 33m")
                    && noCount.contains("Awake, 0h 29m"),
                "The card is announced with its figure, its comparison and its two durations, and the "
                    + "durations are spelled as durations rather than as the clock form printed "
                    + "(got \(noCount))")

            assertTest(
                noCount.contains(SleepEfficiencyCard.strapDataNote)
                    && noCount.contains("The night's sleep timeline was not recorded."),
                "…and both absences are spoken as well as drawn. A listener gets no slot and no "
                    + "asterisk, so a description that omitted them would announce two figures and "
                    + "silently drop the two things a sighted reader is told are missing "
                    + "(got \(noCount))")

            let counted = SleepEfficiencyCard.spoken(
                efficiencyPercent: 94, asleepSeconds: 27180, awakeSeconds: 1740,
                typicalEfficiencyPercent: nil, disturbanceCount: 12, timelineLanes: nil)
            assertTest(
                counted.contains("Wake Events, 12")
                    && !counted.contains(SleepEfficiencyCard.strapDataNote)
                    && !counted.contains("typical"),
                "A night a strap counted disturbances for names the count and withholds both the note "
                    + "and a comparison the window could not make "
                    + "(got \(counted))")

            // ── The timeline lanes ───────────────────────────────────────────────────────────────────
            //
            // The card's middle is a picture, and this runner has no renderer — so what is asserted here
            // is the arithmetic the picture is made of, resolved into `SleepTimelineLanes` rather than
            // drawn. Three properties carry the weight: the absence rule, the merge, and the scale.
            let laneStart = Date(timeIntervalSince1970: 1_700_000_000)

            /// A night of `count` 30-second epochs of `stage`, laid end to end from `laneStart`.
            func epochs(_ stages: [SleepStageType]) -> [SleepStageSegment] {
                stages.enumerated().map { index, stage in
                    let from = laneStart.addingTimeInterval(Double(index) * 30)
                    return SleepStageSegment(
                        startTime: from, endTime: from.addingTimeInterval(30), stage: stage)
                }
            }

            assertTest(
                SleepTimelineLanes.make(segments: [], start: laneStart, end: laneStart.addingTimeInterval(3600))
                    == nil,
                "A night with no segments has no timeline, and the card draws its note — an instance with "
                    + "two empty lanes would be a drawn timeline of a night with neither sleep nor "
                    + "wakefulness in it")

            assertTest(
                SleepTimelineLanes.make(
                    segments: epochs([.light]), start: laneStart, end: laneStart) == nil,
                "…and neither does a night with no duration, which is the guard that keeps `make` from "
                    + "dividing by zero into two `NaN` lanes — a mark that takes the whole bar with it "
                    + "rather than one drawn in the wrong place")

            // Three adjacent asleep epochs. One span, not three: an unmerged lane is hundreds of abutting
            // rectangles on a real night, and anti-aliasing draws a hairline of track between each pair,
            // so eight hours of unbroken sleep comes out looking striped.
            let solid = SleepTimelineLanes.make(
                segments: epochs([.light, .light, .light]),
                start: laneStart, end: laneStart.addingTimeInterval(90))
            assertTest(
                solid?.asleep.count == 1
                    && solid?.asleep.first?.start == 0
                    && abs((solid?.asleep.first?.end ?? 0) - 1) < 1e-9,
                "Three abutting epochs of sleep are one run covering the whole period, not three "
                    + "rectangles — the merge is what makes a lane mean `a stretch of this state` rather "
                    + "than `an epoch` (got \(String(describing: solid?.asleep)))")

            // A waking in the middle. The asleep lane splits in two and the awake lane holds the gap —
            // the two lanes are complements, which is what makes the pair read as one night.
            let broken = SleepTimelineLanes.make(
                segments: epochs([.light, .awake, .deep]),
                start: laneStart, end: laneStart.addingTimeInterval(90))
            assertTest(
                broken?.asleep.count == 2 && broken?.awake.count == 1,
                "An awake epoch between two asleep ones splits the asleep lane in two and puts one run in "
                    + "the awake lane (got \(String(describing: broken?.asleep)) / "
                    + "\(String(describing: broken?.awake)))")

            assertTest(
                abs((broken?.awake.first?.start ?? 0) - 1.0 / 3) < 1e-9
                    && abs((broken?.awake.first?.end ?? 0) - 2.0 / 3) < 1e-9,
                "…and the awake run sits at the middle third of the sleep period, which is the scale both "
                    + "lanes are drawn on: a fraction of the night rather than of the day "
                    + "(got \(String(describing: broken?.awake.first)))")

            // `deep` and `rem` are asleep for this purpose. Only `.awake` is awake, and a lane that
            // treated each sleep stage as its own state would leave the lane half empty on a real night.
            let stages = SleepTimelineLanes.make(
                segments: epochs([.light, .deep, .rem, .awake]),
                start: laneStart, end: laneStart.addingTimeInterval(120))
            assertTest(
                stages?.asleep.count == 1 && stages?.awake.count == 1,
                "All three sleep stages fill the asleep lane as one run, so only the fourth stage lands "
                    + "in the awake lane (got \(String(describing: stages?.asleep)) / "
                    + "\(String(describing: stages?.awake)))")

            // A segment outside the period is clamped into the lane rather than drawn off it: a mark
            // outside the scale reads as a different scale, not as a wrong reading.
            let overhang = SleepTimelineLanes.make(
                segments: [
                    SleepStageSegment(
                        startTime: laneStart.addingTimeInterval(-600),
                        endTime: laneStart.addingTimeInterval(600), stage: .light)
                ],
                start: laneStart, end: laneStart.addingTimeInterval(600))
            assertTest(
                overhang?.asleep.first?.start == 0 && abs((overhang?.asleep.first?.end ?? 0) - 1) < 1e-9,
                "A segment reaching outside the sleep period is clamped into the lane rather than drawn "
                    + "past its end (got \(String(describing: overhang?.asleep)))")

            // The spoken form, which is the only lane content a listener gets.
            let spokenLanes = SleepEfficiencyCard.spoken(
                efficiencyPercent: 94, asleepSeconds: 27180, awakeSeconds: 1740,
                typicalEfficiencyPercent: 87.4, disturbanceCount: nil, timelineLanes: broken)
            assertTest(
                spokenLanes.contains("The night's sleep timeline was recorded")
                    && spokenLanes.contains("1 stretches of waking")
                    && !spokenLanes.contains("was not recorded"),
                "A night with a timeline is announced as recorded and says how many stretches of waking "
                    + "the lanes hold, rather than claiming no timeline was recorded "
                    + "(got \(spokenLanes))")

            // **The two slots are gated apart.** A night can hold a stored timeline and no disturbance
            // count, and it must then speak one note and not two — a single `hasStrapData` flag would
            // have made both slots answer to one producer.
            assertTest(
                spokenLanes.contains(SleepEfficiencyCard.strapDataNote)
                    && spokenLanes.contains("Wake Events"),
                "…and the `WAKE EVENTS` note is still spoken on that same night, because the count and "
                    + "the timeline have different producers and neither speaks for the other "
                    + "(got \(spokenLanes))")

            // ── The timeline survives the round trip ─────────────────────────────────────────────────
            //
            // Until `v12` the segments were computed and dropped at the write, so this is the assertion
            // that fails if the column, the record property or the mapper is removed: it is the whole
            // reason the card can draw a timeline on a night it was not running for.
            do {
                let timelineDB = LocalDatabaseManager(inMemory: true)
                let repo = GRDBSleepRepository(db: timelineDB)
                let segments = epochs([.light, .deep, .awake, .rem])
                let night = SleepSession(
                    date: laneStart, startTime: laneStart,
                    endTime: laneStart.addingTimeInterval(120),
                    targetSleepNeedSeconds: 28800,
                    lightSleepSeconds: 30, deepSleepSeconds: 30, remSleepSeconds: 30,
                    awakeSeconds: 30,
                    sleepStages: segments)
                try await repo.saveSleepSession(night)
                let roundTripped = try await repo.getSleepSession(for: laneStart)

                assertTest(
                    roundTripped?.sleepStages.count == 4,
                    "A night's stage timeline survives the write and the read — the column `v12` added is "
                        + "what lets a recording outlive the moment it was made "
                        + "(got \(roundTripped?.sleepStages.count ?? -1))")
                assertTest(
                    roundTripped?.sleepStages.map(\.stage) == [.light, .deep, .awake, .rem],
                    "…in order, with each epoch's own stage, so the timeline drawn from storage is the "
                        + "one the classifier made (got "
                        + "\(String(describing: roundTripped?.sleepStages.map(\.stage))))")

                // An imported night writes `[]` and must come back as an empty timeline rather than as a
                // stored empty one — "never staged" and "staged as nothing" are the same fact and only
                // one of them gets a representation.
                let imported = SleepSession(
                    date: laneStart.addingTimeInterval(86400),
                    startTime: laneStart, endTime: laneStart.addingTimeInterval(28800),
                    targetSleepNeedSeconds: 28800,
                    lightSleepSeconds: 14400, deepSleepSeconds: 7200, remSleepSeconds: 7200,
                    awakeSeconds: 1800)
                try await repo.saveSleepSession(imported, source: WhoopExportImporter.sourceLabel)
                let importedBack = try await repo.getSleepSession(
                    for: laneStart.addingTimeInterval(86400))

                assertTest(
                    importedBack?.sleepStages.isEmpty == true,
                    "A night with no timeline stores NULL and reads back empty, rather than storing an "
                        + "empty array that would make `was this night staged?` unanswerable from the row "
                        + "(got \(String(describing: importedBack?.sleepStages)))")
                assertTest(
                    SleepTimelineLanes.make(
                        segments: importedBack?.sleepStages ?? [],
                        start: importedBack?.startTime ?? laneStart,
                        end: importedBack?.endTime ?? laneStart) == nil,
                    "…and that empty timeline produces no lanes, so the card draws its note on an "
                        + "imported night — which is every night the export can supply, permanently")
            } catch {
                assertTest(false, "The timeline round trip threw: \(error)")
            }
        }

        do {
            let csvURL = whoopExportURL()
            guard FileManager.default.fileExists(atPath: csvURL.path) else {
                assertTest(false, "The bundled export is missing at \(csvURL.path)")
                return
            }

            let exportDB = LocalDatabaseManager(inMemory: true)
            let exportSleepRepository = GRDBSleepRepository(db: exportDB)
            _ = try await WhoopExportImporter(
                recoveryRepository: GRDBRecoveryRepository(db: exportDB),
                sleepRepository: exportSleepRepository,
                strainRepository: GRDBStrainRepository(db: exportDB),
                napRepository: GRDBNapRepository(db: exportDB),
                workoutRepository: GRDBWorkoutRepository(db: exportDB),
                userProfileRepository: GRDBUserProfileRepository(db: exportDB),
                calendar: Calendar.current
            ).importExport(at: csvURL)

            let imported = try await exportSleepRepository.getSleepHistory(days: 4000)
            let withPeriod = imported.filter { $0.sleepPeriodSeconds > 0 }

            // The identity the card prints two separate figures for, over real data: a reader adding the
            // `ASLEEP` and `AWAKE` rows up reaches the ratio in the headline.
            let offBy = withPeriod.filter { session in
                let exact = session.totalTimeAsleepSeconds / session.sleepPeriodSeconds * 100
                return abs(exact - Double(session.sleepEfficiencyPercentage)) > 0.5
            }
            assertTest(
                offBy.isEmpty,
                "Every imported night's efficiency is its own asleep over its own sleep period, so the "
                    + "two durations the card prints are the ratio above them "
                    + "(\(offBy.count) of \(withPeriod.count) disagree)")

            // The two cards on this page print different numbers, and this is what says so: a mutation
            // pointing the efficiency card at the performance figure would agree on every night.
            let disagreeing = withPeriod.filter {
                $0.sleepEfficiencyPercentage != $0.sleepPerformancePercentage
            }
            assertTest(
                disagreeing.count > 800,
                "…and efficiency is not performance. The two agree on few enough nights that a card "
                    + "reading one for the other is visible on real data "
                    + "(\(disagreeing.count) of \(withPeriod.count) differ)")

            // The restorative week's two bands are the night's own two stage columns and its labelled
            // figure is their sum — `SleepSession.restorativeSleepSeconds` — so the label and the stack
            // cannot come to describe different nights. Driven over every imported night rather than a
            // fixture, and asserted through `MetricWeek` rather than by reading the entity twice, because
            // the join is the thing that could drop or reorder a stage on its way to the chart.
            let splitMismatches = imported.filter { session in
                let day = Calendar.current.startOfDay(for: session.date)
                let week = MetricWeek(endingOn: day, sleep: [session])
                guard let slot = week.days.first(where: { $0.date == day }) else { return true }
                return slot.deepSleepSeconds != session.deepSleepSeconds
                    || slot.remSleepSeconds != session.remSleepSeconds
                    || (slot.deepSleepSeconds ?? 0) + (slot.remSleepSeconds ?? 0)
                        != session.restorativeSleepSeconds
            }
            assertTest(
                splitMismatches.isEmpty,
                "Every imported night's two stages reach a `MetricDay` unchanged and sum to the entity's "
                    + "own `restorativeSleepSeconds`, so the figure over a column is the two bands beneath "
                    + "it rather than a third number beside them "
                    + "(\(splitMismatches.count) of \(imported.count) disagree)")

            // The zero column is a real case in this file and not a defensive branch: 2024-12-10 is 15
            // hours 40 minutes of light sleep with no deep and no REM in it, which is the night the chart
            // draws as a labelled column carrying no bar. Asserted as a property rather than on that
            // date, so a device time zone that moves its day key does not weaken it.
            assertTest(
                imported.contains { $0.restorativeSleepSeconds == 0 },
                "…and a night with no restorative sleep at all is in the file, which is what makes the "
                    + "chart's zero-total column a case to handle rather than a hypothetical")

            // The time-in-bed week's two boundaries, over every imported night. Asserted through
            // `MetricWeek` rather than by reading the entity twice, because the join is the thing that
            // could convert a time in the wrong frame on its way to the chart.
            let boundaryMismatches = imported.filter { session in
                let day = Calendar.current.startOfDay(for: session.date)
                let week = MetricWeek(endingOn: day, sleep: [session])
                guard let slot = week.days.first(where: { $0.date == day }) else { return true }
                return slot.sleepOnsetMinutes
                        != SleepConsistencyMath.nightClockMinutes(
                            session.startTime, calendar: Calendar.current)
                    || slot.sleepWakeMinutes
                        != SleepConsistencyMath.nightClockMinutes(
                            session.endTime, calendar: Calendar.current)
            }
            assertTest(
                boundaryMismatches.isEmpty,
                "Every imported night's onset and wake reach a `MetricDay` as the night clock's own "
                    + "minutes, so the two times a column prints are the row's own and not a second "
                    + "conversion done somewhere else "
                    + "(\(boundaryMismatches.count) of \(imported.count) disagree)")

            // The refused-span branch, measured rather than assumed: a night whose wake does not come
            // after its own onset on the night clock is a row the chart drops a column for, and this says
            // whether that branch costs anything on real data. The twelve-hour night of 2024-12-09 is in
            // the file and is *not* one of these — a 16:16 onset with an 08:16 wake is one contiguous
            // sixteen-hour span on the pivot, which is why it widens the axis instead.
            let undrawable = imported.filter {
                !SleepClockAxis.isDrawable(
                    onset: SleepConsistencyMath.nightClockMinutes(
                        $0.startTime, calendar: Calendar.current),
                    wake: SleepConsistencyMath.nightClockMinutes(
                        $0.endTime, calendar: Calendar.current))
            }
            assertTest(
                undrawable.isEmpty,
                "…and no imported night contains noon on the night clock, so the chart's refused-span "
                    + "branch costs no column on any night the export can supply "
                    + "(\(undrawable.count) of \(imported.count) refused)")

            let earlyOnsets = imported.filter {
                SleepConsistencyMath.nightClockMinutes($0.startTime, calendar: Calendar.current)
                    < SleepClockAxis.defaultStartMinutes
            }
            assertTest(
                !earlyOnsets.isEmpty,
                "…and at least one imported night begins before the default axis' 7 PM top, which is "
                    + "what makes the whole-hour widening a fact about the producer rather than a case "
                    + "someone imagined: with \(imported.count) nights in the file and none of them "
                    + "early, the widening rule would be dead code")
        } catch {
            assertTest(false, "The efficiency block's export import threw: \(error)")
        }

    }
}
