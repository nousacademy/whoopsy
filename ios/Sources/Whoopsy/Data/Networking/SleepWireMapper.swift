import Foundation

/// The wire's own shape for one night of sleep, and the two conversions onto it.
///
/// **`RecoveryDTO`'s shape with two things this resource adds, and both of them are spellings rather
/// than decisions.**
///
/// *Two instants rather than one day.* A recovery is addressed and keyed entirely by a day, so
/// `YYYY-MM-DD` was the only spelling it needed. A night carries its own start and end, and the API
/// publishes one canonical instant form for them — `WorkoutWireMapper.instantKey(for:)`, which is
/// already the rule this app writes down once and forwards rather than re-deriving. The day itself is
/// still a day key, and it is the night's **wake** day: the schema says in as many words that it is not
/// derived from `startTime`, so this mapper must not compute it from one either.
///
/// *An opaque timeline.* `sleepStages` is a `[SleepStageSegment]?` on the record and a **string** here.
/// The server neither parses it, validates its interior nor re-serialises it — the schema's own words —
/// so the honest thing is to hand it the JSON this app already stores and to read back exactly what it
/// returns. The encoder and decoder below are therefore the plain defaults, matching the ones GRDB uses
/// for the `.text` column, and the round trip is the property that matters: what leaves this phone is
/// what comes back.
///
/// **The six nullable fields are written with `encode`, never `encodeIfPresent`.** `SleepWriteSchema`
/// and `SleepBatchRowSchema` are both `additionalProperties: false` with every field `.nullable()` and
/// not `.optional()`, so an absent key is a `400` naming a missing field and a `null` is a value. That
/// is not a corner case here: `sleepStages` is `nil` on all 910 imported nights, `disturbanceCount` and
/// `sleepConsistency` likewise, and `sleepDebt` is `nil` on every strap night — so a synthesised
/// encoder would refuse most of what this app can hold.
public struct SleepDTO: Codable, Equatable, Sendable {

    /// The night's wake day, `YYYY-MM-DD`. Not an instant — see `SleepWireMapper.dayKey(for:in:)`.
    public let date: String

    /// The night's two instants, in the canonical fixed-width UTC form.
    public let startTime: String
    public let endTime: String

    /// Sleep performance as a whole-scale percentage — this app's own figure, clamped before storage.
    public let sleepPerformance: Double

    /// The night's requirement, in seconds.
    public let totalSleepNeeded: Double

    /// The three stage totals and wakefulness, all in seconds.
    public let lightSleep: Double
    public let deepSleep: Double
    public let remSleep: Double
    public let awakeTime: Double

    /// The four nullable measures, each `null` for a night that was not scored rather than `0`.
    public let respiratoryRate: Double?
    public let disturbanceCount: Int?
    public let sleepConsistency: Int?
    public let sleepDebt: Double?

    /// The stage timeline as opaque JSON text, or `null` for a night that was never staged.
    public let sleepStages: String?

    /// Where the row came from — `whoop_export` for an imported night, `null` for one this app scored.
    public let source: String?

    public init(
        date: String,
        startTime: String,
        endTime: String,
        sleepPerformance: Double,
        totalSleepNeeded: Double,
        lightSleep: Double,
        deepSleep: Double,
        remSleep: Double,
        awakeTime: Double,
        respiratoryRate: Double?,
        disturbanceCount: Int?,
        sleepConsistency: Int?,
        sleepDebt: Double?,
        sleepStages: String?,
        source: String?
    ) {
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.sleepPerformance = sleepPerformance
        self.totalSleepNeeded = totalSleepNeeded
        self.lightSleep = lightSleep
        self.deepSleep = deepSleep
        self.remSleep = remSleep
        self.awakeTime = awakeTime
        self.respiratoryRate = respiratoryRate
        self.disturbanceCount = disturbanceCount
        self.sleepConsistency = sleepConsistency
        self.sleepDebt = sleepDebt
        self.sleepStages = sleepStages
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case startTime
        case endTime
        case sleepPerformance
        case totalSleepNeeded
        case lightSleep
        case deepSleep
        case remSleep
        case awakeTime
        case respiratoryRate
        case disturbanceCount
        case sleepConsistency
        case sleepDebt
        case sleepStages
        case source
    }

    /// Written by hand so the six nullable fields reach the wire as `null` rather than as nothing.
    ///
    /// The decoding half stays synthesised, on `RecoveryDTO`'s argument: `decodeIfPresent` reads a
    /// `null` and a missing key alike, and being generous on the way in costs nothing while being
    /// generous on the way out would be a body the server refuses.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(sleepPerformance, forKey: .sleepPerformance)
        try container.encode(totalSleepNeeded, forKey: .totalSleepNeeded)
        try container.encode(lightSleep, forKey: .lightSleep)
        try container.encode(deepSleep, forKey: .deepSleep)
        try container.encode(remSleep, forKey: .remSleep)
        try container.encode(awakeTime, forKey: .awakeTime)
        try container.encode(respiratoryRate, forKey: .respiratoryRate)
        try container.encode(disturbanceCount, forKey: .disturbanceCount)
        try container.encode(sleepConsistency, forKey: .sleepConsistency)
        try container.encode(sleepDebt, forKey: .sleepDebt)
        try container.encode(sleepStages, forKey: .sleepStages)
        try container.encode(source, forKey: .source)
    }
}

/// Row ↔ wire for a night, plus the one question the sync asks about a night before sending it.
///
/// An `enum` with no cases, on `RecoveryWireMapper`'s argument: every member is a pure conversion from
/// a value the caller already holds, and there is no state a mapper could hold that the row does not
/// already say.
public enum SleepWireMapper {

    // MARK: - The day key and the instants

    /// The day key, forwarded to the one place this app writes that rule down.
    ///
    /// The API declares a single `DayKeySchema` and every resource's `date` field references it, so a
    /// second copy here would be a second answer to a question that has one — and the failure would be
    /// invisible, because both spellings would keep parsing and only one would keep agreeing with the
    /// calendar about which day a night woke on.
    public static func dayKey(for day: Date, in calendar: Calendar = .current) -> String {
        RecoveryWireMapper.dayKey(for: day, in: calendar)
    }

    /// The inverse, forwarded for `dayKey(for:in:)`'s reason.
    public static func day(fromDayKey key: String, in calendar: Calendar = .current) -> Date? {
        RecoveryWireMapper.day(fromDayKey: key, in: calendar)
    }

    /// The canonical instant, forwarded to `WorkoutWireMapper`, which owns that spelling.
    ///
    /// **This resource is the second one to need it, and it is the reason the rule is written once.**
    /// A night's two boundary instants and a session's are the same kind of value and the API publishes
    /// one `InstantSchema` for both; a local copy would drift at exactly the millisecond boundary
    /// `instantKey`'s own doc comment describes, and the drift would be a body the server refuses.
    public static func instantKey(for instant: Date) -> String {
        WorkoutWireMapper.instantKey(for: instant)
    }

    /// The instant `key` names, or `nil` for any spelling but the canonical one.
    public static func instant(fromInstantKey key: String) -> Date? {
        WorkoutWireMapper.instant(fromInstantKey: key)
    }

    // MARK: - Row ↔ wire

    /// The body this night is sent as.
    ///
    /// **This is the family's one throwing `dto(for:)`, and the throw is the stage timeline's.** The
    /// other three resources convert only scalars and cannot fail; a `[SleepStageSegment]` has to be
    /// serialised, and `JSONEncoder` throws on a value it cannot write. A night whose timeline will not
    /// encode is a night this app must not quietly send without one, because the server would store the
    /// absence and hand it back as *never staged* — a different fact from *staged and unreadable*.
    ///
    /// **An empty array is sent as `null` and that is a normalisation rather than a loss.**
    /// `GRDBSleepRepository.saveSleepSession` writes `nil` for one, on the argument that *nothing
    /// staged* and *never staged* are the same thing and only one of them has a representation; the
    /// schema says the same, refusing an empty string and calling `null` that thing's only spelling. So
    /// this is the app's own rule restated at the boundary rather than a value being dropped.
    public static func dto(for row: SleepSyncRow, in calendar: Calendar = .current) throws -> SleepDTO {
        SleepDTO(
            date: dayKey(for: row.date, in: calendar),
            startTime: instantKey(for: row.startTime),
            endTime: instantKey(for: row.endTime),
            sleepPerformance: row.sleepPerformance,
            totalSleepNeeded: row.totalSleepNeeded,
            lightSleep: row.lightSleep,
            deepSleep: row.deepSleep,
            remSleep: row.remSleep,
            awakeTime: row.awakeTime,
            respiratoryRate: row.respiratoryRate,
            disturbanceCount: row.disturbanceCount,
            sleepConsistency: row.sleepConsistency,
            sleepDebt: row.sleepDebt,
            sleepStages: try stagesKey(for: row.sleepStages),
            source: row.source
        )
    }

    /// The row a body arriving from the server is stored as.
    ///
    /// Three fields are structured types here and strings on the wire — the day and the two instants —
    /// and each is checked rather than force-unwrapped, naming itself in the refusal so the sentence a
    /// caller logs says which field was unreadable rather than that something was. The stage timeline
    /// is the fourth: a string this app cannot read back as segments throws for the reason above.
    ///
    /// `.malformed` and never `.unreachable`, on `WorkoutWireMapper.row(for:)`'s argument: this is a
    /// server that answered, so a caller must not degrade to local storage over it.
    public static func row(for dto: SleepDTO, in calendar: Calendar = .current) throws -> SleepSyncRow {
        guard let day = day(fromDayKey: dto.date, in: calendar) else {
            throw CloudSyncError.malformed(message: "the answer carried a day this app cannot read: \(dto.date)")
        }

        guard let startTime = instant(fromInstantKey: dto.startTime) else {
            throw CloudSyncError.malformed(
                message: "the answer carried a start this app cannot read: \(dto.startTime)"
            )
        }

        guard let endTime = instant(fromInstantKey: dto.endTime) else {
            throw CloudSyncError.malformed(
                message: "the answer carried an end this app cannot read: \(dto.endTime)"
            )
        }

        return SleepSyncRow(
            date: day,
            startTime: startTime,
            endTime: endTime,
            sleepPerformance: dto.sleepPerformance,
            totalSleepNeeded: dto.totalSleepNeeded,
            lightSleep: dto.lightSleep,
            deepSleep: dto.deepSleep,
            remSleep: dto.remSleep,
            awakeTime: dto.awakeTime,
            respiratoryRate: dto.respiratoryRate,
            disturbanceCount: dto.disturbanceCount,
            sleepConsistency: dto.sleepConsistency,
            sleepDebt: dto.sleepDebt,
            sleepStages: try stages(for: dto.sleepStages),
            source: dto.source
        )
    }

    // MARK: - The timeline

    /// The opaque JSON text for a timeline, or `nil` for one there is none of.
    private static func stagesKey(for stages: [SleepStageSegment]?) throws -> String? {
        guard let stages, !stages.isEmpty else { return nil }
        do {
            let data = try JSONEncoder().encode(stages)
            guard let text = String(data: data, encoding: .utf8) else {
                throw CloudSyncError.malformed(message: "a night's stage timeline did not encode as text")
            }
            return text
        } catch let error as CloudSyncError {
            throw error
        } catch {
            throw CloudSyncError.malformed(
                message: "a night's stage timeline could not be written: \(error)"
            )
        }
    }

    /// The timeline a stored string holds, or `nil` for a night with none.
    ///
    /// An empty string is read as *none* rather than as a failure, which is the schema's own reading —
    /// it refuses `""` on the way in, so a `""` on the way out is a server that stored something this
    /// API does not accept, and treating it as an absence is the reading that loses nothing.
    private static func stages(for key: String?) throws -> [SleepStageSegment]? {
        guard let key, !key.isEmpty else { return nil }
        guard let data = key.data(using: .utf8) else {
            throw CloudSyncError.malformed(message: "a night's stage timeline was not readable text")
        }
        do {
            let stages = try JSONDecoder().decode([SleepStageSegment].self, from: data)
            return stages.isEmpty ? nil : stages
        } catch {
            throw CloudSyncError.malformed(
                message: "a night's stage timeline was not one this app could read: \(error)"
            )
        }
    }

    // MARK: - What the database will accept

    /// Whether this night is one the server can be given.
    ///
    /// **The wire's question and not the app's**, which is the distinction `RecoveryWireMapper.isSendable`
    /// draws: this asks *will the database take it*, and it is deliberately narrower than
    /// `SleepSyncRow.hasMeasurement`-style predicates would be. `POST /sleeps/batch` is one
    /// all-or-nothing transaction, so a single refused night fails a whole chunk of two hundred — which
    /// is why the engine filters on this **before** chunking rather than inside the chunk loop.
    ///
    /// **The first rule is the one the plan names as this resource's own, and it is the schema's
    /// refinement rather than a preference**: `endTime` must be strictly later than `startTime`, because
    /// *a night of zero length is not a night*. It is compared **on the strings that will be sent** and
    /// not on the `Date`s, on `WorkoutWireMapper`'s argument: the server compares `parseInstant`'s two
    /// answers, so two instants rendering to the same millisecond are one instant as far as the request
    /// is concerned, and a sub-millisecond night would otherwise be sent and refused with a sentence
    /// naming a field whose values look plainly ordered to whoever reads the log.
    ///
    /// The remaining rules are the schema's bounds, restated in the layer that has to decide:
    /// `sleepPerformance` in 0…100; the five durations finite and non-negative; `disturbanceCount` and
    /// `sleepConsistency` non-negative with the latter also at most 100; `respiratoryRate` and
    /// `sleepDebt` finite and non-negative when present; the four nullable *strings* either `nil` or
    /// non-empty, since the schema's `.min(1)` is what makes `""` a different answer from `null` and
    /// this app has no producer for one.
    public static func isSendable(_ row: SleepSyncRow) -> Bool {
        guard instantKey(for: row.endTime) > instantKey(for: row.startTime) else { return false }

        guard row.sleepPerformance.isFinite, (0 ... 100).contains(row.sleepPerformance) else { return false }

        for duration in [row.totalSleepNeeded, row.lightSleep, row.deepSleep, row.remSleep, row.awakeTime]
        where !(duration.isFinite && duration >= 0) {
            return false
        }

        if let respiratory = row.respiratoryRate, !(respiratory.isFinite && respiratory >= 0) { return false }
        if let debt = row.sleepDebt, !(debt.isFinite && debt >= 0) { return false }
        if let disturbances = row.disturbanceCount, disturbances < 0 { return false }
        if let consistency = row.sleepConsistency, !(0 ... 100).contains(consistency) { return false }

        if let source = row.source, source.isEmpty { return false }

        return true
    }
}
