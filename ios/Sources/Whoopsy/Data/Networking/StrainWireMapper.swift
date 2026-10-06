import Foundation

/// The wire's own shape for one strain day, and the two conversions onto it.
///
/// **This type is where the field names change, and here that is a smaller job than on the recoveries
/// side.** `StrainRecord` declares no `CodingKeys`, so its property names are already its column names
/// and `StrainSyncRow` took them verbatim — which means every field below goes out under the name it is
/// stored under, and the only namespace that differs is D1's (`strain_score`, `average_heart_rate`),
/// which is `d1StrainRepository.ts`'s business and not this file's. What is left here is the day key and
/// the nullability rule, and both of them are the hard parts.
///
/// **`source` is written with `encode`, never `encodeIfPresent`, and it is the whole reason this type
/// spells out its own `encode(to:)`.** Synthesised `Codable` encodes an optional property with
/// `encodeIfPresent`, which **omits the key** when the value is `nil`. The schema declares `source` as
/// `.nullable()` and not `.optional()`: `null` is a value this API accepts and an absent key is a body
/// that failed validation. A synthesised encoder would therefore turn every strain row this app scored
/// itself — which is every row whose `source` is `nil` — into a `400`, and the message would name a
/// missing field rather than the encoder that dropped it. One nullable field rather than the recoveries
/// table's four, and the failure is identical.
///
/// **`hasMeasurement` rides the wire as a required boolean, and that is what makes this resource's
/// absence rule different from its sibling's.** An unmeasured row is a thing this app stores and a thing
/// the server stores, told apart from a reading by this flag and by nothing else — not by the score,
/// because a genuine rest day is a real `0.0` and a pre-`v7` placeholder holds `0.0` too, and not by the
/// heart rates, which are `nonnegative()` on this wire precisely so they cannot be the discriminator.
/// So the flag is carried unchanged in both directions and is never derived on either side.
///
/// **`date` on the wire is a bare `YYYY-MM-DD` and the stored value is a UTC instant string.** That
/// mismatch is the same one `RecoveryWireMapper` documents, and the day key is **one wire concept rather
/// than two** — this file forwards to that mapper's arithmetic rather than restating it, because two
/// copies of "which day is this instant" would keep parsing and would only ever disagree with the
/// calendar.
public struct StrainDTO: Codable, Equatable, Sendable {

    /// The day, `YYYY-MM-DD`. Not an instant — see `StrainWireMapper.dayKey(for:in:)`.
    public let date: String

    /// WHOOP's 0–21 strain scale.
    public let strainScore: Double

    /// Work done over the day, in kilojoules. `0` is a legitimate measured value.
    public let kilojoules: Double

    /// The day's average heart rate. **Non-negative rather than positive**, unlike a resting rate: an
    /// unmeasured row carries `0` here and is legitimately on this wire.
    public let averageHeartRate: Int

    /// The day's peak heart rate, non-negative for the same reason.
    public let maxHeartRate: Int

    /// Whether the three figures above are readings. Required, and never inferred by either side.
    public let hasMeasurement: Bool

    /// Where the row came from — `whoop_export` for an imported day, `nil` for one this app scored.
    public let source: String?

    public init(
        date: String,
        strainScore: Double,
        kilojoules: Double,
        averageHeartRate: Int,
        maxHeartRate: Int,
        hasMeasurement: Bool,
        source: String?
    ) {
        self.date = date
        self.strainScore = strainScore
        self.kilojoules = kilojoules
        self.averageHeartRate = averageHeartRate
        self.maxHeartRate = maxHeartRate
        self.hasMeasurement = hasMeasurement
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case strainScore
        case kilojoules
        case averageHeartRate
        case maxHeartRate
        case hasMeasurement
        case source
    }

    /// Written by hand so `source` reaches the wire as `null` rather than as nothing.
    ///
    /// The decoding half stays synthesised, deliberately: `decodeIfPresent` reads a `null` and a missing
    /// key alike, and being generous on the way in costs nothing while being generous on the way out
    /// would be a body the server refuses.
    ///
    /// `hasMeasurement` is encoded explicitly for the same reason and not because it is optional: the
    /// synthesised encoder would write it correctly, but writing every field by hand is what makes the
    /// one that *needs* the hand-written form impossible to lose in a later tidy. This body is
    /// `.strict()`, so a field dropped from here is a `400` on every write rather than a default.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(strainScore, forKey: .strainScore)
        try container.encode(kilojoules, forKey: .kilojoules)
        try container.encode(averageHeartRate, forKey: .averageHeartRate)
        try container.encode(maxHeartRate, forKey: .maxHeartRate)
        try container.encode(hasMeasurement, forKey: .hasMeasurement)
        try container.encode(source, forKey: .source)
    }
}

// MARK: - The window

/// The `days`/`endingOn` pair the strains window read takes.
///
/// **A typealias and not a second struct, on `WorkoutWindow`'s rule and for its reason.** The API
/// declares three query schemas — one per resource — and all three carry the same two fields with the
/// same bounds, reading `MAX_STRAIN_WINDOW_DAYS` from `strainService.ts` rather than from a constant of
/// their own. Declaring `StrainWindow` afresh would be a second copy of `RecoveryWindow.init?`'s
/// arithmetic, which is the off-by-one that decides whether a ten-day range is `days: 9` or `days: 10`
/// — and two copies of that drift by exactly one day in a way no screen can see. This name exists so
/// that the strains call sites read in strains' vocabulary; the rule behind it is one rule.
public typealias StrainWindow = RecoveryWindow

// MARK: - The mapper

/// Row ↔ wire, in both directions, plus the one question the sync asks about a row before sending it.
///
/// An `enum` with no cases rather than a `struct`, on `RecoveryWireMapper`'s argument: every member is a
/// pure conversion from one value to another, and there is no state a mapper could hold that would not
/// be a second copy of something the row already says.
public enum StrainWireMapper {

    // MARK: The day key

    /// The day key, forwarded to the one place this app writes that rule down.
    ///
    /// `RecoveryWireMapper` owns the arithmetic because `recoveries` reached the wire first, and the day
    /// key is **one wire concept rather than two** — the API declares a single `DayKeySchema` and this
    /// resource's `date` field is a reference to that same shape. A second copy here would be a second
    /// answer to a question that has one, and the failure would be invisible in the worst way: both
    /// spellings would keep parsing, so nothing would throw, and only one of them would keep agreeing
    /// with the calendar about which day a strain is filed on.
    public static func dayKey(for day: Date, in calendar: Calendar = .current) -> String {
        RecoveryWireMapper.dayKey(for: day, in: calendar)
    }

    /// The inverse, forwarded for `dayKey(for:in:)`'s reason.
    ///
    /// It is the stricter half and the strictness is the calendar's rather than a pattern's:
    /// `2026-02-31` is four digits, a dash and two digits in exactly the right places, and what refuses
    /// it is re-snapping through `startOfDay` and checking the calendar's fields came back unchanged.
    /// See `RecoveryWireMapper.day(fromDayKey:in:)`.
    public static func day(fromDayKey key: String, in calendar: Calendar = .current) -> Date? {
        RecoveryWireMapper.day(fromDayKey: key, in: calendar)
    }

    // MARK: Row ↔ wire

    /// The body this row is sent as.
    ///
    /// Total: it cannot fail, and that is a claim about `isSendable(_:)` rather than about this
    /// function. Every value here is carried across unchanged — nothing is clamped, rounded or filled
    /// in — because a row the database would refuse is a row this app must not quietly repair.
    public static func dto(for row: StrainSyncRow, in calendar: Calendar = .current) -> StrainDTO {
        StrainDTO(
            date: dayKey(for: row.date, in: calendar),
            strainScore: row.strainScore,
            kilojoules: row.kilojoules,
            averageHeartRate: row.averageHeartRate,
            maxHeartRate: row.maxHeartRate,
            hasMeasurement: row.hasMeasurement,
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
    ///
    /// **Nothing here consults `hasMeasurement`.** The row is built whether the flag is `true` or
    /// `false`, because an unmeasured row is a row this app stores and draws a dash for — refusing it
    /// would turn a day the database holds into a day this app has never heard of. That is the one
    /// place this mapper's behaviour differs from a copy of the recoveries one, and it is a difference
    /// about the *wire* rather than about this function: see `CloudSync.strain(on:)`.
    public static func row(for dto: StrainDTO, in calendar: Calendar = .current) throws -> StrainSyncRow {
        guard let day = day(fromDayKey: dto.date, in: calendar) else {
            throw CloudSyncError.malformed(message: "the answer carried a day this app cannot read: \(dto.date)")
        }

        return StrainSyncRow(
            date: day,
            strainScore: dto.strainScore,
            kilojoules: dto.kilojoules,
            averageHeartRate: dto.averageHeartRate,
            maxHeartRate: dto.maxHeartRate,
            hasMeasurement: dto.hasMeasurement,
            source: dto.source
        )
    }

    // MARK: What the database will accept

    /// Whether this row is one the server can be given.
    ///
    /// **This exists because the wire's constraints are stricter than this schema's, and the gap is
    /// reachable on a real database rather than theoretical** — `RecoveryWireMapper.isSendable`'s
    /// argument, applied to the table whose bounds are not the ones a copy would carry over. `POST
    /// /batch` is a single all-or-nothing transaction, so one row the server refuses loses the other
    /// hundred and ninety-nine in its chunk and the user's upload fails with a message naming a day they
    /// never touched.
    ///
    /// **The two heart rates are tested `>= 0` and not `> 0`, and that is the difference from the
    /// recoveries half rather than an oversight.** The schema declares them `.nonnegative()` and says
    /// why in its own words: an unmeasured row carries `0` here and is legitimately on this wire,
    /// distinguished by `hasMeasurement` rather than by its rate. A `positive()` bound copied from
    /// `restingHeartRate` would refuse every unmeasured strain row this app has ever written — which on
    /// a fresh install is most of them — and an unmeasured row is precisely the thing this resource's
    /// `200`-with-`false` response exists to carry.
    ///
    /// It is deliberately **not** `StrainSyncRow.hasMeasurement`, for the reason its sibling states: that
    /// predicate asks *is this a reading*, which is the app's question, while this one asks *will the
    /// database take it*, which is the wire's. An unmeasured row with an in-range score and non-negative
    /// rates is refused by the first and accepted by the second, and sending it is the honest thing —
    /// both stores then hold the same row, and every reader on either side draws the same `—`.
    ///
    /// The finiteness tests are the encoder's, not the schema's: `JSONEncoder` **throws** on a `NaN` or
    /// an infinity rather than writing `null`, so a non-finite value is a request that never leaves the
    /// phone. Refusing it here turns that into a skipped row instead of a failed chunk. The score's upper
    /// bound is the scale's own definition — 21 — and `kilojoules` has no upper bound because energy
    /// expenditure does not.
    public static func isSendable(_ row: StrainSyncRow) -> Bool {
        guard row.strainScore.isFinite, (0 ... 21).contains(row.strainScore) else { return false }
        guard row.kilojoules.isFinite, row.kilojoules >= 0 else { return false }

        // Non-negative, never positive: an unmeasured row carries zero on both and is a row this wire
        // holds. See the comment above for what a copied `> 0` would cost.
        guard row.averageHeartRate >= 0, row.maxHeartRate >= 0 else { return false }

        // `hasMeasurement` is a `Bool` and every value of it is acceptable to the schema, so there is
        // nothing to test and nothing to derive. Writing that down is cheaper than a reader wondering
        // whether its absence from this function is deliberate.

        // The schema is `z.string().min(1).nullable()`: `null` is accepted and `""` is refused. This
        // app's absence is a `nil` and its provenance labels are never empty, so the empty string is a
        // value from some other writer — and sending it would refuse a chunk over a row nobody can see
        // anything wrong with.
        if let source = row.source, source.isEmpty { return false }

        return true
    }
}
