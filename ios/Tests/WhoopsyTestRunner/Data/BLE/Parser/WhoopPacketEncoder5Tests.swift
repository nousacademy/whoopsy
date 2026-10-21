import Foundation
import Whoopsy

// MARK: - 16. The 5.0 command frames, read off the bytes

/// A file of §16's body, cut at the section's own `// MARK:` topic boundary and moved
/// verbatim. `StepTests.run()` calls it, in the order the section ran it in.
enum WhoopPacketEncoder5Tests {
    static func run() async throws {
        // MARK: The published 5.0 command frame

        /// `AA 01 0C 00 00 01 E7 41 23 F1 6A 01 01 00 00 00 58 E9 61 FC`, from `docs/BLE_PROTOCOL.md` §2.1.
        ///
        /// **The only test vector either generation's command path has, and it is worth more than every
        /// other assertion in this section.** Everything else in the two builders is internally consistent
        /// arithmetic — a CRC16 that agrees with the decoder's, a length that agrees with the profile's —
        /// and self-consistency is exactly the trap `CLAUDE.md` records against the 4.0's original
        /// checksum assertions, where a wrong polynomial, a wrong byte order *and* a wrong input all
        /// passed. This frame came from a capture somebody else took, so a wrong polynomial, a wrong
        /// coverage, a wrong length offset, or the two reserved header bytes computed instead of copied
        /// each move a byte here and nowhere else.
        let publishedFiveCommand = Data([
            0xAA, 0x01, 0x0C, 0x00, 0x00, 0x01, 0xE7, 0x41, 0x23, 0xF1,
            0x6A, 0x01, 0x01, 0x00, 0x00, 0x00, 0x58, 0xE9, 0x61, 0xFC,
        ])

        func hex(_ bytes: Data) -> String {
            bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }

        do {
            let built = WhoopPacketEncoder5.buildPacket(
                profile: .whoop5, type: 35, seq: 0xF1, cmd: 0x6A,
                payload: Data([0x01, 0x01, 0x00, 0x00, 0x00]))
            assertTest(
                built == publishedFiveCommand,
                "The 5.0 builder reproduces §2.1's published command frame byte-for-byte — got "
                    + "\(built.map(hex) ?? "nil"), want \(hex(publishedFiveCommand))")

            let staticHello = Data([
                0xAA, 0x01, 0x08, 0x00, 0x00, 0x01, 0xE6, 0x71, 0x23, 0x01,
                0x91, 0x01, 0x36, 0x3E, 0x5C, 0x8D,
            ])
            assertTest(
                WhoopPacketEncoder5.hello(profile: .whoop5, seq: 1) == staticHello
                    && WhoopPacketEncoder5.hello(profile: .whoop5MG, seq: 1) == staticHello,
                "…and the sixteen-byte static CLIENT_HELLO does too, under both 5.0 profiles: a declared "
                    + "length of 8, a crc16 of 0x71E6 and a one-byte `0x01` payload, none of which the "
                    + "command frame's arithmetic pins — got "
                    + "\(WhoopPacketEncoder5.hello(profile: .whoop5, seq: 1).map(hex) ?? "nil")")

            // The other direction: the app's decoder has to read the published bytes back as the fields
            // the builder was asked for. Without this the two could agree on a framing that means
            // something else entirely — the frame would round-trip and the *offsets* would be wrong.
            let decodedPublished = decoder.decodeProprietaryFrame(
                data: publishedFiveCommand, profile: .whoop5)
            assertTest(
                decodedPublished?.type == 35 && decodedPublished?.seq == 0xF1
                    && decodedPublished?.cmd == 0x6A
                    && decodedPublished?.payload == Data([0x01, 0x01, 0x00, 0x00, 0x00]),
                "…and the decoder reads that same frame back as type 35, seq 0xF1, cmd 0x6A and the "
                    + "five-byte parameter block, so both halves of this app are pinned to a third party's "
                    + "bytes rather than only to each other")

            // The counterpart to §1's four "each 4.0 builder refuses a 5.0 profile" assertions, and the
            // one that was missing while the 5.0 opcode table did not exist. Every entry point is here
            // because a single shared gate is a claim about the gate, not about the entries.
            assertTest(
                WhoopPacketEncoder5.buildPacket(profile: .whoop4, type: 35, seq: 1, cmd: 0x6A) == nil
                    && WhoopPacketEncoder5.hello(profile: .whoop4, seq: 1) == nil
                    && WhoopPacketEncoder5.setClock(profile: .whoop4, seq: 1, epochSeconds: 0) == nil
                    && WhoopPacketEncoder5.getClock(profile: .whoop4, seq: 1) == nil
                    && WhoopPacketEncoder5.getDataRange(profile: .whoop4, seq: 1) == nil
                    && WhoopPacketEncoder5.historicalSyncRequest(profile: .whoop4, seq: 1) == nil
                    && WhoopPacketEncoder5.historicalDataAck(
                        profile: .whoop4, seq: 1, token: Data(repeating: 0, count: 8)) == nil
                    && WhoopPacketEncoder5.motionEnableSequence(profile: .whoop4, seq: 1).isEmpty,
                "The 5.0 builder refuses a 4.0 profile on **every** entry point, not merely on the one "
                    + "`buildPacket` gate they share: 4.0 opcodes under a 5.0 envelope are a different "
                    + "message rather than a rejected one, and the two tables share field names while "
                    + "holding different bytes, so a builder that read the other table would produce a "
                    + "frame this app cannot even decode")
        }

        // MARK: The 5.0 enable sequence, read off the bytes

        do {
            let enable = WhoopPacketEncoder5.motionEnableSequence(profile: .whoop5, seq: 0x20)
            assertTest(
                enable.count == 2,
                "The 5.0 IMU enable is two frames — start raw data, then the toggle — got \(enable.count)")
            // Under this envelope the inner record starts at byte 8, so `cmd` is byte 10: 8 header bytes
            // then `type`, `seq`, `cmd`. That is four bytes later than the 4.0's byte 6, and it is the
            // offset a reader porting the 4.0 block above would get wrong.
            assertTest(
                enable.map { $0[10] } == [0x51, 0x6A],
                "The sequence is `0x51 START_RAW_DATA` then `0x6A TOGGLE_IMU_MODE` — the producer before "
                    + "the sensor it reads — with the opcodes read off the frame rather than trusted from "
                    + "the builder: got \(enable.map { String(format: "0x%02X", $0[10]) })")
            assertTest(
                enable.map { $0[9] } == [0x20, 0x21],
                "Each frame carries its own inner seq, because a shared one would say two records were one "
                    + "— got \(enable.map { $0[9] })")
            assertTest(
                enable.allSatisfy { $0[8] == 35 } && enable.allSatisfy { $0[0] == 0xAA && $0[1] == 0x01 },
                "…and both are command-typed under the 5.0 envelope, rather than one of them being a "
                    + "4.0-framed record that happens to sit in the same array")
            // Sizes: declaredLength = 3 + payload + 4, and the frame is 8 + declaredLength. So a bare
            // frame is 15 bytes and the five-byte toggle payload makes 20 — which is exactly §2.1's frame.
            assertTest(
                enable[0].count == 15,
                "`0x51` is sent bare — 15 bytes — because the reference names the opcode and stops, and an "
                    + "invented payload would be an invented wire format. Got \(enable[0].count)")
            assertTest(
                enable[1].count == 20
                    && Array(enable[1][11..<16]) == [0x01, 0x01, 0x00, 0x00, 0x00],
                "The `0x6A` toggle carries §2.1's published five-byte enable payload `01 01 00 00 00`, "
                    + "which reconciles §6's two-byte shorthand `[1, 1]` with the frame actually captured "
                    + "— got \(Array(enable[1].dropFirst(11)))")

            // **The published frame is the enable's second half.** Running the sequence one seq earlier
            // makes its toggle frame byte-identical to §2.1's capture, which is what says the published
            // payload is the enable form rather than this app's reading of one — and it is the same
            // fixture, not a second copy of the bytes.
            let publishedSequence = WhoopPacketEncoder5.motionEnableSequence(
                profile: .whoop5, seq: 0xF0)
            assertTest(
                publishedSequence.count == 2 && publishedSequence[1] == publishedFiveCommand,
                "Run at seq 0xF0, the enable's second frame **is** §2.1's published frame — got "
                    + "\(publishedSequence.count == 2 ? hex(publishedSequence[1]) : "\(publishedSequence.count) frames")")

            let stop = WhoopPacketEncoder5.motionEnableSequence(profile: .whoop5, seq: 0x20, enable: false)
            assertTest(
                stop.count == 2 && stop.map { $0[10] } == [0x52, 0x6A],
                "Stopping is the same two verbs the other way round — `0x52` then the toggle — so the "
                    + "producer is released before the IMU is switched and neither direction leaves the "
                    + "sensor running with nothing consuming it. Got "
                    + "\(stop.map { String(format: "0x%02X", $0[10]) })")
            assertTest(
                stop[1].count == 20 && Array(stop[1][11..<16]) == [0x01, 0x00, 0x00, 0x00, 0x00],
                "…and the toggle's stop form is the published enable payload with its flag cleared, not a "
                    + "second invented payload: byte 0 stays `01` and byte 1 is §6's `0` — got "
                    + "\(Array(stop[1].dropFirst(11)))")
            assertTest(
                WhoopPacketEncoder5.motionEnableSequence(profile: .whoop5MG, seq: 0x20).count == 2
                    && WhoopPacketEncoder5.motionEnableSequence(profile: .whoop5MG, seq: 0x20)[1]
                        == enable[1],
                "The MG follows the 5.0 frame for frame, because §2 gives the two one envelope: a "
                    + "generation-specific difference between them here would be a difference nobody "
                    + "documented")
        }

        // MARK: Haptics — the 4.0's pattern 79 and the 5.0's remapped 0x13

        let fourHaptics = WhoopCommandFrames.hapticsPattern(
            profile: .whoop4, seq: 0x30, pattern: 2, loops: 3)
        assertTest(
            fourHaptics?[6] == 0x4F
                && fourHaptics.map { Array($0[7..<12]) } == [0x02, 0x03, 0x00, 0x00, 0x00],
            "The 4.0's buzz is command **79 `0x4F`** with `[pattern, loops, 0, 0, 0]` — five body bytes, "
                + "the two trailing zeroes included because the observed body carries them rather than "
                + "because this builder pads — got \(fourHaptics.map { "0x" + String($0[6], radix: 16) } ?? "nil") "
                + "with \(fourHaptics.map { Array($0.dropFirst(7)) } ?? [])")
        assertTest(
            WhoopCommandFrames.hapticsPattern(
                profile: .whoop4, seq: 0x30, pattern: 2, loops: 3) != nil
                && WhoopCommandFrames.hapticsPattern(
                    profile: .whoop5, seq: 0x30, pattern: 2, loops: 3) != nil,
            "…and the façade builds one on both generations, which is the whole point of the remap: a "
                + "caller asks for a buzz without knowing which envelope will carry it")
        assertTest(
            WhoopPacketEncoder.runHapticsPattern(profile: .whoop5, seq: 0x30, pattern: 2, loops: 3) == nil
                && WhoopPacketEncoder5.hapticsNotification(profile: .whoop4, seq: 0x30, loops: 3) == nil,
            "**Neither builder frames the other generation**, and the refusal is not symmetry for its "
                + "own sake: `0x4F` under the CRC16 envelope and `0x13` under the CRC8 one are different "
                + "commands rather than one command in a different container")

        let fiveHaptics = WhoopCommandFrames.hapticsPattern(
            profile: .whoop5, seq: 0x30, pattern: 2, loops: 3)
        assertTest(
            fiveHaptics?[10] == 0x13,
            "The 5.0's buzz is **opcode 0x13**, a remap of catalog pattern 79 rather than 79 itself: a "
                + "real MG answers 79 with result `0x03` (unsupported). A build that sent 79 under this "
                + "envelope would look correct and never vibrate — got "
                + "\(fiveHaptics.map { "0x" + String($0[10], radix: 16) } ?? "nil")")
        assertTest(
            fiveHaptics.map { Array($0[11..<23]) }
                == [0x01, 0x2F, 0x98, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02],
            "…and its twelve-byte notification preset is exactly `[01] + [2F 98 00×6] + [00 00] + "
                + "[loops − 1]`: the effects are the captured body's own and `overallLoop` is 2 for "
                + "three plays, which is the reference's one-shot convention rather than a repeat count "
                + "this app chose — got \(fiveHaptics.map { Array($0.dropFirst(11)) } ?? [])")
        assertTest(
            WhoopCommandFrames.hapticsPattern(profile: .whoop5, seq: 0x30, pattern: 1, loops: 3)
                == WhoopCommandFrames.hapticsPattern(profile: .whoop5, seq: 0x30, pattern: 9, loops: 3),
            "…and a 5.0 ignores the `pattern` argument entirely, because the captured body names its "
                + "effects itself and a caller-chosen catalog id has nowhere to go — this is why the "
                + "façade documents `pattern` as 4.0-only rather than silently dropping it")
        assertTest(
            WhoopCommandFrames.hapticsPattern(profile: .whoop4, seq: 0x30, pattern: 2, loops: 0) == nil
                && WhoopCommandFrames.hapticsPattern(profile: .whoop5, seq: 0x30, pattern: 2, loops: 0) == nil,
            "A zero loop count is refused on both: `overallLoop = loops − 1` would underflow to 255 and "
                + "ask for 256 plays where the caller asked for none")
    }
}
