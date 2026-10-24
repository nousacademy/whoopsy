import Foundation
import GRDB

/// The `strainAlgorithms` row — the reference table that documents every formula which can have
/// produced a `strains` row.
///
/// **A catalogue rather than a lookup.** Nothing joins this table; it is read by the suite, by a
/// person holding the database open, and by the JSON export, which walks `sqlite_master` and therefore
/// carries the algorithm record with the data it describes. The point is that a stored score can be
/// explained from the same file that stores it, without the source code at the version that wrote it.
///
/// `version` is the primary key and matches `StrainAlgorithm.rawValue`. `parameters` is a JSON document
/// rather than a column per constant, because every version defines a different set of constants and a
/// nullable-column-per-parameter table would be mostly NULL and cannot say what it meant.
///
/// **No `CodingKeys`, so the property names are the column names** — `StrainRecord`'s convention, and
/// the migration spells them this way. A record declaring `createdAt` against a column named
/// `created_at` fails at launch with `no such column`, and a failing migration `fatalError`s.
public struct StrainAlgorithmRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "strainAlgorithms"

    public var version: String
    public var formula: String
    public var parameters: String
    public var notes: String?
    public var createdAt: Date

    public init(
        version: String,
        formula: String,
        parameters: String,
        notes: String?,
        createdAt: Date
    ) {
        self.version = version
        self.formula = formula
        self.parameters = parameters
        self.notes = notes
        self.createdAt = createdAt
    }
}
