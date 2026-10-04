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
        /// at payload 4, and the token at payload 6 — which is **frame 17**, the offset §4 writes as
        /// payload `[6,14)` for this generation.
        ///
        /// Built by the real encoder and read back through the real decoder, so the session is fed a frame
        /// this app actually produced. A `WhoopRawFrame` assembled by hand would let the token's offset and
        /// the session's agree while both were wrong about the envelope.
        func fiveMarker(cmd: UInt8, unix: UInt32, payloadBytes: Int) -> WhoopRawFrame? {
            var payload = [UInt8](repeating: 0, count: max(payloadBytes, 4))
            payload[0] = UInt8(unix & 0xFF)
            payload[1] = UInt8((unix >> 8) & 0xFF)
            payload[2] = UInt8((unix >> 16) & 0xFF)
            payload[3] = UInt8((unix >> 24) & 0xFF)
            for (offset, byte) in token.enumerated() where 6 + offset < payload.count {
                payload[6 + offset] = byte
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

        // **§4 states the token twice and the two statements are one field**, which is the whole reason a
        // single session type serves both generations. The assertion is on the derivation rather than on
        // the number, so an edit that hardcodes either generation's payload offset fails here.
        assertTest(
            HistoricalDrainSession.continuationTokenFrameOffset == 17
                && WhoopProtocolProfile.whoop4.innerOrigin + 13 == 17
                && WhoopProtocolProfile.whoop5.innerOrigin
                    + WhoopProtocolProfile.whoop5.innerPrefixBytes + 6 == 17,
            "The token is frame byte 17 on both generations — the 4.0's `inner[13:21]` is 4 + 13 and the "
                + "5.0's payload `[6,14)` is 11 + 6 — because the two payload origins are four bytes "
                + "apart. A reader built on either offset literally is correct for exactly one strap")

        do {
            let start = fiveMarker(cmd: 1, unix: oldEpoch, payloadBytes: 14)
            let end = fiveMarker(cmd: 2, unix: oldEpoch, payloadBytes: 14)
            let complete = fiveMarker(cmd: 3, unix: oldEpoch, payloadBytes: 14)
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
                    "HISTORY_END asks for the token back: the action carries the eight bytes at frame 17 "
                        + "and nothing else, and it is the only frame in the loop that is answered")
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
            // A marker one byte short of holding a token. §4's point is that a *wrong* token is worse
            // than none — it leaves the strap re-sending while this app believes it answered — so a short
            // marker must produce no acknowledgement at all rather than a padded or truncated one.
            let shortFive = fiveMarker(cmd: 2, unix: oldEpoch, payloadBytes: 13)
            let shortFour = fourMarker(cmd: 2, payloadBytes: 17)
            assertTest(
                shortFive != nil && shortFour != nil,
                "A 13-byte 5.0 marker and a 17-byte 4.0 one each frame and decode — one byte short of the "
                    + "14 and 18 their tokens need, which is what makes the pair below about the token "
                    + "rather than about a frame that failed to validate")
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
                    "…and its token comes back from the same eight frame bytes the 5.0's does, though §4 "
                        + "writes one as `inner[13:21]` and the other as payload `[6,14)`: this is the "
                        + "assertion that fails if anyone re-derives the offset per generation")

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
                    cmd: 2, unix: UInt32(Int64(epochs) + Int64(offset)), payloadBytes: 14)
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
            if let complete = fiveMarker(cmd: 3, unix: oldEpoch, payloadBytes: 14) {
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
                fiveClock.count == 1 && fiveClock[0].count == 23
                    && Array(fiveClock[0][11..<15]) == epochBytes
                    && Array(fiveClock[0][15..<19]) == [0x00, 0x00, 0x00, 0x00],
                "The 5.0 takes one form and gets one frame: `0x92` with `[u32 epoch LE][u32 0]`, where "
                    + "the 4.0's newer form spends the second word on a subsecond unit this app never sets")
            assertTest(
                WhoopCommandFrames.clockReadBack(profile: .whoop4, seq: 5) == nil
                    && WhoopCommandFrames.clockReadBack(profile: .whoop5, seq: 5)?[10] == 0x93,
                "The clock's read-back exists on one generation only — neither reference gives the 4.0 "
                    + "one, so asking gets `nil` rather than a command this app invented. **Sending it is "
                    + "not checking it**: nothing in this app decodes the reply, so no path here may claim "
                    + "a clock latched; what the pair buys is that a capture sees both sides of it")
        }
    }
}
