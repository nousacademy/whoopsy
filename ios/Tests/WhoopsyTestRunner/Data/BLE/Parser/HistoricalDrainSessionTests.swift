import Foundation
import Whoopsy

// MARK: - 16. The drain session and the generation-agnostic dispatch

/// A file of §16's body, cut at the section's own `// MARK:` topic boundary and moved
/// verbatim. `StepTests.run()` calls it, in the order the section ran it in.
enum HistoricalDrainSessionTests {
    static func run() async throws {
        // MARK: The drain session

        /// The continuation token. Eight arbitrary bytes — what matters is where they come from and that
        /// they come back unchanged, not what they are.
        let token = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])

        let drainNow = Date(timeIntervalSince1970: 1_800_000_000)

        /// A timestamp far from `drainNow`, so a marker carrying it is never the live edge.
        let oldEpoch: UInt32 = 1_700_000_000

        /// A 5.0 metadata marker of `payloadBytes` bytes: `unix` at payload 0 (frame 11), a zero subsecond
        /// at payload 4, and the token at payload **10** — frame **21** under this envelope, the slice
        /// NOOP hardware-verified as the trim cursor.
        ///
        /// Built by the real encoder and read back through the real decoder, so the session is fed a frame
        /// this app actually produced. A `WhoopRawFrame` assembled by hand would let the token's offset and
        /// the session's agree while both were wrong about the envelope.
        func fiveMarker(
            cmd: UInt8, unix: UInt32, payloadBytes: Int, expected: Int? = nil,
            tokenBytes: Data? = nil
        ) -> WhoopRawFrame? {
            let tokenBytes = tokenBytes ?? token
            var payload = [UInt8](repeating: 0, count: max(payloadBytes, 4))
            payload[0] = UInt8(unix & 0xFF)
            payload[1] = UInt8((unix >> 8) & 0xFF)
            payload[2] = UInt8((unix >> 16) & 0xFF)
            payload[3] = UInt8((unix >> 24) & 0xFF)
            // The Gen 5 declared frame count, at payload 6 — `inner[9]`, ahead of the token at 10.
            if let expected, payload.count >= HistoricalDrainSession.expectedFrameCountPayloadOffset + 4 {
                let start = HistoricalDrainSession.expectedFrameCountPayloadOffset
                for offset in 0..<4 {
                    payload[start + offset] = UInt8((expected >> (8 * offset)) & 0xFF)
                }
            }
            for (offset, byte) in tokenBytes.enumerated() where 10 + offset < payload.count {
                payload[10 + offset] = byte
            }
            guard let framed = WhoopPacketEncoder5.buildPacket(
                profile: .whoop5, type: WhoopProtocolProfile.whoop5.packetTypes.metadata, seq: 0x01,
                cmd: cmd, payload: Data(payload))
            else { return nil }
            return decoder.decodeProprietaryFrame(data: framed, profile: .whoop5)
        }

        /// The 4.0 counterpart, whose token sits at payload **10** — §4's `inner[13:21]`, and the same
        /// frame byte 17. `unix` is written into the leading bytes only so a reader that reached for the
        /// 5.0's field on this generation has something plausible to trip over.
        func fourMarker(cmd: UInt8, payloadBytes: Int, unix: UInt32 = 0) -> WhoopRawFrame? {
            var payload = [UInt8](repeating: 0, count: max(payloadBytes, 4))
            payload[0] = UInt8(unix & 0xFF)
            payload[1] = UInt8((unix >> 8) & 0xFF)
            payload[2] = UInt8((unix >> 16) & 0xFF)
            payload[3] = UInt8((unix >> 24) & 0xFF)
            for (offset, byte) in token.enumerated() where 10 + offset < payload.count {
                payload[10 + offset] = byte
            }
            guard let framed = WhoopPacketEncoder.buildPacket(
                profile: .whoop4, type: WhoopProtocolProfile.whoop4.packetTypes.metadata, seq: 0x02,
                cmd: cmd, payload: Data(payload))
            else { return nil }
            return decoder.decodeProprietaryFrame(data: framed, profile: .whoop4)
        }

        // **The token is at payload 10 on both generations**, which is frame 17 on the 4.0 and frame 21
        // on the 5.0 because their payload origins are four bytes apart. The assertion is on the
        // derivation rather than on a literal, so an edit that hardcodes one generation's frame offset
        // fails here — which is exactly the failure that made every drain replay the same batch.
        assertTest(
            HistoricalDrainSession.continuationTokenPayloadOffset == 10
                && HistoricalDrainSession.continuationTokenFrameOffset(for: .whoop4) == 17
                && HistoricalDrainSession.continuationTokenFrameOffset(for: .whoop5) == 21
                && WhoopProtocolProfile.whoop4.innerOrigin
                    + WhoopProtocolProfile.whoop4.innerPrefixBytes + 10 == 17
                && WhoopProtocolProfile.whoop5.innerOrigin
                    + WhoopProtocolProfile.whoop5.innerPrefixBytes + 10 == 21,
            "The token is payload 10 on both generations — frame 17 on the 4.0 and frame 21 on the 5.0 — "
                + "because the payload origins are four bytes apart. A reader built on one generation's "
                + "frame offset is four bytes early on the other, and the strap accepts the write and "
                + "never advances")

        do {
            let start = fiveMarker(cmd: 1, unix: oldEpoch, payloadBytes: 18)
            let end = fiveMarker(cmd: 2, unix: oldEpoch, payloadBytes: 18)
            let complete = fiveMarker(cmd: 3, unix: oldEpoch, payloadBytes: 18)
            assertTest(
                start != nil && end != nil && complete != nil,
                "The three 5.0 metadata markers frame and decode — a failure here would make every "
                    + "assertion below it vacuous, which is why it stands on its own")

            if let start, let end, let complete {
                var session = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)

                let t1 = drainNow.addingTimeInterval(3)
                assertTest(
                    session.accept(start, now: t1) == .none && session.recordCount == 0
                        && session.batchCount == 0,
                    "HISTORY_START is informational — §4 says ignore it — so it is neither a record nor a "
                        + "batch and nothing is sent back")
                assertTest(
                    session.lastActivity == t1,
                    "…and it still counts as activity, which is what keeps a strap mid-history from idling "
                        + "out while it is working")

                let t2 = drainNow.addingTimeInterval(6)
                assertTest(
                    session.accept(end, now: t2) == .acknowledge(token: token) && session.batchCount == 1,
                    "HISTORY_END asks for the token back: the action carries the eight token bytes at "
                        + "payload 10 — frame 21 under this envelope — and nothing else, and it is the "
                        + "only frame in the loop that is answered")
                assertTest(
                    session.recordCount == 0,
                    "…and it is not a record, so the batch count and the record count are separate "
                        + "figures rather than two names for one")

                let t3 = drainNow.addingTimeInterval(9)
                assertTest(
                    session.accept(complete, now: t3) == .finish && session.finishReason == .complete,
                    "HISTORY_COMPLETE stops the drain and carries no token — §4 is explicit that it is not "
                        + "a batch and that answering it is answering a question the strap did not ask")
                assertTest(
                    session.accept(end, now: t3) == .none && session.batchCount == 1,
                    "…and a finished session ignores everything after it, so a late batch cannot reopen a "
                        + "drain the strap has already declared complete")
            }
        }

        do {
            var counter = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            var recordFrame = StepTests.fiveFrame(
                type: WhoopProtocolProfile.whoop5.packetTypes.historicalData, payloadBytes: 1244)
            StepTests.sealFive(&recordFrame)
            let record = decoder.decodeProprietaryFrame(data: Data(recordFrame), profile: .whoop5)
            assertTest(record != nil, "A type-47 record frames and decodes for the counter below")
            if let record {
                let t1 = drainNow.addingTimeInterval(3)
                assertTest(
                    counter.accept(record, now: t1) == .none && counter.recordCount == 1
                        && counter.batchCount == 0,
                    "A banked type-47 record is a record rather than a batch: counted, never "
                        + "acknowledged, because the ack answers the HISTORY_END that closes the batch and "
                        + "not the records inside it")

                // The live 43 stream shares the connection with a 5.0 drain, and counting it as activity
                // would leave the idle watchdog unable to fire on a strap that stopped answering.
                var liveFrame = StepTests.fiveFrame(
                    type: WhoopProtocolProfile.whoop5.packetTypes.realtimeRawData, payloadBytes: 1244)
                StepTests.sealFive(&liveFrame)
                let live = decoder.decodeProprietaryFrame(data: Data(liveFrame), profile: .whoop5)
                assertTest(
                    live != nil && counter.accept(live!, now: t1.addingTimeInterval(30)) == .none
                        && counter.recordCount == 1 && counter.lastActivity == t1,
                    "A live type-43 frame is neither a record nor activity: it is a different "
                        + "conversation, and letting it re-arm the window would keep a drain that has "
                        + "stopped answering from ever timing out")
            }
        }

        do {
            // ---- The record range the strain refresh backfills ----
            //
            // **The oldest stamp is the half a count cannot supply.** A backlog drain covers a span,
            // and the refresh scores the days between these two instants; without the minimum a
            // drain could only say how far forward it reached, and every day behind the newest would
            // go unscored. The stamp sits at payload `[4]` on both generations, which is frame 15
            // under the 5.0 envelope (payload origin 11).
            func stampedRecord(_ unix: UInt32) -> WhoopRawFrame? {
                var bytes = StepTests.fiveFrame(
                    type: WhoopProtocolProfile.whoop5.packetTypes.historicalData, payloadBytes: 64)
                // **The layout selector matters to the range now.** A stamp is only read from a layout
                // on the 1 Hz grid (`HistoricalDrainSession.timestampedLayouts`), so this fixture names
                // R18 at frame 9 — `inner[1]` — rather than leaving whatever `fiveFrame` defaults to.
                bytes[9] = HeartRatePayloadDecoder.historicalLayout
                let origin = 11
                bytes[origin + 4] = UInt8(unix & 0xFF)
                bytes[origin + 5] = UInt8((unix >> 8) & 0xFF)
                bytes[origin + 6] = UInt8((unix >> 16) & 0xFF)
                bytes[origin + 7] = UInt8((unix >> 24) & 0xFF)
                StepTests.sealFive(&bytes)
                return decoder.decodeProprietaryFrame(data: Data(bytes), profile: .whoop5)
            }

            var ranged = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            assertTest(
                ranged.lowestRecordTimestamp == nil && ranged.highestRecordTimestamp == nil,
                "A drain that has carried no record has no range — nil, not the start instant")

            // Out of order on purpose: the drain's batches alternate streams, so the minimum and the
            // maximum are drain-wide rather than first-and-last.
            let middle: UInt32 = 1_700_000_400
            let oldest: UInt32 = 1_700_000_100
            if let newestFrame = stampedRecord(middle), let oldestFrame = stampedRecord(oldest),
               let unstamped = stampedRecord(0) {
                _ = ranged.accept(newestFrame, now: drainNow)
                _ = ranged.accept(oldestFrame, now: drainNow)
                _ = ranged.accept(unstamped, now: drainNow)

                assertTest(
                    ranged.lowestRecordTimestamp == Date(timeIntervalSince1970: TimeInterval(oldest)),
                    "The range's oldest stamp is the drain's minimum, got "
                        + "\(ranged.lowestRecordTimestamp?.description ?? "nil")")
                assertTest(
                    ranged.highestRecordTimestamp == Date(timeIntervalSince1970: TimeInterval(middle)),
                    "…and its newest is the maximum, got "
                        + "\(ranged.highestRecordTimestamp?.description ?? "nil")")
            }

            var unstampedOnly = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            if let unstamped = stampedRecord(0) {
                _ = unstampedOnly.accept(unstamped, now: drainNow)
                assertTest(
                    unstampedOnly.lowestRecordTimestamp == nil
                        && unstampedOnly.highestRecordTimestamp == nil,
                    "A stamp that is not a real date is not evidence for any day — the range stays nil "
                        + "rather than filing the record on 1970")
            }
        }

        do {
            // A marker one byte short of holding a token. §4's point is that a *wrong* token is worse
            // than none — it leaves the strap re-sending while this app believes it answered — so a short
            // marker must produce no acknowledgement at all rather than a padded or truncated one.
            let shortFive = fiveMarker(cmd: 2, unix: oldEpoch, payloadBytes: 17)
            let shortFour = fourMarker(cmd: 2, payloadBytes: 17)
            assertTest(
                shortFive != nil && shortFour != nil,
                "A 17-byte marker on either generation frames and decodes — one byte short of the 18 "
                    + "its token needs, which is what makes the pair below about the token rather than "
                    + "about a frame that failed to validate")
            if let shortFive, let shortFour {
                var five = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
                var four = HistoricalDrainSession(profile: .whoop4, startedAt: drainNow)
                assertTest(
                    five.accept(shortFive, now: drainNow) == .none && five.batchCount == 1,
                    "A 5.0 HISTORY_END with no room for a token is still a batch and still gets no "
                        + "acknowledgement: a padded token would be eight invented bytes sent to a strap "
                        + "that would take them for a cursor")
                assertTest(
                    four.accept(shortFour, now: drainNow) == .none && four.batchCount == 1,
                    "…and the same holds one generation over, at the other token offset — so neither "
                        + "reader is relying on the frame being long enough")
            }
        }

        do {
            // The same token, from the other generation's marker, with §4's other derivation of it.
            let fourEnd = fourMarker(cmd: 2, payloadBytes: 18)
            assertTest(fourEnd != nil, "A hand-built 4.0 HISTORY_END validates under the 4.0 envelope")
            if let fourEnd {
                var session = HistoricalDrainSession(profile: .whoop4, startedAt: drainNow)
                assertTest(
                    session.accept(fourEnd, now: drainNow) == .acknowledge(token: token),
                    "…and its token comes back from the same eight **payload** bytes the 5.0's does — "
                        + "payload 10 on both, frame 17 here and frame 21 there. This is the assertion "
                        + "that fails if anyone builds the reader on a frame offset instead: four bytes "
                        + "early on the other strap, and its cursor never advances")

                // The 4.0's live edge. §4 publishes this generation's marker layout no further than the
                // token, so the field the 5.0 reads is not a timestamp here — and the marker below
                // deliberately carries a *plausible* one in that position, so a reader that reached for
                // the 5.0's rule would end this drain two seconds after it started.
                let plausible = fourMarker(
                    cmd: 2, payloadBytes: 18, unix: UInt32(drainNow.timeIntervalSince1970))
                assertTest(
                    plausible != nil
                        && session.accept(plausible!, now: drainNow) == .acknowledge(token: token),
                    "A 4.0 never trips the live edge, even with a fresh timestamp sitting in the bytes the "
                        + "5.0 reads: the drain ends on HISTORY_COMPLETE or the idle window, which is the "
                        + "conservative direction — a 4.0 that stopped early would lose the history behind "
                        + "the batch it stopped on")
            }
        }

        do {
            let epochs = UInt32(drainNow.timeIntervalSince1970)
            let window = HistoricalDrainSession.liveEdgeWindowSeconds
            assertTest(
                window == 5,
                "The live-edge window is five seconds")

            func liveEdge(_ offset: TimeInterval) -> HistoricalDrainSession.DrainAction? {
                var session = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
                guard let marker = fiveMarker(
                    cmd: 2, unix: UInt32(Int64(epochs) + Int64(offset)), payloadBytes: 18)
                else { return nil }
                return session.accept(marker, now: drainNow)
            }

            assertTest(
                liveEdge(4) == .acknowledgeAndFinish(token: token),
                "A batch stamped four seconds ahead of the phone ends the drain: that is the strap having "
                    + "caught up with the present, so there is nothing behind it left to fetch — and the "
                    + "acknowledgement still goes out, because the strap is waiting for it either way")
            assertTest(
                liveEdge(-4) == .acknowledgeAndFinish(token: token),
                "…and so is one stamped four seconds behind. **Two-sided on purpose**: a strap whose RTC "
                    + "is wrong is wrong in both directions, and a one-sided window on a fast strap would "
                    + "end the drain early and silently lose everything behind it")
            assertTest(
                liveEdge(6) == .acknowledge(token: token) && liveEdge(-6) == .acknowledge(token: token),
                "…while six seconds out on either side is an ordinary batch, which is what places the "
                    + "boundary at the constant rather than somewhere near it")
            assertTest(
                liveEdge(4) != liveEdge(6),
                "The two verdicts above are genuinely different actions rather than two spellings of one")
        }

        do {
            /// One R18 record carrying `unix` at payload `[4]`, built through the real encoder and
            /// decoder so the session is fed a frame this app produced.
            func r18Record(unix: UInt32) -> WhoopRawFrame? {
                var payload = [UInt8](repeating: 0, count: HeartRatePayloadDecoder.r18PayloadBytes)
                payload[4] = UInt8(unix & 0xFF)
                payload[5] = UInt8((unix >> 8) & 0xFF)
                payload[6] = UInt8((unix >> 16) & 0xFF)
                payload[7] = UInt8((unix >> 24) & 0xFF)
                guard let framed = WhoopPacketEncoder5.buildPacket(
                    profile: .whoop5,
                    type: WhoopProtocolProfile.whoop5.packetTypes.historicalData,
                    seq: HeartRatePayloadDecoder.historicalLayout,
                    cmd: 0,
                    payload: Data(payload))
                else { return nil }
                return decoder.decodeProprietaryFrame(data: framed, profile: .whoop5)
            }

            let nowEpoch = UInt32(drainNow.timeIntervalSince1970)
            let nowMarker = fiveMarker(cmd: 2, unix: nowEpoch, payloadBytes: 18)

            // **The owner's real drain, in miniature.** On 2026-10-23 every drain returned the same
            // 59 records stamped 2026-08-24 and a marker stamped now; the old rule read the marker and
            // ended the drain after one batch, reporting `caughtUpToLiveEdge` over two months of
            // unread backlog. These three assertions are the difference.
            var backlog = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            _ = r18Record(unix: oldEpoch).map { backlog.accept($0, now: drainNow) }
            assertTest(
                nowMarker.map { backlog.accept($0, now: drainNow) } == .acknowledge(token: token),
                "A batch whose records are two months old is not the live edge even though its "
                    + "HISTORY_END is stamped now — the marker's head is the drain's clock, not the "
                    + "records', and trusting it stopped every real drain after one batch")

            var caughtUp = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            _ = r18Record(unix: nowEpoch).map { caughtUp.accept($0, now: drainNow) }
            assertTest(
                nowMarker.map { caughtUp.accept($0, now: drainNow) } == .acknowledgeAndFinish(token: token),
                "…and a batch whose newest record is stamped now does finish, so the marker's fallback "
                    + "is a belt and not the rule")

            var stalled = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            var actions: [HistoricalDrainSession.DrainAction?] = []
            for _ in 0..<4 {
                _ = r18Record(unix: oldEpoch).map { stalled.accept($0, now: drainNow) }
                actions.append(nowMarker.map { stalled.accept($0, now: drainNow) })
            }
            assertTest(
                actions.prefix(3).allSatisfy { $0 == .acknowledge(token: token) }
                    && actions[3] == .acknowledgeAndFinish(token: token)
                    && stalled.finishReason == .idleTimeout,
                "The same batch four times is a stall, not a backlog: the first three are acknowledged "
                    + "and the fourth ends the drain as `.idleTimeout` — without the guard a re-sending "
                    + "strap never idles out, because its records keep the window armed")

            // **The owner's strap's actual pattern.** Two buffered bursts from 2026-08-24 alternated
            // for as long as the drain ran: `firstRecord` 12:51:13 / newest 12:52:11, then 12:57:42 /
            // 12:58:41, then the first again. A pairwise guard sees every batch as newer than the one
            // before it; only the drain-wide maximum sees the second pass.
            var alternating = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            var alternatingActions: [HistoricalDrainSession.DrainAction?] = []
            for unix in [oldEpoch, oldEpoch + 360, oldEpoch, oldEpoch + 360, oldEpoch] {
                _ = r18Record(unix: unix).map { alternating.accept($0, now: drainNow) }
                alternatingActions.append(nowMarker.map { alternating.accept($0, now: drainNow) })
            }
            assertTest(
                alternatingActions.prefix(4).allSatisfy { $0 == .acknowledge(token: token) }
                    && alternatingActions[4] == .acknowledgeAndFinish(token: token)
                    && alternating.finishReason == .idleTimeout,
                "Two bursts alternating forever stall on their second pass: the first four batches are "
                    + "acknowledged and the fifth ends the drain — each batch beats the one before it, "
                    + "and the drain-wide maximum is what catches the repeat")

            // **The owner's drain ended here on 2026-10-23.** The last batch carried no records at
            // all, and its marker was stamped now — so the marker fallback declared "caught up" over a
            // buffer whose newest record was 2026-08-26. An empty batch is the end of the buffer, not
            // the present.
            var endOfBuffer = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            _ = r18Record(unix: oldEpoch).map { endOfBuffer.accept($0, now: drainNow) }
            let firstEnd = nowMarker.map { endOfBuffer.accept($0, now: drainNow) }
            let emptyEnd = nowMarker.map { endOfBuffer.accept($0, now: drainNow) }
            assertTest(
                firstEnd == .acknowledge(token: token) && emptyEnd == .acknowledge(token: token),
                "An empty HISTORY_END at the end of the buffer is not the live edge: its marker is "
                    + "stamped now while the newest record the drain has seen is two months old, so the "
                    + "drain keeps listening and ends on the idle window rather than claiming it caught up")

            // ---- The Gen 5 count gate: read, logged, and deliberately not obeyed ----

            /// Any type this build can frame and decode — the histogram counts a frame before it looks
            /// at its revision, so a frame of a type nothing decodes is still evidence of what arrived.
            func typedFrame(type: UInt8) -> WhoopRawFrame? {
                guard let framed = WhoopPacketEncoder5.buildPacket(
                    profile: .whoop5, type: type, seq: 0, cmd: 0,
                    payload: Data(repeating: 0, count: 8))
                else { return nil }
                return decoder.decodeProprietaryFrame(data: framed, profile: .whoop5)
            }

            assertTest(
                HistoricalDrainSession.countedFrameTypes == [47, 48, 50, 53, 54, 55]
                    && !HistoricalDrainSession.countedFrameTypes.contains(49)
                    && !HistoricalDrainSession.countedFrameTypes.contains(51)
                    && !HistoricalDrainSession.countedFrameTypes.contains(52)
                    && HistoricalDrainSession.countedBatchTypes.contains(49),
                "The count gate's membership is **six types — 47, 48, 50, 53, 54, 55 — and not the "
                    + "records**: type 49 is the marker that carries the count, 51/52 are the IMU stream, "
                    + "and getting this wrong is the reference's Groundhog Day equivalent. 49 stays in "
                    + "the logged histogram only so a burst's framing is visible")

            assertTest(
                HistoricalDrainSession.expectedFrameCountPayloadOffset == 6
                    && HistoricalDrainSession.expectedFrameCountPayloadOffset + 4
                        == HistoricalDrainSession.continuationTokenPayloadOffset,
                "…and the declared count is the four bytes immediately before the token: payload 6 is "
                    + "`inner[9]`, the field the Gen 5 reference names `expected_count`. A marker long "
                    + "enough to hold the token is long enough to hold this, so one guard covers both")

            /// One burst: three records, an event, a console-log frame, and a marker declaring `expected`.
            func burst(counting expected: Int) -> HistoricalDrainSession? {
                var session = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
                _ = fiveMarker(cmd: 1, unix: oldEpoch, payloadBytes: 18).map { session.accept($0, now: drainNow) }
                for _ in 0..<3 { _ = r18Record(unix: oldEpoch).map { session.accept($0, now: drainNow) } }
                _ = typedFrame(type: 48).map { session.accept($0, now: drainNow) }
                _ = typedFrame(type: 50).map { session.accept($0, now: drainNow) }
                let end = fiveMarker(cmd: 2, unix: oldEpoch, payloadBytes: 18, expected: expected)
                guard let end else { return nil }
                _ = session.accept(end, now: drainNow)
                return session
            }

            if let agreeing = burst(counting: 5) {
                assertTest(
                    agreeing.lastBurstFrameCounts
                        == HistoricalDrainSession.BurstFrameCounts(expected: 5, counted: 5)
                        && agreeing.lastBurstFrameCounts?.matches == true,
                    "A burst of three records, one event and one console-log frame declares **5**, and "
                        + "the session counts 5 — the three records alone would read 3, which is the "
                        + "undercount this whole change is about, and the HISTORY_START marker in the "
                        + "same burst contributes nothing to either side")
            } else {
                assertTest(false, "The agreeing-count burst could not be built")
            }

            if let short = burst(counting: 8) {
                assertTest(
                    short.lastBurstFrameCounts
                        == HistoricalDrainSession.BurstFrameCounts(expected: 8, counted: 5)
                        && short.lastBurstFrameCounts?.difference == 3,
                    "…while the same burst against a marker declaring **8** is recorded as a shortfall "
                        + "of three — the signature of frames lost in transit, which today is "
                        + "indistinguishable from a complete burst")
                assertTest(
                    short.finishReason != .liveEdge,
                    "**A mismatch is logged and not acted on**: the acknowledgement still goes out as "
                        + "success, so nothing downstream changes until the validator is trusted. This "
                        + "assertion is the one that fails when enforcement lands, which is exactly when "
                        + "it should")
            } else {
                assertTest(false, "The short-count burst could not be built")
            }

            var excluding = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            _ = r18Record(unix: oldEpoch).map { excluding.accept($0, now: drainNow) }
            _ = typedFrame(type: 51).map { excluding.accept($0, now: drainNow) }
            _ = typedFrame(type: 53).map { excluding.accept($0, now: drainNow) }
            if let end = fiveMarker(cmd: 2, unix: oldEpoch, payloadBytes: 18, expected: 2) {
                _ = excluding.accept(end, now: drainNow)
            }
            assertTest(
                excluding.lastBurstFrameCounts
                    == HistoricalDrainSession.BurstFrameCounts(expected: 2, counted: 2),
                "The membership is applied in both directions on the same burst: the type-51 IMU "
                    + "frame is **not** counted, the type-53 frame is — so the number is the "
                    + "reference's six-way rule rather than 'everything that arrived'")

            var fourth = HistoricalDrainSession(profile: .whoop4, startedAt: drainNow)
            // The same bytes a Gen 5 marker would use — on this generation the field at payload 6 is
            // a record-id / batch counter, so a reader that took it for a count would see a burst
            // declaring thousands and refuse every one.
            if let end = fourMarker(cmd: 2, payloadBytes: 18) {
                _ = fourth.accept(end, now: drainNow)
            }
            assertTest(
                fourth.lastBurstFrameCounts == nil
                    && WhoopProtocolProfile.whoop4.declaresBurstFrameCount == false
                    && WhoopProtocolProfile.whoop5.declaresBurstFrameCount
                    && WhoopProtocolProfile.whoop5MG.declaresBurstFrameCount,
                "**The count field is Gen 5's and the gate is off where it is not**: on a 4.0 the "
                    + "same offset is a record-id / batch counter, so nothing is read and nothing is "
                    + "compared — a validator there would refuse every burst the strap sent. Both "
                    + "5.0 profiles declare it, which is what makes the rule follow the envelope")

            // ---- The trim cursor: the token read as the two words the acknowledgement echoes ----

            assertTest(
                HistoricalDrainSession.TrimCursor.decode(token)
                    == HistoricalDrainSession.TrimCursor(
                        trimPage: 0x44332211, wrapCount: 0x88776655),
                "The eight-byte token is two little-endian words — a **trim page** and a **wrap "
                    + "count** — which is what makes a rewind readable: `11 22 33 44 55 66 77 88` "
                    + "decodes to trim `0x44332211`, wrap `0x88776655`")
            assertTest(
                HistoricalDrainSession.TrimCursor.decode(Data([0x01, 0x02])) == nil
                    && HistoricalDrainSession.TrimCursor.decode(Data()) == nil,
                "…and a token of any other length answers `nil` rather than padding a cursor out of "
                    + "bytes that were never sent — the same refusal the marker reader makes")

            var cursored = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            assertTest(cursored.lastTrimCursor == nil, "A session that has seen no marker holds no cursor")
            let firstToken = Data([0x64, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00])
            let secondToken = Data([0x69, 0x00, 0x00, 0x00, 0x18, 0x00, 0x00, 0x00])
            if let first = fiveMarker(
                cmd: 2, unix: oldEpoch, payloadBytes: 18, tokenBytes: firstToken) {
                _ = cursored.accept(first, now: drainNow)
            }
            let firstCursor = cursored.lastTrimCursor
            if let second = fiveMarker(
                cmd: 2, unix: oldEpoch, payloadBytes: 18, tokenBytes: secondToken) {
                _ = cursored.accept(second, now: drainNow)
            }
            assertTest(
                firstCursor == HistoricalDrainSession.TrimCursor(trimPage: 100, wrapCount: 24)
                    && cursored.lastTrimCursor
                        == HistoricalDrainSession.TrimCursor(trimPage: 105, wrapCount: 24),
                "Each burst records **its own** cursor rather than a drain-wide one: a trim page of "
                    + "100 followed by 105 moves forward five, which is the reference's own per-batch "
                    + "advance — and a page that stayed put, or came back, is the rewind the stamps "
                    + "only hint at")

            // ---- R26 is a record and not a clock ----

            /// A type-47 frame with an arbitrary layout selector and payload length, so a revision this
            /// build does not decode can still be fed to the session — which is exactly how it arrives.
            func record(layout: UInt8, unix: UInt32, payloadBytes: Int = 73) -> WhoopRawFrame? {
                var payload = [UInt8](repeating: 0, count: max(payloadBytes, 8))
                payload[4] = UInt8(unix & 0xFF)
                payload[5] = UInt8((unix >> 8) & 0xFF)
                payload[6] = UInt8((unix >> 16) & 0xFF)
                payload[7] = UInt8((unix >> 24) & 0xFF)
                guard let framed = WhoopPacketEncoder5.buildPacket(
                    profile: .whoop5,
                    type: WhoopProtocolProfile.whoop5.packetTypes.historicalData,
                    seq: layout, cmd: 0, payload: Data(payload))
                else { return nil }
                return decoder.decodeProprietaryFrame(data: framed, profile: .whoop5)
            }

            assertTest(
                HistoricalDrainSession.timestampedLayouts == [18, 21, 24]
                    && !HistoricalDrainSession.timestampedLayouts.contains(26),
                "**Only the 1 Hz layouts are allowed to be the clock** — R18, R21 and the 4.0's type 24 "
                    + "— while `R26`, the Pulse Information Packet, is a record whose own time is an "
                    + "event time rather than a slot on the grid")

            if let r26 = record(layout: 26, unix: nowEpoch) {
                assertTest(
                    HistoricalDrainSession.recordTimestamp(r26) == nil,
                    "…so an `R26` record yields **no stamp at all**, even with a perfectly good unix "
                        + "sitting in the bytes every other layout keeps its clock in — measured on "
                        + "2026-10-26, where one stamped 00:18:04 arrived after a batch that had "
                        + "reached 00:18:43 and the drain logged a stall that was not one")
            } else {
                assertTest(false, "The R26 record could not be built")
            }

            var r26Bursts = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            _ = r18Record(unix: oldEpoch).map { r26Bursts.accept($0, now: drainNow) }
            var r26Actions: [HistoricalDrainSession.DrainAction?] = []
            for _ in 0..<4 {
                _ = record(layout: 26, unix: oldEpoch).map { r26Bursts.accept($0, now: drainNow) }
                r26Actions.append(nowMarker.map { r26Bursts.accept($0, now: drainNow) })
            }
            assertTest(
                r26Actions.allSatisfy { $0 == .acknowledge(token: token) }
                    && r26Bursts.finishReason == nil,
                "**Four `R26`-only bursts do not stall a drain that is advancing.** Their stamps would "
                    + "all sit behind the 1 Hz record that opened it, and three consecutive stalls end "
                    + "a drain as `.idleTimeout` — a fuse, not a log line, so a night with a few of "
                    + "these packets would stop a good drain and call it stalled")
            assertTest(
                r26Bursts.recordCount == 5,
                "…while the `R26` frames still **count**: five records reached the session, so the "
                    + "revision is refused as a clock and not discarded as data "
                    + "(\(r26Bursts.recordCount))")

            var r26Edge = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            // A 1 Hz batch first, so the drain has a position to fall back to — the marker is only the
            // fallback for a session that has seen no record at all, and that is a separate rule.
            _ = r18Record(unix: oldEpoch).map { r26Edge.accept($0, now: drainNow) }
            _ = fiveMarker(cmd: 2, unix: oldEpoch, payloadBytes: 18)
                .map { r26Edge.accept($0, now: drainNow) }
            _ = record(layout: 26, unix: nowEpoch).map { r26Edge.accept($0, now: drainNow) }
            assertTest(
                nowMarker.map { r26Edge.accept($0, now: drainNow) } == .acknowledge(token: token)
                    && r26Edge.finishReason == nil,
                "…and an `R26` stamped **now** does not declare the live edge: read as a 1 Hz record "
                    + "it would make a burst of one end a drain whose backlog is still behind it, which "
                    + "is the same field trusted in the wrong direction")

            var counting = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            _ = r18Record(unix: oldEpoch).map { counting.accept($0, now: drainNow) }
            _ = record(layout: 26, unix: oldEpoch).map { counting.accept($0, now: drainNow) }
            if let end = fiveMarker(
                cmd: 2, unix: oldEpoch, payloadBytes: 18, expected: 2) {
                _ = counting.accept(end, now: drainNow)
            }
            assertTest(
                counting.lastBurstFrameCounts
                    == HistoricalDrainSession.BurstFrameCounts(expected: 2, counted: 2),
                "An `R26` frame counts toward the burst's declared total as one type-47 frame — the "
                    + "count gate and the clock are two different questions about the same record")

            // ---- A batch that starts at or before the last one is flagged where it happens ----

            var repeatCheck = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            var repeatFlags: [Bool?] = []
            // Forward, forward, **repeat**, **backwards** — the two shapes the 2026-10-25 capture
            // showed, fed as batches rather than left to be spotted in a log.
            for unix in [oldEpoch, oldEpoch + 60, oldEpoch + 60, oldEpoch + 30] {
                _ = r18Record(unix: unix).map { repeatCheck.accept($0, now: drainNow) }
                _ = fiveMarker(cmd: 2, unix: oldEpoch, payloadBytes: 18)
                    .map { repeatCheck.accept($0, now: drainNow) }
                repeatFlags.append(repeatCheck.lastBatchRepeatedStart)
            }
            assertTest(
                repeatFlags == [false, false, true, true]
                    && repeatCheck.repeatedStartBatchCount == 2,
                "**A batch that begins at or before the previous batch's first record sets `repeat` "
                    + "on its own line**, so a rewind is a flag in the capture rather than two lines "
                    + "that have to be found and compared — the reading that a rotation can separate "
                    + "into different files and a paste can truncate away "
                    + "(\(repeatFlags.map { $0.map { $0 ? "repeat" : "forward" } ?? "nil" }), "
                    + "count \(repeatCheck.repeatedStartBatchCount))")
            assertTest(
                repeatCheck.startedAt == drainNow,
                "…and the session keeps **the instant it started**, which is what the closing "
                    + "`DRAIN_END` summary reports: a night's per-batch lines can rotate out of the "
                    + "capture file, and the line that says when the drain began must not")

            // ---- The capture log this file writes to is not the developer's Documents ----

            let documents = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)[0]
            assertTest(
                FileManager.default.fileExists(atPath: CaptureLog.shared.url.path)
                    && !CaptureLog.shared.url.path.hasPrefix(documents.path),
                "**The suite's `DRAIN_BATCH` lines land in a scratch file, not in `.documentDirectory`.** "
                    + "Every marker above appended one, and on a host build that search path is a "
                    + "general user folder rather than the app's sandbox — measured on 2026-10-26, "
                    + "where a run appended fixture batches beside the person's own files and rotated "
                    + "the previous one out of the way. `WHOOPSY_CAPTURE_DIR` is what `scripts/test.sh` "
                    + "points into `tmp/` (\(CaptureLog.shared.url.path))")
        }


        do {
            let fourIdle = drainNow.addingTimeInterval(8)
            var four = HistoricalDrainSession(profile: .whoop4, startedAt: drainNow)
            var five = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            assertTest(
                four.idleTimeoutSeconds == 8 && five.idleTimeoutSeconds == 60
                    && HistoricalDrainSession(profile: .whoop5MG, startedAt: drainNow)
                        .idleTimeoutSeconds == 60,
                "The idle window is the generation's own — 8 s for the 4.0 and 60 s for the 5.0 and the "
                    + "MG — read off the profile rather than passed in, so a caller cannot pair a 5.0 "
                    + "window with a 4.0 drain. Both are reported figures from §4 and neither is measured")
            assertTest(
                !four.checkIdleTimeout(now: drainNow.addingTimeInterval(7.9)) && four.finishReason == nil,
                "A tenth of a second short of the 4.0's window the drain is still running")
            assertTest(
                four.checkIdleTimeout(now: fourIdle) && four.finishReason == .idleTimeout,
                "…and at eight seconds it stops with the reason **recorded** rather than inferred: 'the "
                    + "strap said it was done' and 'we gave up waiting' are different facts about the same "
                    + "drain, and a screen reporting a sync needs to tell them apart")
            assertTest(
                !four.checkIdleTimeout(now: drainNow.addingTimeInterval(600)),
                "A finished session does not time out twice: the reason is set once, so a caller polling "
                    + "it in a loop sees a single transition rather than one per tick")
            assertTest(
                !five.checkIdleTimeout(now: fourIdle),
                "The same eight seconds does not time out a 5.0, whose window is sixty — the pair is what "
                    + "says the window came off the profile rather than being a constant this app holds")
            assertTest(
                five.checkIdleTimeout(now: drainNow.addingTimeInterval(60))
                    && five.finishReason == .idleTimeout,
                "…and sixty seconds does")

            // Re-arming: the window measures from the last activity, not from the start.
            var rearmed = HistoricalDrainSession(profile: .whoop4, startedAt: drainNow)
            if let marker = fourMarker(cmd: 2, payloadBytes: 18) {
                _ = rearmed.accept(marker, now: drainNow.addingTimeInterval(7))
            }
            assertTest(
                !rearmed.checkIdleTimeout(now: drainNow.addingTimeInterval(14)),
                "A batch at seven seconds re-arms the window, so fourteen seconds from the start is seven "
                    + "from the last frame and the drain runs on — without the re-arm this is a timeout, "
                    + "and a drain that gave up between two batches of a slow strap would report a partial "
                    + "history as a complete one")
            assertTest(
                rearmed.checkIdleTimeout(now: drainNow.addingTimeInterval(15.1)),
                "…and it does time out at fifteen, which is eight seconds after that batch")
        }

        do {
            // A drain the strap finished, then disconnected. `CLAUDE.md`'s rule for `conclude(_:)`: the
            // session's own reason wins, because a completed sync reported as an interrupted one prints
            // its record count as what was fetched before giving up.
            var finished = HistoricalDrainSession(profile: .whoop5, startedAt: drainNow)
            if let complete = fiveMarker(cmd: 3, unix: oldEpoch, payloadBytes: 18) {
                _ = finished.accept(complete, now: drainNow)
            }
            finished.abort()
            assertTest(
                finished.finishReason == .complete && finished.isFinished,
                "A drain the strap declared complete stays complete when the link then drops — `abort()` "
                    + "cannot relabel it — and an idle timeout cannot either, since a finished session "
                    + "answers `false` to the poll")
        }

        // MARK: The generation-agnostic dispatch

        do {
            let fourEnable = WhoopCommandFrames.motionEnableSequence(profile: .whoop4, seq: 0x30)
            let fiveEnable = WhoopCommandFrames.motionEnableSequence(profile: .whoop5, seq: 0x30)
            assertTest(
                fourEnable.count == 3 && fiveEnable.count == 2,
                "The façade routes by envelope rather than by whichever opcode table is non-`nil`: three "
                    + "frames for the 4.0 and two for the 5.0, which is what makes the manager's enable "
                    + "call site generation-agnostic — got \(fourEnable.count) and \(fiveEnable.count)")
            assertTest(
                fourEnable.map { $0[6] } == [0x6A, 0x3F, 0x6B]
                    && fiveEnable.map { $0[10] } == [0x51, 0x6A],
                "…and each sequence is its own builder's: the 4.0's opcodes sit at frame byte 6 and the "
                    + "5.0's at byte 10, four bytes apart, because the two envelopes put the inner record "
                    + "at different origins. A router that reached for the wrong table could not produce "
                    + "both of these shapes")

            // **The seek, which the drain was missing entirely.** The request carries no window, so the
            // read cursor is the only thing that says where a drain starts — and without moving it a
            // strap that has been streaming answers from the live edge. Measured across five drains on
            // five drains over two days: ~58 records, one batch, about a minute, every time.
            let fourRewind = WhoopCommandFrames.rewindReadPointer(profile: .whoop4, seq: 2)
            let fiveRewind = WhoopCommandFrames.rewindReadPointer(profile: .whoop5, seq: 2)
            assertTest(
                fourRewind?[6] == 0x21 && fiveRewind?[10] == 0x21,
                "`SET_READ_POINTER` is command **33 / 0x21** under both envelopes, so the seek is one "
                    + "byte in either table")
            assertTest(
                fourRewind.map { Array($0[7..<11]) } == [0x00, 0x00, 0x00, 0x00] && fourRewind?.count == 15
                    && fiveRewind.map { Array($0[11..<15]) } == [0x00, 0x00, 0x00, 0x00]
                    && fiveRewind?.count == 19,
                "…carrying a **u32 little-endian byte offset of 0** and nothing else — the rewind to the "
                    + "oldest record the strap holds. 15 and 19 bytes are `header + 3 + 4 + 4`, the pair "
                    + "that fails if the offset changes width on one builder only")
            assertTest(
                WhoopCommandFrames.rewindReadPointer(profile: .whoop4, seq: 2, offset: 0x0800_0000)
                    .map { Array($0[7..<11]) } == [0x00, 0x00, 0x00, 0x08],
                "…and a non-zero offset is little-endian at the same origin, so the builder can seek to a "
                    + "known position rather than only rewinding")

            let fourRequest = WhoopCommandFrames.historicalSyncRequest(profile: .whoop4, seq: 1)
            let fiveRequest = WhoopCommandFrames.historicalSyncRequest(profile: .whoop5, seq: 1)
            assertTest(
                fourRequest?[6] == 0x16 && fiveRequest?[10] == 0x16,
                "Both generations' drain request is `0x16 SEND_HISTORICAL_DATA` — the same byte, written "
                    + "in different radixes by the two references — so this is the one drain opcode the "
                    + "4.0's correction and the 5.0's table agree on")
            // **The body is one `00` byte on both, and this block used to pin an eight-byte window.**
            // Four sources agree and this app was alone against them: noop's implemented
            // `send(.sendHistoricalData, payload: [0x00])`, noop's command doc ("observed working in
            // device captures on 41.17.6.0"), OpenStrap's `build_command(…, b"\x00")`, and the captured
            // vector `aa0800a823041600c7c25288` that same file annotates `0x16 [00]`.
            //
            // **The two whole-frame lengths are not equal, and that is the pair worth pinning**: 12 and 16
            // differ by exactly the four extra header bytes the 5.0 envelope spends on its declared length
            // and CRC16. Both are `header + 3 + 1 + 4`, so an eight-byte body puts them at 19 and 23 — and
            // the lengths are what catch a body that changed width on only one of the two builders.
            assertTest(
                fourRequest.map { Array($0[7..<8]) } == [0x00] && fourRequest?.count == 12
                    && fiveRequest.map { Array($0[11..<12]) } == [0x00] && fiveRequest?.count == 16,
                "…carrying a single `00` at each envelope's own payload origin, and nothing else. The "
                    + "eight-byte `[u32 start][u32 end]` window this used to assert was this app's own "
                    + "invention: the only eight-byte start/end-shaped value either reference holds is "
                    + "`HISTORY_END`'s token, which noop calls opaque. A body of 1 byte is the whole "
                    + "difference — got \(fourRequest?.count ?? -1) and \(fiveRequest?.count ?? -1) bytes "
                    + "against 12 and 16")

            let fourAck = WhoopCommandFrames.historicalDataAck(
                profile: .whoop4, seq: 2, token: token)
            let fiveAck = WhoopCommandFrames.historicalDataAck(
                profile: .whoop5, seq: 2, token: token)
            assertTest(
                fourAck?[6] == 0x17 && fiveAck?[10] == 0x17
                    && fourAck.map { Array($0[7..<16]) } == [0x01] + Array(token)
                    && fiveAck.map { Array($0[11..<20]) } == [0x01] + Array(token),
                "The ACK is `[0x01] + the token` on both — the success status byte then the eight bytes "
                    + "the marker carried, at each envelope's own origin. **Without this frame the strap "
                    + "re-sends the same batch forever**, which is why the request byte above waited for "
                    + "the loop rather than the other way round")
            assertTest(
                WhoopCommandFrames.historicalDataAck(profile: .whoop5, seq: 2, token: Data([0x01])) == nil
                    && WhoopCommandFrames.historicalDataAck(
                        profile: .whoop4, seq: 2, token: Data(repeating: 0, count: 9)) == nil,
                "…and a token that is not eight bytes is refused rather than padded or truncated: a short "
                    + "one would be a different record rather than a rejected ACK")

            // The drain's abort is asserted in §16's table block, where the two generations are compared
            // against each other and against the published numbers — it is one byte on both generations,
            // so it is a claim about the tables rather than about the façade.
        }

        do {
            // 1_700_000_000 = 0x6553F100, so the wire reads 00 F1 53 65 little-endian.
            let epochBytes: [UInt8] = [0x00, 0xF1, 0x53, 0x65]
            let fourClock = WhoopCommandFrames.setClockFrames(
                profile: .whoop4, seq: 4, epochSeconds: 1_700_000_000)
            let fiveClock = WhoopCommandFrames.setClockFrames(
                profile: .whoop5, seq: 4, epochSeconds: 1_700_000_000)
            assertTest(
                fourClock.count == 2 && fourClock[0].count == 19 && fourClock[1].count == 20,
                "The 4.0 takes two clock forms and **both are sent** — an 8-byte payload and a 9-byte one, "
                    + "so 19 and 20 bytes — because a wrong-length set is acknowledged but not latched and "
                    + "each is a no-op on the other's firmware. Published clients disagree on the length, "
                    + "which is what makes sending both safer than choosing. Got "
                    + "\(fourClock.map(\.count))")
            assertTest(
                fourClock.count == 2
                    && Array(fourClock[0][7..<11]) == epochBytes
                    && Array(fourClock[1][7..<11]) == epochBytes,
                "…and the two forms agree on the four bytes they share: the epoch, little-endian, at each "
                    + "one's payload origin")
            assertTest(
                fourClock.count == 2 && fourClock[0][5] == 4 && fourClock[1][5] == 5,
                "…as two records rather than one sent twice, which is what the differing seq says")
            assertTest(
                fiveClock.count == 2
                    && fiveClock[0].count == 23 && fiveClock[1].count == 24
                    && Array(fiveClock[0][11..<15]) == epochBytes
                    && Array(fiveClock[0][15..<19]) == [0x00, 0x00, 0x00, 0x00]
                    && Array(fiveClock[1][11..<15]) == epochBytes,
                "The 5.0 now takes **both** lengths too — the 8-byte `[u32 epoch LE][u32 0]` and the "
                    + "9-byte legacy form — because the 8-byte one was measured *not latching* on a real "
                    + "5.0: written confirmed, acknowledged, and the RTC stayed at 2000-01-03, read off "
                    + "the motion record's own clock field. The two are 23 and 24 bytes and share the "
                    + "epoch at their payload origin. Got \(fiveClock.map(\.count))")
            assertTest(
                fiveClock.count == 2 && fiveClock[0][9] == 4 && fiveClock[1][9] == 5,
                "…and they are two records rather than one sent twice, which is what the differing seq "
                    + "says — the second is a no-op if the firmware takes the first")
            let fourReadBack = WhoopCommandFrames.clockReadBack(profile: .whoop4, seq: 5)
            assertTest(
                fourReadBack?[6] == 0x0B
                    && WhoopCommandFrames.clockReadBack(profile: .whoop5, seq: 5)?[10] == 0x0B,
                "The clock's read-back exists on **both** generations and is command **11** on both — "
                    + "the same byte in two envelopes, which is what makes the number a claim about the "
                    + "command rather than about the strap. **Sending it is not checking it**: the reply "
                    + "is logged raw and nothing decodes it, so no path here may claim a clock latched; "
                    + "what the pair buys is that a capture sees both sides of it")
        }
    }
}
