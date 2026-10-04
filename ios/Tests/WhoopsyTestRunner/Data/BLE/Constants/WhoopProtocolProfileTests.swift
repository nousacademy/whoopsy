import Foundation
import Whoopsy

// MARK: - 16. The two opcodes that must never be transmitted

/// A file of §16's body, cut at the section's own `// MARK:` topic boundary and moved
/// verbatim. `StepTests.run()` calls it, in the order the section ran it in.
enum WhoopProtocolProfileTests {
    static func run() async throws {
        // MARK: The two opcodes that must never be transmitted

        /// Every opcode a profile transmits, by field name.
        ///
        /// **Both tables, and every field of each.** This used to read `commandOpcodes` alone, which was
        /// complete while the 4.0 was the only generation with a set — and became a hole the moment the
        /// 5.0 got one, because the sweep below would then have run over an *empty* dictionary for two of
        /// the three straps and passed vacuously. The failure mode is exactly the one the block exists to
        /// prevent: a destructive opcode added to `SyncOpcodes` and never checked.
        ///
        /// The keys are prefixed because the two tables share field *names* while holding different bytes —
        /// `requestHistoricalSync` is `0x16` in both, `setClock` is `0x0A` against `0x92` — so an unprefixed
        /// merge would silently drop one of a colliding pair.
        func transmittedOpcodes(_ profile: WhoopProtocolProfile) -> [String: UInt8] {
            var table: [String: UInt8] = [:]
            if let four = profile.commandOpcodes {
                table["4.0.liveTelemetry"] = four.liveTelemetry
                table["4.0.hapticAlarm"] = four.hapticAlarm
                table["4.0.ping"] = four.ping
                table["4.0.requestHistoricalSync"] = four.requestHistoricalSync
                table["4.0.toggleIMUMode"] = four.toggleIMUMode
                table["4.0.sendRealtimeMotion"] = four.sendRealtimeMotion
                table["4.0.enableOpticalData"] = four.enableOpticalData
                table["4.0.setClock"] = four.setClock
                table["4.0.abortHistoricalTransmits"] = four.abortHistoricalTransmits
                table["4.0.setReadPointer"] = four.setReadPointer
                table["4.0.getDataRange"] = four.getDataRange
                table["4.0.historicalDataResult"] = four.historicalDataResult
            }
            if let five = profile.syncOpcodes {
                table["5.0.hello"] = five.hello
                table["5.0.requestHistoricalSync"] = five.requestHistoricalSync
                table["5.0.historicalDataResult"] = five.historicalDataResult
                table["5.0.getDataRange"] = five.getDataRange
                table["5.0.stopRawData"] = five.stopRawData
                table["5.0.startRawData"] = five.startRawData
                table["5.0.toggleIMUModeLive"] = five.toggleIMUModeLive
                table["5.0.toggleIMUModeHistorical"] = five.toggleIMUModeHistorical
                table["5.0.setClock"] = five.setClock
                table["5.0.getClock"] = five.getClock
                table["5.0.abortHistoricalTransmits"] = five.abortHistoricalTransmits
                table["5.0.setReadPointer"] = five.setReadPointer
            }
            return table
        }

        assertTest(
            transmittedOpcodes(.whoop4).count == 12,
            "The 4.0's table is enumerated and non-empty, so the two assertions below are not passing on "
                + "an empty dictionary. Twelve is the count of `CommandOpcodes`' fields; a field added to "
                + "the type and not to `transmittedOpcodes` fails here")
        // The counterpart, and it is the assertion that would have caught the hole above rather than the
        // one that was already covered: a 5.0 profile must hand back a full table too. **Twelve is the
        // count of `SyncOpcodes`' fields, and it is twelve rather than the ten this type landed with** —
        // see the block below, which is where the two it was missing came from. A field added to that type
        // and not listed here fails.
        assertTest(
            transmittedOpcodes(.whoop5).count == 12
                && transmittedOpcodes(.whoop5MG).count == 12,
            "A 5.0 profile hands back its own twelve opcodes — the `SyncOpcodes` fields — and not the "
                + "empty dictionary it used to hand back before that table existed. **It does not hand "
                + "back the 4.0's twelve beside them**, because `commandOpcodes` is `nil` for both 5.0 "
                + "profiles: the two tables are for different envelopes and are not interchangeable, "
                + "which is why this is twelve and not twenty-four")
        // **The two opcodes the 5.0 table was missing, and the reason they are asserted by number rather
        // than only counted.** The table landed at ten entries on the stated basis that this generation
        // publishes no byte for the 4.0's `abortHistoricalTransmits` or its `setReadPointer`. Both are
        // published, both under the same number the 4.0 uses — so the omission was not a conservative
        // default and the substitution it caused was not a smaller claim. `abortHistoricalTransmits` is
        // the one that mattered: without it the drain's only stop had no byte to send and `0x52
        // STOP_RAW_DATA` stood in, which stops the producer and leaves the drain running while the app
        // reports a stopped sync.
        //
        // These are written as literals rather than read back off the profile, because a table asserting
        // its own values is the self-referential shape this file's CRC block exists to warn about.
        assertTest(
            WhoopProtocolProfile.whoop5.syncOpcodes?.abortHistoricalTransmits == 0x14
                && WhoopProtocolProfile.whoop5MG.syncOpcodes?.abortHistoricalTransmits == 0x14,
            "Both 5.0 profiles carry `0x14 ABORT_HISTORICAL_TRANSMITS` — the same number the 4.0 uses, "
                + "under the other envelope. The reference that establishes this set marks ID 20 supported "
                + "for this generation, so a table without it is short by a published byte rather than "
                + "cautious")
        assertTest(
            WhoopProtocolProfile.whoop5.syncOpcodes?.setReadPointer == 0x21
                && WhoopProtocolProfile.whoop5MG.syncOpcodes?.setReadPointer == 0x21,
            "…and `0x21 SET_READ_POINTER` likewise, carried and never sent: the reference groups it with "
                + "forced trim as an operation that mutates history ownership and cannot substitute for "
                + "the per-batch acknowledgement, which is this drain's own rule stated from the other "
                + "side")
        assertTest(
            WhoopCommandFrames.abortHistoricalTransmits(profile: .whoop4, seq: 3)?[6] == 0x14
                && WhoopCommandFrames.abortHistoricalTransmits(profile: .whoop5, seq: 3)?[10] == 0x14,
            "…and the façade sends that byte to a 5.0 rather than `0x52`, which is the assertion that "
                + "fails if the substitution is ever reinstated. The two frames differ in envelope and "
                + "agree on the opcode, which is what having a real 5.0 abort means")

        let forbidden: [UInt8: String] = [
            0x19: "0x19 FORCE_TRIM, a flash erase",
            0x9A: "0x9A TOGGLE_PERSISTENT_R21, which forces the optical engine on across reboots",
        ]
        for profile in [WhoopProtocolProfile.whoop4, .whoop5, .whoop5MG] {
            let table = transmittedOpcodes(profile)
            for opcode in forbidden.keys.sorted() {
                assertTest(
                    !table.values.contains(opcode),
                    "No \(profile.generation) command table transmits \(forbidden[opcode]!). The drain is "
                        + "non-destructive by design and needs no trim — issuing one to clear a backlog "
                        + "destroys history that has not been drained — and a strap left with the optical "
                        + "engine forced on burns battery until it is rebooted")
            }
        }

        // The motion opcodes are the ones the live 4.0 step path hangs on, so they are pinned by value
        // rather than only swept for two forbidden bytes. A table that carried the right *names* and the
        // wrong numbers would satisfy every assertion above.
        do {
            let opcodes = WhoopProtocolProfile.whoop4.commandOpcodes
            assertTest(
                opcodes?.toggleIMUMode == 0x6A && opcodes?.sendRealtimeMotion == 0x3F
                    && opcodes?.enableOpticalData == 0x6B,
                "The 4.0's motion enable group is 0x6A TOGGLE_IMU_MODE, 0x3F SEND_R10_R11_REALTIME and "
                    + "0x6B ENABLE_OPTICAL_DATA, from docs/BLE_PROTOCOL.md §6 — got "
                    + "\(opcodes.map { "\($0.toggleIMUMode)/\($0.sendRealtimeMotion)/\($0.enableOpticalData)" } ?? "no table")")
            assertTest(
                opcodes?.setClock == 0x0A && opcodes?.abortHistoricalTransmits == 0x14
                    && opcodes?.setReadPointer == 0x21 && opcodes?.getDataRange == 0x22
                    && opcodes?.historicalDataResult == 0x17,
                "The 4.0's drain group is 0x0A SET_CLOCK, 0x14 ABORT_HISTORICAL_TRANSMITS, 0x21 "
                    + "SET_READ_POINTER, 0x22 GET_DATA_RANGE and 0x17 HISTORICAL_DATA_RESULT, from "
                    + "docs/BLE_PROTOCOL.md §4 — these are the bytes the ACK loop and the clock set are built "
                    + "from, and a transposed pair among them is a command that does something else")

            // The enable sequence, as the manager sends it: three frames on enable, one on stop, in order.
            let enableFrames = WhoopPacketEncoder.motionEnableSequence(
                profile: .whoop4, seq: 0x10, enable: true)
            assertTest(
                enableFrames.count == 3,
                "The 4.0 IMU enable is three frames — the toggle, then the realtime record, then the "
                    + "optical enable — got \(enableFrames.count)")
            // Each frame is `AA lenLo lenHi crc8 type seq cmd [payload…] crc32×4`, so the opcode sits at
            // byte 6, the sequence at byte 5, and a payload starts at byte 7. Reading the sequence off the
            // bytes rather than trusting the builder is the point: it is what makes the ordering and the
            // per-frame seq assertions below statements about the wire rather than about this app.
            let enableOpcodes = enableFrames.map { $0[6] }
            assertTest(
                enableOpcodes == [0x6A, 0x3F, 0x6B],
                "The sequence is ordered toggle → realtime → optical, so a strap cannot be asked for a "
                    + "100 Hz record before its IMU is on — got \(enableOpcodes.map { String(format: "0x%02X", $0) })")
            assertTest(
                enableFrames.map { $0[5] } == [0x10, 0x11, 0x12],
                "Each frame in the sequence carries its own inner seq, because a shared one would say "
                    + "three records were one — got \(enableFrames.map { $0[5] })")
            // All three carry a payload, and the byte counts are `4 + 3 + payload + 4`: 12 for the two
            // one-byte forms, 13 for the two-byte one. **The two that used to be sent bare are one change
            // here and the toggle's width is the other** — every implemented client gives all three a body,
            // so 11 is the one length no source produces. See `WhoopPacketEncoder.motionEnableSequence`'s
            // doc comment for which client each payload comes from.
            assertTest(
                enableFrames[0].count == 12 && enableFrames[0][7] == 0x01,
                "The 0x6A toggle carries ONE byte on the 4.0 — 13 would be §6's two-byte `[1, 1]`, which "
                    + "belongs to the optical and persistent toggles and not to this one. OpenStrap's "
                    + "`TWO_BYTE_TOGGLES` names those four opcodes and excludes `0x6A`; noop's 4.0 branch "
                    + "sends `[0x01]` while giving its 5/MG the two-byte form — got "
                    + "\(enableFrames[0].count) bytes with payload "
                    + "\(Array(enableFrames[0].dropFirst(7).prefix(2)))")
            assertTest(
                enableFrames[1].count == 12 && enableFrames[1][7] == 0x01
                    && enableFrames[2].count == 13 && enableFrames[2][7] == 0x01 && enableFrames[2][8] == 0x01,
                "0x3F carries `[01]` and 0x6B carries `[01, 01]`, both from the references' running "
                    + "clients rather than composed here: noop's `sendR10R11Realtime` is documented "
                    + "`[0x01]`=on and verified on-device, and OpenStrap's `cmd_enable_optical` sends "
                    + "`[REVISION_1, enable]` as a two-byte payload by its own header's convention. A "
                    + "bodyless 0x3F starts no live record — got \(enableFrames[1].count) and "
                    + "\(enableFrames[2].count) bytes, where 11 would mean no payload at all")
            // The stop form's width is asserted for the same reason the enable form's is: `[0x01, 0x00]`
            // is the two-byte shape this builder used to send, and it is the 5/MG's (`[0x01, 0x00]` under
            // noop's `== .whoop5` branch), so a 13-byte stop on a 4.0 is a 5/MG frame wearing a 4.0
            // envelope. OpenStrap's stop is `b"\x00"`, one byte, like its enable.
            let stopFrames = WhoopPacketEncoder.motionEnableSequence(profile: .whoop4, seq: 0x10, enable: false)
            assertTest(
                stopFrames.count == 1 && stopFrames[0].count == 12 && stopFrames[0][7] == 0x00,
                "Stopping is the IMU toggle alone — the other two are enable verbs with no documented "
                    + "counterpart, and inventing one would be inventing a wire format — and it is one "
                    + "byte `[00]`, not the 5/MG's `[01, 00]`: got \(stopFrames.count) frame(s), "
                    + "\(stopFrames.first?.count ?? 0) bytes")
            // **This is a claim about the 4.0 builder, not about a 5.0 strap.** It used to read as the
            // latter, which was true when the 5.0 had no builder at all — and a 5.0 now does, so the
            // sentence had to move with the code rather than keep describing a strap whose enable exists
            // three blocks below. What is asserted here is only that this file refuses to frame one.
            assertTest(
                WhoopPacketEncoder.motionEnableSequence(profile: .whoop5, seq: 0x10, enable: true).isEmpty
                    && WhoopPacketEncoder.motionEnableSequence(profile: .whoop5MG, seq: 0x10, enable: true).isEmpty,
                "The **4.0 builder** refuses a 5.0 or MG profile rather than framing a 4.0 toggle for one: "
                    + "all-or-nothing, because a partially-applied enable is a strap with its IMU on and "
                    + "nothing being emitted, which burns battery and produces no steps. That a 5.0 does "
                    + "get an enable sequence is a different claim, made of a different builder, in the "
                    + "5.0 blocks below")
        }
    }
}
