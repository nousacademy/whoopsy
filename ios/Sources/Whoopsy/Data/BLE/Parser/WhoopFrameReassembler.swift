import Foundation

/// Reassembles a proprietary frame that arrives split across several BLE notifications.
///
/// `docs/BLE_PROTOCOL.md` §4 names this as the remaining half of the framing problem: the decoder verifies a
/// frame's checksums, but it is handed **one notification's bytes**, so a frame longer than the
/// negotiated MTU is not "rejected" — it is never seen at all. `decodeProprietaryFrame` requires
/// `data.count >= declaredLength + 4` and returns `nil` when it is short, and the manager drops that
/// `nil` on the floor. Every record the motion path needs is in that category: the 4.0 live IMU
/// stream runs to **1921** bytes of frame — 1917 declared, the one motion layout in `docs/BLE_PROTOCOL.md`
/// §6 that is published and hardware-verified — and the 5.0/MG type-47 buffer to 1244 or 2140 by that
/// document's least-verifiable source, against a notification that carries at most `MTU − 3` bytes.
/// So nothing downstream of the envelope is reachable until this exists.
///
/// **The reassembler owns boundaries, not validity.** It decides where a frame starts and how long it
/// is; it never decides whether the bytes are a frame. That second question has exactly one answer in
/// this codebase — `WhoopPacketDecoder.decodeProprietaryFrame` — and this type calls it rather than
/// restating its rules. A candidate the decoder refuses is treated as evidence that the `0xAA` it
/// started on was a payload byte that happened to look like a boundary, and the scan resumes one byte
/// later. Duplicating the length or checksum rules here is the drift this arrangement exists to
/// prevent: the two would agree until one moved.
///
/// Three consequences worth stating rather than discovering:
///
/// * **Resynchronisation is automatic and costs bytes, never a wrong reading.** A frame lost to a
///   dropped notification leaves the buffer holding bytes that will never form a valid frame; the
///   scan walks past them one `0xAA` at a time and picks up at the next real boundary. There is no
///   "resync mode" to enter or leave.
/// * **The buffer is bounded without a trim rule.** The scan cannot stop on a candidate longer than
///   `maximumFrameBytes`, so the buffer holds at most one such candidate plus the notification that
///   overflowed it — see that constant.
/// * **State is per-connection.** `reset()` must be called on connect and on disconnect; a partial
///   frame left over from a previous connection would prepend stale bytes to the new stream's first
///   frame and shift every field in it.
///
/// **Nothing here has been exercised against a strap.** No proprietary frame has ever been captured
/// on this project's hardware — `biometric_samples` holds zero rows in every database on this machine
/// — so this is written to the documented framing and proven by synthetic fragments, and a passing
/// run is evidence about the reassembler and not about a strap.
public struct WhoopFrameReassembler: Sendable {
    /// The largest frame this type will hold bytes for.
    ///
    /// **Its job is to stop a false boundary from stalling the scan, not to describe the protocol.**
    /// Without it, a payload byte that reads as `0xAA` and happens to be followed by a large length
    /// would park the scan waiting for bytes that will never arrive, and every frame behind it would
    /// be held with it. A boundary declaring more than this is treated as false and skipped, so the
    /// buffer is bounded by this plus one notification's worth of bytes.
    ///
    /// **The value is set above every documented shape rather than measured.** The largest record
    /// `docs/BLE_PROTOCOL.md` describes is the 5.0/MG optical buffer, which declares 2140 bytes — the frame
    /// is `innerOrigin + declaredLength`, so 2148 under the 5.0 envelope and 2144 under the 4.0 one,
    /// and the 5.0 figure is the one that counts because that is the envelope the record arrives
    /// under. The 4.0 live IMU frame at 1921 bytes, the 5.0/MG IMU record at 1244 declared bytes and
    /// its 124-byte rollup all sit below both. 4096 clears all of them. **The error is asymmetric and
    /// that is why the value is generous**: a real frame larger than this would be skipped and decode
    /// as nothing, which is silent but writes no reading, whereas a bound set too low for a shape
    /// nobody has seen yet would do the same thing — so the cost of being wrong is a frame not decoded
    /// rather than a wrong one. Only the 4.0's figure is hardware-verified; the 5.0/MG shapes come
    /// from the one source `docs/BLE_PROTOCOL.md` cannot reach, so a capture is what would settle them —
    /// §7 Q9 asks for one.
    public static let maximumFrameBytes: Int = 4096

    /// Bytes held from the previous notification that have not yet formed a complete frame.
    ///
    /// Exposed because it is the one piece of state a caller can be wrong about: a non-zero count
    /// after a disconnect is the bug `reset()` prevents, and there is otherwise no way to see it.
    public var bufferedByteCount: Int { buffer.count }

    private let decoder = WhoopPacketDecoder()
    private var buffer: [UInt8] = []

    public init() {}

    /// Discards any partial frame.
    ///
    /// Called on connect and on disconnect. A new connection is a new byte stream: bytes held from
    /// the previous one would be prepended to its first frame, moving every field by the number of
    /// bytes held — which would surface as a checksum failure rather than as a decode, so the frame
    /// would be lost rather than corrupted. It is still wrong, and it is cheap to be right.
    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }

    /// Appends one notification's bytes and returns every complete frame they completed.
    ///
    /// Returns an array rather than yielding, because a single notification can carry a whole frame
    /// plus the head of the next — and after a gap, several frames can be completed at once. The
    /// caller walks the result the same way it would walk one frame.
    ///
    /// The scan is length-driven from the first `0xAA` it can find, and every `Int` below is an offset
    /// into `buffer` from zero, which is why the buffer is a `[UInt8]` and not a `Data`: a `Data`
    /// slice carries the indices of the buffer it came from, and a scan written against one silently
    /// reads the wrong bytes once the head is trimmed.
    public mutating func append(_ data: Data, profile: WhoopProtocolProfile) -> [WhoopRawFrame] {
        buffer.append(contentsOf: data)

        var frames: [WhoopRawFrame] = []
        var consumed = 0
        // Bytes skipped because they could not begin a frame. Reported once per call rather than once
        // per byte: a resync through a long stretch of noise is one event, not several hundred.
        var discarded = 0

        while true {
            // A frame starts at the first 0xAA from here. Anything before it is not a frame's head —
            // either the tail of one that was lost, or bytes the strap sent that this build does not
            // model — so it is dropped rather than prepended to the next candidate.
            guard let start = buffer[consumed...].firstIndex(of: WhoopPacketDecoder.startOfFrame) else {
                discarded += buffer.count - consumed
                consumed = buffer.count
                break
            }
            discarded += start - consumed
            consumed = start

            // The declared length is a `u16` at the profile's own offset, so a candidate needs that
            // plus two bytes before its size is knowable — three under 4.0, four under 5.0, which
            // spends byte 1 on a format byte. **This was a literal three, on the stated belief that
            // "§2's two envelopes both put `length` at `[1..3]`".** That belief was wrong in the same
            // way §2's packet-type table was wrong: 5.0's length is at `[2..4]`, and reading it at
            // `[1]` would take the format byte as its low half.
            guard buffer.count >= consumed + profile.lengthFieldOffset + 2 else { break }

            let declaredLength = Int(buffer[consumed + profile.lengthFieldOffset])
                | (Int(buffer[consumed + profile.lengthFieldOffset + 1]) << 8)
            let frameBytes = profile.frameByteCount(declaredLength: declaredLength)

            // The lower bound is derived from the profile rather than restated, so it moves with the
            // envelope: it is the same inequality `decodeProprietaryFrame` applies, and a length below
            // it could not hold the inner record's own prefix.
            guard declaredLength >= WhoopProtocolProfile.checksumTrailerBytes + profile.innerPrefixBytes,
                  frameBytes <= Self.maximumFrameBytes
            else {
                // A false boundary. Step past this byte and look for the next one — never skip the
                // declared length, because the length came from the byte we are rejecting.
                consumed += 1
                continue
            }

            // Not all here yet. Stop without consuming: the next notification resumes from this
            // start of frame, which is what makes a split frame cost one buffer and no bookkeeping.
            guard buffer.count >= consumed + frameBytes else { break }

            let candidate = Data(buffer[consumed..<(consumed + frameBytes)])
            if let frame = decoder.decodeProprietaryFrame(data: candidate, profile: profile) {
                frames.append(frame)
                consumed += frameBytes
            } else {
                // The decoder refused it, so this 0xAA was a payload byte. Its declared length is
                // meaningless and stepping by it would skip a real boundary.
                consumed += 1
            }
        }

        buffer.removeFirst(consumed)

        if discarded > 0 {
            // Read into locals before logging: `AppLogger`'s message is an `@autoclosure`, so
            // interpolating `buffer.count` directly would capture this `mutating` method's `self`
            // from an escaping context.
            let held = buffer.count
            AppLogger.decoder.debug("""
                Reassembly: discarded \(discarded, privacy: .public) bytes before a frame boundary, \
                holding \(held, privacy: .public)
                """)
        }

        return frames
    }
}
