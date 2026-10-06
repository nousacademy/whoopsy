import Foundation

/// The wire's own shape for the one profile this install owns, and the one conversion onto it.
///
/// **The family's only one-way mapper, and the direction is missing because the port is.** `UserProfile`
/// as a wire *read* schema exists — `GET /v1/profile` answers one — but the client's `CloudSync` gains
/// `writeProfile(_:)` and nothing else (Stage 2's table), so nothing this app does turns a DTO back into
/// a row. Where a recovery, a session or an entry is both pushed and pulled, a profile is only pushed:
/// it is the row the user typed in on the BIOMETRICS pane, and a pull would be a second author for a
/// form the user is looking at. Adding a `row(for:)` here before a caller exists would be a conversion
/// with no user, so there is none — and if a later stage gives the read path a profile leg, this is
/// where the inverse goes.
///
/// **`UserProfileWrite` requires all seven fields and forbids everything else**, so this DTO carries no
/// `id` and no extra key, and every nullable reaches the wire as JSON `null`. The id is the interesting
/// half: `UserProfileSyncRow` carries `"primary"` because the record declares it, and the server
/// addresses a profile by *path* rather than by an id field — the route's own `400` is documented as
/// *including a body naming its own identity*, so sending the id would not be a harmless extra key, it
/// would be a refusal. That is why `dto(for:)` reads the row's other seven properties and never
/// `row.id`.
///
/// **The DTO is `Codable` rather than `Encodable`**, on `RecoveryDTO`'s argument: `PUT /v1/profile`
/// answers with the row **read back from the database** rather than with the request echoed, so the
/// client decodes that answer — which is exactly how the route says a caller can see that a `weightKg`
/// sent as `null` is still `null` rather than a `0` some layer defaulted.
public struct UserProfileDTO: Codable, Equatable, Sendable {

    /// The maximum heart rate, in bpm. Required, and the schema asks for strictly more than zero.
    public let maxHeartRate: Int

    /// The resting heart rate, in bpm. Required, positive, and strictly below `maxHeartRate`.
    public let restingHeartRate: Int

    /// The body weight the calorie estimate divides by, or `null`. The schema refuses `0`.
    public let weightKg: Double?

    /// The user's first name, or `null`. Never `""`.
    public let name: String?

    /// The birthday as a bare `YYYY-MM-DD` day key, or `null` — the one field this resource converts.
    public let birthDate: String?

    /// `UserProfile.Gender`'s raw value, or `null`. The schema validates it as a closed enum.
    public let gender: String?

    /// The user's height in centimetres, or `null`. The schema refuses `0`.
    public let heightCm: Double?

    public init(
        maxHeartRate: Int,
        restingHeartRate: Int,
        weightKg: Double?,
        name: String?,
        birthDate: String?,
        gender: String?,
        heightCm: Double?
    ) {
        self.maxHeartRate = maxHeartRate
        self.restingHeartRate = restingHeartRate
        self.weightKg = weightKg
        self.name = name
        self.birthDate = birthDate
        self.gender = gender
        self.heightCm = heightCm
    }

    private enum CodingKeys: String, CodingKey {
        case maxHeartRate
        case restingHeartRate
        case weightKg
        case name
        case birthDate
        case gender
        case heightCm
    }

    /// Written by hand so the four nullable fields reach the wire as `null` rather than as nothing.
    ///
    /// `additionalProperties: false` with all seven keys required is the strictest body in this family,
    /// and it means an omitted key is a `400` even when the value it would have carried is *nothing*.
    /// `container.encode(_:forKey:)` on an `Optional` writes `null`, which this schema accepts and a
    /// synthesised encoder's `encodeIfPresent` would not.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(maxHeartRate, forKey: .maxHeartRate)
        try container.encode(restingHeartRate, forKey: .restingHeartRate)
        try container.encode(weightKg, forKey: .weightKg)
        try container.encode(name, forKey: .name)
        try container.encode(birthDate, forKey: .birthDate)
        try container.encode(gender, forKey: .gender)
        try container.encode(heightCm, forKey: .heightCm)
    }
}

/// Row → wire for the one profile, plus the question the sync asks before sending it.
public enum UserProfileWireMapper {

    // MARK: - The day key

    /// The day key, forwarded to the one place this app writes that rule down.
    ///
    /// The birthday is the only `Date` on this row that becomes a *day* — the two heart rates are
    /// integers and the rest are strings — and the API declares a single `DayKeySchema`, so a local copy
    /// would be a second answer to a question that has one.
    public static func dayKey(for day: Date, in calendar: Calendar = .current) -> String {
        RecoveryWireMapper.dayKey(for: day, in: calendar)
    }

    // MARK: - Row → wire

    /// The body this profile is sent as.
    ///
    /// Total, and the row's `id` is deliberately not read: the wire has no field for it and refuses a
    /// body that names its own identity. The birthday is converted here and nowhere else, which is the
    /// one conversion this resource contributes to `Data/Networking/`.
    public static func dto(for row: UserProfileSyncRow, in calendar: Calendar = .current) -> UserProfileDTO {
        UserProfileDTO(
            maxHeartRate: row.maxHeartRate,
            restingHeartRate: row.restingHeartRate,
            weightKg: row.weightKg,
            name: row.name,
            birthDate: row.birthDate.map { dayKey(for: $0, in: calendar) },
            gender: row.gender,
            heightCm: row.heightCm
        )
    }

    // MARK: - What the database will accept

    /// Whether this profile is one the server can be given.
    ///
    /// **This is the family's only `isSendable` with a rule that spans two fields**, and it is the
    /// schema's own: `PUT /v1/profile` documents its `400` as covering *a resting heart rate not strictly
    /// below the maximal one*. `restingHeartRate < maxHeartRate` is therefore not a sanity check this
    /// app invented — it is the one refinement the API publishes, and a profile that fails it is refused
    /// whole rather than field by field.
    ///
    /// **Both rates must be strictly positive, and that is worth stating because it looks like the
    /// app's rule rather than the wire's.** `exclusiveMinimum: 0` on both, and the schema's own reasoning
    /// is that a rate of zero is not a measurement but an absent one — an absent one has no row here.
    /// So a legacy row carrying the app's old `0` placeholder is **not** sendable, and the honest
    /// consequence is that the profile does not sync until the user fills the form in. The alternative —
    /// sending it and taking the `400` — would fail the whole request for a reason the log could not
    /// distinguish from a malformed body, and the alternative before that, quietly substituting a
    /// plausible rate, is the exact fabrication this repo's absence rule exists to forbid.
    ///
    /// `weightKg` and `heightCm` are the same shape one notch weaker: `exclusiveMinimum: 0` when present,
    /// and `null` always legal. **Zero is refused rather than read as unset** — the weight is the field a
    /// calorie estimate divides by, so a `0` there is a division with no answer, and the schema says so
    /// in as many words.
    ///
    /// The three string fields are checked against their own constraints: `name` must be non-empty when
    /// present, since the schema's `.min(1)` is what makes `""` a different answer from `null`; `gender`
    /// must be one of `UserProfile.Gender`'s four raw values, because the wire validates it as a closed
    /// enum and the local enum and the wire enum agree exactly — so the test is `Gender(rawValue:)` and
    /// not a second literal list that could drift from either. `birthDate` needs no test: `dayKey(for:)`
    /// renders a `Date` and cannot fail, and the schema leaves the key's interior to the client.
    public static func isSendable(_ row: UserProfileSyncRow) -> Bool {
        guard row.maxHeartRate > 0, row.restingHeartRate > 0 else { return false }
        guard row.restingHeartRate < row.maxHeartRate else { return false }

        if let weight = row.weightKg, !(weight.isFinite && weight > 0) { return false }
        if let height = row.heightCm, !(height.isFinite && height > 0) { return false }

        if let name = row.name, name.isEmpty { return false }
        if let gender = row.gender, UserProfile.Gender(rawValue: gender) == nil { return false }

        return true
    }
}
