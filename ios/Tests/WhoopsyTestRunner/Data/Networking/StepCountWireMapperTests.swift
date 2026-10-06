import Foundation
import Whoopsy

// MARK: - 22.2 One day of steps, and the one field that decides whether the other two are a measurement

/// **`measuredSeconds` is the whole of this resource's wire, and this file is where that is said as an
/// assertion.** The table has no `source` column — `CLAUDE.md` records why a per-row provenance label
/// could not be written honestly — so the only thing separating a measured zero from a day the strap was
/// never worn is that one number, and `StepCount.hasMeasurement` is exactly `measuredSeconds > 0`.
///
/// Two refusals here are the app's and not the schema's, and they are worth separating from the ones that
/// are the schema's. `measuredSeconds == 0` is refused because the wire's `0` is a legal reading of *zero
/// steps* while this app's `0` means *no measurement*, so the same value is two different facts on the two
/// sides of the boundary. Everything else — a negative count, a NaN duration — is the schema restated,
/// and the NaN test is the one that matters in practice because an infinity passes a `> 0` test and then
/// makes `JSONEncoder` refuse the whole chunk rather than the one day.
///
/// **The DTO declares no `CodingKeys`**, so the spelling below is the *synthesised* one — the same
/// precedent `WorkoutRoutePointDTO` sets. That makes the key set worth pinning rather than assuming: a
/// property renamed to `measured_seconds` would compile, encode, and be refused by
/// `additionalProperties: false` at runtime with nothing here to catch it.
enum StepCountWireMapperTests {

    static func run() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        /// A day, `offset` days from today, snapped — §11's rule.
        let day: (Int) -> Date = { offset in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }

        // MARK: The three fields, round-tripped through both conversions

        let row = StepCountSyncRow(date: day(-2), stepCount: 11_903, measuredSeconds: 70_400)

        let dto = StepCountWireMapper.dto(for: row)
        assertTest(dto.date == RecoveryWireMapper.dayKey(for: day(-2)),
                   "The day becomes the wire's bare key, read off the mapper that owns that spelling")
        assertTest(dto.stepCount == 11_903, "The day's total crosses unchanged")
        assertTest(dto.measuredSeconds == 70_400, "…and the seconds it took to count, which is not a decoration")

        assertTest(try StepCountWireMapper.row(for: dto) == row, "All three fields survive row → wire → row")

        // The day key is forwarded rather than re-derived, on the same argument the entry mapper's is:
        // a local copy would keep parsing and stop agreeing with the calendar about which day a step
        // count belongs to, and the mismatch would be invisible on both sides.
        for offset in [-400, -7, -1, 0] {
            assertTest(StepCountWireMapper.dayKey(for: day(offset)) == RecoveryWireMapper.dayKey(for: day(offset)),
                       "The day key is `RecoveryWireMapper`'s, on a day \(offset) days out")
            assertTest(StepCountWireMapper.day(fromDayKey: RecoveryWireMapper.dayKey(for: day(offset)))
                           == day(offset),
                       "…and reads back to the same day")
        }

        // MARK: The wire's own JSON

        let encoded = try JSONEncoder().encode(dto)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            assertTest(false, "The wire's body encodes to a JSON object")
            return
        }
        assertTest(Set(object.keys) == ["date", "stepCount", "measuredSeconds"],
                   "The body's keys are the wire's three, and this type has no `CodingKeys` — so this is "
                       + "the spelling `Codable` synthesises from the property names, which is the rule "
                       + "rather than an accident")

        // Nothing here is nullable, which is why the encoder is the synthesised one: there is no key that
        // could reach the wire absent, so there is nothing to write by hand. A `null` on this table would
        // be a *fourth* spelling of absence and the schema declares none.
        assertTest(!object.values.contains { $0 is NSNull },
                   "…and no field is null, because none of the three is nullable on this schema")

        // MARK: A measured zero and an unmeasured day are different rows

        // **The pair at the centre of this file.** Both rows say `stepCount: 0` and only one of them is a
        // measurement — the difference is the seconds, and it is the same test `StepCount.hasMeasurement`
        // applies on both sides of the write.
        assertTest(StepCountWireMapper.isSendable(
            StepCountSyncRow(date: day(-1), stepCount: 0, measuredSeconds: 3_600)),
            "A measured day of zero steps is a reading and is sent: the strap was on and nobody walked")
        assertTest(!StepCountWireMapper.isSendable(
            StepCountSyncRow(date: day(-1), stepCount: 0, measuredSeconds: 0)),
            "…while a day with no measured seconds is an absence and is refused, even at the same count")
        assertTest(!StepCountWireMapper.isSendable(
            StepCountSyncRow(date: day(-1), stepCount: 8_412, measuredSeconds: 0)),
            "…and that refusal does not turn on the count: a day nobody counted is absent however many "
                + "steps it claims, because a step total with no strap behind it is the fabrication the "
                + "whole absence rule exists to forbid")

        assertTest(StepCountWireMapper.isSendable(row), "An ordinary worn day is sendable")

        // MARK: The schema's own bounds, restated where the decision is actually made

        assertTest(!StepCountWireMapper.isSendable(
            StepCountSyncRow(date: day(-1), stepCount: -1, measuredSeconds: 3_600)),
            "A negative step total is refused")
        assertTest(!StepCountWireMapper.isSendable(
            StepCountSyncRow(date: day(-1), stepCount: 100, measuredSeconds: -1)),
            "A negative duration is refused")

        // Finiteness is not pedantry on a `Double`: an infinite duration passes a bare `> 0` test and is
        // a value `JSONEncoder` refuses outright — so the failure would be the whole chunk rather than
        // this one day, and the sentence would name a count the user never touched.
        assertTest(!StepCountWireMapper.isSendable(
            StepCountSyncRow(date: day(-1), stepCount: 100, measuredSeconds: .infinity)),
            "An infinite duration is refused before the encoder throws on it")
        assertTest(!StepCountWireMapper.isSendable(
            StepCountSyncRow(date: day(-1), stepCount: 100, measuredSeconds: .nan)),
            "…and so is a NaN one")

        // MARK: A body this app cannot read

        do {
            _ = try StepCountWireMapper.row(
                for: StepCountDTO(date: "not-a-day", stepCount: 100, measuredSeconds: 3_600))
            assertTest(false, "A day this app cannot read is refused rather than guessed at")
        } catch let error as CloudSyncError {
            guard case let .malformed(message) = error else {
                assertTest(false, "…with the malformed case, not another one")
                return
            }
            assertTest(message.contains("not-a-day"), "…and the message names the day it could not read")
        }

        // The read half takes a row the *write* half would refuse, and that asymmetry is deliberate:
        // `isSendable` answers *will the database take this*, and a download has no such gate — every row
        // the server hands over is one this app can store, which is why a zero-second day arriving from
        // the far side is stored rather than dropped.
        let unmeasured = try StepCountWireMapper.row(
            for: StepCountDTO(date: RecoveryWireMapper.dayKey(for: day(-3)), stepCount: 0, measuredSeconds: 0))
        assertTest(unmeasured.measuredSeconds == 0,
                   "A zero-length day arriving from the server reads back as a zero-length day, not as "
                       + "an absence: the two sides of a sync must agree about whether the day is on disk")
    }
}
