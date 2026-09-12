import Foundation

/// One row of WHOOP's `physiological_cycles.csv`, parsed and nothing more.
///
/// Every field is optional because the export leaves cells empty and that absence is information: a
/// cycle that has not ended yet has no strain, and a day the strap was not worn has no HRV. Deciding
/// what an empty cell *means* is the importer's job, not the parser's — this type only refuses to
/// invent a value for one.
public struct WhoopExportRow: Sendable, Equatable {
    /// The cycle's start. Also the sleep onset for most rows.
    public let cycleStart: Date
    /// The morning the cycle ended. **This is the day key** — see `WhoopExportImporter`.
    public let wakeOnset: Date?
    public let sleepOnset: Date?

    public let recoveryScorePercent: Int?
    public let restingHeartRate: Int?
    public let hrvMs: Double?
    public let skinTempCelsius: Double?
    public let bloodOxygenPercent: Double?

    public let dayStrain: Double?
    public let energyKcal: Double?
    public let maxHeartRate: Int?
    public let averageHeartRate: Int?

    public let sleepPerformancePercent: Int?
    public let respiratoryRate: Double?
    public let asleepMinutes: Double?
    public let inBedMinutes: Double?
    public let lightMinutes: Double?
    public let deepMinutes: Double?
    public let remMinutes: Double?
    public let awakeMinutes: Double?
    public let sleepNeedMinutes: Double?

    /// Whether this row carries anything worth writing. `false` for the export's blank filler rows,
    /// which exist to close a cycle and hold no measurement at all.
    public var isEmpty: Bool {
        recoveryScorePercent == nil && dayStrain == nil && wakeOnset == nil
    }
}

public enum WhoopExportError: Error, LocalizedError {
    case unreadable(URL)
    /// The export is not in this build's resources at all — a packaging fault, not a bad file.
    case notBundled
    case missingColumns([String])
    case unparseableDate(line: Int, value: String)
    case unparseableTimezone(line: Int, value: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url):
            return "The WHOOP export at \(url.lastPathComponent) could not be read."
        case .notBundled:
            return "This build does not include the WHOOP export file."
        case .missingColumns(let names):
            return "This does not look like a WHOOP export — no \(names.joined(separator: ", ")) column."
        case .unparseableDate(let line, let value):
            return "Line \(line) has an unreadable date: \"\(value)\"."
        case .unparseableTimezone(let line, let value):
            return "Line \(line) has an unreadable timezone: \"\(value)\"."
        }
    }
}

/// Reads WHOOP's `physiological_cycles.csv`.
///
/// **Nothing here silently skips a row.** The previous CSV parser in this codebase used
/// `ISO8601DateFormatter`, which returns nil for the export's `2026-08-22 00:17:13` format, so its
/// `guard ... else { continue }` discarded every row and it returned an empty array with no error —
/// an import that reports success and writes nothing. A row this parser cannot place in time is a
/// thrown error naming the line, not a missing day discovered weeks later.
public enum WhoopExportParser {

    /// The columns the importer depends on. Validated up front so a different file fails loudly
    /// rather than importing a table of nils.
    private static let requiredColumns = [
        "Cycle start time",
        "Cycle timezone",
        "Wake onset",
    ]

    public static func parseCycles(at url: URL) throws -> [WhoopExportRow] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw WhoopExportError.unreadable(url)
        }
        return try parseCycles(text)
    }

    public static func parseCycles(_ text: String) throws -> [WhoopExportRow] {
        // `\r` because the file may have been round-tripped through a tool that wrote CRLF, and a
        // trailing carriage return on every field would poison every numeric parse.
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "\r", with: "") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard let header = lines.first else { return [] }
        let columns = header.components(separatedBy: ",")
        let index = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, $0) })

        let missing = requiredColumns.filter { index[$0] == nil }
        guard missing.isEmpty else { throw WhoopExportError.missingColumns(missing) }

        return try lines.dropFirst().enumerated().compactMap { offset, line in
            // +2 because `enumerated()` is zero-based over a collection that already dropped the
            // header, and a human reading the file counts from 1.
            let lineNumber = offset + 2
            let fields = line.components(separatedBy: ",")

            let timezoneLabel = field(fields, index["Cycle timezone"])
            guard let offsetSeconds = Self.offsetSeconds(from: timezoneLabel),
                let zone = TimeZone(secondsFromGMT: offsetSeconds)
            else {
                throw WhoopExportError.unparseableTimezone(line: lineNumber, value: timezoneLabel)
            }

            // The export writes local wall-clock time plus the zone it was recorded in, so the zone
            // is part of the value rather than a presentation detail — drop it and every timestamp
            // shifts by four or five hours.
            func date(_ column: String) throws -> Date? {
                let raw = field(fields, index[column])
                guard !raw.isEmpty else { return nil }
                guard let parsed = Self.dateFormatter(zone).date(from: raw) else {
                    throw WhoopExportError.unparseableDate(line: lineNumber, value: raw)
                }
                return parsed
            }

            let start = try date("Cycle start time")
            guard let cycleStart = start else {
                throw WhoopExportError.unparseableDate(
                    line: lineNumber, value: field(fields, index["Cycle start time"]))
            }

            func number(_ column: String) -> Double? {
                let raw = field(fields, index[column])
                return raw.isEmpty ? nil : Double(raw)
            }
            func integer(_ column: String) -> Int? {
                number(column).map { Int($0.rounded()) }
            }
            func minutes(_ column: String) -> Double? { number(column) }

            return WhoopExportRow(
                cycleStart: cycleStart,
                wakeOnset: try date("Wake onset"),
                sleepOnset: try date("Sleep onset"),
                recoveryScorePercent: integer("Recovery score %"),
                restingHeartRate: integer("Resting heart rate (bpm)"),
                hrvMs: number("Heart rate variability (ms)"),
                skinTempCelsius: number("Skin temp (celsius)"),
                bloodOxygenPercent: number("Blood oxygen %"),
                dayStrain: number("Day Strain"),
                energyKcal: number("Energy burned (cal)"),
                maxHeartRate: integer("Max HR (bpm)"),
                averageHeartRate: integer("Average HR (bpm)"),
                sleepPerformancePercent: integer("Sleep performance %"),
                respiratoryRate: number("Respiratory rate (rpm)"),
                asleepMinutes: minutes("Asleep duration (min)"),
                inBedMinutes: minutes("In bed duration (min)"),
                lightMinutes: minutes("Light sleep duration (min)"),
                deepMinutes: minutes("Deep (SWS) duration (min)"),
                remMinutes: minutes("REM duration (min)"),
                awakeMinutes: minutes("Awake duration (min)"),
                sleepNeedMinutes: minutes("Sleep need (min)"))
        }
    }

    // MARK: - Field parsing

    private static func field(_ fields: [String], _ index: Int?) -> String {
        guard let index, fields.indices.contains(index) else { return "" }
        return fields[index].trimmingCharacters(in: .whitespaces)
    }

    /// `UTC-04:00` → `-14400`. A fixed offset rather than a named zone: the export states an offset,
    /// so resolving a named zone here would be inventing a fact the file does not carry.
    private static func offsetSeconds(from label: String) -> Int? {
        guard label.hasPrefix("UTC") else { return nil }
        let rest = label.dropFirst(3)
        guard let sign = rest.first, sign == "+" || sign == "-" else { return nil }
        let parts = rest.dropFirst().split(separator: ":")
        guard parts.count == 2,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1])
        else { return nil }
        let magnitude = hours * 3600 + minutes * 60
        return sign == "-" ? -magnitude : magnitude
    }

    private static func dateFormatter(_ zone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        // POSIX so a device set to a locale with its own calendar or numeral system cannot change how
        // the export's digits are read.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }
}
