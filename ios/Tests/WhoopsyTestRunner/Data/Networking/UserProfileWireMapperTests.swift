import Foundation
import Whoopsy

// MARK: - 22.2 One profile on the wire, and the family's only one-way conversion

/// **The profile is the one resource this app only ever sends**, and the shape of the test follows from
/// that rather than from a preference. There is **no `row(for:)` on this mapper and therefore no round
/// trip below**: `GET /v1/profile` exists on the server and the client's `CloudSync` does not read it,
/// because the profile is the row the user typed in on the `BIOMETRICS` pane and a pull would be a
/// second author for a form the user is looking at. A `row(for:)` written before a caller existed would
/// be a conversion with no user, so the inverse is deliberately absent and a block asserting one would
/// be asserting a method nothing has.
///
/// What replaces the round trip is the *decode* half, and it is a real assertion rather than a
/// substitute for one. `UserProfileDTO` is `Codable` and not merely `Encodable` because
/// `PUT /v1/profile` answers with the row **read back from the database** rather than with the request
/// echoed — which is the route's own way of showing a caller that a `weightKg` sent as `null` is still
/// `null` rather than a `0` some layer defaulted. So the block below decodes a server answer and pins
/// the seven fields, including the asymmetry the decoding half is allowed to have.
///
/// **Two rules here are this resource's own and neither has a second instance in the family.**
/// `isSendable` is the only one whose rule **spans two fields** — `restingHeartRate < maxHeartRate`,
/// which is the API's published `400` rather than a sanity check this app invented — and `gender` is
/// the only field whose test is a memberwise lookup on an app enum, written as `Gender(rawValue:)` so
/// the local enum and the wire's closed enum cannot drift apart into two lists.
enum UserProfileWireMapperTests {

    static func run() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        /// A day, `offset` days from today, snapped — §11's rule.
        let day: (Int) -> Date = { offset in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }

        // MARK: Every field, converted forward

        // A birthday with a clock time on it, because that is what the column holds: `birthDate` is a
        // `.datetime` and the entity reads it as an instant, so the *mapper* is where an instant becomes
        // a day key and the only place that conversion happens.
        let birthday = day(-12_000) + 13 * 3600 + 47 * 60
        let row = UserProfileSyncRow(
            maxHeartRate: 191,
            restingHeartRate: 52,
            weightKg: 74.5,
            name: "Sam",
            birthDate: birthday,
            gender: UserProfile.Gender.nonBinary.rawValue,
            heightCm: 178.0)

        let dto = UserProfileWireMapper.dto(for: row, in: calendar)
        assertTest(dto.maxHeartRate == 191, "The maximal heart rate crosses unchanged")
        assertTest(dto.restingHeartRate == 52, "…and the resting one beside it")
        assertTest(dto.weightKg == 74.5, "…and the weight a calorie estimate divides by")
        assertTest(dto.name == "Sam", "…and the name")
        assertTest(dto.gender == UserProfile.Gender.nonBinary.rawValue, "…and the gender's raw value")
        assertTest(dto.heightCm == 178.0, "…and the height")
        assertTest(dto.birthDate == RecoveryWireMapper.dayKey(for: birthday, in: calendar),
                   "…and the birthday, converted once, into the day key the one `DayKeySchema` declares")
        assertTest(dto.birthDate?.contains(":") == false,
                   "…as a bare day, so no clock time survives the conversion")

        // The id is the row's one field with **no wire counterpart**, and its absence is load-bearing
        // rather than tidy: the route's own `400` is documented as covering a body that names its own
        // identity, so a mapper reading `row.id` would turn a correct request into a refusal.
        assertTest(row.id == "primary", "The local row is keyed `primary`, as the record defaults")
        assertTest(!(String(data: try JSONEncoder().encode(dto), encoding: .utf8) ?? "").contains("primary"),
                   "…and nothing about that key reaches the body, because the wire has no field for it")

        // MARK: The wire's own JSON

        let encoded = try JSONEncoder().encode(dto)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            assertTest(false, "The wire's body encodes to a JSON object")
            return
        }
        assertTest(Set(object.keys) == [
            "maxHeartRate", "restingHeartRate", "weightKg", "name", "birthDate", "gender", "heightCm",
        ], "The body's keys are the wire's seven, spelled as the server declares them")
        assertTest(!object.keys.contains("id"),
                   "…and `id` is not among them: `UserProfileWrite` requires all seven and forbids "
                       + "everything else, so an eighth key here would be a refusal rather than a hint")

        // The four nullable fields, all absent at once. This is a user who filled in the two rates and
        // nothing else, which is a state the form allows and therefore a body the route must accept.
        let bare = UserProfileSyncRow(maxHeartRate: 185, restingHeartRate: 58)
        let bareEncoded = try JSONEncoder().encode(UserProfileWireMapper.dto(for: bare, in: calendar))
        guard let bareObject = try JSONSerialization.jsonObject(with: bareEncoded) as? [String: Any] else {
            assertTest(false, "A profile with four fields empty still encodes")
            return
        }
        for key in ["weightKg", "name", "birthDate", "gender", "heightCm"] {
            assertTest(bareObject.keys.contains(key),
                       "The body carries '\(key)' as a key even when the user supplied nothing")
            assertTest(bareObject[key] is NSNull,
                       "…and carries it as null, which is a value the schema accepts and an omitted key "
                           + "is not — this is why the encoder is written by hand")
        }

        // MARK: The answer, read back — the half the round trip would have covered

        // The route answers with the stored row, so the client decodes it. Written as JSON text rather
        // than by encoding a DTO, because a test that built its input with the same encoder it is
        // checking would pass for a body that was never on the wire.
        let answer = """
        {"maxHeartRate":191,"restingHeartRate":52,"weightKg":null,"name":null,
         "birthDate":"1994-03-08","gender":null,"heightCm":null}
        """
        let decoded = try JSONDecoder().decode(UserProfileDTO.self, from: Data(answer.utf8))
        assertTest(decoded.maxHeartRate == 191 && decoded.restingHeartRate == 52,
                   "The two rates survive an answer read back from the database")
        assertTest(decoded.birthDate == "1994-03-08",
                   "…and the birthday arrives as the bare day the client sent, still bare")
        assertTest(decoded.weightKg == nil && decoded.name == nil
                       && decoded.gender == nil && decoded.heightCm == nil,
                   "…and the four nulls read back as absences, which is the route's own way of showing "
                       + "that a `null` was stored as `null` and not defaulted to a `0` somewhere")

        // The asymmetry the decoding half is allowed and the encoding half is not: `decodeIfPresent`
        // reads a missing key and a `null` alike, so a server that omitted a key it was required to
        // send still yields a profile here. Being generous on the way in costs nothing; being generous
        // on the way out would be a body the route refuses.
        let terse = try JSONDecoder().decode(
            UserProfileDTO.self,
            from: Data(#"{"maxHeartRate":185,"restingHeartRate":58}"#.utf8))
        assertTest(terse.weightKg == nil && terse.birthDate == nil && terse.heightCm == nil,
                   "A body that omits the nullable keys decodes to the same absences as one carrying null")

        // MARK: What the server will take

        assertTest(UserProfileWireMapper.isSendable(row), "A fully-filled profile is sendable")
        assertTest(UserProfileWireMapper.isSendable(bare),
                   "…and so is one carrying only the two rates, which is the state the form allows")

        // **The family's only cross-field rule, and it is the API's rather than this app's.**
        // `restingHeartRate < maxHeartRate` is not a sanity check invented here — `PUT /v1/profile`
        // publishes it as one of its `400`s — so a profile that fails it is refused whole.
        assertTest(!UserProfileWireMapper.isSendable(
            UserProfileSyncRow(maxHeartRate: 60, restingHeartRate: 60)),
            "A resting rate equal to the maximal one is refused: the rule is strict, not `<=`")
        assertTest(!UserProfileWireMapper.isSendable(
            UserProfileSyncRow(maxHeartRate: 60, restingHeartRate: 61)),
            "…and so is one above it, which is the shape a transposed pair of fields would have")
        assertTest(UserProfileWireMapper.isSendable(
            UserProfileSyncRow(maxHeartRate: 61, restingHeartRate: 60)),
            "…while one beat below is accepted, so the boundary is the rule and not an off-by-one")

        // Both rates strictly positive, which looks like the app's rule and is the wire's:
        // `exclusiveMinimum: 0` on both, because a rate of zero is not a measurement but an absent one.
        assertTest(!UserProfileWireMapper.isSendable(
            UserProfileSyncRow(maxHeartRate: 0, restingHeartRate: 0)),
            "The app's old `0` placeholder pair is not sendable, and the honest consequence is that a "
                + "profile holding one does not sync until the user fills the form in")
        assertTest(!UserProfileWireMapper.isSendable(
            UserProfileSyncRow(maxHeartRate: 190, restingHeartRate: 0)),
            "…nor is a profile with only the resting rate missing")
        assertTest(!UserProfileWireMapper.isSendable(
            UserProfileSyncRow(maxHeartRate: -1, restingHeartRate: -2)),
            "…and a negative pair is refused rather than read as unset")

        // The two body measurements: `exclusiveMinimum: 0` when present, and `null` always legal. Zero is
        // refused rather than read as unset, because the weight is what a calorie estimate divides by.
        for (label, weight, height) in [
            ("a zero weight", 0.0 as Double?, nil as Double?),
            ("a negative weight", -1.0, nil),
            ("an infinite weight", .infinity, nil),
            ("a NaN weight", .nan, nil),
            ("a zero height", nil, 0.0),
            ("a negative height", nil, -1.0),
            ("an infinite height", nil, .infinity),
        ] {
            assertTest(!UserProfileWireMapper.isSendable(
                UserProfileSyncRow(maxHeartRate: 190, restingHeartRate: 55,
                                   weightKg: weight, heightCm: height)),
                "A profile carrying \(label) is refused")
        }
        assertTest(UserProfileWireMapper.isSendable(
            UserProfileSyncRow(maxHeartRate: 190, restingHeartRate: 55, weightKg: 0.1, heightCm: 0.1)),
            "…while the smallest legal pair is accepted, so the bound is `> 0` and not a plausible range")

        // The two strings with a `.min(1)`, where `""` is a different answer from `null`.
        assertTest(!UserProfileWireMapper.isSendable(
            UserProfileSyncRow(maxHeartRate: 190, restingHeartRate: 55, name: "")),
            "An empty name is refused where an absent one is accepted")
        assertTest(UserProfileWireMapper.isSendable(
            UserProfileSyncRow(maxHeartRate: 190, restingHeartRate: 55, name: nil)),
            "…and a profile with no name at all is the common case rather than a gap")

        // **The gender test is a memberwise lookup and not a second literal list**, which is what keeps
        // the local enum and the wire's closed enum from drifting into two answers. Every case the app
        // can produce is therefore acceptable by construction rather than by a list being kept in step.
        for gender in UserProfile.Gender.allCases {
            assertTest(UserProfileWireMapper.isSendable(
                UserProfileSyncRow(maxHeartRate: 190, restingHeartRate: 55, gender: gender.rawValue)),
                "The wire accepts the app's own '\(gender.rawValue)', read off `Gender(rawValue:)`")
        }
        assertTest(UserProfile.Gender.allCases.count == 4,
                   "…and there are four of them, so the sweep above is not over an empty list")
        assertTest(!UserProfileWireMapper.isSendable(
            UserProfileSyncRow(maxHeartRate: 190, restingHeartRate: 55, gender: "unspecified")),
            "A gender the app has no case for is refused rather than sent and rejected by the enum")
        assertTest(!UserProfileWireMapper.isSendable(
            UserProfileSyncRow(maxHeartRate: 190, restingHeartRate: 55, gender: "")),
            "…and an empty string is refused on the same rule a name is")

        // The birthday needs no test and this is the assertion that says so: `dayKey(for:)` renders a
        // `Date` and cannot fail, and the schema leaves the key's interior to the client — so a
        // birthday is never the reason a profile is withheld.
        assertTest(UserProfileWireMapper.isSendable(
            UserProfileSyncRow(maxHeartRate: 190, restingHeartRate: 55, birthDate: day(0))),
            "A birthday is never the reason a profile cannot be sent")
    }
}
