import Foundation

/// One completed fast out of Zero's `fast_data`, parsed and nothing more.
///
/// **Three fields, because three is all this app reads.** The producer's objects carry six:
/// `GoalHours`, `IsEnded` and `GoalID` are deliberately dropped here. `GoalHours` and `GoalID` describe
/// a *target* the user set — 13 hours, a circadian-rhythm schedule — and not the fast that happened, so
/// storing either would put a plan on a row whose figure is a measurement. `IsEnded` is `true` on all
/// 170 of the bundled rows by construction: an unfinished fast has no `EndDTM` to give, so a record
/// without one cannot become a session at all and the field would be a constant. Dropping them is also
/// what keeps the parser immune to a producer that renames a *schedule*: the import reads a start, an
/// end and an id, and nothing else in the file can break it.
///
/// The three that remain are the whole of what a `workouts` row needs. Everything else about the row
/// — that it was a fast, that no sensor was behind it — is the importer's to say, not the file's.
public struct ZeroFastingRow: Sendable, Equatable {

    /// Zero's own `FastID`, kept as the string it arrives as.
    ///
    /// **Not a `UUID` here**, though every one of the bundled rows parses as one. `GRDBWorkoutRepository
    /// .makeSessions` skips any stored row whose id will not round-trip through `UUID(uuidString:)`, so
    /// a record whose id is malformed would be written and never readable — the worse of the two
    /// failure modes. The importer is where that is guarded and counted, and it can only count what the
    /// parser handed it, so the raw string survives this far on purpose.
    public let fastID: String

    /// The fast's window. Both are instants with a `Z` suffix and a whole-second precision.
    public let startedAt: Date
    public let endedAt: Date
}

public enum ZeroFastingError: Error, LocalizedError {
    case unreadable(URL)
    /// The file is not in this build's resources at all — a packaging fault, not a bad file.
    case notBundled
    /// The JSON decoded, but is not the shape this app reads.
    case missingFastData
    /// The top level is not an object at all, so there is no `fast_data` to look for.
    case malformedDocument
    /// An instant this parser cannot place. **Carries the record's id rather than a line number**,
    /// because a JSON file has no lines — the id is the only handle a reader has on a bad record.
    case unparseableDate(record: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "The Zero fasting export at \(url.lastPathComponent) could not be read."
        case .notBundled:
            return "This build does not include the Zero fasting export file."
        case .missingFastData:
            return "This does not look like a Zero fasting export — it has no fast_data."
        case .malformedDocument:
            return "This does not look like a Zero fasting export — it is not a JSON object."
        case .unparseableDate(let record, let value):
            return "The fast \(record) has an unreadable date: \"\(value)\"."
        }
    }
}

/// Reads Zero's fasting history out of a `biodata.json`.
///
/// **Nothing here silently skips a row.** This is `WhoopExportParser`'s rule and the reason it exists:
/// the CSV parser that came before it used `ISO8601DateFormatter` against a format it could not read,
/// so its `guard … else { continue }` discarded every row and the import reported success while
/// writing nothing. A fast this parser cannot place in time is a **thrown error naming the record**,
/// not a missing day discovered weeks later.
///
/// The two differences from the CSV parser are both consequences of the format. A JSON file has no
/// lines, so an error names the offending `FastID` instead of a line number; and the file is a
/// *document* with nineteen top-level keys of which one is read, so the check that a caller pointed
/// this at the right file is `missingFastData` rather than a list of missing columns. That check is
/// what makes `firestore.json` — or any of the nineteen sibling keys — fail loudly instead of
/// decoding to zero rows and reporting a successful import of nothing.
public enum ZeroFastingParser {

    /// The one key this app reads, out of the producer's nineteen.
    static let fastDataKey = "fast_data"

    public static func parseFasts(at url: URL) throws -> [ZeroFastingRow] {
        guard let data = try? Data(contentsOf: url) else {
            throw ZeroFastingError.unreadable(url)
        }
        return try parseFasts(data)
    }

    public static func parseFasts(_ text: String) throws -> [ZeroFastingRow] {
        try parseFasts(Data(text.utf8))
    }

    public static func parseFasts(_ data: Data) throws -> [ZeroFastingRow] {
        guard let document = try? JSONSerialization.jsonObject(with: data) else {
            throw ZeroFastingError.malformedDocument
        }
        guard let root = document as? [String: Any] else {
            throw ZeroFastingError.malformedDocument
        }
        guard let records = root[fastDataKey] as? [[String: Any]] else {
            throw ZeroFastingError.missingFastData
        }
        return try records.map(makeRow(from:))
    }

    /// One record. The id falls back to a placeholder when the file has none, and the two instants
    /// never do — see this type's comment on why a row is refused rather than skipped.
    private static func makeRow(from record: [String: Any]) throws -> ZeroFastingRow {
        let identifier = record["FastID"] as? String ?? "an unnamed fast"

        func instant(_ key: String) throws -> Date {
            let raw = record[key] as? String ?? ""
            guard let parsed = date(from: raw) else {
                throw ZeroFastingError.unparseableDate(record: identifier, value: raw)
            }
            return parsed
        }

        return ZeroFastingRow(
            fastID: record["FastID"] as? String ?? "",
            startedAt: try instant("StartDTM"),
            endedAt: try instant("EndDTM"))
    }

    /// The producer's instant grammar, in one place.
    ///
    /// **A fixed format rather than `ISO8601DateFormatter` and rather than a `dateDecodingStrategy`.**
    /// The export writes `2022-02-27T02:15:40Z` — whole seconds, a literal `Z` — and
    /// `ISO8601DateFormatter` is the trap this repo has already documented against the CSV files: it
    /// returns `nil` for anything outside its default options, and the `guard … else { continue }` that
    /// follows silently drops the row. Spelled out here, a value the format does not describe throws
    /// with the record's id on it. The `Z` is a literal rather than a zone resolved through
    /// `TimeZone(abbreviation:)` because the file states UTC and nothing else, so honouring a
    /// hypothetical offset here would be inventing a fact the producer does not write.
    private static func date(from raw: String) -> Date? {
        let formatter = DateFormatter()
        // POSIX so a device set to a locale with its own calendar or numeral system cannot change how
        // the file's digits are read — `WhoopExportParser.dateFormatter(_:)`'s reason verbatim.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.date(from: raw)
    }
}
