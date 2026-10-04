import CoreBluetooth
import Foundation
import Whoopsy

// MARK: - 1. CRC & Packet Framing Tests
//
// This section used to be four assertions that could not fail: `crc8Val >= 0` on a `UInt8` (never
// false), `!= 0` for the other two (which only rules out identically zero), and a frame-layout check
// against the encoder's own constant. A wrong polynomial, a wrong byte order and a wrong *input* all
// passed — which is exactly how `buildPacket` hashed three bytes into a CRC8 the format says covers
// two, on every command frame this app has ever sent, without anything noticing.
//
// It is now built on the four vectors `docs/BLE_PROTOCOL.md` §2.1 records from the two reverse-engineering
// references' own published frames. These are checkable with no strap, and they are the assertions
// that fail if the arithmetic or the frame layout moves.

/// The section's body. Driven from top level by `runSynchronousSections(_:)`.
enum PacketFramingTests {
    static func run() {
        // The 4.0 header CRC8 is over the two length bytes only, poly 0x07. Both values are the references'
        // own, quoted in §2.1.
        assertTest(CRCUtils.crc8(Data([0x08, 0x00])) == 0xA8, "crc8([0x08, 0x00]) == 0xA8 (reference vector)")
        assertTest(CRCUtils.crc8(Data([0x10, 0x00])) == 0x57, "crc8([0x10, 0x00]) == 0x57 (reference vector)")

        // The 5.0 `CLIENT_HELLO` is a static 16-byte frame, so it validates the CRC16-Modbus over the first
        // six header bytes *and* the CRC32 over the inner record in one. The two assertions here pin the
        // arithmetic; the block further down hands the same sixteen bytes to the decoder and asserts the
        // *envelope*, which is a different claim — the CRC functions agreeing with the reference about two
        // substrings is what makes the envelope a question of framing rather than of checksums.
        assertTest(
            CRCUtils.crc16Modbus(hello50.subdata(in: 0..<6)) == 0x71E6,
            "crc16Modbus(5.0 hello[0..<6]) == 0x71E6 (reference vector)")
        assertTest(
            CRCUtils.crc32(hello50.subdata(in: 8..<12)) == 0x8D5C3E36,
            "crc32(5.0 hello payload) == 0x8D5C3E36 (reference vector)")

        // The 4.0 envelope, end to end. `hapticAlarmCommand` carries a two-byte payload, so the inner record
        // is `type seq cmd 03 01` — five bytes — and `length` is that plus four.
        let haptic = WhoopPacketEncoder.hapticAlarmCommand(
            profile: .whoop4, seq: 0x07, durationSeconds: 3, pattern: 1)
        assertTest(haptic != nil, "Encoder builds a frame for the 4.0 envelope")
        if let haptic {
            assertTest(haptic[0] == 0xAA, "Frame start of frame is 0xAA")
            // The defect this section could not see before: the CRC8 input. `length` is 9, so the two length
            // bytes are `09 00` and the reference says the checksum over them is 0x57.
            assertTest(haptic[1] == 0x09 && haptic[2] == 0x00, "Frame declares length 9 (5 inner bytes + 4)")
            assertTest(
                haptic[3] == CRCUtils.crc8(Data([haptic[1], haptic[2]])),
                "Header crc8 is over the two length bytes only")
            assertTest(haptic[4] == WhoopProtocolProfile.whoop4.packetTypes.command, "Inner type is the command type")
            assertTest(haptic[5] == 0x07, "Inner seq echoes the sequence number handed in")
            assertTest(haptic[6] == 0x10, "Inner cmd is 0x10 (haptic alarm)")
            assertTest(haptic.count == 13, "Total frame size is length + 4")
            // CRC32 covers the inner record `frame[4 ..< length]`, not the payload alone.
            let inner = haptic.subdata(in: 4..<9)
            let trailer = haptic.subdata(in: 9..<13)
            let declared = UInt32(trailer[trailer.startIndex])
                | (UInt32(trailer[trailer.startIndex + 1]) << 8)
                | (UInt32(trailer[trailer.startIndex + 2]) << 16)
                | (UInt32(trailer[trailer.startIndex + 3]) << 24)
            assertTest(declared == CRCUtils.crc32(inner), "Payload crc32 covers the inner record, not the payload")
        }

        // The two CRC8 vectors are quoted for specific *declared lengths*, so they are reachable only from a
        // frame that declares those lengths — 0x08 is an inner record of four bytes (a one-byte payload), 0x10
        // one of twelve. Asserting them against the frame that produces each is what ties the arithmetic to
        // the layout; quoted bare in §1 above they validate the polynomial and nothing else.
        let lengthEight = WhoopPacketEncoder.buildPacket(
            profile: .whoop4, type: WhoopProtocolProfile.whoop4.packetTypes.command,
            seq: 0, cmd: 0x05, payload: Data([0x01]))!
        assertTest(
            lengthEight[1] == 0x08 && lengthEight[2] == 0x00 && lengthEight[3] == 0xA8,
            "A frame declaring length 8 carries crc8 0xA8 (the reference vector, in place)")
        let lengthSixteen = WhoopPacketEncoder.buildPacket(
            profile: .whoop4, type: WhoopProtocolProfile.whoop4.packetTypes.command,
            seq: 0, cmd: 0x05, payload: Data(repeating: 0x01, count: 9))!
        assertTest(
            lengthSixteen[1] == 0x10 && lengthSixteen[2] == 0x00 && lengthSixteen[3] == 0x57,
            "A frame declaring length 16 carries crc8 0x57 (the reference vector, in place)")

        // A sequence that advances and wraps rather than repeating a constant. A repeated `seq` would be a
        // second invented value sitting where a field is expected — the same class of error as a fabricated
        // battery percentage, and just as invisible.
        let seqCounter = WhoopCommandSequence()
        let seqValues = (0..<256).map { _ in seqCounter.next() }
        assertTest(seqValues.first == 1, "Command sequence starts at 1")
        assertTest(seqValues.last == 0, "Command sequence wraps at 256 rather than overflowing")
        assertTest(Set(seqValues).count == 256, "Command sequence produces 256 distinct values before repeating")

        // The envelope is selected by generation, and **reading and writing are still answered
        // separately** — but both answers are now yes for all three straps, and the separation is carried
        // by *which table* answers rather than by whether one exists.
        //
        // `WhoopProtocolProfile.profile(for:)` is the choke point the generation-aware path rests on. What
        // is pinned below is that the three straps transmit through **two different tables** — the 4.0
        // through `commandOpcodes`, the 5.0 and MG through `syncOpcodes` — and that neither table is a
        // fallback for the other. The failure this prevents is silent: a 4.0-framed command on a 5.0 strap
        // is a *different message* rather than a rejected one, and one documented 4.0 opcode is a
        // destructive flash erase.
        assertTest(WhoopProtocolProfile.profile(for: .whoop4) == .whoop4, "whoop4 has a profile")
        assertTest(
            WhoopProtocolProfile.profile(for: .whoop5) == .whoop5,
            "whoop5 has a profile — this build can validate its inbound frames")
        assertTest(
            WhoopProtocolProfile.profile(for: .whoop5MG) == .whoop5MG,
            "whoop5MG has a profile, and one that names its own generation")
        for generation in [WhoopHardwareGeneration.standardBleHR, .simulator] {
            assertTest(
                WhoopProtocolProfile.profile(for: generation) == nil,
                "\(generation.rawValue) has no profile — it frames no proprietary envelope at all")
        }
        assertTest(
            WhoopProtocolProfile.whoop4.canTransmitCommands
                && WhoopProtocolProfile.whoop5.canTransmitCommands
                && WhoopProtocolProfile.whoop5MG.canTransmitCommands,
            "All three straps can transmit — the drain is implemented on both generations")
        // **The one that matters, and the one that is easy to lose.** `canTransmitCommands` is now true
        // for three profiles, so it no longer says anything about *which* opcodes a profile carries. What
        // keeps the two generations apart is that each table is answered by its own envelope: the 4.0 has
        // `commandOpcodes` and no 5.0 set, the 5.0 and MG are the other way round. A build that filled the
        // 4.0's table on a 5.0 "so the drain works there too" would satisfy every assertion above it.
        assertTest(
            WhoopProtocolProfile.whoop4.commandOpcodes != nil
                && WhoopProtocolProfile.whoop4.syncOpcodes == nil,
            "The 4.0 transmits through commandOpcodes and carries no 5.0 set")
        assertTest(
            WhoopProtocolProfile.whoop5.commandOpcodes == nil
                && WhoopProtocolProfile.whoop5MG.commandOpcodes == nil,
            "Neither 5.0 profile carries the 4.0 command set — the two are not interchangeable")
        assertTest(
            WhoopProtocolProfile.whoop5.syncOpcodes != nil
                && WhoopProtocolProfile.whoop5MG.syncOpcodes != nil,
            "Both 5.0 profiles carry the 5.0 opcode set, established from the references rather than assumed")
        // The bytes themselves, pinned as literals so a table edited to match 4.0's numbering fails here
        // rather than building a frame a strap would accept and act on.
        let fiveOpcodes = WhoopProtocolProfile.whoop5.syncOpcodes
        assertTest(
            fiveOpcodes?.hello == 0x91 && fiveOpcodes?.setClock == 0x92 && fiveOpcodes?.getClock == 0x93,
            "The 5.0 hello and clock pair read 0x91/0x92/0x93 rather than 4.0's bytes")
        assertTest(
            fiveOpcodes?.requestHistoricalSync == 0x16 && fiveOpcodes?.historicalDataResult == 0x17,
            "The 5.0 drain pair is 0x16/0x17 — the same numbering as the 4.0's, in the other envelope")
        assertTest(
            fiveOpcodes?.startRawData == 0x51 && fiveOpcodes?.stopRawData == 0x52
                && fiveOpcodes?.toggleIMUModeLive == 0x6A && fiveOpcodes?.toggleIMUModeHistorical == 0x69,
            "The 5.0 raw-data and IMU opcodes are its own set, not the 4.0's 0x3F/0x6B")
        assertTest(
            WhoopProtocolProfile.whoop5MG.syncOpcodes == fiveOpcodes,
            "The MG shares the 5.0's opcode set — one envelope, one table, and no MG-specific bytes")

        let catalog = WhoopProtocolCatalog()
        for generation in [WhoopHardwareGeneration.whoop4, .whoop5, .whoop5MG] {
            assertTest(
                catalog.supportsProprietarySync(generation),
                "Catalog reports sync implemented for \(generation.rawValue)")
        }
        for generation in [WhoopHardwareGeneration.standardBleHR, .simulator] {
            assertTest(
                !catalog.supportsProprietarySync(generation),
                "Catalog reports sync not implemented for \(generation.rawValue) — it is not a WHOOP strap")
        }
        // The caption's name is read off the profile's own checksum variant, so it cannot name an
        // envelope the builder would not write. Pinned as literals because a caption is user-facing text.
        assertTest(
            catalog.protocolEnvelopeName(.whoop4) == "4.0",
            "The 4.0's envelope is named 4.0 for the sync caption")
        assertTest(
            catalog.protocolEnvelopeName(.whoop5) == "5.0"
                && catalog.protocolEnvelopeName(.whoop5MG) == "5.0",
            "Both 5.0 profiles name the 5.0 envelope — one envelope, and the MG is not a third")
        assertTest(
            catalog.protocolEnvelopeName(.standardBleHR) == nil
                && catalog.protocolEnvelopeName(.simulator) == nil,
            "A generation with no envelope gets no name rather than a caption naming someone else's")

        // The three models the user can choose, derived from the cases rather than listed beside them — a
        // hardcoded list is one that a new case silently fails to join.
        assertTest(
            WhoopHardwareGeneration.selectableModels == [.whoop4, .whoop5, .whoop5MG],
            "The selectable models are exactly the three straps, 5.0 and MG distinct")

        assertTest(
            WhoopPacketEncoder.pingCommand(profile: .whoop5, seq: 1) == nil,
            "Encoder refuses to build a frame under an envelope it has no command opcodes for")
        assertTest(
            WhoopPacketEncoder.hapticAlarmCommand(profile: .whoop5, seq: 1) == nil,
            "Every command builder refuses the read-only envelope")
        assertTest(
            WhoopPacketEncoder.enableLiveTelemetry(profile: .whoop5, seq: 1) == nil
                && WhoopPacketEncoder.requestHistoricalSync(profile: .whoop5, seq: 1) == nil,
            "The telemetry and drain builders refuse it too — every builder, not the two that were sampled")
        assertTest(
            WhoopPacketEncoder.pingCommand(profile: .whoop5MG, seq: 1) == nil,
            "The MG is refused on the same grounds rather than on a name check")
        assertTest(
            WhoopPacketEncoder.buildPacket(
                profile: .whoop5, type: 35, seq: 1, cmd: 0x91, payload: Data([0x01])) == nil,
            "The encoder refuses even a 5.0 frame whose opcode is the one the reference documents")

        // MARK: The 5.0 / MG envelope
        //
        // This block is anchored on the one published 5.0 frame in hand — the static sixteen-byte
        // `CLIENT_HELLO` quoted in `docs/BLE_PROTOCOL.md` §2.1 — and everything below is asserted against those
        // bytes rather than against this app's own encoder, which cannot build a 5.0 frame and must not.
        // That is the difference between this block and the CRC vectors above it: those pin two functions,
        // this pins a *slice*, and a slice is where an offset error lives.

        let decodedHello = decoder.decodeProprietaryFrame(data: hello50, profile: .whoop5)
        assertTest(decodedHello != nil, "The published 5.0 CLIENT_HELLO decodes under the 5.0 envelope")
        if let decodedHello {
            assertTest(
                decodedHello.generation == .whoop5,
                "A frame read under the 5.0 profile names the 5.0, so it cannot be filed against a 4.0")
            // The inner record begins at offset 8, not 4 — the four-byte shift. Reading `cmd` at 4.0's
            // offset would take the crc16's high byte (`0x71`) as the opcode.
            assertTest(
                decodedHello.type == WhoopProtocolProfile.whoop5.packetTypes.command,
                "Inner type is the profile's command type — 0x23 and 35 are one byte, not two numberings")
            assertTest(decodedHello.seq == 1, "Inner seq is 1, read at byte 9 rather than byte 5")
            assertTest(decodedHello.cmd == 0x91, "Inner cmd is 0x91, the hello's own opcode")
            assertTest(
                decodedHello.payload == Data([0x01]),
                "The payload is the single byte past the three-byte inner prefix, not the inner record")
        }
        assertTest(
            decoder.decodeProprietaryFrame(data: hello50, profile: .whoop5MG)?.generation == .whoop5MG,
            "The same envelope read under the MG profile names the MG — one envelope, two generations")

        // The declared length is at a different offset under each envelope, and this is the assertion that
        // fails if anyone tidies the two profiles onto one. 5.0 spends byte 1 on a format byte, so a decoder
        // that reads `data[1]` and `data[2]` reads the hello's length as 0x0801 — 2049 — and then rejects a
        // sixteen-byte frame for being 2049 bytes short. The failure is a total loss of 5.0 traffic rather
        // than a wrong field, which is why it is worth a literal.
        assertTest(
            WhoopProtocolProfile.whoop4.lengthFieldOffset == 1
                && WhoopProtocolProfile.whoop5.lengthFieldOffset == 2,
            "The declared length sits at byte 1 under 4.0 and byte 2 under 5.0")
        let helloMisread = Int(hello50[1]) | (Int(hello50[2]) << 8)
        assertTest(
            helloMisread == 0x0801,
            "4.0's length offset reads the hello as declaring 2049 bytes, not 8")

        // The frame-size rule, and the identity that makes one decoder serve both envelopes: the two
        // documented forms — 4.0's `length + 4` and 5.0's `declLength + 8` — are `innerOrigin + declared`.
        // The sweep is accumulated into one assertion because fifteen of them would be fifteen lines of the
        // same sentence; the failures it collects are what makes it discriminating.
        assertTest(
            WhoopProtocolProfile.whoop4.frameByteCount(declaredLength: 1247) == 1251
                && WhoopProtocolProfile.whoop5.frameByteCount(declaredLength: 8) == 16
                && WhoopProtocolProfile.whoop5.frameByteCount(declaredLength: 8) == hello50.count,
            "4.0's `length + 4` and 5.0's `declLength + 8` are the same rule, and it sizes the real hello")
        assertTest(
            WhoopProtocolProfile.whoop4.innerByteCount(declaredLength: 1247) == 1243
                && WhoopProtocolProfile.whoop5.innerByteCount(declaredLength: 8) == 4,
            "The inner record is `declaredLength - 4` under both — which is the hello's four inner bytes")
        var sizeRuleFailures: [String] = []
        for profile in [WhoopProtocolProfile.whoop4, .whoop5, .whoop5MG] {
            for declared in [8, 124, 1244, 2140, 1247] {
                let whole = profile.frameByteCount(declaredLength: declared)
                let inner = profile.innerByteCount(declaredLength: declared)
                if whole != profile.innerOrigin + declared
                    || inner + profile.innerOrigin + WhoopProtocolProfile.checksumTrailerBytes != whole {
                    sizeRuleFailures.append("\(profile.generation.rawValue)/\(declared)")
                }
            }
        }
        assertTest(
            sizeRuleFailures.isEmpty,
            "Every documented record size obeys the one rule under all three profiles: \(sizeRuleFailures)")

        // What the CRC16 covers, which is not what the CRC8 covers. These three bytes are read by no other
        // check — not the start of frame, not the length, not the inner record — so a frame carrying a
        // flipped one is refused *only* if the checksum input reaches back to byte 0. A checksum taken over
        // `frame[2..<6]`, which is what "over the length and the header bytes" would mean if anyone
        // generalised the 4.0 rule, accepts all three.
        for index in [1, 4, 5] {
            var tampered = hello50
            tampered[index] ^= 0x01
            let accepted = decoder.decodeProprietaryFrame(data: tampered, profile: .whoop5) != nil
            assertTest(
                !accepted,
                "Flipping header byte \(index) is refused — the crc16 input starts at the start of frame")
        }
        do {
            // The payload CRC32 covers `frame[8 ..< declLength + 4]`, the inner record. Flipping its last
            // byte must be refused, and the byte is the payload's — which is what makes this the assertion
            // that the trailer is found relative to the inner origin rather than at a fixed offset.
            var tampered = hello50
            tampered[11] ^= 0x01
            assertTest(
                decoder.decodeProprietaryFrame(data: tampered, profile: .whoop5) == nil,
                "Flipping the hello's last inner byte is refused by the payload crc32")
        }
        do {
            // And the reverse direction: the hello under the 4.0 envelope. `length` would be read as 0x0801
            // and the 4.0 header CRC8 — over what it thinks are the two length bytes — would not match
            // either, so this is refused twice over.
            assertTest(
                decoder.decodeProprietaryFrame(data: hello50, profile: .whoop4) == nil,
                "The 5.0 hello is refused under the 4.0 envelope — the envelope discriminates, not the type")
        }

        // Which model a strap is: a stored choice, never overridden by the guess.
        //
        // The precedence rule, asserted directly. `resolvedGeneration` is a static function of its two inputs
        // precisely so this is reachable — constructing a `WhoopBLEManager` would raise a system Bluetooth
        // prompt in the middle of a test run.
        assertTest(
            WhoopBLEManager.resolvedGeneration(stored: .whoop5MG, advertisedName: "WHOOP Strap")
                == .whoop5MG,
            "A stored choice wins over the name heuristic")
        assertTest(
            WhoopBLEManager.resolvedGeneration(stored: .whoop4, advertisedName: "WHOOP 5.0")
                == .whoop4,
            "A stored choice is not overridden by a name that advertises the opposite")
        assertTest(
            WhoopBLEManager.resolvedGeneration(stored: nil, advertisedName: "WHOOP 5.0") == .whoop5,
            "With nothing stored, the name heuristic still answers")
        assertTest(
            WhoopBLEManager.resolvedGeneration(stored: nil, advertisedName: "WHOOP Strap") == .whoop4,
            "An unnamed strap falls back to 4.0 — the heuristic cannot read a name it was never given")

        // MARK: Length-driven reassembly across notifications
        //
        // `docs/BLE_PROTOCOL.md` §4 named this as the remaining half of the framing problem, and it is the gate
        // on every motion record this app wants. A notification carries at most `MTU − 3` bytes; the
        // 5.0/MG type-47 buffer is 1244 or 2140 bytes on that document's least-verifiable source, and the
        // 4.0 live IMU frame is 1921, published and hardware-verified. Before this, the decoder was handed
        // *one* notification and
        // returned `nil` for anything longer, and the manager dropped that `nil` on the floor — so a large
        // frame was not rejected, it was never seen at all.
        let reassemblyProfile = WhoopProtocolProfile.whoop4

        // The bound is pinned with its basis, in the shape of the other constant assertions: changing it
        // means deleting the sentence that says where it came from.
        assertTest(
            WhoopFrameReassembler.maximumFrameBytes == 4096,
            "The reassembly bound is 4096 — above the largest documented record (2140 declared + 4)")

        // A frame long enough to be genuinely split, built by the encoder so the two halves cannot drift
        // apart. The payload is 1240 bytes, the 5.0/MG IMU buffer's documented size, and it is generated
        // rather than constant so that it *contains* 0xAA bytes — a payload of one repeated value would
        // pass a boundary scan that never had to reject a false start.
        let longPayload = Data((0..<1240).map { UInt8($0 % 251) })
        assertTest(longPayload.contains(0xAA), "The long fixture payload contains a byte equal to the start of frame")
        let longFrame = WhoopPacketEncoder.buildPacket(
            profile: reassemblyProfile,
            type: reassemblyProfile.packetTypes.historicalData,
            seq: 0x11,
            cmd: 0x00,
            payload: longPayload)!
        assertTest(
            longFrame.count == 1251,
            "The long frame is 1251 bytes (3 prefix + 1240 payload + 8) — past what one notification carries")

        // `Data` slices inherit the indices of the buffer they came from, and a scan written against one
        // reads the wrong bytes once the head is trimmed — so every fragment below is rebuilt as a fresh,
        // zero-based `Data`, which is what a notification actually is.
        func fragment(_ bytes: Data, _ range: Range<Int>) -> Data { Data(Array(bytes[range])) }

        // 1. **Every split point, not one chosen split.** A reassembler that only works when the cut
        // happens to fall outside a field is a reassembler that works on the fixture. This walks all 1250
        // of them, which is also what proves the buffer resumes from the frame's own start rather than
        // from where the last notification ended.
        var splitFailures: [Int] = []
        for cut in 1..<longFrame.count {
            var reassembler = WhoopFrameReassembler()
            let head = reassembler.append(fragment(longFrame, 0..<cut), profile: reassemblyProfile)
            let tail = reassembler.append(fragment(longFrame, cut..<longFrame.count), profile: reassemblyProfile)
            let ok = head.isEmpty && tail.count == 1
                && tail[0].payload == longPayload
                && tail[0].type == reassemblyProfile.packetTypes.historicalData
            if !ok { splitFailures.append(cut) }
        }
        assertTest(
            splitFailures.isEmpty,
            "A frame split across two notifications reassembles at all 1250 boundaries (failed: \(splitFailures.prefix(5)))")

        // 2. **Byte at a time** — the worst case a real link can present, and the one where a scan that
        // consumed optimistically would discard the frame on its first partial read.
        var drip = WhoopFrameReassembler()
        var dripFrames: [WhoopRawFrame] = []
        for index in 0..<longFrame.count {
            dripFrames += drip.append(fragment(longFrame, index..<(index + 1)), profile: reassemblyProfile)
        }
        assertTest(dripFrames.count == 1, "A frame delivered one byte per notification still reassembles exactly once")
        assertTest(dripFrames.first?.payload == longPayload, "The byte-at-a-time frame's payload is intact")
        assertTest(drip.bufferedByteCount == 0, "Nothing is left buffered once the frame completed")

        // 3. **Two frames in one notification.** A notification is a byte stream, not a frame: it can
        // carry a whole frame plus the head of the next, and after a gap it can complete several at once.
        var packed = WhoopFrameReassembler()
        let packedFrames = packed.append(longFrame + longFrame, profile: reassemblyProfile)
        assertTest(packedFrames.count == 2, "Two frames arriving in one notification both come back")
        assertTest(packed.bufferedByteCount == 0, "Both frames are consumed, leaving nothing buffered")

        // 4. **Leading noise is discarded, not prepended.** Bytes before a start of frame are the tail of
        // one that was lost; holding them would move every field in the next frame.
        var noisy = WhoopFrameReassembler()
        let noisyFrames = noisy.append(Data([0x01, 0x02, 0x03]) + longFrame, profile: reassemblyProfile)
        assertTest(noisyFrames.count == 1, "Garbage before a frame does not stop it decoding")
        assertTest(noisyFrames.first?.payload == longPayload, "The frame behind the noise is byte-identical")

        var pureNoise = WhoopFrameReassembler()
        assertTest(
            pureNoise.append(Data([0x01, 0x02, 0x03]), profile: reassemblyProfile).isEmpty
                && pureNoise.bufferedByteCount == 0,
            "Bytes containing no start of frame are discarded rather than buffered")

        // 5. **A `0xAA` inside a payload is not a boundary, and its declared length is meaningless.**
        // The payload is crafted so the false start declares a *plausible* size rather than an absurd one
        // — the case a length sanity check alone lets through, and the reason the decoder's checksums are
        // what decide rather than this type's arithmetic.
        let falseBoundaryPayload = Data([0xAA, 0x08, 0x00, 0xAA, 0x08, 0x00, 0xAA])
        let falseBoundaryFrame = WhoopPacketEncoder.buildPacket(
            profile: reassemblyProfile,
            type: reassemblyProfile.packetTypes.event,
            seq: 0x05,
            cmd: 0x00,
            payload: falseBoundaryPayload)!
        var falseBoundary = WhoopFrameReassembler()
        let falseBoundaryFrames = falseBoundary.append(falseBoundaryFrame, profile: reassemblyProfile)
        assertTest(falseBoundaryFrames.count == 1, "A 0xAA inside a payload does not split the frame carrying it")
        assertTest(
            falseBoundaryFrames.first?.payload == falseBoundaryPayload,
            "The frame with an embedded 0xAA decodes with its payload intact")

        // 6. **A false boundary that declares an impossible length is skipped, and the real frame behind
        // it survives.** `0xAA FF FF` declares 65535, which is past `maximumFrameBytes`; the byte below it
        // declares 1, which could not hold the inner record's own prefix. Neither may park the scan.
        var absurd = WhoopFrameReassembler()
        let absurdFrames = absurd.append(Data([0xAA, 0xFF, 0xFF]) + longFrame, profile: reassemblyProfile)
        assertTest(absurdFrames.count == 1, "An over-long declared length is skipped as a false boundary")
        var undersized = WhoopFrameReassembler()
        assertTest(
            undersized.append(Data([0xAA, 0x01, 0x00]) + longFrame, profile: reassemblyProfile).count == 1,
            "A declared length below the profile's minimum is skipped as a false boundary")

        // 7. **A partial frame is held, not emitted and not discarded.** This is the state the whole type
        // exists to carry, and `bufferedByteCount` is the only way to see it — its doc comment says so.
        var holding = WhoopFrameReassembler()
        assertTest(
            holding.append(fragment(longFrame, 0..<500), profile: reassemblyProfile).isEmpty,
            "Half a frame produces no frame")
        assertTest(holding.bufferedByteCount == 500, "Half a frame is held whole, not partially consumed")
        let completed = holding.append(fragment(longFrame, 500..<longFrame.count), profile: reassemblyProfile)
        assertTest(completed.count == 1 && completed[0].payload == longPayload, "The held head completes with its tail")

        // 8. **`reset()` drops the partial frame.** A new connection is a new byte stream: bytes held
        // across one would be prepended to the next connection's first frame and shift every field in it.
        // The tail alone must therefore yield nothing rather than completing the frame it once belonged to.
        var resetting = WhoopFrameReassembler()
        _ = resetting.append(fragment(longFrame, 0..<500), profile: reassemblyProfile)
        resetting.reset()
        assertTest(resetting.bufferedByteCount == 0, "reset() empties the buffer")
        let afterReset = resetting.append(fragment(longFrame, 500..<longFrame.count), profile: reassemblyProfile)
        assertTest(
            afterReset.allSatisfy { $0.payload != longPayload },
            "A frame's tail cannot complete a frame whose head was dropped by reset()")

        // 9. **The reassembler does not accept what the decoder refuses.** It decides boundaries and
        // nothing else; a candidate failing either checksum is evidence the 0xAA it started on was a
        // payload byte. Corrupting the frame's payload without moving its declared length is the case
        // that separates the two — the length still says a frame is here, and only the checksum disagrees.
        var corruptedFrame = longFrame
        corruptedFrame[600] = corruptedFrame[600] &+ 1
        var corrupting = WhoopFrameReassembler()
        assertTest(
            corrupting.append(corruptedFrame, profile: reassemblyProfile).isEmpty,
            "A frame failing its payload checksum yields no frame and is walked past")
        assertTest(corrupting.bufferedByteCount == 0, "Nothing is left held after a checksum failure is consumed")

        // 10. **The 5.0 envelope reassembles too, and its length sits at a different offset.** This is the
        // case the reassembler exists for on the strap the user has two of: §6's type-47 buffer is 1244
        // bytes for the 6-axis IMU record, ~40× a notification, and it is unreachable until a frame
        // spanning notifications comes back whole. It is also the assertion that
        // fails if the length offset stays a literal 1 — a 5.0 frame read that way declares 0x01xx and is
        // never completed.
        //
        // The frame is **hand-built to §2's table rather than produced by the encoder**, and that is the
        // point rather than a workaround: the encoder refuses this envelope, and a frame it built would be
        // checked against the same offsets it was written with — the self-referential assertion §2.1
        // records as having hidden a wrong CRC input for months.
        func fiveFrame(inner: [UInt8]) -> Data {
            let declared = inner.count + WhoopProtocolProfile.checksumTrailerBytes
            var frame: [UInt8] = [0xAA, 0x01, 0, 0, 0x00, 0x01, 0, 0]
            frame[2] = UInt8(declared & 0xFF)
            frame[3] = UInt8((declared >> 8) & 0xFF)
            let crc16 = CRCUtils.crc16Modbus(Data(frame[0..<6]))
            frame[6] = UInt8(crc16 & 0xFF)
            frame[7] = UInt8((crc16 >> 8) & 0xFF)
            frame.append(contentsOf: inner)
            // `[4..6]` are the two header bytes §2 labels and does not specify; `00 01` is what the one
            // published 5.0 frame carries, and the crc16 above covers them either way.
            let crc32 = CRCUtils.crc32(Data(inner))
            frame.append(contentsOf: [
                UInt8(crc32 & 0xFF), UInt8((crc32 >> 8) & 0xFF),
                UInt8((crc32 >> 16) & 0xFF), UInt8((crc32 >> 24) & 0xFF),
            ])
            return Data(frame)
        }
        let imuInner = [UInt8(47), 0, 0x2F] + (0..<1244).map { UInt8($0 % 251) }
        let imuFrame = fiveFrame(inner: imuInner)
        assertTest(
            imuFrame.count == 1259,
            "The 5.0 IMU frame is 1259 bytes: 8 header + (3 prefix + 1244 payload) + 4 trailer")
        assertTest(
            imuFrame[2] == 0xE3 && imuFrame[3] == 0x04,
            "Its declared length sits at bytes 2 and 3 — 1251, where 4.0's offset would read byte 1's `01`")
        assertTest(
            WhoopProtocolProfile.whoop5.frameByteCount(declaredLength: 1251) == imuFrame.count,
            "The frame-sizing rule agrees with the hand-built frame, which is a different construction")
        do {
            let decoded = decoder.decodeProprietaryFrame(data: imuFrame, profile: .whoop5)
            assertTest(
                decoded?.type == 47 && decoded?.payload.count == 1244,
                "The hand-built frame decodes as a type-47 record carrying its 1244-byte payload")
        }
        var fiveSplitFailures: [String] = []
        for split in 1..<imuFrame.count {
            var subject = WhoopFrameReassembler()
            var got = subject.append(fragment(imuFrame, 0..<split), profile: .whoop5)
            got += subject.append(fragment(imuFrame, split..<imuFrame.count), profile: .whoop5)
            if got.count != 1 || got[0].payload.count != 1244 {
                fiveSplitFailures.append("\(split)")
            }
        }
        assertTest(
            fiveSplitFailures.isEmpty,
            "A 5.0 type-47 frame reassembles at all \(imuFrame.count - 1) of its boundaries, not one chosen "
                + "split: \(fiveSplitFailures.prefix(4))")
        do {
            var byteAtATime = WhoopFrameReassembler()
            var helloCount = 0
            for index in 0..<hello50.count {
                helloCount += byteAtATime.append(fragment(hello50, index..<(index + 1)), profile: .whoop5).count
            }
            assertTest(
                helloCount == 1 && byteAtATime.bufferedByteCount == 0,
                "The 16-byte 5.0 hello delivered a byte per notification arrives exactly once")
        }
        do {
            // The envelope discriminates at the reassembler too, though **not by refusing** — and the
            // distinction is worth pinning because it is the shape a reader would assume wrong. Handed the
            // 4.0 profile these bytes declare 0x0801 at that offset, so the reassembler believes a
            // 2053-byte frame is in flight and holds all sixteen bytes waiting for it. Nothing is handed
            // up, which is the property that matters, but nothing is discarded either: the buffer sits at
            // sixteen bytes until `reset()`. That is the whole reason `WhoopBLEManager` takes the profile
            // from the *resolved* generation and never guesses one — a mis-set model leaves a strap's
            // traffic accumulating in a buffer instead of decoding.
            var wrongEnvelope = WhoopFrameReassembler()
            let got = wrongEnvelope.append(hello50, profile: .whoop4)
            assertTest(got.isEmpty, "The 5.0 hello under the 4.0 profile yields no frame")
            assertTest(
                wrongEnvelope.bufferedByteCount == hello50.count,
                "Those bytes are held rather than discarded — the reassembler thinks 2053 bytes are coming")
        }

        // The 4.0 identifiers, pinned against the **reference literals** rather than against
        // `WhoopGATTConstants` — the same distinction the CRC block above is built on, and here it is the
        // only thing that can see the defect at all.
        //
        // A wrong base half does not fail as a decode error, so it never reaches a single assertion below
        // this point: the scan filters on a service the strap does not advertise, the peripheral is never
        // discovered, and every framing, checksum and envelope assertion in this file still passes. That is
        // precisely how the `…82A5-4E40-1CA360B95B30` half sat here unremarked — the suite was green, and a
        // real scan would have found nothing. These literals are noop's `docs/BLE_REVERSE_ENGINEERING.md`
        // line for line, which is also where the five roles come from; `docs/BLE_PROTOCOL.md` §1 carries the
        // provenance and the list of clients that agree.
        let whoop4Base = "8D6D-82B8-614A-1C8CB0F8DCC6"
        assertTest(
            WhoopGATTConstants.whoop4ServiceUUID == CBUUID(string: "61080001-\(whoop4Base)"),
            "The 4.0 service is 61080001-\(whoop4Base) (reference UUID)")
        assertTest(
            WhoopGATTConstants.whoop4CommandUUID == CBUUID(string: "61080002-\(whoop4Base)")
                && WhoopGATTConstants.whoop4ResponseUUID == CBUUID(string: "61080003-\(whoop4Base)")
                && WhoopGATTConstants.whoop4EventsUUID == CBUUID(string: "61080004-\(whoop4Base)"),
            "The 4.0 command, response and event characteristics carry that same base half")
        // The data-stream characteristic is the one a drain reads from, so it is called out separately
        // rather than folded into the line above.
        assertTest(
            WhoopGATTConstants.whoop4DataStreamUUID == CBUUID(string: "61080005-\(whoop4Base)"),
            "The 4.0 data-stream characteristic carries that same base half")
        // The scan list is what discovery actually filters on, so a correct service UUID that is missing
        // from it is just as undiscoverable as a wrong one — and just as quiet.
        assertTest(
            WhoopGATTConstants.scannableServiceUUIDs.contains(WhoopGATTConstants.whoop4ServiceUUID)
                && WhoopGATTConstants.scannableServiceUUIDs.contains(WhoopGATTConstants.whoop5ServiceUUID),
            "The scan list carries both proprietary service families")
    }
}
