import Foundation

/// The `CloudSync` a build with no `WHOOPSYAPIBaseURL` gets, and **it is not a stub.**
///
/// Nothing about it is fake: every method throws `CloudSyncError.unreachable`, which is exactly what a
/// request to a base URL that does not exist would produce, and the message says which key is absent
/// rather than reporting a network fault that never happened. A caller that degrades over
/// `.unreachable` degrades here for the same reason it degrades anywhere else, and a caller that does
/// not gets a sentence naming the actual problem.
///
/// **It exists because `DIContainer` builds `SyncEngine` unconditionally**, where the
/// routing decorator is built only on the configured branch. The two are not the same kind of object:
/// the decorator sits *in* the read path, so an unconfigured build would pay an `await` on every
/// recovery read for a settings store that can never mark a day cloud-held — while the engine is
/// reached only when a user opens `STORAGE` and presses a button, and the pane needs an object to hold
/// regardless. Handing it `nil` instead would be a second spelling of *this build has no database*,
/// free to disagree with `DIContainer.isCloudConfigured`, which is the one the pane actually draws.
///
/// This is `UnavailableOfflineMaps`' shape one layer down, and that type's own argument applies here
/// verbatim: a build whose capability is absent gets an implementation that behaves the way the app
/// behaved before the capability existed, rather than an absence every call site has to remember.
public struct UnconfiguredCloudSync: CloudSync {

    /// The `Info.plist` key this build is missing, carried so the sentence can name it.
    private let missingKey: String

    public init(missingKey: String = WhoopsyAPIClient.baseURLInfoKey) {
        self.missingKey = missingKey
    }

    public func recovery(on day: Date) async throws -> RecoverySyncRow? {
        throw failure()
    }

    public func recoveries(from: Date, to: Date) async throws -> [RecoverySyncRow] {
        throw failure()
    }

    public func writeRecovery(_ row: RecoverySyncRow) async throws {
        throw failure()
    }

    public func writeRecoveries(_ rows: [RecoverySyncRow]) async throws -> Int {
        throw failure()
    }

    public func strain(on day: Date) async throws -> StrainSyncRow? {
        throw failure()
    }

    public func strains(from: Date, to: Date) async throws -> [StrainSyncRow] {
        throw failure()
    }

    public func writeStrain(_ row: StrainSyncRow) async throws {
        throw failure()
    }

    public func writeStrains(_ rows: [StrainSyncRow]) async throws -> Int {
        throw failure()
    }

    public func workout(id: UUID) async throws -> WorkoutSyncRow? {
        throw failure()
    }

    public func workouts(from: Date, to: Date) async throws -> [WorkoutSyncRow] {
        throw failure()
    }

    public func writeWorkout(_ row: WorkoutSyncRow) async throws {
        throw failure()
    }

    public func writeWorkouts(_ rows: [WorkoutSyncRow]) async throws -> Int {
        throw failure()
    }

    public func writeSleep(_ row: SleepSyncRow) async throws {
        throw failure()
    }

    public func writeSleeps(_ rows: [SleepSyncRow]) async throws -> Int {
        throw failure()
    }

    public func writeStepCount(_ row: StepCountSyncRow) async throws {
        throw failure()
    }

    public func writeStepCounts(_ rows: [StepCountSyncRow]) async throws -> Int {
        throw failure()
    }

    public func writeReceptiveInactivity(_ row: ReceptiveInactivitySyncRow) async throws {
        throw failure()
    }

    public func writeReceptiveInactivities(_ rows: [ReceptiveInactivitySyncRow]) async throws -> Int {
        throw failure()
    }

    public func writeProfile(_ row: UserProfileSyncRow) async throws {
        throw failure()
    }

    /// One sentence, built once, so all nineteen methods fail identically and a caller cannot tell from the
    /// message which one it reached — which is right, because the answer is the same for all nineteen.
    private func failure() -> CloudSyncError {
        .unreachable(
            message: "this build has no database behind it: \(missingKey) is not set in Info.plist")
    }
}
