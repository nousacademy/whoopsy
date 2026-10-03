import Foundation
import GRDB

/// A nap, in its own table — see `v11_recorded_naps` for why it is not a row of `sleeps`.
///
/// **The identity is the nap's start instant, not a fresh `UUID`, and that is what makes the import
/// idempotent.** `naps` is `id`-keyed like `workouts`, and GRDB's `save` is INSERT-or-UPDATE by
/// primary key — so a second press of the import button updates the same eight rows rather than
/// writing eight more. A `UUID()` minted per import would silently double the table on every run,
/// which is the one failure this table's key choice has to prevent.
public struct NapRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "naps"

    /// The nap's start instant, as a stable string — see the type's doc comment.
    public let id: String
    /// `startOfDay(startedAt)`: the day the nap was taken, which is the day whose night the sleep
    /// screen is showing. See `WhoopExportImporter` for the measurement behind that key.
    public var date: Date
    public let startedAt: Date
    public let endedAt: Date
    public let asleepSeconds: Double

    /// See `RecoveryRecord.source`.
    public let source: String?

    public init(
        id: String,
        date: Date,
        startedAt: Date,
        endedAt: Date,
        asleepSeconds: Double,
        source: String? = nil
    ) {
        self.id = id
        self.date = date
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.asleepSeconds = asleepSeconds
        self.source = source
    }

    /// Declared because these columns are snake_case while `StrainRecord`'s are camelCase — the
    /// mismatch `CLAUDE.md` warns about. A missing case here is `no such column` at runtime, not a
    /// compile error.
    enum CodingKeys: String, CodingKey {
        case id
        case date
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case asleepSeconds = "asleep_seconds"
        case source
    }
}
