import Foundation
import Whoopsy

// MARK: - 22.2b The instant's one spelling, and what the wire will take of a session

/// **The aggregate resource's own half of the wire contract**, and the three things it has that
/// `recoveries` had nothing to say about: a second instant format, an addressing id, and two child
/// arrays that ride inside the body.
///
/// **Nothing here opens a database or a socket** — `RecoveryWireMapperTests`' own reason, one file over:
/// a value that goes onto the wire wrong is inherited by every block below it, and the block that
/// catches it should be the one that costs nothing to run.
///
/// **The instant's spelling is the section's sharpest assertion here, and it is pinned as a literal
/// rather than derived.** `workouts.started_at` is a TEXT column that D1 orders lexicographically, so
/// the string *is* the chronology — which means a spelling that is right about the instant and wrong
/// about its width sorts a day's sessions into a different order than they happened in, with nothing
/// throwing and every screen still drawing plausible rows. `2026-08-22T13:45:00.000Z` is therefore
/// written out here as the bytes, and every other claim about this function is a consequence of it.
enum WorkoutWireMapperTests {

    static func run() async throws {
        let utc = utcCalendar()

        // MARK: The day key is forwarded rather than re-derived

        // **One wire concept, one implementation.** The API declares a single `DayKeySchema` and this
        // resource's `date` field references it, so the assertion that matters is not what the day key
        // *is* — `RecoveryWireMapperTests` owns that, from three zones — but that this module does not
        // hold a second answer to it. The two are compared over a set of days rather than at one point,
        // because a re-derivation that happened to agree about today would pass a single-value check.
        for (year, month, day) in [(2026, 8, 21), (2026, 2, 29), (2024, 2, 29), (2026, 12, 31)] {
            let instant = utcInstant(year, month, day, 0, 0, 0)
            assertTest(WorkoutWireMapper.dayKey(for: instant, in: utc) == RecoveryWireMapper.dayKey(for: instant, in: utc),
                       "The workouts day key is the recoveries day key at \(year)-\(month)-\(day)")
            assertTest(WorkoutWireMapper.day(fromDayKey: RecoveryWireMapper.dayKey(for: instant, in: utc), in: utc) == instant,
                       "…and reads back through the same single implementation")
        }

        // The strict half is inherited too, and it is the half a forwarded rule could lose by being
        // re-implemented: `2026-02-31` has the right shape and no such day.
        assertTest(WorkoutWireMapper.day(fromDayKey: "2026-02-31", in: utc) == nil,
                   "A day that does not exist is refused here as it is there")
        assertTest(WorkoutWireMapper.day(fromDayKey: "2026-2-3", in: utc) == nil,
                   "…and so is an unpadded one")

        // MARK: The instant, pinned as the bytes

        let afternoon = utcInstant(2026, 8, 22, 13, 45, 0)
        assertTest(WorkoutWireMapper.instantKey(for: afternoon) == "2026-08-22T13:45:00.000Z",
                   "An instant renders as the one canonical 24-byte UTC spelling")
        assertTest(WorkoutWireMapper.instantKey(for: afternoon).utf8.count == 24,
                   "…which is 24 bytes, the width the column's ordering depends on")

        // **Fixed width is the whole property, so it is asserted across the fields a shorter spelling
        // would collapse.** A formatter that dropped a leading zero, or rendered single-digit months,
        // would still name the right instant and would sort `2026-8-9` after `2026-12-01`.
        assertTest(WorkoutWireMapper.instantKey(for: utcInstant(2026, 1, 2, 3, 4, 5)) == "2026-01-02T03:04:05.000Z",
                   "Every field is padded, so a lexicographic sort is a chronological one")
        assertTest(WorkoutWireMapper.instantKey(for: utcInstant(2026, 8, 22, 23, 59, 59)) == "2026-08-22T23:59:59.000Z",
                   "…including the last second of a day")
        assertTest(WorkoutWireMapper.instantKey(for: utcInstant(2026, 8, 22, 0, 0, 0)) == "2026-08-22T00:00:00.000Z",
                   "…and the first, which is where a 12-hour clock would print `12`")

        // **UTC and not the device's zone, and the absence of a `calendar:` parameter is the claim.**
        // A local-time rendering would put a session recorded at 13:45 in New York at `18:45Z` beside
        // the same session recorded in London at `13:45Z`, and the two rows would sort as though they
        // had happened five hours apart. Pinned by rendering the same instant twice through two
        // calendars this file does own: the key does not read either of them.
        let west = calendar(inSecondsFromGMT: -8 * 3600)
        let east = calendar(inSecondsFromGMT: 10 * 3600)
        let westAfternoon = midnight(2026, 8, 22, in: west) + 13 * 3600 + 45 * 60
        assertTest(WorkoutWireMapper.instantKey(for: westAfternoon) == "2026-08-22T21:45:00.000Z",
                   "A UTC−8 device's 13:45 is the same instant as 21:45Z and is spelled that way")
        assertTest(WorkoutWireMapper.instantKey(for: midnight(2026, 8, 22, in: east) + 13 * 3600 + 45 * 60)
                    == "2026-08-22T03:45:00.000Z",
                   "…and a UTC+10 device's 13:45 is 03:45Z")

        // MARK: The millisecond, computed by subtraction

        // **The one place this function is not a straight component read, and the disagreement is
        // narrow enough that only an assertion this specific can see it.** `Date` holds a `Double`, so
        // reading `.nanosecond` truncates where subtracting and rounding rounds: an instant at `.0006`
        // is `.001` here and `.000` there. A live session's instants come off the same clock that
        // produces these fractions, which is why the arithmetic rather than the component is the rule.
        let rounding = afternoon.addingTimeInterval(0.0006)
        assertTest(WorkoutWireMapper.instantKey(for: rounding) == "2026-08-22T13:45:00.001Z",
                   "A fraction past the half-millisecond rounds up to .001")
        let truncating = utc.dateComponents([.nanosecond], from: rounding).nanosecond ?? 0
        assertTest(truncating / 1_000_000 == 0,
                   "…where the nanosecond component reads .000, which is the disagreement the arithmetic avoids")

        // The carry, which is the case that would otherwise render a fourth digit and fail this
        // function's own reader: `.9996` rounds to a full thousand milliseconds.
        let carrying = afternoon.addingTimeInterval(0.9996)
        let carried = WorkoutWireMapper.instantKey(for: carrying)
        assertTest(carried == "2026-08-22T13:45:01.000Z",
                   "A fraction at .9996 carries into the next second rather than rendering .1000")
        assertTest(carried.utf8.count == 24, "…so the width holds at the one value that could break it")

        // The carry across a minute and across midnight, because a carry that only handles the second
        // field would be a string of the right width naming a second that does not exist.
        assertTest(WorkoutWireMapper.instantKey(for: utcInstant(2026, 8, 22, 13, 45, 59).addingTimeInterval(0.9996))
                    == "2026-08-22T13:46:00.000Z",
                   "…and across a minute boundary")
        assertTest(WorkoutWireMapper.instantKey(for: utcInstant(2026, 8, 22, 23, 59, 59).addingTimeInterval(0.9996))
                    == "2026-08-23T00:00:00.000Z",
                   "…and across midnight, into a day the session's own key may not name")

        // MARK: The instant, read back

        // The round trip is the property a chunked upload and a resumed download both stand on: every
        // key this app writes is a key it can read. Swept over a day's edges rather than at one point.
        for components in [(2026, 8, 22, 13, 45, 0), (2026, 1, 1, 0, 0, 0), (2026, 12, 31, 23, 59, 59), (2024, 2, 29, 6, 30, 15)] {
            let instant = utcInstant(components.0, components.1, components.2, components.3, components.4, components.5)
            let key = WorkoutWireMapper.instantKey(for: instant)
            assertTest(WorkoutWireMapper.instant(fromInstantKey: key) == instant,
                       "An instant round-trips through its own key: \(key)")
        }

        // The millisecond survives the trip, which a reader that dropped the fraction would fail while
        // still returning a Date — one second out, on a column that orders sessions.
        let millis = utcInstant(2026, 8, 22, 13, 45, 0).addingTimeInterval(0.375)
        assertTest(WorkoutWireMapper.instantKey(for: millis) == "2026-08-22T13:45:00.375Z",
                   "A third of a second is spelled .375")
        assertTest(WorkoutWireMapper.instant(fromInstantKey: "2026-08-22T13:45:00.375Z") == millis,
                   "…and reads back to the instant it names, not to the second it sits in")

        // **Nine refusals, each a different kind of near-miss**, because the shape check and the round
        // trip are two separate guards and a reader that leaned on either one alone would admit a
        // different set. The first four are the shape: too short, too long, and the two punctuation
        // bytes a plausible typo moves.
        assertTest(WorkoutWireMapper.instant(fromInstantKey: "") == nil, "An empty key names no instant")
        assertTest(WorkoutWireMapper.instant(fromInstantKey: "2026-08-22T13:45:00.00Z") == nil,
                   "A two-digit fraction is a different width and is refused")
        assertTest(WorkoutWireMapper.instant(fromInstantKey: "2026-08-22T13:45:00.0000Z") == nil,
                   "…and so is a four-digit one")
        assertTest(WorkoutWireMapper.instant(fromInstantKey: "2026-08-22 13:45:00.000Z") == nil,
                   "A space where the `T` belongs is refused")
        assertTest(WorkoutWireMapper.instant(fromInstantKey: "2026-08-22T13:45:00,000Z") == nil,
                   "…and a comma where the decimal point belongs")
        assertTest(WorkoutWireMapper.instant(fromInstantKey: "2026-08-22T13:45:00.000z") == nil,
                   "A lowercase `z` is a different byte and is refused")
        assertTest(WorkoutWireMapper.instant(fromInstantKey: "2026-08-22T13:45:00.00AZ") == nil,
                   "A non-digit inside the fraction is refused before any number is built from it")

        // **The four the shape check admits and only the calendar refuses.** `2026-02-31` is four
        // digits, a dash and two digits in exactly the right places; so are month 13, hour 24 and
        // minute 60. `Calendar.date(from:)` normalises each by rolling forward, so what catches them is
        // re-rendering the parse and comparing it to the input — which is why this reader cannot be
        // wrong about February without being wrong about its own arithmetic too.
        assertTest(WorkoutWireMapper.instant(fromInstantKey: "2026-02-31T00:00:00.000Z") == nil,
                   "A day that does not exist is refused rather than rolled into March")
        assertTest(WorkoutWireMapper.instant(fromInstantKey: "2026-13-01T00:00:00.000Z") == nil,
                   "A thirteenth month is refused")
        assertTest(WorkoutWireMapper.instant(fromInstantKey: "2026-08-22T24:00:00.000Z") == nil,
                   "An hour of 24 is refused rather than read as the next midnight")
        assertTest(WorkoutWireMapper.instant(fromInstantKey: "2026-08-22T13:60:00.000Z") == nil,
                   "A sixtieth minute is refused")

        // **The byte count and not the character count, which is the one refusal a reader would have to
        // be unlucky to write correctly.** A 24-*character* key holding a multi-byte character is 25
        // bytes, and a reader that counted characters would slice a field out of a string that does not
        // align with it — reading a digit that is not there, or reading past the end.
        let wide = "2026-08-22T13:45:00.00éZ"
        assertTest(wide.count == 24 && wide.utf8.count == 25,
                   "The fixture is 24 characters and 25 bytes, which is the case the order of the two matters for")
        assertTest(WorkoutWireMapper.instant(fromInstantKey: wide) == nil,
                   "A key whose bytes are not 24 long is refused before any digit is read")

        // MARK: The row ⇄ wire round trip, children in order

        // **A row carrying every field with a value no other field shares**, so a mapping that swapped
        // two of them cannot cancel itself out. `offlineRegionID` and `steps` are given values unlike
        // anything else on the row, and the three measurements are distinct from each other.
        let sessionID = UUID()
        let started = utcInstant(2026, 8, 21, 13, 45, 0)
        let ended = utcInstant(2026, 8, 21, 14, 45, 0)
        let dayKey = WorkoutWireMapper.day(fromDayKey: "2026-08-21", in: utc) ?? .distantPast

        // **The children run newest-first on purpose.** The array's order is the server's `seq` — bound
        // from the index on the way in and read back by it on the way out — so a mapper that sorted by
        // timestamp would be inventing a second ordering rule. A fixture in ascending order could not
        // see that, because sorting an already-sorted array is a no-op.
        let route = [
            WorkoutRoutePoint(latitude: 51.5074, longitude: -0.1278,
                              timestamp: utcInstant(2026, 8, 21, 14, 44, 0), heartRate: 164),
            WorkoutRoutePoint(latitude: 51.5070, longitude: -0.1280,
                              timestamp: utcInstant(2026, 8, 21, 14, 20, 0), heartRate: 150),
            WorkoutRoutePoint(latitude: 51.5065, longitude: -0.1284,
                              timestamp: utcInstant(2026, 8, 21, 13, 46, 0), heartRate: 121),
        ]
        let splits = [
            WorkoutSplit(elapsed: 3600, strain: 4.1),
            WorkoutSplit(elapsed: 1800, strain: 2.6),
        ]

        let source = WorkoutSyncRow(
            id: sessionID,
            date: dayKey,
            startedAt: started,
            endedAt: ended,
            strain: 4.1,
            averageHeartRate: 121,
            maxHeartRate: 164,
            source: "whoop_export",
            activityName: "Basketball",
            hrZonePercents: [10, 20, 35, 25, 5],
            steps: 693,
            offlineRegionID: "mapbox-region-7",
            route: route,
            splits: splits)

        let wire = WorkoutWireMapper.dto(for: source, in: utc)
        assertTest(wire.id == sessionID.uuidString, "The row's id crosses as the string the API addresses it by")
        assertTest(wire.date == "2026-08-21", "The row's day is spelled as the wire's bare day")
        assertTest(wire.startedAt == "2026-08-21T13:45:00.000Z", "…and its start as the canonical instant")
        assertTest(wire.endedAt == "2026-08-21T14:45:00.000Z", "…and its end")
        assertTest(wire.strain == 4.1, "The strain crosses unchanged")
        assertTest(wire.averageHeartRate == 121, "The average rate crosses unchanged")
        assertTest(wire.maxHeartRate == 164, "The maximal rate crosses unchanged")
        assertTest(wire.source == "whoop_export", "Provenance crosses — the field the day skip reads")
        assertTest(wire.activityName == "Basketball", "The activity name crosses unchanged")
        assertTest(wire.hrZonePercents == [10, 20, 35, 25, 5], "The five shares cross in band order")
        assertTest(wire.steps == 693, "The step count crosses unchanged")
        assertTest(wire.offlineRegionID == "mapbox-region-7", "The tile region id crosses unchanged")

        assertTest(wire.route.count == 3, "The route crosses whole")
        assertTest(wire.route.map(\.id) == route.map(\.id.uuidString),
                   "…carrying each fix's id as the string the wire validates")
        assertTest(wire.route.map(\.timestamp) == route.map { WorkoutWireMapper.instantKey(for: $0.timestamp) },
                   "…and each fix's own instant, not the session's")
        assertTest(wire.route.map(\.heartRate) == [164, 150, 121],
                   "…in the order the row held them, which is the sequence they were recorded in")
        assertTest(wire.splits.map(\.elapsed) == [3600, 1800], "The splits cross whole and in their own order")

        let back = try WorkoutWireMapper.row(for: wire, in: utc)
        assertTest(back == source, "All fourteen fields and both child arrays survive row → wire → row")
        assertTest(back.route.map(\.id) == route.map(\.id),
                   "…with the route's order preserved rather than restored by a sort")
        assertTest(back.splits.map(\.id) == splits.map(\.id),
                   "…and the splits' order preserved the same way")

        // MARK: The wire's own JSON

        // The hand-written `encode(to:)` exists so the eight nullables reach the wire as `null` rather
        // than as absent keys — every one of them is `.nullable()` and not `.optional()`, so an absent
        // key is a `400` naming a missing field. That is not a corner case here: a Zero fast carries no
        // strain, no heart rates, no zone block and no steps, and it is 170 of the rows this app holds.
        let fast = WorkoutSyncRow(
            id: UUID(),
            date: dayKey,
            startedAt: started,
            endedAt: ended,
            strain: nil,
            averageHeartRate: nil,
            maxHeartRate: nil,
            source: "zero_fasting",
            activityName: "Fast")

        let encoded = try JSONEncoder().encode(WorkoutWireMapper.dto(for: fast, in: utc))
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            assertTest(false, "The wire's body encodes to a JSON object")
            return
        }
        assertTest(Set(object.keys) == [
            "id", "date", "startedAt", "endedAt", "strain", "averageHeartRate", "maxHeartRate",
            "source", "activityName", "hrZonePercents", "steps", "offlineRegionID", "route", "splits"
        ], "The body's keys are the wire's fourteen, spelled as the server declares them")

        for key in ["strain", "averageHeartRate", "maxHeartRate", "hrZonePercents", "steps", "offlineRegionID"] {
            assertTest(object.keys.contains(key), "A fast's body carries '\(key)' as a key even though nothing measured it")
            assertTest(object[key] is NSNull, "…and carries it as null, not as a missing field")
        }
        // The two that are *not* nullable, asserted in the same breath: `route` and `splits` are required
        // arrays with no default, because a body that could omit them would wipe a stored path rather
        // than leave it alone. An empty array is therefore an affirmative claim, not an absence.
        assertTest(object["route"] is [Any] && (object["route"] as? [Any])?.isEmpty == true,
                   "…while the route is an empty array rather than a null, which is a claim that there is none")
        assertTest(object["splits"] is [Any] && (object["splits"] as? [Any])?.isEmpty == true,
                   "…and so are the splits")

        // MARK: A row this app cannot read

        // **This direction throws and the other does not**, which is the asymmetry `recoveries` records:
        // a row this app holds is one the database accepts by construction, while an answer has crossed
        // a network and may hold anything. Each of the four structured fields names itself in the
        // refusal, so the sentence a caller logs says *which* field was unreadable.
        func answer(
            id: String = sessionID.uuidString,
            date: String = "2026-08-21",
            startedAt: String = "2026-08-21T13:45:00.000Z",
            endedAt: String = "2026-08-21T14:45:00.000Z",
            route: [WorkoutRoutePointDTO] = [],
            splits: [WorkoutSplitDTO] = []
        ) -> WorkoutDTO {
            WorkoutDTO(
                id: id, date: date, startedAt: startedAt, endedAt: endedAt,
                strain: 4.1, averageHeartRate: 121, maxHeartRate: 164,
                source: "whoop_export", activityName: "Basketball",
                hrZonePercents: [10, 20, 35, 25, 5], steps: 693,
                offlineRegionID: nil, route: route, splits: splits)
        }

        // **The baseline the four refusals are measured against.** The same `answer()` with nothing
        // altered has to read back, or a refusal below is a fixture that was never readable rather than
        // the field under test. It is deliberately **not** compared to `source`: that row above carries a
        // tile region id, three fixes and two splits, and this answer carries none of the three — which
        // is the difference between *readable* and *the same row*, and the comparison would fail on a
        // correct mapper.
        do {
            let plain = try WorkoutWireMapper.row(for: answer(), in: utc)
            assertTest(plain.id == sessionID, "The fixture the four refusals are built from is otherwise readable")
            assertTest(plain.date == dayKey, "…on the day its own `date` field names")
            assertTest(plain.startedAt == started && plain.endedAt == ended,
                       "…with both of its instants read from the strings it carried")
            assertTest(plain.offlineRegionID == nil, "…and the field it left out read back as an absence")
            assertTest(plain.route.isEmpty && plain.splits.isEmpty,
                       "…with its two child arrays empty, which is a claim rather than a null")
        } catch {
            assertTest(false, "The fixture the four refusals are built from is unreadable: \(error)")
        }

        let refusals: [(String, WorkoutDTO, String)] = [
            ("id", answer(id: "not-a-uuid"), "an id this app cannot read: not-a-uuid"),
            ("day", answer(date: "2026-02-31"), "a day this app cannot read: 2026-02-31"),
            ("start", answer(startedAt: "2026-08-21T25:00:00.000Z"), "a start this app cannot read: 2026-08-21T25:00:00.000Z"),
            ("end", answer(endedAt: "yesterday"), "an end this app cannot read: yesterday"),
        ]
        for (field, body, phrase) in refusals {
            do {
                _ = try WorkoutWireMapper.row(for: body, in: utc)
                assertTest(false, "An unreadable \(field) is refused rather than guessed at")
            } catch let error as CloudSyncError {
                guard case let .malformed(message) = error else {
                    assertTest(false, "…with the malformed case, not another one, for the \(field)")
                    continue
                }
                assertTest(message.contains(phrase), "…and the message names the \(field) it could not read: \(message)")
            }
        }

        // **The children carry their own two refusals, because a fix has a timestamp the parent's
        // instants say nothing about.** A route point stored with a time nothing can read would put a
        // fix in the app's route at a moment it was not taken, on a path drawn in `timestamp` order.
        let badPointID = answer(route: [WorkoutRoutePointDTO(
            id: "not-a-uuid", latitude: 51.5, longitude: -0.12,
            timestamp: "2026-08-21T13:45:00.000Z", heartRate: 150)])
        do {
            _ = try WorkoutWireMapper.row(for: badPointID, in: utc)
            assertTest(false, "A route point whose id is unreadable is refused")
        } catch let error as CloudSyncError {
            // An `if case` rather than the `guard`/`continue` the loop above uses: this block is not a
            // loop, and a `return` here would leave the section instead of the block — skipping every
            // assertion below it. The two arms are the same two assertions either way.
            if case let .malformed(message) = error {
                assertTest(message.contains("not-a-uuid"), "…naming the fix's own id")
            } else {
                assertTest(false, "…with the malformed case")
            }
        }

        let badPointTime = answer(route: [WorkoutRoutePointDTO(
            id: UUID().uuidString, latitude: 51.5, longitude: -0.12,
            timestamp: "2026-08-21 13:45:00", heartRate: 150)])
        do {
            _ = try WorkoutWireMapper.row(for: badPointTime, in: utc)
            assertTest(false, "A route point whose time is unreadable is refused")
        } catch let error as CloudSyncError {
            if case let .malformed(message) = error {
                assertTest(message.contains("2026-08-21 13:45:00"), "…naming the fix's own time")
            } else {
                assertTest(false, "…with the malformed case")
            }
        }

        // The split is the deliberate exception: its only string is its id, and `WorkoutSplit`'s
        // initialiser defaults that — so an unreadable id costs the split its identity rather than the
        // whole answer its meaning, and the session still reads back.
        let anonymousSplit = answer(splits: [WorkoutSplitDTO(id: "not-a-uuid", elapsed: 1800, strain: 2.6)])
        let splitBack = try WorkoutWireMapper.row(for: anonymousSplit, in: utc)
        assertTest(splitBack.splits.count == 1, "A split with an unreadable id is kept rather than refused")
        assertTest(splitBack.splits.first?.elapsed == 1800 && splitBack.splits.first?.strain == 2.6,
                   "…with its measurement intact and only its identity minted")

        // MARK: The published bounds

        // **Mirrored from the server rather than chosen here**, so the three are pinned as literals: a
        // client-side cap that drifted below the server's would silently skip rows the database would
        // happily have taken, and one that drifted above it would fail a whole chunk on one row.
        assertTest(WorkoutWireMapper.maximumRoutePoints == 2000,
                   "The route cap is the server's MAX_ROUTE_POINTS")
        assertTest(WorkoutWireMapper.maximumSplits == 200,
                   "The splits cap is the server's MAX_SPLITS")
        assertTest(WorkoutWireMapper.zoneCount == 5,
                   "The zone block is five shares, as ZONE_COUNT says")

        // MARK: What the database will take

        // `isSendable` is the wire's question and not the app's, which is the distinction `recoveries`
        // drew between this and `hasMeasurement`: it asks *will the database take it*, and it is
        // stricter than anything a screen asks. `POST /batch` is one all-or-nothing transaction, so one
        // row the server refuses fails a whole chunk — which is why the use case filters on this
        // **before** chunking rather than inside the chunk loop.
        func session(
            start: Date = started,
            end: Date = ended,
            strain: Double? = 4.1,
            average: Int? = 121,
            max: Int? = 164,
            source: String? = "whoop_export",
            name: String? = "Basketball",
            zones: [Double]? = [10, 20, 35, 25, 5],
            steps: Int? = 693,
            region: String? = nil,
            route: [WorkoutRoutePoint] = [],
            splits: [WorkoutSplit] = []
        ) -> WorkoutSyncRow {
            WorkoutSyncRow(
                id: UUID(), date: dayKey, startedAt: start, endedAt: end,
                strain: strain, averageHeartRate: average, maxHeartRate: max,
                source: source, activityName: name, hrZonePercents: zones,
                steps: steps, offlineRegionID: region, route: route, splits: splits)
        }

        assertTest(WorkoutWireMapper.isSendable(session()), "A fully-measured session is sendable")

        // **The absence rule applied to the whole row**: a fast measures none of the three, carries no
        // zone block, no steps and no region, and is 170 of the rows this app holds. A row of absences
        // is the shape the eight nullables exist for, so it must be sendable — and a reader that
        // narrowed this into `hasMeasurement` would refuse every one of them.
        let fastRow = session(strain: nil, average: nil, max: nil, source: "zero_fasting",
                              name: "Fast", zones: nil, steps: nil)
        assertTest(WorkoutWireMapper.isSendable(fastRow),
                   "A session nothing measured is sendable — the absences are the server's business")

        // **The pair the two instants are compared on.** `isSendable` compares the *strings that will be
        // sent*, not the `Date`s, because the server compares `parseInstant`'s answers — so two instants
        // that render to the same millisecond are one instant as far as the request is concerned. A
        // sub-millisecond session would otherwise be sent and refused with `endedAt must be after
        // startedAt`, naming a field whose values look plainly ordered to whoever reads the log.
        let subStart = started.addingTimeInterval(0.0004)
        let subEnd = started.addingTimeInterval(0.00049)
        assertTest(subEnd > subStart, "The sub-millisecond pair really is ordered as instants")
        assertTest(WorkoutWireMapper.instantKey(for: subStart) == WorkoutWireMapper.instantKey(for: subEnd),
                   "…and really does render to one string, which is the whole of why the string decides")
        assertTest(!WorkoutWireMapper.isSendable(session(start: subStart, end: subEnd)),
                   "…so a session shorter than the wire's resolution is refused rather than sent and rejected")

        assertTest(!WorkoutWireMapper.isSendable(session(start: ended, end: started)),
                   "A session that ends before it starts is refused")
        assertTest(!WorkoutWireMapper.isSendable(session(start: started, end: started)),
                   "…and so is one of zero length, which is the boundary the strict comparison is for")

        // The measurements: two that must be at least zero, and two that must be strictly positive.
        // **A zero heart rate is not a rate**, which is the schema's `.positive()` and also the reason
        // the route-point rule below bites on the app's own recorded fixes.
        assertTest(!WorkoutWireMapper.isSendable(session(strain: -0.1)), "A negative strain is refused")
        assertTest(!WorkoutWireMapper.isSendable(session(strain: .nan)), "…and a NaN one, before the encoder throws on it")
        assertTest(!WorkoutWireMapper.isSendable(session(strain: .infinity)), "…and an infinite one")
        assertTest(WorkoutWireMapper.isSendable(session(strain: 0)),
                   "…while a measured strain of exactly zero is a reading and is sent")
        assertTest(!WorkoutWireMapper.isSendable(session(average: 0)), "A zero average rate is a placeholder and is refused")
        assertTest(!WorkoutWireMapper.isSendable(session(average: -1)), "…as is a negative one")
        assertTest(!WorkoutWireMapper.isSendable(session(max: 0)), "A zero maximal rate is refused")
        assertTest(WorkoutWireMapper.isSendable(session(average: 60, max: 190)), "…where real rates are sent")

        // The three non-empty strings. `.min(1)` on the schema is what makes an empty string a
        // *different answer* from `nil` — and this app has no producer for one, so a row carrying it is
        // a row from somewhere else.
        assertTest(WorkoutWireMapper.isSendable(session(source: nil)), "A nil provenance is sendable")
        assertTest(!WorkoutWireMapper.isSendable(session(source: "")), "An empty provenance label is refused where nil is accepted")
        assertTest(!WorkoutWireMapper.isSendable(session(name: "")), "…and an empty activity name")
        assertTest(WorkoutWireMapper.isSendable(session(name: nil)),
                   "…while a session the export did not name is sendable, because a name is not a measurement")
        assertTest(!WorkoutWireMapper.isSendable(session(region: "")), "…and an empty tile-region id")
        assertTest(WorkoutWireMapper.isSendable(session(region: "mapbox-region-7")), "…where a real region id is sent")

        assertTest(WorkoutWireMapper.isSendable(session(steps: 0)),
                   "A session that measured motion and counted no steps is a real zero")
        assertTest(!WorkoutWireMapper.isSendable(session(steps: -1)), "…and a negative count is refused")

        // The zone block. `nil` is not `[0, 0, 0, 0, 0]` and **both are sendable**, which is the pair
        // that would fail if anyone collapsed the two: the first is a session with no block at all, the
        // second is a measured workout that never reached zone 1 — 45 of the bundled export's 673 rows.
        assertTest(WorkoutWireMapper.isSendable(session(zones: nil)), "A session with no zone block is sendable")
        assertTest(WorkoutWireMapper.isSendable(session(zones: [0, 0, 0, 0, 0])),
                   "…and so is a measured one that never reached zone 1, which is a different statement")
        assertTest(WorkoutWireMapper.isSendable(session(zones: [20, 20, 20, 20, 20])),
                   "A block summing to exactly 100 is sendable — the rule is *at most*")
        assertTest(!WorkoutWireMapper.isSendable(session(zones: [20, 20, 20, 20, 21])),
                   "…and one summing past 100 is refused")
        assertTest(WorkoutWireMapper.isSendable(session(zones: [0, 0, 0, 0, 100])),
                   "A session spent entirely in zone 5 is sendable")
        assertTest(!WorkoutWireMapper.isSendable(session(zones: [10, 20, 30, 20])),
                   "A four-band block is refused — the API's blocks are five")
        assertTest(!WorkoutWireMapper.isSendable(session(zones: [10, 20, 30, 20, 10, 0])),
                   "…and so is a six-band one")
        assertTest(!WorkoutWireMapper.isSendable(session(zones: [10.5, 20, 30, 20, 10])),
                   "A fractional share is refused rather than rounded, because rounding would invent a reading")
        assertTest(!WorkoutWireMapper.isSendable(session(zones: [-1, 20, 30, 20, 10])), "A negative share is refused")
        assertTest(!WorkoutWireMapper.isSendable(session(zones: [101, 0, 0, 0, 0])), "A share above 100 is refused")
        assertTest(!WorkoutWireMapper.isSendable(session(zones: [.nan, 0, 0, 0, 0])), "A NaN share is refused")

        // The caps, at both edges. `route.count <= 2000` and `splits.count <= 200` are the array bounds
        // the schema publishes, and the equality matters as much as the refusal: a session carrying
        // exactly the maximum is one the server takes.
        let point: (Double) -> WorkoutRoutePoint = { offset in
            WorkoutRoutePoint(latitude: 51.5, longitude: -0.12,
                              timestamp: started.addingTimeInterval(offset), heartRate: 150)
        }
        assertTest(WorkoutWireMapper.isSendable(session(route: (0 ..< 2000).map { point(Double($0)) })),
                   "A session carrying exactly the maximum route is sendable")
        assertTest(!WorkoutWireMapper.isSendable(session(route: (0 ..< 2001).map { point(Double($0)) })),
                   "…and one fix more is refused whole rather than trimmed")

        let split: (Double) -> WorkoutSplit = { elapsed in WorkoutSplit(elapsed: elapsed, strain: 1.0) }
        assertTest(WorkoutWireMapper.isSendable(session(splits: (0 ..< 200).map { split(Double($0)) })),
                   "A session carrying exactly the maximum splits is sendable")
        assertTest(!WorkoutWireMapper.isSendable(session(splits: (0 ..< 201).map { split(Double($0)) })),
                   "…and a lap more is refused")

        // **The route point's own rules, and the heart rate is the one that bites.** A live session with
        // `RECORD ROUTE` on can collect its first GPS fixes before the accumulator has seen a sample, and
        // those fixes are stamped with the documented `0` sentinel — so a row this app produced can hold
        // a point the API will not take. The remedy is to skip the session and never to trim the array:
        // dropping the points would send a *different route* from the one on disk.
        assertTest(WorkoutWireMapper.isSendable(session(route: [point(0)])), "A plausible fix is sendable")
        assertTest(!WorkoutWireMapper.isSendable(session(route: [point(0), WorkoutRoutePoint(
            latitude: 51.5, longitude: -0.12, timestamp: started, heartRate: 0)])),
                   "A fix stamped with the pre-sample sentinel is refused, and takes the session with it")
        assertTest(!WorkoutWireMapper.isSendable(session(route: [WorkoutRoutePoint(
            latitude: 51.5, longitude: -0.12, timestamp: started, heartRate: -1)])),
                   "…as is a negative rate")

        let corner: (Double, Double) -> WorkoutRoutePoint = { latitude, longitude in
            WorkoutRoutePoint(latitude: latitude, longitude: longitude, timestamp: started, heartRate: 150)
        }
        assertTest(WorkoutWireMapper.isSendable(session(route: [corner(90, 180)])),
                   "The two extremes of both ranges are places and are sendable")
        assertTest(WorkoutWireMapper.isSendable(session(route: [corner(-90, -180)])),
                   "…at the other corner too")
        assertTest(!WorkoutWireMapper.isSendable(session(route: [corner(90.1, 0)])), "A latitude past the pole is refused")
        assertTest(!WorkoutWireMapper.isSendable(session(route: [corner(-90.1, 0)])), "…and one past it to the south")
        assertTest(!WorkoutWireMapper.isSendable(session(route: [corner(0, 180.1)])), "A longitude past the antimeridian is refused")
        assertTest(!WorkoutWireMapper.isSendable(session(route: [corner(Double.nan, 0)])), "A NaN latitude is refused")

        // **The one rule here that is not the range test, and it is the app's own convention.** The
        // route the map draws drops a `(0, 0)` fix through `WorkoutRoutePoint.isPlausible`; the wire
        // has no such rule and 0/0 is a legal coordinate, so a placeholder fix is *sendable* and is
        // filtered on the way to the picture instead. Asserted rather than left to be assumed, because
        // it is the difference between the two layers that a reader would guess at.
        assertTest(!corner(0, 0).isPlausible, "A `(0, 0)` fix is not a place as far as the map is concerned")
        assertTest(WorkoutWireMapper.isSendable(session(route: [corner(0, 0)])),
                   "…and the wire takes it anyway, which is the two rules being different rules")

        // The splits' two numbers, which are the same shape as the strain rule one level up.
        assertTest(WorkoutWireMapper.isSendable(session(splits: [WorkoutSplit(elapsed: 0, strain: 0)])),
                   "A lap of zero elapsed and zero strain is a pair of readings and is sent")
        assertTest(!WorkoutWireMapper.isSendable(session(splits: [WorkoutSplit(elapsed: -1, strain: 1)])),
                   "A negative lap length is refused")
        assertTest(!WorkoutWireMapper.isSendable(session(splits: [WorkoutSplit(elapsed: .nan, strain: 1)])),
                   "…and a NaN one")
        assertTest(!WorkoutWireMapper.isSendable(session(splits: [WorkoutSplit(elapsed: 60, strain: -1)])),
                   "…and a negative lap strain")
        assertTest(!WorkoutWireMapper.isSendable(session(splits: [WorkoutSplit(elapsed: 60, strain: .nan)])),
                   "…and a NaN one")
    }
}

// MARK: - Helpers

/// A calendar pinned to one offset, so the instant's zone-independence can be asserted outside the
/// device's own zone — the same helper `RecoveryWireMapperTests` carries, under its own file-private
/// name because the two files are one module.
private func calendar(inSecondsFromGMT offset: Int) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

/// Gregorian, in UTC — the one zone `instantKey` reads and writes in, and therefore the zone every
/// literal in this file is written in.
private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    return calendar
}

/// Midnight at the start of a day **in that calendar's zone**.
private func midnight(_ year: Int, _ month: Int, _ day: Int, in calendar: Calendar) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    return calendar.startOfDay(for: calendar.date(from: components) ?? Date.distantPast)
}

/// The instant `year-month-dayThour:minute:second.000Z` names — built in UTC rather than measured
/// against the device's clock, so every literal in this file holds on any machine.
private func utcInstant(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int
) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    return utcCalendar().date(from: components) ?? Date.distantPast
}
