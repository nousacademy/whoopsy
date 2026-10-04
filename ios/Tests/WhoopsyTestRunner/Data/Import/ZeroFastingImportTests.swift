import Foundation
import Whoopsy

// MARK: - 20. The Zero fasting import

/// The Zero fasting import — a fourth producer of `workouts` rows, and the first one in this app with
/// **no measurement behind it at all**.
///
/// ## What this section is shaped by
///
/// 1. **A fast has no strain and no heart rate, and that is the whole reason `v18` exists.** `v6`
///    declared `strain`, `average_heart_rate` and `max_heart_rate` NOT NULL, which was correct while a
///    strap was the only writer; a fasting window has none of the three, and a NOT NULL column leaves
///    it only one thing to write — a `0` that reads as *measured, and no strain at all*. The
///    migration relaxes the three, and block B is where the absences are asserted one at a time on a
///    row **read back out of the database**, because the failure this guards against is a mapper or a
///    record quietly turning NULL into `0` on the way out.
/// 2. **The parser throws on a row it cannot place; it never skips one.** That is
///    `WhoopExportParser`'s hard-won rule — a `guard … else { continue }` once discarded every row of
///    a file and reported a successful import of nothing — and block A asserts the throwing half
///    directly, because an import that silently drops rows reports the same green as one that does not.
/// 3. **The export's day-already-recorded skip must not count a fast.** `recordedWorkoutDays()` asks
///    whether a day holds *any* workout and refuses every export row landing on one; once fasts are in
///    `workouts`, a fast's start day would read as recorded and the export's rows for it would be
///    dropped — **measured, 16 of the file's 673 rows sit on the 10 days that are also fast start
///    days**. So the two imports would erase each other's days depending on which button was pressed
///    first. Block B asserts the fix from **both directions**, which is the only shape that can see it:
///    a one-direction assertion passes on whichever order happens to work.
/// 4. **The two figures a session prints are absence rules, and until `v18` neither could be
///    exercised** — `WorkoutSession.strain` was non-optional, so there was no such thing as a session
///    with no strain to draw. `ActivityFigure` is a value type rather than two expressions in the two
///    views that draw them for this repo's standing reason (the runner has no renderer), and block C
///    is its only coverage.
/// 5. **`ActivityBaseline`'s strain mean is a third population.** While every session had a strain the
///    window and the strain population were the same set; a fast parts them, and averaging `?? 0` over
///    a mixed window is worse than withholding the figure — a window of ten fasts reports a
///    **fabricated** `0.0`, and three measured priors at `7.0` beside seven fasts reports `2.1`.
///
/// **None of it is evidence about a strap.** Like §16–§19, `biometric_samples` holds 0 rows on every
/// database on this machine; what this proves is parsing, storage, the day-skip fix and the two figure
/// rules. The 170 fasts are a real file, so the row count, the instants and the id syntax are facts
/// about a producer — and the three figures are facts about no producer at all, which is the point.


/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
///
/// The blocks live in sibling files, one per topic, cut at this section's own
/// `// MARK: - ` boundaries and moved verbatim — so the counterpart of each app file sits
/// beside this one, and this file says only which of them run, and in what order.
enum ZeroFastingImportTests {
    static func run() async throws {
        try await ZeroFastingParserTests.run()

        // One database, built here and threaded into both blocks that need it. §6.2: the
        // import below writes through this repository and the covering-read block reads what
        // it wrote, so recreating either would keep every assertion green while deleting the
        // guarantee — the covering read would find an empty database.
        let db = LocalDatabaseManager(inMemory: true)
        let repository = GRDBWorkoutRepository(db: db)

        try await ZeroFastingImporterTests.run(repository: repository)
        try await ActivityFigureTests.run()
        try await FastingZoneTests.run()
        try await FastingDayZoneTests.run()
        try await FastingEndTextTests.run()
        try await WorkoutCoveringReadTests.run(repository: repository)
    }

    // MARK: The builders and the two values the section shares across its files

    /// §15's `TypicalRangeTests.breakdown` precedent: a fixture more than one topic file needs
    /// lives as a namespace static on the section's own dispatcher enum, so there is one
    /// definition of it rather than one per caller.
    ///
    /// **None of the four functions is state.** They are pure functions of their arguments, so
    /// a call from another file produces exactly what the declaring file would have got. §6.2's
    /// rule about not recreating shared things is about *accumulating* state — a database, a
    /// repository, a session — which these are not.
    ///
    /// `anchor` and `dayCalendar` are here rather than in a topic file for a different reason:
    /// they are read by the *bodies* above and below this comment, so they cannot be a one-line
    /// alias anywhere. Both are pure values — a literal instant and `Calendar.current` — which
    /// is what makes hoisting them safe rather than a second copy of something that moves.

    static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    static let dayCalendar = Calendar.current

    /// A session at a known offset carrying only what the block needs.
    static func session(
        _ name: String?, strain: Double?, durationSeconds: TimeInterval = 3600
    ) -> WorkoutSession {
        WorkoutSession(
            startedAt: anchor,
            endedAt: anchor.addingTimeInterval(durationSeconds),
            strain: strain,
            averageHeartRate: strain == nil ? nil : 121,
            maxHeartRate: strain == nil ? nil : 164,
            route: [], splits: [],
            source: ZeroFastingImporter.sourceLabel,
            activityName: name)
    }

    /// A local wall-clock instant on a named day.
    static func localInstant(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0
    ) -> Date {
        dayCalendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second))
            ?? Date(timeIntervalSince1970: 0)
    }

    /// A fast of `seconds` starting at `start`, carrying what `ZeroFastingImporter` actually writes:
    ///
    /// no strain, no heart rates, and the label. Built rather than run through the importer because
    /// these fixtures are about the arithmetic, and the importer's own output is asserted above.
    static func fastSession(startingAt start: Date, seconds: TimeInterval) -> WorkoutSession {
        WorkoutSession(
            startedAt: start,
            endedAt: start.addingTimeInterval(seconds),
            strain: nil, averageHeartRate: nil, maxHeartRate: nil,
            route: [], splits: [],
            source: ZeroFastingImporter.sourceLabel,
            activityName: "Fast")
    }

    /// Every calendar day a session's span *touches*, as candidates.
    ///
    /// **Candidates and not answers, deliberately.** A session ending exactly at `00:00:00` touches
    /// the day it ends at without covering it, so the caller must still apply the half-open rule —
    /// the two assertions below that compare a covering read against a derived expectation build
    /// their map by applying it per candidate rather than including the range blindly, which is what
    /// makes that off-by-one-day visible instead of built in.
    static func coveredDayCandidates(of session: WorkoutSession) -> [Date] {
        var days: [Date] = []
        var day = dayCalendar.startOfDay(for: session.startedAt)
        let last = dayCalendar.startOfDay(for: session.endedAt)
        while day <= last {
            days.append(day)
            day = dayCalendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return days
    }
}
