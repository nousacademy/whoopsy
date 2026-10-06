import Foundation

/// The wire's own shape for one day's steps, and the two conversions onto it.
///
/// **Three fields, no optional, no seam — and the absence of a seam is the thing to say out loud.**
/// `StepCountRecord` declares no `CodingKeys` and this DTO's three property names are spelled the same
/// way, so `Codable` is synthesised here rather than written out. That is `WorkoutRoutePointDTO`'s
/// precedent, and the condition it asks for is met exactly: there is nothing on this type that could
/// reach the wire as an absent key, because every field is non-optional and the schema marks none of
/// them nullable.
///
/// **`measuredSeconds` is not a decoration.** It is what separates a measured zero from a day with no
/// row — `StepCount.hasMeasurement` is `measuredSeconds > 0` — and it is the column this app deliberately
/// gives no `source` sibling. Dropping it from this DTO would turn every unmeasured day into a measured
/// one on the far side, so it is carried in both directions and `isSendable` gates on it.
public struct StepCountDTO: Codable, Equatable, Sendable {

    /// The day, `YYYY-MM-DD`.
    public let date: String

    /// The day's step total. `0` is a real measurement here and not an absence.
    public let stepCount: Int

    /// How long the strap was actually counting, in seconds. The one field that decides whether the
    /// other two are a measurement at all.
    public let measuredSeconds: Double

    public init(date: String, stepCount: Int, measuredSeconds: Double) {
        self.date = date
        self.stepCount = stepCount
        self.measuredSeconds = measuredSeconds
    }
}

/// Row ↔ wire for a day's steps, plus the one question the sync asks before sending one.
public enum StepCountWireMapper {

    // MARK: - The day key

    /// The day key, forwarded to the one place this app writes that rule down.
    ///
    /// The API declares a single `DayKeySchema` and every resource's `date` references it, so a local
    /// copy would be a second answer to a question that has one.
    public static func dayKey(for day: Date, in calendar: Calendar = .current) -> String {
        RecoveryWireMapper.dayKey(for: day, in: calendar)
    }

    /// The inverse, forwarded for `dayKey(for:in:)`'s reason.
    public static func day(fromDayKey key: String, in calendar: Calendar = .current) -> Date? {
        RecoveryWireMapper.day(fromDayKey: key, in: calendar)
    }

    // MARK: - Row ↔ wire

    /// The body this day is sent as.
    ///
    /// **Total, and it is the only mapper here that could be.** There is no structured field to
    /// serialise and no unparseable key to read, so both conversions below are assignments.
    public static func dto(for row: StepCountSyncRow, in calendar: Calendar = .current) -> StepCountDTO {
        StepCountDTO(
            date: dayKey(for: row.date, in: calendar),
            stepCount: row.stepCount,
            measuredSeconds: row.measuredSeconds
        )
    }

    /// The row a body arriving from the server is stored as.
    ///
    /// One field is a structured type here and a string on the wire — the day — and it is checked
    /// rather than force-unwrapped, naming itself in the refusal. `.malformed` and never `.unreachable`,
    /// on `WorkoutWireMapper.row(for:)`'s argument: this is a server that answered, so a caller must not
    /// degrade to local storage over it.
    public static func row(for dto: StepCountDTO, in calendar: Calendar = .current) throws -> StepCountSyncRow {
        guard let day = day(fromDayKey: dto.date, in: calendar) else {
            throw CloudSyncError.malformed(message: "the answer carried a day this app cannot read: \(dto.date)")
        }

        return StepCountSyncRow(date: day, stepCount: dto.stepCount, measuredSeconds: dto.measuredSeconds)
    }

    // MARK: - What the database will accept

    /// Whether this day is one the server can be given.
    ///
    /// **The gate the plan names is `measuredSeconds > 0`, and it is the app's own test rather than the
    /// schema's** — the schema only asks for `minimum: 0` and would happily store a row for a day the
    /// strap never counted. Sending one would be the fabrication this repo's absence rule exists to
    /// prevent: a `0`-step day that this app reports as **no row** would arrive on the far side as a
    /// measurement of zero steps, and `StepCount.hasMeasurement` reads exactly `measuredSeconds > 0`, so
    /// the two sides would disagree about the same day by construction.
    ///
    /// The rest is the schema restated: `stepCount` non-negative, `measuredSeconds` finite and
    /// non-negative. Finiteness is not pedantry on a `Double` — an infinite `measuredSeconds` passes
    /// `> 0` and is a value `JSONEncoder` refuses outright, which would fail the whole chunk rather than
    /// this one day.
    public static func isSendable(_ row: StepCountSyncRow) -> Bool {
        guard row.measuredSeconds.isFinite, row.measuredSeconds > 0 else { return false }
        guard row.stepCount >= 0 else { return false }
        return true
    }
}
