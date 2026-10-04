import CryptoKit
import Foundation

/// One receptive inactivity out of a producer's JSON, parsed, identified and nothing more.
///
/// **Four fields, because four is what the row needs.** The producer's records carry three — a date, a
/// type and a note — and the fourth is the identity this app derives from them, because unlike Zero's
/// fasts these records carry no id of their own. Everything else about the row — that it was received
/// rather than done, that no sensor was behind it — is the importer's to say, not the file's.
///
/// **`type` is the file's own word and stays that way through here.** `dreams.json` writes
/// `"type": "dream"`, and this parser does not require it to be `"dream"` or to be any member of
/// `ReceptiveInactivityCatalog.names`: the mapping from a producer's vocabulary to the app's belongs to
/// the catalogue's `name(for:)`, and a parser that hard-coded one file's word would be a parser that
/// has to change when a second file arrives. A future file of `"type": "meditation"` reads through this
/// path unchanged.
public struct InactivityRow: Sendable, Equatable {

    /// The row's identity, **derived from its own content and never minted**.
    ///
    /// This is the whole reason the parser computes it rather than the importer. `ReceptiveInactivity
    /// .init` declares `id: UUID = UUID()`, and GRDB's `save` is INSERT-or-UPDATE **by primary key** —
    /// so an importer calling the convenience initialiser per record appends all 60 rows again on every
    /// press of the button, and reads back perfectly well while doing it. It is the same trap
    /// `CLAUDE.md` records against `workouts` and `naps`.
    ///
    /// `fasts.json` escapes it by carrying Zero's own `FastID`. These records carry nothing to use, so
    /// the id is computed from the record — see ``InactivityParser/identifier(date:type:note:)``.
    public let id: UUID

    /// The day this is filed on, already snapped to `startOfDay` in the device's own zone.
    public let date: Date

    /// The producer's own word for what was received, e.g. `"dream"`.
    public let type: String

    /// The entry's prose — which is **both** the stored value and an input to the id above.
    ///
    /// Non-optional here, unlike `ReceptiveInactivity.note`: a record that reaches this type has
    /// already survived the parser's refusal of a record with no text, and an optional that can never
    /// be `nil` at this point would be an absence the importer still had to handle. See
    /// ``InactivityParser`` for why a missing note is refused rather than defaulted.
    public let note: String
}

public enum InactivityImportError: Error, LocalizedError {
    case unreadable(URL)
    /// The file is not in this build's resources at all — a packaging fault, not a bad file.
    case notBundled
    /// The JSON decoded, but is not the shape this app reads.
    case missingInactivities
    /// The top level is not an object at all, so there is no `receptive_inactivities` to look for.
    case malformedDocument

    /// A field this app cannot do without. **Carries the record's own values rather than a line
    /// number**, because a JSON file has no lines — `ZeroFastingError.unparseableDate`'s reason.
    ///
    /// It covers a key that is absent **and** a key whose value is blank, and the second is not
    /// stretching the word: a blank `type` would capitalise to nothing and a blank `note` would be a
    /// value nobody supplied. `""` is not a name and `""` is not text, which is the rule
    /// `ReceptiveInactivityDraft.setNote(_:)` already holds on the sheet's side.
    case missingField(record: String, field: String)

    /// A date this parser cannot place.
    case unparseableDate(record: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "The receptive inactivity file at \(url.lastPathComponent) could not be read."
        case .notBundled:
            return "This build does not include the receptive inactivity file."
        case .missingInactivities:
            return "This does not look like a receptive inactivity file — it has no receptive_inactivities."
        case .malformedDocument:
            return "This does not look like a receptive inactivity file — it is not a JSON object."
        case .missingField(let record, let field):
            return "One record has no \"\(field)\": \(record)."
        case .unparseableDate(let record, let value):
            return "The record \(record) has an unreadable date: \"\(value)\"."
        }
    }
}

/// Reads a file of received states — the owner's own dream journal — out of a JSON document.
///
/// **Nothing here silently skips a row.** This is `ZeroFastingParser`'s and `WhoopExportParser`'s rule,
/// and the reason it exists: the CSV parser that came before them used `ISO8601DateFormatter` against a
/// format it could not read, so its `guard … else { continue }` discarded every row and the import
/// reported success while writing nothing. A record this parser cannot read is a **thrown error naming
/// the record**, not a missing entry discovered weeks later.
///
/// ## Two fields are required that a more forgiving parser would default
///
/// `date` and `type` are obvious. **`note` is the one worth arguing**, because it is prose and prose has
/// a natural absence — but on *this* file it does not: `dreams.json` is generated from a notes journal
/// by a generator outside this repository, every one of its 60 records carries a note, and a record without
/// one is a generator fault rather than a dream nobody wrote down. Defaulting it to `""` would store a
/// value nobody supplied *and* — because the note is an input to the id — give two different faults the
/// same identity. A future producer of meditations, which genuinely can carry no text, wants
/// `ReceptiveInactivity.note`'s `nil`, and that is a change to this parser's contract rather than
/// something to guess at now.
///
/// ## The two guards are the *file* check
///
/// A JSON document has no columns to be missing, so pointing a caller at the wrong file cannot fail the
/// way `WhoopExportParser`'s `missingColumns` fails. The root must be a JSON **object** (else
/// `.malformedDocument`), and it must carry a `receptive_inactivities` **array** (else
/// `.missingInactivities`). That second guard is this file's `missingFastData`: it is what makes
/// pointing the importer at any other JSON fail loudly rather than decoding to zero rows and reporting
/// a successful import of nothing.
public enum InactivityParser {

    /// The one key this app reads.
    static let inactivitiesKey = "receptive_inactivities"

    private static let dateKey = "date"
    private static let typeKey = "type"
    private static let noteKey = "note"

    public static func parseInactivities(at url: URL) throws -> [InactivityRow] {
        guard let data = try? Data(contentsOf: url) else {
            throw InactivityImportError.unreadable(url)
        }
        return try parseInactivities(data)
    }

    public static func parseInactivities(_ text: String) throws -> [InactivityRow] {
        try parseInactivities(Data(text.utf8))
    }

    public static func parseInactivities(_ data: Data) throws -> [InactivityRow] {
        guard let document = try? JSONSerialization.jsonObject(with: data) else {
            throw InactivityImportError.malformedDocument
        }
        guard let root = document as? [String: Any] else {
            throw InactivityImportError.malformedDocument
        }
        guard let records = root[inactivitiesKey] as? [[String: Any]] else {
            throw InactivityImportError.missingInactivities
        }
        // `enumerated()` rather than a plain `map`, so a record with neither a date nor a type can
        // still be named by its position — see `label(for:at:)`.
        return try records.enumerated().map { try makeRow(from: $0.element, at: $0.offset) }
    }

    /// One record, or a thrown error naming it.
    private static func makeRow(from record: [String: Any], at index: Int) throws -> InactivityRow {
        let label = label(for: record, at: index)

        guard let rawDate = nonBlank(record[dateKey]) else {
            throw InactivityImportError.missingField(record: label, field: dateKey)
        }
        guard let date = date(from: rawDate) else {
            throw InactivityImportError.unparseableDate(record: label, value: rawDate)
        }
        guard let type = nonBlank(record[typeKey]) else {
            throw InactivityImportError.missingField(record: label, field: typeKey)
        }
        guard let note = nonBlank(record[noteKey]) else {
            throw InactivityImportError.missingField(record: label, field: noteKey)
        }

        return InactivityRow(
            id: identifier(date: date, type: type, note: note),
            date: date,
            type: type,
            note: note)
    }

    /// A string value that is present and carries something. `nil` for an absent key **and** for a
    /// blank value, so one guard covers both — see `missingField`'s doc comment for why they are one
    /// case rather than two.
    private static func nonBlank(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What a bad record is called in an error message.
    ///
    /// A JSON file has no line numbers, so the handle has to come from the record itself. The date is
    /// the best one when it is there — it is the field a reader would search the file for — then the
    /// type, and then the record's position, which is the only thing left when both are missing and is
    /// **counted from one** because it is read by a person rather than by an index.
    private static func label(for record: [String: Any], at index: Int) -> String {
        if let date = nonBlank(record[dateKey]) { return "the record dated \(date)" }
        if let type = nonBlank(record[typeKey]) { return "the \(type) record" }
        return "record #\(index + 1)"
    }

    // MARK: - The identity

    /// The pinned namespace, as its own 16 bytes rather than a parsed string.
    ///
    /// **The UUID it spells is `1B671A64-40D5-491E-99B0-DA7E7B3FB3E1`**, and that string is the thing
    /// to quote when reproducing this in another language. The bytes are written out here rather than
    /// run through `UUID(uuidString:)` so that the constant is total: a force-unwrapped literal is a
    /// crash waiting on a typo, and a namespace this app hashes into every imported id is not a value
    /// to be optimistic about.
    private static let namespaceBytes: [UInt8] = [
        0x1B, 0x67, 0x1A, 0x64, 0x40, 0xD5, 0x49, 0x1E,
        0x99, 0xB0, 0xDA, 0x7E, 0x7B, 0x3F, 0xB3, 0xE1,
    ]

    /// The id an imported entry gets, derived from its own day, type and text.
    ///
    /// **A UUIDv5 (RFC 4122 §4.3)**: SHA-1 over the ``namespaceBytes`` followed by the UTF-8 of the
    /// name string, truncated to sixteen bytes, with the version and variant bits stamped. The name
    /// string is exactly —
    ///
    ///     <yyyy-MM-dd>|<type>|<note>
    ///
    /// — with a literal `|` between the three and the date written the way the file writes it. For the
    /// bundled file's first record that is
    /// `2023-07-23|dream|<its note>`, which resolves to the UUID asserted in §21 of the suite; the same
    /// namespace and name give the same value under Python's `uuid.uuid5`, which is what makes the
    /// assertion an expected value rather than a self-consistent round trip. That rule matters here
    /// more than usual: this is the one place where the *only* thing keeping the import idempotent is
    /// the id itself.
    ///
    /// **The date round-trips through the same pinned formatter that parsed it**, and that pairing is
    /// load-bearing rather than tidy. `dayText(from:)` is the inverse of `date(from:)`, so the string
    /// hashed here is the string the file holds — which is what makes an entry's identity a property
    /// of the file rather than of the device that read it, and therefore what keeps a re-import on a
    /// phone in another time zone from minting sixty new ids and a second copy of the journal.
    ///
    /// **`type` and `note` are hashed verbatim and are not normalised.** `type` is deliberately *not*
    /// folded the way `ReceptiveInactivityCatalog.name(for:)` folds it: that resolver answers what the
    /// app should draw, while this answers what the file said, and folding here would give a file's
    /// `"Dream"` and `"dream"` one row — which is the right answer to a different question, and one the
    /// resolver already gives at the point where it matters.
    public static func identifier(date: Date, type: String, note: String) -> UUID {
        let name = "\(dayText(from: date))|\(type)|\(note)"

        var bytes = namespaceBytes
        bytes.append(contentsOf: Array(name.utf8))
        var digest = Array(Insecure.SHA1.hash(data: Data(bytes)).prefix(16))

        // RFC 4122 §4.3: the version in the high nibble of byte 6, the variant in the top two bits of
        // byte 8. Without these the value is sixteen arbitrary bytes and is not a uuid5 — which
        // `UUID(uuidString:)` would still round-trip, so nothing downstream would notice.
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80

        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    // MARK: - The one grammar, and it is two-way

    /// The file's day grammar, in one place, because it is used in **both** directions and the two
    /// halves have to agree.
    ///
    /// **The time zone is `.current` and that is the sharpest trap in this file.** `DateFormatter`
    /// defaults to UTC, so a bare `"yyyy-MM-dd"` formatter turns `"2023-07-23"` into `2023-07-23T00:00Z`
    /// — which `Calendar.current.startOfDay` in a negative-offset zone snaps back to **2023-07-22**.
    /// That is every record filed a day early, silently, on a screen that still looks plausible, and
    /// nothing in the app would say so. Parsing in the device's own zone and re-snapping through
    /// `startOfDay` is what keeps the parsed day the day the file named.
    ///
    /// `en_US_POSIX` is `ZeroFastingParser.date(from:)`'s reason verbatim: a device set to a locale with
    /// its own calendar or numeral system must not change how the file's digits are read.
    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// `"2023-07-23"` as the day it names, in this device's zone.
    private static func date(from raw: String) -> Date? {
        formatter().date(from: raw)?.startOfDay
    }

    /// A day back as the string `date(from:)` read it from. The inverse, and only used by
    /// ``identifier(date:type:note:)``.
    private static func dayText(from date: Date) -> String {
        formatter().string(from: date)
    }
}
