import Foundation
import Whoopsy

// MARK: - 22.2 One night on the wire, and the two shapes it adds to the family

/// **This is the widest row in the family and the only one whose DTO conversion can throw.** Two things
/// on it are new rather than a restatement of the recoveries mapper, and both are asserted here.
///
/// *Two instants rather than one day.* A night carries its own start and end, and the API publishes one
/// canonical instant form for them — `WorkoutWireMapper`'s, forwarded. The day is still a day key and it
/// is the night's **wake** day; the schema says in as many words that it is not derived from `startTime`,
/// so the mapping below is a copy and the block that checks a night which began before midnight is
/// asserting that nothing here recomputes one.
///
/// *An opaque timeline.* `sleepStages` is a `[SleepStageSegment]?` on the row and a JSON **string** on the
/// wire. The server neither parses nor validates it, so the property that matters is the round trip: what
/// leaves this phone is what comes back. An empty array is normalised to `null` on the way out, which is
/// the app's own rule restated at the boundary rather than a value being dropped.
///
/// **The six nullable fields are the reason the encoder is written by hand**, and this is the resource
/// where that is not a corner case: `sleepStages` is `nil` on all 910 imported nights, `disturbanceCount`
/// and `sleepConsistency` likewise, and `sleepDebt` is `nil` on every strap night. A synthesised encoder
/// would therefore refuse most of what this app can hold.
enum SleepWireMapperTests {

    static func run() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        /// A day, `offset` days from today, snapped — §11's rule.
        let day: (Int) -> Date = { offset in
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }

        /// A whole-second instant, so it survives the wire's milliseconds exactly: `instantKey` floors
        /// sub-millisecond precision away, and a fixture built from `Date()` would fail a round trip for
        /// a reason that has nothing to do with this mapping.
        let instant: (Int) -> Date = { offset in Date(timeIntervalSince1970: 1_755_000_000 + Double(offset)) }

        // MARK: Every field, round-tripped through both conversions

        // A night with all fifteen fields set and each carrying a value no other field shares, so a
        // mapping that swapped two of them cannot cancel itself out. The timeline is two segments with
        // explicit ids, because the id is on the wire and a round trip that minted a fresh one would not
        // compare equal — the property being asserted is that the whole value survives, not that the
        // segments are the same three numbers.
        let night = SleepSyncRow(
            date: day(-1),
            startTime: instant(-28_800),
            endTime: instant(-100),
            sleepPerformance: 88.5,
            totalSleepNeeded: 28_800,
            lightSleep: 14_400,
            deepSleep: 5_400,
            remSleep: 7_200,
            awakeTime: 1_800,
            respiratoryRate: 14.25,
            disturbanceCount: 6,
            sleepConsistency: 71,
            sleepDebt: 3_600,
            sleepStages: [
                SleepStageSegment(startTime: instant(-28_800), endTime: instant(-20_000), stage: .light),
                SleepStageSegment(startTime: instant(-20_000), endTime: instant(-14_000), stage: .deep),
            ],
            source: "whoop_export")

        let dto = try SleepWireMapper.dto(for: night)
        assertTest(dto.date == RecoveryWireMapper.dayKey(for: day(-1)),
                   "The night's wake day becomes the wire's bare key, read off the mapper that owns it")
        assertTest(dto.startTime == WorkoutWireMapper.instantKey(for: instant(-28_800)),
                   "The onset is an instant, in the one canonical form this app writes down")
        assertTest(dto.endTime == WorkoutWireMapper.instantKey(for: instant(-100)), "…and so is the wake")
        assertTest(dto.sleepPerformance == 88.5, "The performance crosses unchanged")
        assertTest(dto.totalSleepNeeded == 28_800, "…and the night's requirement")
        assertTest(dto.lightSleep == 14_400 && dto.deepSleep == 5_400
                       && dto.remSleep == 7_200 && dto.awakeTime == 1_800,
                   "…and the three stage totals and wakefulness, each in its own field")
        assertTest(dto.respiratoryRate == 14.25, "…and the respiratory rate")
        assertTest(dto.disturbanceCount == 6, "…and the disturbance count")
        assertTest(dto.sleepConsistency == 71, "…and the consistency score")
        assertTest(dto.sleepDebt == 3_600, "…and the accumulated debt")
        assertTest(dto.sleepStages != nil, "…and the stage timeline, as opaque text")
        assertTest(dto.source == "whoop_export", "…and the provenance that tells an imported night from a scored one")

        assertTest(try SleepWireMapper.row(for: dto) == night,
                   "All fifteen fields and both stage segments survive row → wire → row")

        // MARK: The timeline is opaque, and an empty one is an absence

        // `GRDBSleepRepository.saveSleepSession` writes `nil` for an empty timeline, on the argument that
        // *nothing staged* and *never staged* are the same thing and only one of them has a
        // representation — and the schema refuses `""` while calling `null` that thing's only spelling.
        // So this is the app's own rule restated at the boundary rather than a value going missing.
        let unstaged = SleepSyncRow(date: day(-2), startTime: instant(-86_400), endTime: instant(-80_000),
                                    sleepPerformance: 74, totalSleepNeeded: 28_800,
                                    lightSleep: 16_000, deepSleep: 4_000, remSleep: 6_000,
                                    awakeTime: 1_200, sleepStages: [])
        assertTest(try SleepWireMapper.dto(for: unstaged).sleepStages == nil,
                   "An empty timeline is sent as null, which is the only spelling the schema has for none")

        // The two normalising halves are a round trip in their own right: `null` in, `nil` out, and no
        // empty array reappearing on the far side — which would be a night that says *staged, with
        // nothing in it* about a night nobody staged.
        let unstagedBack = try SleepWireMapper.row(for: try SleepWireMapper.dto(for: unstaged))
        assertTest(unstagedBack.sleepStages == nil, "…and reads back as an absent timeline, not an empty one")

        // MARK: The wire's own JSON

        let encoded = try JSONEncoder().encode(dto)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            assertTest(false, "The wire's body encodes to a JSON object")
            return
        }
        assertTest(Set(object.keys) == [
            "date", "startTime", "endTime", "sleepPerformance", "totalSleepNeeded",
            "lightSleep", "deepSleep", "remSleep", "awakeTime",
            "respiratoryRate", "disturbanceCount", "sleepConsistency", "sleepDebt", "sleepStages", "source",
        ], "The body's keys are the wire's fifteen, spelled as the server declares them")

        // The six nullable fields, all absent at once — which is the shape of an ordinary strap night
        // rather than a corner case, since four of the six have no producer for one.
        let bareNature = SleepSyncRow(date: day(-3), startTime: instant(-172_800), endTime: instant(-160_000),
                                      sleepPerformance: 61, totalSleepNeeded: 27_000,
                                      lightSleep: 15_000, deepSleep: 3_600, remSleep: 5_400, awakeTime: 900)
        let bareEncoded = try JSONEncoder().encode(try SleepWireMapper.dto(for: bareNature))
        guard let bareObject = try JSONSerialization.jsonObject(with: bareEncoded) as? [String: Any] else {
            assertTest(false, "A night with every optional absent still encodes")
            return
        }
        for key in ["respiratoryRate", "disturbanceCount", "sleepConsistency", "sleepDebt",
                    "sleepStages", "source"] {
            assertTest(bareObject.keys.contains(key), "The body carries '\(key)' as a key even when it is empty")
            assertTest(bareObject[key] is NSNull, "…and carries it as null, which the schema accepts and needs")
        }

        // MARK: What the database will take

        assertTest(SleepWireMapper.isSendable(night), "A fully-scored night is sendable")
        assertTest(SleepWireMapper.isSendable(bareNature),
                   "…and so is a strap night carrying none of the six optional measures")

        // The resource's own rule, and the one the plan names: **a night of zero length is not a night.**
        assertTest(!SleepWireMapper.isSendable(
            SleepSyncRow(date: day(-1), startTime: instant(0), endTime: instant(0),
                         sleepPerformance: 80, totalSleepNeeded: 28_800, lightSleep: 16_000,
                         deepSleep: 4_000, remSleep: 6_000, awakeTime: 1_200)),
            "A night that ended when it began is refused")
        assertTest(!SleepWireMapper.isSendable(
            SleepSyncRow(date: day(-1), startTime: instant(3_600), endTime: instant(0),
                         sleepPerformance: 80, totalSleepNeeded: 28_800, lightSleep: 16_000,
                         deepSleep: 4_000, remSleep: 6_000, awakeTime: 1_200)),
            "…and so is one that ended before it began")

        // **The comparison is made on the strings that will be sent and not on the `Date`s**, which is
        // the refinement worth its own assertion: the server compares its two `parseInstant` answers, so
        // two instants rendering to the same millisecond are one instant as far as the request is
        // concerned. A `Date`-based test would call this night ordered and send a body the server refuses
        // with a sentence naming a field whose two values look plainly ordered to whoever reads the log.
        let subMillisecond = Date(timeIntervalSince1970: 1_755_000_000 + 0.0001)
        assertTest(subMillisecond > Date(timeIntervalSince1970: 1_755_000_000),
                   "The two instants are genuinely ordered as `Date`s")
        assertTest(WorkoutWireMapper.instantKey(for: subMillisecond)
                       == WorkoutWireMapper.instantKey(for: Date(timeIntervalSince1970: 1_755_000_000)),
                   "…and render to the same millisecond, which is the fact the rule turns on")
        assertTest(!SleepWireMapper.isSendable(
            SleepSyncRow(date: day(-1), startTime: Date(timeIntervalSince1970: 1_755_000_000),
                         endTime: subMillisecond, sleepPerformance: 80, totalSleepNeeded: 28_800,
                         lightSleep: 16_000, deepSleep: 4_000, remSleep: 6_000, awakeTime: 1_200)),
            "…so a night shorter than a millisecond is refused rather than sent and refused by the server")

        // The schema's bounds, restated in the layer that has to decide.
        assertTest(!SleepWireMapper.isSendable(
            SleepSyncRow(date: day(-1), startTime: instant(0), endTime: instant(28_800),
                         sleepPerformance: 101, totalSleepNeeded: 28_800, lightSleep: 16_000,
                         deepSleep: 4_000, remSleep: 6_000, awakeTime: 1_200)),
            "A performance above 100 is refused")
        assertTest(!SleepWireMapper.isSendable(
            SleepSyncRow(date: day(-1), startTime: instant(0), endTime: instant(28_800),
                         sleepPerformance: 80, totalSleepNeeded: 28_800, lightSleep: -1,
                         deepSleep: 4_000, remSleep: 6_000, awakeTime: 1_200)),
            "A negative stage total is refused")
        assertTest(!SleepWireMapper.isSendable(
            SleepSyncRow(date: day(-1), startTime: instant(0), endTime: instant(28_800),
                         sleepPerformance: 80, totalSleepNeeded: 28_800, lightSleep: 16_000,
                         deepSleep: 4_000, remSleep: 6_000, awakeTime: 1_200,
                         sleepConsistency: 101)),
            "A consistency score above 100 is refused")
        assertTest(!SleepWireMapper.isSendable(
            SleepSyncRow(date: day(-1), startTime: instant(0), endTime: instant(28_800),
                         sleepPerformance: 80, totalSleepNeeded: 28_800, lightSleep: 16_000,
                         deepSleep: 4_000, remSleep: 6_000, awakeTime: 1_200, source: "")),
            "An empty provenance label is refused where nil is accepted")

        // MARK: A body this app cannot read

        // Four checked fields on this mapper and each refusal names itself, which is the property that
        // makes a log line actionable rather than merely alarming. The day is first because it is the
        // keying rule; the two instants are what tell a user *which* of a night's edges arrived broken.
        for (label, bad) in [
            ("day", SleepDTO(date: "not-a-day", startTime: "2026-08-21T00:00:00.000Z",
                             endTime: "2026-08-21T08:00:00.000Z", sleepPerformance: 80,
                             totalSleepNeeded: 28_800, lightSleep: 16_000, deepSleep: 4_000,
                             remSleep: 6_000, awakeTime: 1_200, respiratoryRate: nil,
                             disturbanceCount: nil, sleepConsistency: nil, sleepDebt: nil,
                             sleepStages: nil, source: nil)),
            ("start", SleepDTO(date: "2026-08-21", startTime: "2026-08-21T00:00:00",
                               endTime: "2026-08-21T08:00:00.000Z", sleepPerformance: 80,
                               totalSleepNeeded: 28_800, lightSleep: 16_000, deepSleep: 4_000,
                               remSleep: 6_000, awakeTime: 1_200, respiratoryRate: nil,
                               disturbanceCount: nil, sleepConsistency: nil, sleepDebt: nil,
                               sleepStages: nil, source: nil)),
            ("end", SleepDTO(date: "2026-08-21", startTime: "2026-08-21T00:00:00.000Z",
                             endTime: "tomorrow", sleepPerformance: 80,
                             totalSleepNeeded: 28_800, lightSleep: 16_000, deepSleep: 4_000,
                             remSleep: 6_000, awakeTime: 1_200, respiratoryRate: nil,
                             disturbanceCount: nil, sleepConsistency: nil, sleepDebt: nil,
                             sleepStages: nil, source: nil)),
        ] {
            do {
                _ = try SleepWireMapper.row(for: bad)
                assertTest(false, "A night whose \(label) this app cannot read is refused rather than guessed at")
            } catch let error as CloudSyncError {
                guard case .malformed = error else {
                    assertTest(false, "…with the malformed case, not another one")
                    return
                }
                assertTest(true, "…and a night with an unreadable \(label) is a malformed answer")
            }
        }

        // The fifth: a timeline the app cannot read back as segments. It throws for the same reason the
        // encoder does — a night whose stages will not parse is not the same fact as a night nobody
        // staged, and storing the absence would report the second in place of the first.
        do {
            _ = try SleepWireMapper.row(
                for: SleepDTO(date: "2026-08-21", startTime: "2026-08-21T00:00:00.000Z",
                              endTime: "2026-08-21T08:00:00.000Z", sleepPerformance: 80,
                              totalSleepNeeded: 28_800, lightSleep: 16_000, deepSleep: 4_000,
                              remSleep: 6_000, awakeTime: 1_200, respiratoryRate: nil,
                              disturbanceCount: nil, sleepConsistency: nil, sleepDebt: nil,
                              sleepStages: "not json at all", source: nil))
            assertTest(false, "A stage timeline this app cannot read is refused")
        } catch let error as CloudSyncError {
            guard case .malformed = error else {
                assertTest(false, "…with the malformed case")
                return
            }
            assertTest(true, "…rather than being stored as a night that was never staged")
        }

        // MARK: The day is the night's wake day and nothing here recomputes it

        // The one keying rule this resource adds, asserted at the mapping rather than at the database:
        // a night that began before midnight is filed on the morning it ended, and a mapper that derived
        // the day from `startTime` would send it one early on this side of the call.
        let overnight = SleepSyncRow(
            date: day(-1),
            startTime: day(-2) + 22 * 3600,
            endTime: day(-1) + 6 * 3600,
            sleepPerformance: 82, totalSleepNeeded: 28_800,
            lightSleep: 15_000, deepSleep: 4_800, remSleep: 6_600, awakeTime: 1_800)
        let overnightDTO = try SleepWireMapper.dto(for: overnight)
        assertTest(overnightDTO.date == RecoveryWireMapper.dayKey(for: day(-1)),
                   "A night that began before midnight keeps the day it woke on")
        assertTest(overnightDTO.startTime != overnightDTO.endTime,
                   "…and its two instants are its own, unmoved by the day beside them")
    }
}
