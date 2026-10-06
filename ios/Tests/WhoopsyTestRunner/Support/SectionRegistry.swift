import Foundation

// MARK: - Section selection

/// The sections to run, from `WHOOPSY_SECTIONS=13,15`. Empty means all of them.
///
/// Read once at launch rather than per section, so a section cannot be selected halfway through a run.
let selectedSections: Set<Int> = {
    guard let raw = ProcessInfo.processInfo.environment["WHOOPSY_SECTIONS"], !raw.isEmpty else {
        return []
    }
    return Set(raw.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
}()

// MARK: - The registry

/// One numbered section of the suite.
///
/// **A section's number is typed exactly once, and that is what this type buys.** It used to be written
/// four times — the `sectionEnabled(n)` call, the `// MARK: - n.` header, the `[n/20]` string printed
/// above the body, and the prose — so adding a section meant renumbering every header after it and
/// editing a doc sentence per section. Now the entry below is the only place the number appears, the
/// banner's denominator is the registry's own count, and **a new section takes the next free number and
/// nothing is renumbered.**
///
/// Numbers are therefore **stable identifiers, not positions**. `WHOOPSY_SECTIONS=13` keeps its meaning
/// for good, and §-references in `CLAUDE.md`, `docs/` and the section doc comments keep theirs.
struct TestSection {
    /// The stable `WHOOPSY_SECTIONS` key, and the numerator of the `[id/total]` banner above the body.
    let id: Int
    /// Printed after the id — the one-line statement of what the section covers.
    let title: String
    /// The section's body, awaited inside the `Task` by `runSections(_:)`.
    ///
    /// **Deliberately not `@MainActor`, and this is the one isolation fact the split must not change.**
    /// These bodies lived in `runMainSections()`, a plain `async throws` function, so every call they
    /// make into a `@MainActor` type is a real hop: the call suspends, the job is enqueued, and whatever
    /// the main actor already had queued runs first. Marking them `@MainActor` removes those hops and
    /// makes those calls synchronous — which changes what is *observable*, not merely how fast. Measured:
    /// §18's route block yields a GPS fix and then awaits `end()`; with an isolated body the consumer task
    /// that yield resumed is still queued when `end()` reads the route and the fourth fix is lost (3 kept
    /// where the assertion requires 4), while a nonisolated body lets it run first.
    ///
    /// `throws`, because the bodies it holds did: §6's exports and §11–§20's CSV reads all `try`. A throw
    /// propagates out through `runSections(_:)` into `main.swift`'s `do`/`catch` — the path it took before
    /// the split.
    ///
    /// `nil` for §1–§5, whose bodies are synchronous and are driven from top level by
    /// `runSynchronousSections(_:)`. Exactly one of the two is ever set.
    var body: (() async throws -> Void)?
    /// A §1–§5 body. `nil` for every section `body` is non-`nil` for.
    ///
    /// Deliberately **not** `@MainActor`, and that is a fact about where these five run rather than a
    /// preference: they are driven from top-level code, which `swiftc` compiles as a synchronous
    /// *nonisolated* context — so an isolated body could not be called from there at all. Their blocks
    /// are pure values and arithmetic, which is why they never needed an actor.
    var synchronousBody: (() -> Void)?

    init(
        id: Int,
        title: String,
        body: (() async throws -> Void)? = nil,
        synchronousBody: (() -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.synchronousBody = synchronousBody
    }
}

/// Every section, in run order.
///
/// **Adding a section means appending one entry here and nothing else.** §1–§5 carry
/// `synchronousBody:` and are driven from top level before the `Task` exists; §6–§22 carry `body:` and
/// are awaited inside it. That split is not cosmetic — see `runSynchronousSections(_:)`.
///
/// A `func` rather than a top-level `let`, because a global `let` holding non-`Sendable` closures is
/// a Swift 6 error under strict concurrency.
///
/// Nonisolated, so top level can build the list before the `Task` exists; the §6–§22 closures it hands
/// back are nonisolated too, for the reason `TestSection.body` records at length.
///
/// **"Nothing else" is true of this file and not of the suite.** `main.swift` drives §6 onward through
/// `runSections(6...N)`, and `N` is a literal there rather than this list's count — so a section appended
/// here runs only once that range is widened too. The summary line's `sections=` field is read off this
/// registry, not off what executed, so a section left outside the range is reported in the very field
/// that exists to catch a dropped section. Widening the range is part of adding a section.
func testSections() -> [TestSection] {
    [
        TestSection(
            id: 1,
            title: "Testing CRC Algorithms & Framing...",
            synchronousBody: PacketFramingTests.run),
        TestSection(
            id: 2,
            title: "Testing WHOOP Packet Decoder...",
            synchronousBody: PacketDecoderTests.run),
        TestSection(
            id: 3,
            title: "Testing HRV (RMSSD, SDNN, pNN50) & Artifact Rejection...",
            synchronousBody: HeartRateVariabilityMathTests.run),
        TestSection(
            id: 4,
            title: "Testing Strain Integrator & Karvonen Zones...",
            synchronousBody: StrainAccumulatorMathTests.run),
        TestSection(
            id: 5,
            title: "Testing Recovery z-Score Baseline Model...",
            synchronousBody: RecoveryScoringTests.run),
        TestSection(
            id: 6,
            title: "Testing DI Container, Use Cases & Data Sovereignty Export...",
            body: DIContainerTests.run),
        TestSection(
            id: 7,
            title: "Testing migrations, biometric round-trip and day-keyed writes...",
            body: PersistenceSchemaTests.run),
        TestSection(
            id: 8,
            title: "Testing HRV metric isolation, baseline guards and formatters...",
            body: FormatterTests.run),
        TestSection(
            id: 9,
            title: "Testing HealthKit import attribution, skipping and idempotency...",
            body: HealthKitImportTests.run),
        TestSection(
            id: 10,
            title: "Testing no-data days store zeros, and zeros never enter a baseline...",
            body: NoDataDayTests.run),
        TestSection(
            id: 11,
            title: "Testing the WHOOP export import against the real file...",
            body: WhoopExportImportTests.run),
        TestSection(
            id: 12,
            title: "Testing that a chosen day is read, and an imported day is never overwritten...",
            body: DaySelectionTests.run),
        TestSection(
            id: 13,
            title: "Testing that a night's Sleep Need follows the previous day's Strain...",
            body: SleepNeedTests.run),
        TestSection(
            id: 14,
            title: "Testing the `+` menu's three rows, recorded workouts, the receptive inactivities "
                + "card, HealthKit steps, the Stress Monitor, the recovery ring tiers and the "
                + "seven-day MetricWeek join...",
            body: HomeSourceTests.run),
        TestSection(
            id: 15,
            title: "Testing the sleep stage typical range, its whole-percent column, its absence "
                + "rules, the night's heading, the hours-vs-needed card, the sleep-efficiency card and "
                + "the within-sleep stress model...",
            body: TypicalRangeTests.run),
        TestSection(
            id: 16,
            title: "Testing the pedometer, both motion layouts, the step accumulator and the strap's "
                + "step storage...",
            body: StepTests.run),
        TestSection(
            id: 17,
            title: "Testing the workouts parser, the derived workout id, the hr_zone_percents round "
                + "trip, the day's zone aggregate and the export's zone properties...",
            body: WorkoutZoneTests.run),
        TestSection(
            id: 18,
            title: "Testing the `+` menu's one recording row, the session accumulator, the band "
                + "labels, the profile form's parsing and the session's write...",
            body: LiveSessionTests.run),
        TestSection(
            id: 19,
            title: "Testing the activity window and its band, the five zone rows, the export's zone "
                + "property, `workout.steps` and the two readers of one motion stream...",
            body: ActivityDetailTests.run),
        TestSection(
            id: 20,
            title: "Testing the Zero fasting parser, the import it writes and the two figures a "
                + "session with no measurement behind it prints...",
            body: ZeroFastingImportTests.run),
        TestSection(
            id: 21,
            title: "Testing the receptive inactivity parser, its derived id, the import it writes, "
                + "the note column round trip and the two readers of one day's card...",
            body: InactivityImportTests.run),
        TestSection(
            id: 22,
            title: "Testing the storage switch, all seven resources' wire names, the decorator's "
                + "degrade, the run's own arithmetic, and the absence of a delete...",
            body: SyncSectionTests.run),
    ]
}

// MARK: - Driving them

/// Opens a section: applies the `WHOOPSY_SECTIONS` gate, records it in the tally and prints its banner.
///
/// Returns `false` when the section is not selected, in which case nothing is opened and nothing is
/// printed — the gate is on the section's *call*, so a skipped section opens no database and imports
/// no CSV, which is the cost being skipped.
///
/// The header lives here rather than inside each body so a section's number and title are written once,
/// in the registry, and cannot drift from the id the banner and the tally use.
private func open(_ section: TestSection, of total: Int) -> Bool {
    guard selectedSections.isEmpty || selectedSections.contains(section.id) else { return false }
    tally.markSection(section.id)
    print("\n[\(section.id)/\(total)] \(section.title)")
    return true
}

/// Runs §1–§5, **synchronously, from top level and before the `Task` exists**.
///
/// That placement is deliberate and is not an implementation detail. These five sections were inline
/// top-level `if` blocks, so they ran on the main actor ahead of everything else — and every block
/// inside them is free of `await`, `async` and `try`. Moving them inside the `Task` instead would have
/// been simpler and would have changed when they run relative to §6, which is a behavioural change this
/// split is not allowed to make.
///
/// Nonisolated because its caller is top-level code, which is a synchronous nonisolated context.
func runSynchronousSections(_ ids: [Int]) {
    let sections = testSections()
    for section in sections where ids.contains(section.id) {
        guard let run = section.synchronousBody else { continue }
        guard open(section, of: sections.count) else { continue }
        run()
    }
}

/// Runs §6–§22, awaited inside the `Task`, and closes the run.
///
/// `throws` even though no section body currently throws: the `Task` in `main.swift` wraps this in a
/// `do`/`catch`, and an unobserved throw would otherwise idle out the `RunLoop` and exit **0** over a
/// suite that never finished. Keeping the signature throwing is what keeps that catch honest.
///
/// Nonisolated, because its predecessor `runMainSections()` was — see `TestSection.body` for what
/// `@MainActor` here would cost.
func runSections(_ ids: ClosedRange<Int>) async throws {
    let sections = testSections()
    for section in sections where ids.contains(section.id) {
        guard let body = section.body else { continue }
        guard open(section, of: sections.count) else { continue }
        try await body()
    }

    print("\n==================================================")
    print("✅ ALL WHOOPSY TESTS PASSED SUCCESSFULLY! (100% OK)")
    print("==================================================")

    // The single exit path for every outcome. `finishSuite` also owns the unknown-section check, which
    // needs the registry to know the valid ids — see its comment.
    finishSuite()
}
