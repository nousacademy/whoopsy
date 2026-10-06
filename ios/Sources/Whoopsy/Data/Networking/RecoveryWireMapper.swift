import Foundation

/// The wire's own shape for one recovery day, and the two conversions onto it.
///
/// **This type is where the field names change, and it is the only place they do.** A recovery reading
/// goes by three names on its way from SQLite to the server — `skin_temperature` / `skinTemp` /
/// `skinTemperature` — and every one of those is a place a mapping can be written wrong in a way
/// nothing catches, because both sides of a wrong mapping are the same `Double?` and a screen built on
/// either one looks right. `RecoverySyncRow` takes the *record's* property names precisely so the
/// conversions here are a field-for-field copy with no naming decision inside them, which leaves this
/// one file as the single place a wire name is written down.
///
/// **The nullable four are written with `encode`, never `encodeIfPresent`, and that is the whole reason
/// this type spells out its own `encode(to:)`.** Synthesised `Codable` encodes an optional property with
/// `encodeIfPresent`, which **omits the key** when the value is `nil`. The server's four optional fields
/// are `.nullable()` and not `.optional()`: `null` is a value this API accepts and an absent key is a
/// body that failed validation. So the synthesised version would turn every imported day — all 910 of
/// them carry no skin temperature — into a `400`, and the message would name a missing field rather than
/// the encoder that dropped it.
///
/// **`date` on the wire is a bare `YYYY-MM-DD` and the stored value is a UTC instant string.** That
/// mismatch is the single hardest thing in this file and it fails silently in both directions; see
/// `dayKey(for:in:)` and `day(fromDayKey:in:)`, which carry it.
public struct RecoveryDTO: Codable, Equatable, Sendable {

    /// The day, `YYYY-MM-DD`. Not an instant — see `RecoveryWireMapper.dayKey(for:in:)`.
    public let date: String
    public let recoveryScore: Int
    public let restingHeartRate: Int
    public let hrvValueMs: Double
    public let hrvMetric: HRVMetric
    public let skinTemperature: Double?
    public let spo2Percentage: Double?
    public let respiratoryRate: Double?
    public let source: String?

    public init(
        date: String,
        recoveryScore: Int,
        restingHeartRate: Int,
        hrvValueMs: Double,
        hrvMetric: HRVMetric,
        skinTemperature: Double?,
        spo2Percentage: Double?,
        respiratoryRate: Double?,
        source: String?
    ) {
        self.date = date
        self.recoveryScore = recoveryScore
        self.restingHeartRate = restingHeartRate
        self.hrvValueMs = hrvValueMs
        self.hrvMetric = hrvMetric
        self.skinTemperature = skinTemperature
        self.spo2Percentage = spo2Percentage
        self.respiratoryRate = respiratoryRate
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case recoveryScore
        case restingHeartRate
        case hrvValueMs
        case hrvMetric
        case skinTemperature
        case spo2Percentage
        case respiratoryRate
        case source
    }

    /// Written by hand so the four nullable fields reach the wire as `null` rather than as nothing.
    ///
    /// The decoding half stays synthesised, deliberately: `decodeIfPresent` reads a `null` and a missing
    /// key alike, and being generous on the way in costs nothing while being generous on the way out
    /// would be a body the server refuses.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(recoveryScore, forKey: .recoveryScore)
        try container.encode(restingHeartRate, forKey: .restingHeartRate)
        try container.encode(hrvValueMs, forKey: .hrvValueMs)
        try container.encode(hrvMetric, forKey: .hrvMetric)
        try container.encode(skinTemperature, forKey: .skinTemperature)
        try container.encode(spo2Percentage, forKey: .spo2Percentage)
        try container.encode(respiratoryRate, forKey: .respiratoryRate)
        try container.encode(source, forKey: .source)
    }
}

/// The wire's window query, derived from this app's half-open range.
///
/// **Two conventions meet here and neither one moves.** The app's ranges are half-open `[from, to)` —
/// `Date.startOfNextDay` builds the upper bound, because `Date.endOfDay` is the last *instant* of a day
/// and a bound one second short drops a row written at midnight. The server's window is `days` back
/// from `endingOn`, **inclusive at both ends**, so `days = 14` answers 15 days. A caller that passed its
/// own half-open arithmetic straight through would therefore ask for one day too many, every time, and
/// would receive a day it had already filed under the neighbouring chunk.
///
/// The translation is one subtraction and it is stated once, here, rather than at each call site: the
/// last day *in* a half-open range is `to` minus a day, and `days` is the count from `from` to that day
/// rather than the count of days covered. A ten-day range is `days = 9`.
public struct RecoveryWindow: Equatable, Sendable {
    /// Days back from `endingOn`, inclusive at both ends. Zero is legal and means `endingOn` alone.
    public let days: Int

    /// The day the window ends on, as a bare `YYYY-MM-DD` key.
    public let endingOn: String

    public init(days: Int, endingOn: String) {
        self.days = days
        self.endingOn = endingOn
    }

    /// Translate a half-open local range into the server's inclusive window.
    ///
    /// Returns `nil` for a range that holds no days at all — `to <= from` — which is a request with no
    /// honest spelling rather than an error to report: the server's `days` is a non-negative count back
    /// from a day, so an empty range has no `endingOn` to anchor on. Callers treat it as *nothing to
    /// read*, which is what it is.
    ///
    /// `calendar` is a parameter so the arithmetic can be asserted outside the device's own zone. It
    /// must be the same calendar `dayKey(for:in:)` is given, or the two halves of one window are
    /// computed in two zones.
    public init?(from: Date, to: Date, calendar: Calendar = .current) {
        let first = calendar.startOfDay(for: from)
        let upper = calendar.startOfDay(for: to)
        guard upper > first else { return nil }

        guard let last = calendar.date(byAdding: .day, value: -1, to: upper),
              let span = calendar.dateComponents([.day], from: first, to: last).day,
              span >= 0
        else { return nil }

        self.days = span
        self.endingOn = RecoveryWireMapper.dayKey(for: last, in: calendar)
    }
}

/// Row ↔ wire, in both directions, plus the two questions the sync asks about a row before sending it.
///
/// An `enum` with no cases rather than a `struct`, because there is nothing here to instantiate: every
/// member is a pure conversion from one value to another, and making that unrepresentable is cheaper
/// than a convention that nobody constructs one.
public enum RecoveryWireMapper {

    // MARK: - The day key

    /// The wire's day for a local instant, in the device's own zone.
    ///
    /// **This is the highest-value line in the file and it is the inverse of the bug `InactivityParser`
    /// already documents.** GRDB stores a `Date` as a UTC instant string, so `recoveries.date` on this
    /// machine — a UTC−4 device — holds `"2026-09-10 04:00:00.000"` for the day it calls the 10th.
    /// Reading that instant's *UTC* calendar day gives the 10th by luck at a negative offset and the
    /// **11th** at a positive one; the day the app means is the one in the zone the app is running in.
    ///
    /// It is built from `Calendar` and not from a `DateFormatter` deliberately. A formatter has a
    /// `timeZone` that defaults to UTC, and the failure that produces is a screen that looks right and
    /// files every day one early — the defect `InactivityParser` sets `timeZone = .current` to avoid.
    /// A calendar has no such default to forget: `Calendar.current` *is* the device's, and the only way
    /// to get another zone is to ask for one, which is exactly what the `calendar:` parameter exists for.
    public static func dayKey(for day: Date, in calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The local day a wire key names, or `nil` if it does not name one.
    ///
    /// It parses in the device's zone and then **re-snaps through `startOfDay`**, and both halves are
    /// load-bearing. Parsing `"2026-09-10"` with a UTC calendar gives `2026-09-10T00:00Z`, which is
    /// `2026-09-09 20:00` here — and every keyed read and write in this app matches on
    /// `date.startOfDay`, so the row would be filed a day early, invisibly, beside a screen drawing the
    /// right date. The re-snap is what makes the returned value the same shape every other writer in
    /// this app produces, so it can be compared and stored without a second normalisation.
    ///
    /// The shape test refuses more than a split on `-`. `"2026-2-3"` is not the wire's format, and the
    /// round-trip check below refuses a day that does not exist: `Calendar` rolls `2026-02-31` forward to
    /// March, and a server that did that would file a day nobody named under a key that looks fine.
    public static func day(fromDayKey key: String, in calendar: Calendar = .current) -> Date? {
        let fields = key.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2])
        else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day

        guard let parsed = calendar.date(from: components) else { return nil }

        let check = calendar.dateComponents([.year, .month, .day], from: parsed)
        guard check.year == year, check.month == month, check.day == day else { return nil }

        return calendar.startOfDay(for: parsed)
    }

    // MARK: - Row ↔ wire

    /// The body this row is sent as.
    ///
    /// Total: it cannot fail, and that is a claim about `isSendable(_:)` rather than about this
    /// function. Every value here is carried across unchanged — nothing is clamped, rounded or filled
    /// in — because a row the database would refuse is a row this app must not quietly repair.
    public static func dto(for row: RecoverySyncRow, in calendar: Calendar = .current) -> RecoveryDTO {
        RecoveryDTO(
            date: dayKey(for: row.date, in: calendar),
            recoveryScore: row.recoveryScore,
            restingHeartRate: row.restingHeartRate,
            hrvValueMs: row.hrvValueMs,
            hrvMetric: row.hrvMetric,
            skinTemperature: row.skinTemp,
            spo2Percentage: row.spo2,
            respiratoryRate: row.respiratoryRate,
            source: row.source
        )
    }

    /// The row a body arriving from the server is stored as.
    ///
    /// The only failure is a `date` this client cannot read, and it is thrown rather than defaulted: a
    /// row stored under a guessed day is a day the user did not measure, filed where they will find it
    /// and believe it. `CloudSyncError.malformed` is the right case because it is exactly what that
    /// error documents — an answer this client could not read, surfaced as the bug it is rather than
    /// degraded into a cached local figure.
    public static func row(for dto: RecoveryDTO, in calendar: Calendar = .current) throws -> RecoverySyncRow {
        guard let day = day(fromDayKey: dto.date, in: calendar) else {
            throw CloudSyncError.malformed(message: "the answer carried a day this app cannot read: \(dto.date)")
        }

        return RecoverySyncRow(
            date: day,
            recoveryScore: dto.recoveryScore,
            restingHeartRate: dto.restingHeartRate,
            hrvValueMs: dto.hrvValueMs,
            hrvMetric: dto.hrvMetric,
            skinTemp: dto.skinTemperature,
            spo2: dto.spo2Percentage,
            respiratoryRate: dto.respiratoryRate,
            source: dto.source
        )
    }

    // MARK: - What the database will accept

    /// Whether this row is one the server can be given.
    ///
    /// **This exists because the wire's constraints are stricter than this schema's, and the gap is
    /// reachable on a real database rather than theoretical.** Measured against the developer's own
    /// `whoopsy.sqlite`, both `recoveries` rows carry `resting_heart_rate = 0` — legacy placeholders
    /// from before the app's absence rule, which `recovery_score`/`hrv_value_ms` also show as zero. The
    /// column is `NOT NULL` with no check, so a zero is storable; the server declares that field
    /// `.positive()` and says why in the schema's own words: *a rate of zero is not a measurement, it is
    /// an absent one, and an absent one has no row here*. The server is refusing precisely the rows this
    /// app's readers already draw as `—`.
    ///
    /// So the sync must ask before it sends, and it must ask here rather than in the use case: predicting
    /// what the server accepts is a fact about the wire's shape, and this file is where that shape is
    /// written down. The alternative is measured and unacceptable — `POST /batch` is one transaction and
    /// all-or-nothing, so one placeholder in a chunk of two hundred refuses the other hundred and
    /// ninety-nine, and the user's upload fails with a message naming a day they never touched.
    ///
    /// It is deliberately **not** `RecoverySyncRow.hasMeasurement`. That predicate asks *is this a
    /// reading*, which is the app's question; this one asks *will the database take it*, which is the
    /// wire's. They agree about a zero-rate placeholder and part company on a row with a plausible rate
    /// and no variability: that row is unmeasured by the app's rule and perfectly acceptable to the
    /// server. Sending it is the honest thing — the two stores then hold the same row, and every reader
    /// on either side draws the same `—` — so this function must not be narrowed into the other.
    ///
    /// The finiteness tests are the encoder's, not the schema's: `JSONEncoder` **throws** on a `NaN` or
    /// an infinity rather than writing `null`, so a non-finite value is a request that never leaves the
    /// phone. Refusing it here turns that into a skipped row instead of a failed chunk.
    public static func isSendable(_ row: RecoverySyncRow) -> Bool {
        guard row.restingHeartRate > 0 else { return false }
        guard (0 ... 100).contains(row.recoveryScore) else { return false }
        guard row.hrvValueMs.isFinite, row.hrvValueMs >= 0 else { return false }

        if let skin = row.skinTemp, !skin.isFinite { return false }
        if let spo2 = row.spo2, !(spo2.isFinite && (0 ... 100).contains(spo2)) { return false }
        if let respiratory = row.respiratoryRate, !(respiratory.isFinite && respiratory >= 0) { return false }

        // The schema is `z.string().min(1).nullable()`: `null` is accepted and `""` is refused. This
        // app's absence is a `nil` and its provenance labels are never empty, so the empty string is a
        // value from some other writer — and sending it would refuse a chunk over a row nobody can see
        // anything wrong with.
        if let source = row.source, source.isEmpty { return false }

        return true
    }
}
