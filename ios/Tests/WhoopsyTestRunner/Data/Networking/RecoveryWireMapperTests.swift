import Foundation
import Whoopsy

// MARK: - 22.2 The day key in both directions, and the nine fields across three namespaces

/// **Two of these blocks are pure values and one of them is the wire's own spelling**, so nothing here
/// opens a database or a socket — this section's first file after the settings value, and for the same
/// reason: a day filed one early is inherited by every block below it.
///
/// The day key is the section's sharpest assertion and it is asserted from **three zones**, because the
/// formatting half alone cannot see the defect it exists to prevent. Measured on this machine, a UTC−8
/// device's midnight formats to the same `YYYY-MM-DD` under a UTC calendar, so a `DateFormatter` left on
/// its default would pass a one-zone test; a UTC+10 device's does not, and the *parse* half fails in the
/// opposite direction. Both are here.
enum RecoveryWireMapperTests {

    static func run() async throws {
        let utc = calendar(inSecondsFromGMT: 0)
        let west = calendar(inSecondsFromGMT: -8 * 3600)
        let east = calendar(inSecondsFromGMT: 10 * 3600)

        // MARK: The day key, written

        let westDay = midnight(2026, 8, 21, in: west)
        let eastDay = midnight(2026, 8, 21, in: east)

        assertTest(RecoveryWireMapper.dayKey(for: westDay, in: west) == "2026-08-21",
                   "A UTC−8 midnight formats as its own day")
        assertTest(RecoveryWireMapper.dayKey(for: eastDay, in: east) == "2026-08-21",
                   "A UTC+10 midnight formats as its own day")

        // The tell that the formatting half is not enough on its own: on this side of Greenwich the
        // wrong calendar agrees, because midnight local is still the same UTC day.
        assertTest(RecoveryWireMapper.dayKey(for: westDay, in: utc) == "2026-08-21",
                   "…and a UTC calendar agrees about a negative offset, which is why one zone proves nothing")
        assertTest(RecoveryWireMapper.dayKey(for: eastDay, in: utc) == "2026-08-20",
                   "…and files a positive offset's day one early")

        // MARK: The day key, read

        assertTest(RecoveryWireMapper.day(fromDayKey: "2026-08-21", in: west) == westDay,
                   "A wire key parses back to its own local midnight")
        assertTest(RecoveryWireMapper.day(fromDayKey: "2026-08-21", in: east) == eastDay,
                   "…in either direction from Greenwich")

        // And the round trip is the property a chunked upload depends on: every key the app writes is a
        // key it can read, so a boundary advanced to a sent day can be resumed from.
        for zone in [utc, west, east] {
            let key = RecoveryWireMapper.dayKey(for: midnight(2026, 3, 1, in: zone), in: zone)
            assertTest(RecoveryWireMapper.day(fromDayKey: key, in: zone) == midnight(2026, 3, 1, in: zone),
                       "A day key round-trips through its own zone")
        }

        // **The defect, stated as the failure it is.** Parsing the key as UTC midnight gives
        // `2026-08-21T00:00Z`, which a UTC−8 device's `startOfDay` snaps back to the 20th — every record
        // filed a day early, beside a screen drawing the right date. This is where a formatter left on
        // its default lands, and it is the reason the mapper builds from a `Calendar`.
        let utcMidnight = midnight(2026, 8, 21, in: utc)
        assertTest(west.startOfDay(for: utcMidnight) == midnight(2026, 8, 20, in: west),
                   "Parsing the key as UTC midnight files the day on the 20th, which is the bug")

        // Refusals: three near-misses, each of a different kind.
        assertTest(RecoveryWireMapper.day(fromDayKey: "2026-2-3", in: west) == nil,
                   "An unpadded key is not the wire's format")
        assertTest(RecoveryWireMapper.day(fromDayKey: "2026-02-31", in: west) == nil,
                   "A day that does not exist is refused rather than rolled into March")
        assertTest(RecoveryWireMapper.day(fromDayKey: "2026-08-21T00:00:00Z", in: west) == nil,
                   "A key carrying a time component is refused rather than snapped")
        assertTest(RecoveryWireMapper.day(fromDayKey: "", in: west) == nil,
                   "An empty key names no day")

        // MARK: The window, translated from this app's half-open range

        let window = RecoveryWindow(from: midnight(2026, 8, 12, in: west),
                                    to: midnight(2026, 8, 22, in: west),
                                    calendar: west)
        assertTest(window != nil, "A ten-day half-open range has a window")
        assertTest(window?.days == 9, "…whose server-side span is nine, not ten — the windows are inclusive")
        assertTest(window?.endingOn == "2026-08-21", "…ending on the range's last day, not on its upper bound")

        // The one-day range, which is the boundary case both conventions agree about.
        let oneDay = RecoveryWindow(from: midnight(2026, 8, 21, in: west),
                                    to: midnight(2026, 8, 22, in: west),
                                    calendar: west)
        assertTest(oneDay?.days == 0, "A one-day range asks for zero days back from its own day")
        assertTest(oneDay?.endingOn == "2026-08-21", "…anchored on that day")

        assertTest(RecoveryWindow(from: midnight(2026, 8, 22, in: west),
                                  to: midnight(2026, 8, 12, in: west),
                                  calendar: west) == nil,
                   "A reversed range has no window")
        assertTest(RecoveryWindow(from: midnight(2026, 8, 21, in: west),
                                  to: midnight(2026, 8, 21, in: west),
                                  calendar: west) == nil,
                   "An empty range has no window rather than a zero-day one")

        // MARK: The nine fields, across the three namespaces

        // A row carrying **every** field, so nothing survives by being absent from both sides. The values
        // are deliberately distinct: a mapping that swapped two of them would be caught here rather than
        // by two equal `Double?`s cancelling out.
        let source = RecoverySyncRow(
            date: westDay,
            recoveryScore: 71,
            restingHeartRate: 52,
            hrvValueMs: 68.4,
            hrvMetric: .sdnn,
            skinTemp: 34.25,
            spo2: 96.5,
            respiratoryRate: 13.75,
            source: "whoop_export")

        let dto = RecoveryWireMapper.dto(for: source, in: west)
        assertTest(dto.date == "2026-08-21", "The record's instant becomes the wire's bare day")
        assertTest(dto.recoveryScore == 71, "The score crosses unchanged")
        assertTest(dto.restingHeartRate == 52, "The resting rate crosses unchanged")
        assertTest(dto.hrvValueMs == 68.4, "The HRV value crosses unchanged")
        assertTest(dto.hrvMetric == .sdnn, "The HRV metric crosses unchanged")
        assertTest(dto.skinTemperature == 34.25, "skinTemp becomes skinTemperature")
        assertTest(dto.spo2Percentage == 96.5, "spo2 becomes spo2Percentage")
        assertTest(dto.respiratoryRate == 13.75, "The respiratory rate crosses unchanged")
        assertTest(dto.source == "whoop_export", "Provenance crosses — the field RecoveryMetric has no home for")

        let back = try RecoveryWireMapper.row(for: dto, in: west)
        assertTest(back == source, "All nine fields survive record → wire → record")

        // The middle namespace, pinned by name: the row's properties are the *record's*, which is what
        // makes the conversion above a copy with no naming decision inside it. `RecoveryMetric` spells
        // two of them a fourth way (`skinTemperatureCelsius`, `spO2Percentage`), so a sync built on the
        // entity would be reaching through a different vocabulary than the column it was writing.
        assertTest(source.skinTemp == 34.25, "The row carries the record's property name for skin temperature")
        assertTest(source.spo2 == 96.5, "…and for SpO2")

        // MARK: The wire's own JSON

        // The hand-written `encode(to:)` exists so the four optionals reach the wire as `null` rather
        // than as absent keys — the server declares them `.nullable()` and not `.optional()`, so a
        // synthesised encoder would turn all 910 imported days into a `400`. The key set is asserted
        // whole, and then a nil field is asserted to be present and null rather than missing.
        let encoded = try JSONEncoder().encode(dto)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            assertTest(false, "The wire's body encodes to a JSON object")
            return
        }
        assertTest(Set(object.keys) == [
            "date", "recoveryScore", "restingHeartRate", "hrvValueMs", "hrvMetric",
            "skinTemperature", "spo2Percentage", "respiratoryRate", "source"
        ], "The body's keys are the wire's nine, spelled as the server declares them")

        let bare = RecoveryDTO(
            date: "2026-08-21", recoveryScore: 40, restingHeartRate: 55, hrvValueMs: 41.0,
            hrvMetric: .rmssd, skinTemperature: nil, spo2Percentage: nil,
            respiratoryRate: nil, source: nil)
        let bareEncoded = try JSONEncoder().encode(bare)
        guard let bareObject = try JSONSerialization.jsonObject(with: bareEncoded) as? [String: Any] else {
            assertTest(false, "A body with every optional absent still encodes")
            return
        }
        for key in ["skinTemperature", "spo2Percentage", "respiratoryRate", "source"] {
            assertTest(bareObject.keys.contains(key), "The body carries '\(key)' as a key even when it is empty")
            assertTest(bareObject[key] is NSNull, "…and carries it as null, not as a missing field")
        }

        // MARK: A day the client cannot read

        let unreadable = RecoveryDTO(
            date: "not-a-day", recoveryScore: 40, restingHeartRate: 55, hrvValueMs: 41.0,
            hrvMetric: .rmssd, skinTemperature: nil, spo2Percentage: nil,
            respiratoryRate: nil, source: nil)
        do {
            _ = try RecoveryWireMapper.row(for: unreadable, in: west)
            assertTest(false, "A day this app cannot read is refused rather than guessed at")
        } catch let error as CloudSyncError {
            guard case let .malformed(message) = error else {
                assertTest(false, "…with the malformed case, not another one")
                return
            }
            assertTest(message.contains("not-a-day"), "…and the message names the day it could not read")
        }

        // MARK: What the database will take

        // `isSendable` is the wire's question and not the app's, so its four refusals are asserted apart
        // from `RecoverySyncRow.hasMeasurement`'s. The row below is *unmeasured* by the app's rule — no
        // variability at all — and must still be sendable, which is the pair that fails if anyone narrows
        // this into the other predicate.
        assertTest(RecoveryWireMapper.isSendable(source), "A fully-measured row is sendable")
        assertTest(RecoveryWireMapper.isSendable(
            RecoverySyncRow(date: westDay, recoveryScore: 0, restingHeartRate: 55,
                            hrvValueMs: 0, hrvMetric: .rmssd)),
            "A measured rate with no variability is the server's business and is sendable")

        assertTest(!RecoveryWireMapper.isSendable(
            RecoverySyncRow(date: westDay, recoveryScore: 0, restingHeartRate: 0,
                            hrvValueMs: 0, hrvMetric: .rmssd)),
            "A zero resting rate is a placeholder and is refused")
        assertTest(!RecoveryWireMapper.isSendable(
            RecoverySyncRow(date: westDay, recoveryScore: 101, restingHeartRate: 55,
                            hrvValueMs: 41, hrvMetric: .rmssd)),
            "A score above 100 is refused")
        assertTest(!RecoveryWireMapper.isSendable(
            RecoverySyncRow(date: westDay, recoveryScore: 40, restingHeartRate: 55,
                            hrvValueMs: .nan, hrvMetric: .rmssd)),
            "A NaN HRV is refused before the encoder throws on it")
        assertTest(!RecoveryWireMapper.isSendable(
            RecoverySyncRow(date: westDay, recoveryScore: 40, restingHeartRate: 55,
                            hrvValueMs: 41, hrvMetric: .rmssd, spo2: 101)),
            "An SpO2 above 100 is refused")
        assertTest(!RecoveryWireMapper.isSendable(
            RecoverySyncRow(date: westDay, recoveryScore: 40, restingHeartRate: 55,
                            hrvValueMs: 41, hrvMetric: .rmssd, respiratoryRate: -1)),
            "A negative respiratory rate is refused")
        assertTest(!RecoveryWireMapper.isSendable(
            RecoverySyncRow(date: westDay, recoveryScore: 40, restingHeartRate: 55,
                            hrvValueMs: 41, hrvMetric: .rmssd, source: "")),
            "An empty provenance label is refused where nil is accepted")
    }
}

// MARK: - Helpers

/// A calendar pinned to one offset, so the day-key arithmetic can be asserted outside the device's own
/// zone — the mapper takes a `calendar:` parameter for precisely this, and a test that used
/// `Calendar.current` would be asserting something different on someone else's machine.
private func calendar(inSecondsFromGMT offset: Int) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

/// Midnight at the start of a day **in that calendar's zone**, which is what makes the three-zone
/// contrast meaningful: the same numbers name three different instants.
private func midnight(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    let parsed = calendar.date(from: components) ?? Date.distantPast
    return calendar.startOfDay(for: parsed)
}
