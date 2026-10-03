import Foundation

/// One stored value, in the shape the store actually holds it rather than in the shape any screen wants
/// it.
///
/// **This is a description of storage and not a domain type, and the distinction is the whole reason it
/// exists.** Every other value in `Domain/Entities/` is one thing the app knows — a night, a score, a
/// session — with the absence rules those carry. This one knows nothing: it is whatever SQLite had in
/// the column, so a table added by a future migration is exported without an edit anywhere, and a
/// column that is `NULL` on a row is exported as `null` rather than dropped, fabricated or defaulted.
///
/// **The alternative it replaced is the failure it prevents.** An export written as a `[String: Any]`
/// per entity is a second definition of the schema, in a file that no migration updates — so the day
/// somebody adds a table, the export keeps reporting success while silently omitting it. That is the
/// same class of defect this repo records against a migration that names a column the record does not
/// declare, and here it would be invisible on every screen: an export is a file nobody opens in a
/// build.
///
/// **`blob` carries base64 rather than `Data`** so the whole enum is `Sendable` and cheap to compare —
/// an in-flight export crosses an actor boundary to leave `LocalDatabaseManager`, and `Data` would be
/// legal only by another `Sendable` conformance this type does not need. The app's own blobs are JSON
/// text in a `.text` column (see `biometric_samples.rrIntervalsMs`), so nothing in this database
/// actually takes this arm today; it is here so a future `BLOB` column is exported honestly rather
/// than dropped.
public enum LocalDataValue: Sendable, Equatable {

    /// The column held `NULL`. Distinct from every other case, and never folded into one: a `NULL` in
    /// `workouts.strain` means *nothing measured this*, which is the app's whole absence vocabulary.
    case null

    case integer(Int64)
    case real(Double)
    case text(String)

    /// A `BLOB`, carried as its base64 so the case stays `Sendable`. See the type's note.
    case blob(base64: String)
}

/// One row, keyed by the column names the table actually has — read off the table rather than off a
/// record's `CodingKeys`, so the export cannot disagree with the schema.
///
/// **The keys are column names and not property names**, which matters on this schema because the two
/// are not the same everywhere: `RecoveryRecord` declares `CodingKeys` mapping to snake_case
/// (`hrv_value_ms`) while `StrainRecord` has none, so its columns are camelCase (`strainScore`). An
/// export that went through the records would have to pick one convention and be wrong about half the
/// database; reading the table is right about all of it.
public struct LocalDataRow: Sendable, Equatable {

    public let values: [String: LocalDataValue]

    public init(values: [String: LocalDataValue]) {
        self.values = values
    }
}

/// Every row of every table the migrations created — the whole store, with no window over it.
///
/// **There is deliberately no date bound here, and that is the difference between this and every other
/// read in the app.** `getRecoveryHistory(days:endingOn:)` and its siblings are *screens*: they ask for
/// the span a chart draws and answer `nil` or `[]` outside it. An export asks for the record, and a
/// window over it would be this app deciding which part of the user's own history they are allowed to
/// have — which is the one thing an export must not do. The four repository reads the exporter used
/// before this type existed were a 30-day window, and it is why the JSON they produced carried counts
/// rather than rows.
///
/// **`tables` is a dictionary rather than a list of typed arrays** so the set of tables is whatever
/// `sqlite_master` says, not whatever an author remembered to add. The guarantee that follows — every
/// table this app has is in here — is asserted in §6 against `existingTableNames()`, which is the same
/// query, so a migration that adds a table cannot land unexported.
public struct LocalDataSnapshot: Sendable, Equatable {

    /// Rows per table, keyed by table name. A table with no rows is present with an empty array, which
    /// is different from absent: it says *this table exists and holds nothing*, where a missing key
    /// would be indistinguishable from a table the export forgot.
    public let tables: [String: [LocalDataRow]]

    public init(tables: [String: [LocalDataRow]]) {
        self.tables = tables
    }

    /// The table names, sorted — for a caller that needs a stable order rather than a dictionary's.
    public var tableNames: [String] { tables.keys.sorted() }

    /// Rows per table, for a summary line or an assertion about coverage.
    public var rowCounts: [String: Int] { tables.mapValues(\.count) }

    /// Every row in the store.
    public var totalRows: Int { tables.values.reduce(0) { $0 + $1.count } }
}
