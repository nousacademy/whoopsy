import Foundation
import SwiftUI
import Whoopsy

// MARK: - 18. The live session
//
// The app's **only recording path**, and the section is shaped by three things a strap-less machine
// cannot supply.
//
// **It never touches the strap.** `biometric_samples` holds 0 rows in every database on this machine,
// so nothing here is evidence that a real strap's beats produce a meaningful session — what it proves
// is the arithmetic, the throttle, the storage and the button. `ScriptedTelemetryRepository` below is
// the fixture that makes that possible: it is a `WhoopBLEDeviceRepository` whose telemetry stream this
// section drives directly, which is the only way to deliver a *known* sample train to a type that
// reads `liveTelemetryStream` and nothing else.
//
// **It never touches `ActivityKit`.** `ActivityAttributes` is `@available(macOS, unavailable)` and this
// runner is a macOS binary, so the card is asserted through `SpyLiveActivityController` — a
// `LiveActivityControlling` with counters. That is not a workaround: the throttle being tested is the
// *use case's*, and a spy is the only instrument that can see when it pushed.
//
// **It never touches a renderer.** `LiveSessionView`'s drawing — the ring, the five-band row, the
// waveform, the hidden tab bar — is invisible here. What is asserted is every value the drawing is
// made of, which is why they live in `LiveSessionAccumulator`, `StrainAccumulatorMath` and
// `ProfileDraft` rather than in the view's `body`.

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.

/// The section's body. Awaited inside the `Task` by `runSections(_:)`.
///
/// The blocks live in sibling files, one per topic, cut at this section's own
/// `// ---- Title ----` boundaries and moved verbatim. The five values the end-to-end
/// block used to build for itself are built here instead and threaded into both halves
/// — see the note on `LiveSessionRecordingTests.run`.
enum LiveSessionTests {
    static func run() async throws {
        try await LiveSessionBarTests.run()
        try await LiveSessionAccumulatorTests.run()
        try await ProfileFormTests.run()

        // One database and one scripted stream, shared by the two halves of the block below
        // and built here rather than inside either of them. §6.2: an in-memory database
        // recreated in the fast half still reports `fastDay.count == 1`, but for the wrong
        // reason, and a second `ScriptedTelemetryRepository` would stop the two halves
        // sharing the one scripted stream whose subscriber count the first half asserts.
        let db = LocalDatabaseManager(inMemory: true)
        let profileRepository = GRDBUserProfileRepository(db: db)
        let workoutRepository = GRDBWorkoutRepository(db: db)
        let telemetry = ScriptedTelemetryRepository()
        let stream = StreamBiometricsUseCase(
            bleRepository: telemetry, biometricRepository: EmptyBiometricStore())

        try await LiveSessionRecordingTests.run(
            db: db, profileRepository: profileRepository, workoutRepository: workoutRepository,
            telemetry: telemetry, stream: stream)
        try await LiveFastTests.run(
            profileRepository: profileRepository, workoutRepository: workoutRepository,
            telemetry: telemetry, stream: stream)
    }
}
