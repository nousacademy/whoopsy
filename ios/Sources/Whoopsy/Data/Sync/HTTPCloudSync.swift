import Foundation

/// The `CloudSync` port over `WhoopsyAPIClient`, and the layer where this app's dates become the wire's.
///
/// **It is a translation and nothing else.** Every method here is the same three steps — a day or a range
/// becomes a key, the client makes a call, the answer becomes rows — and there is deliberately no
/// retrying, no caching, no filtering and no clamping. Each of those belongs somewhere it can be seen:
/// retries are the caller's, because only the caller knows whether re-sending is safe; filtering is
/// `RecoveryWireMapper.isSendable`'s, because that is a fact about the wire's shape; and the server's
/// window limit is `SyncResource.maximumLookbackDays`'s, because it is a policy about a range rather
/// than a property of a request.
///
/// **The calendar is injected rather than read from `.current` at each call.** Both halves of the
/// conversion need the *same* zone — a day key built in one and parsed in another files every day one
/// early — and a type that reads `.current` twice is a type whose two readings are only equal by
/// assumption. Held once, they cannot disagree, and the runner can construct one in a fixed zone to
/// assert the round trip without depending on where the machine is.
///
/// **Nothing here sorts.** `recoveries(from:to:)` documents an ascending answer and the database
/// supplies one — `ORDER BY date ASC` over `YYYY-MM-DD` keys, which sort lexically into date order — so a
/// defensive sort would be a second ordering rule that could disagree with the first while looking
/// identical. The wire's window is built the same way: `RecoveryWindow` translates the app's half-open
/// range into the server's inclusive one, and that translation is the only arithmetic in this file.
public struct HTTPCloudSync: CloudSync {

    private let client: WhoopsyAPIClient
    private let calendar: Calendar

    public init(client: WhoopsyAPIClient, calendar: Calendar = .current) {
        self.client = client
        self.calendar = calendar
    }

    public func recovery(on day: Date) async throws -> RecoverySyncRow? {
        let key = RecoveryWireMapper.dayKey(for: day, in: calendar)

        // `nil` from the client is the server's `404 no_measurement_for_day`, already translated into one
        // spelling of absence. It passes straight through: this app's absence is an absent row, and a
        // caller that had to distinguish "the database has no row" from "the database refused" would be
        // reading a distinction the protocol does not make.
        guard let dto = try await client.recovery(onDay: key) else { return nil }
        return try RecoveryWireMapper.row(for: dto, in: calendar)
    }

    public func recoveries(from: Date, to: Date) async throws -> [RecoverySyncRow] {
        // A range holding no days has no `endingOn` to anchor on and no rows to ask for. It is answered
        // here rather than sent, because the server's `days` is a non-negative count back from a day and
        // an empty range has no honest spelling as one.
        guard let window = RecoveryWindow(from: from, to: to, calendar: calendar) else { return [] }

        let dtos = try await client.recoveries(in: window)
        return try dtos.map { try RecoveryWireMapper.row(for: $0, in: calendar) }
    }

    public func writeRecovery(_ row: RecoverySyncRow) async throws {
        // The echo is discarded deliberately: the port returns nothing, and a caller that has just
        // decided what to write has no use for the server reading it back. It is still *decoded* inside
        // the client, because a `200` carrying something this app cannot parse is a contract mismatch and
        // the transport is the only place that can notice.
        try await client.writeRecovery(RecoveryWireMapper.dto(for: row, in: calendar))
    }

    public func writeRecoveries(_ rows: [RecoverySyncRow]) async throws -> Int {
        // An empty array is answered by the client without a socket, because the schema requires at least
        // one row. It reaches here only from a caller that filtered everything out, and it reports the
        // honest number for that: nothing was written.
        try await client.writeRecoveries(rows.map { RecoveryWireMapper.dto(for: $0, in: calendar) })
    }

    // MARK: - Strains

    public func strain(on day: Date) async throws -> StrainSyncRow? {
        let key = StrainWireMapper.dayKey(for: day, in: calendar)

        // `nil` from the client is the server's `404 no_measurement_for_day` — the *same* code the
        // recoveries read translates, because both name a day that has no row at all. It is the `200`
        // that differs between the two resources: a strain row carrying `hasMeasurement: false` comes
        // back from the client as a DTO like any other, and it becomes a row here rather than a `nil`.
        // Nothing in this method reads the flag, and that is deliberate — an unmeasured day is a day the
        // database holds, and this app draws a dash for it rather than pretending it never happened.
        guard let dto = try await client.strain(onDay: key) else { return nil }
        return try StrainWireMapper.row(for: dto, in: calendar)
    }

    public func strains(from: Date, to: Date) async throws -> [StrainSyncRow] {
        // A range holding no days has no `endingOn` to anchor on and no rows to ask for, on the
        // recoveries' argument. `StrainWindow` is `RecoveryWindow`, so this is the same arithmetic rather
        // than a second copy of it — and the off-by-one it owns is the one that must not be copied.
        guard let window = StrainWindow(from: from, to: to, calendar: calendar) else { return [] }

        let dtos = try await client.strains(in: window)
        return try dtos.map { try StrainWireMapper.row(for: $0, in: calendar) }
    }

    public func writeStrain(_ row: StrainSyncRow) async throws {
        // The echo is discarded for `writeRecovery`'s reason: the port returns nothing, and a caller that
        // has just decided what to write has no use for the server reading it back. It is still *decoded*
        // inside the client, because a `200` carrying something this app cannot parse is a contract
        // mismatch and the transport is the only place that can notice.
        try await client.writeStrain(StrainWireMapper.dto(for: row, in: calendar))
    }

    public func writeStrains(_ rows: [StrainSyncRow]) async throws -> Int {
        // An empty array is answered by the client without a socket, because the schema requires at least
        // one row. It reaches here only from a caller that filtered everything out, and it reports the
        // honest number for that: nothing was written.
        try await client.writeStrains(rows.map { StrainWireMapper.dto(for: $0, in: calendar) })
    }

    // MARK: - Workouts

    public func workout(id: UUID) async throws -> WorkoutSyncRow? {
        // The id becomes the path's own spelling here and nowhere else, which is this file's job for the
        // session as it is for the day: above this line an id is a `UUID`, below it is a string, and the
        // one conversion is written once.
        //
        // `nil` from the client is the server's `404 not_found` — **not** the recoveries'
        // `no_measurement_for_day`, which names a day rather than an id — already translated into the
        // port's one spelling of absence.
        guard let dto = try await client.workout(id: id.uuidString) else { return nil }
        return try WorkoutWireMapper.row(for: dto, in: calendar)
    }

    public func workouts(from: Date, to: Date) async throws -> [WorkoutSyncRow] {
        // A range holding no days has no `endingOn` to anchor on and no rows to ask for, on the
        // recoveries' argument: the server's `days` is a non-negative count back from a day and an empty
        // range has no honest spelling as one. `WorkoutWindow` is `RecoveryWindow`, so this is the same
        // arithmetic rather than a second copy of it.
        guard let window = WorkoutWindow(from: from, to: to, calendar: calendar) else { return [] }

        let dtos = try await client.workouts(in: window)
        return try dtos.map { try WorkoutWireMapper.row(for: $0, in: calendar) }
    }

    public func writeWorkout(_ row: WorkoutSyncRow) async throws {
        // The echo is discarded for `writeRecovery`'s reason. The children go with it: `dto(for:)` carries
        // them, so a session written here replaces its route and its splits in the same request.
        try await client.writeWorkout(WorkoutWireMapper.dto(for: row, in: calendar))
    }

    public func writeWorkouts(_ rows: [WorkoutSyncRow]) async throws -> Int {
        // The count that comes back is sessions and not rows, and it is passed through untouched. An empty
        // array is answered by the client without a socket, because the schema requires at least one row.
        try await client.writeWorkouts(rows.map { WorkoutWireMapper.dto(for: $0, in: calendar) })
    }

    // MARK: - Sleeps

    public func writeSleep(_ row: SleepSyncRow) async throws {
        // **The one write in this file whose DTO conversion throws**, and that is the stage timeline's
        // rather than a property of this method: `SleepWireMapper.dto(for:in:)` serialises a
        // `[SleepStageSegment]`, so a night whose timeline will not encode fails here rather than being
        // sent without one. The error is `.malformed` and travels out of the port unchanged — a caller
        // that swallowed it would store an absence on the far side and call the night unstaged.
        try await client.writeSleep(try SleepWireMapper.dto(for: row, in: calendar))
    }

    public func writeSleeps(_ rows: [SleepSyncRow]) async throws -> Int {
        // Mapped before the call and not inside the client, so a timeline that cannot be written fails
        // this whole chunk loudly instead of half of it being sent. An empty array is answered by the
        // client without a socket, because the schema requires at least one row.
        try await client.writeSleeps(rows.map { try SleepWireMapper.dto(for: $0, in: calendar) })
    }

    // MARK: - Step counts

    public func writeStepCount(_ row: StepCountSyncRow) async throws {
        // Total, and unlike the sleeps above there is nothing here that can fail before the socket: this
        // mapper converts three scalars.
        try await client.writeStepCount(StepCountWireMapper.dto(for: row, in: calendar))
    }

    public func writeStepCounts(_ rows: [StepCountSyncRow]) async throws -> Int {
        try await client.writeStepCounts(rows.map { StepCountWireMapper.dto(for: $0, in: calendar) })
    }

    // MARK: - Receptive inactivities

    public func writeReceptiveInactivity(_ row: ReceptiveInactivitySyncRow) async throws {
        // The entry's id becomes the path's own spelling, exactly as a session's does in `writeWorkout`:
        // above this line an id is the app's string, below it it is the path's.
        try await client.writeReceptiveInactivity(ReceptiveInactivityWireMapper.dto(for: row, in: calendar))
    }

    public func writeReceptiveInactivities(_ rows: [ReceptiveInactivitySyncRow]) async throws -> Int {
        try await client.writeReceptiveInactivities(rows.map {
            ReceptiveInactivityWireMapper.dto(for: $0, in: calendar)
        })
    }

    // MARK: - The profile

    public func writeProfile(_ row: UserProfileSyncRow) async throws {
        // **The echo is the one this file cannot discard, and it is not read here either.** `PUT
        // /v1/profile` answers with the row read back from the database, and the client decodes it so a
        // `200` carrying something unreadable is caught at the transport — but the port returns nothing,
        // so there is no second copy of the profile for this app to hold. The row it just sent is the row
        // it has.
        try await client.writeProfile(UserProfileWireMapper.dto(for: row, in: calendar))
    }
}
