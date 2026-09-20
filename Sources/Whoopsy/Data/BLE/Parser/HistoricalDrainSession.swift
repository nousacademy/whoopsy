import Foundation

/// The state machine a flash drain runs through, and the reason a drain is a loop rather than a
/// request.
///
/// **A drain that is started and not answered leaves the strap re-sending the same batch forever.**
/// `BLE_PROTOCOL.md` §4's reference calls it the Groundhog Day bug: records stream back in batches,
/// each one ends with a `HISTORY_END` marker carrying an eight-byte continuation token, and the strap
/// will not move its read cursor until that token comes back in a `HISTORICAL_DATA_RESULT` reply. A
/// build that sends `SEND_HISTORICAL_DATA` while holding no ACK loop is therefore worse off than one
/// that sends nothing — which is why the 4.0's request byte sat at the wrong value until this type
/// existed, and why the correction and the loop landed together.
///
/// **The loop is identical on both generations and so is this type.** The opcodes are the same numbers
/// written in different radixes, the sub-types are the same three, and — the part that is not obvious
/// from either table — **the continuation token sits at the same eight frame bytes on both.** §4 states
/// it twice: as `inner[13:21]` for the 4.0 and as `end_data(8)` at payload `[6,14)` for the 5.0. Those
/// look like different fields and are the same one, because the two payload origins are four bytes
/// apart (frame 7 against frame 11) and `13 - 3 + 7` and `6 + 11` are both **frame 17**. So the offset
/// below is kept frame-absolute, exactly as §6's motion layouts are, and the subtraction happens once.
///
/// **What this type does not do is store anything.** `accept` classifies a frame and says what to send
/// back; the caller is what decides where a record's payload goes. That split is what keeps a session
/// testable with hand-built frames and no strap, which is the only way anything in this file has ever
/// been tested.
public struct HistoricalDrainSession: Sendable {
    /// What the caller should do about one inbound frame.
    public enum DrainAction: Sendable, Equatable {
        /// Nothing to send — a record, a `HISTORY_START`, or a frame belonging to some other
        /// conversation.
        case none

        /// Send `HISTORICAL_DATA_RESULT` carrying this eight-byte token, then keep listening.
        case acknowledge(token: Data)

        /// Send the acknowledgement **and then stop**: the batch that just ended is the live edge, so
        /// there is nothing behind it to fetch.
        case acknowledgeAndFinish(token: Data)

        /// Stop. **Do not acknowledge this one** — §4 is explicit that `HISTORY_COMPLETE` is not a
        /// batch, and answering it is answering a question the strap did not ask.
        case finish
    }

    /// Why a session stopped. Recorded rather than inferred from the counters, because "the strap said
    /// it was done" and "we gave up waiting" are different facts about the same drain and a reader
    /// showing a sync result needs to tell them apart.
    public enum FinishReason: Sendable, Equatable {
        case complete
        case liveEdge
        case idleTimeout
        case aborted
    }

    /// `HISTORY_END`'s continuation token, in **frame-absolute** bytes — 17 through 24 inclusive.
    ///
    /// The number is not in either reference in this form; it is the reconciliation of the two forms
    /// that are (`inner[13:21]` and payload `[6,14)`), and the suite asserts both derivations against
    /// hand-built markers so a future edit that hardcodes one generation's payload offset fails loudly.
    public static let continuationTokenFrameOffset = 17

    /// Eight bytes. The same eight on both generations, which is why one reader serves both.
    public static let continuationTokenBytes = 8

    /// How close to *now* a batch's own timestamp has to be before the drain treats it as the live
    /// edge. **Two-sided on purpose**: a strap whose RTC is wrong is wrong in both directions, and a
    /// one-sided test on a strap running fast would end a drain early and lose the history behind it.
    public static let liveEdgeWindowSeconds: TimeInterval = 5

    /// The 4.0's idle window. §4 reports ~8 s; it is a **reported** figure and not a measured one.
    public static let idleTimeoutWhoop4Seconds: TimeInterval = 8

    /// The 5.0's idle window. §4 reports 60 s as this generation's offload watchdog, re-armed only by
    /// genuine offload frames — which is the sense in which the live 40/43 streams are excluded, and
    /// which is why `accept` only counts a frame as activity when it is this generation's own data or
    /// metadata type.
    public static let idleTimeoutWhoop5Seconds: TimeInterval = 60

    public let profile: WhoopProtocolProfile

    /// Records seen — `historicalData`-typed frames, one per record.
    public private(set) var recordCount = 0

    /// Batches ended — `HISTORY_END` markers, which is what the acknowledgements are counted against.
    public private(set) var batchCount = 0

    /// The last inbound frame that belonged to this drain.
    public private(set) var lastActivity: Date

    public private(set) var finishReason: FinishReason?

    public var isFinished: Bool { finishReason != nil }

    /// The generation's idle window, chosen by the profile rather than by a parameter so a caller
    /// cannot pair a 5.0 window with a 4.0 drain.
    public var idleTimeoutSeconds: TimeInterval {
        profile.headerChecksum == .crc8OverLengthBytes
            ? Self.idleTimeoutWhoop4Seconds
            : Self.idleTimeoutWhoop5Seconds
    }

    public init(profile: WhoopProtocolProfile, startedAt: Date) {
        self.profile = profile
        self.lastActivity = startedAt
    }

    /// Classifies one inbound frame.
    ///
    /// **A frame that is not this generation's data or metadata type is not activity and is not
    /// anything else either** — it returns `.none` without touching `lastActivity`. That matters for
    /// the 5.0, whose live 43 stream shares the connection with the drain: counting live frames as
    /// activity would keep the idle watchdog from ever firing on a strap that has stopped answering.
    public mutating func accept(_ frame: WhoopRawFrame, now: Date) -> DrainAction {
        guard !isFinished else { return .none }

        let types = profile.packetTypes

        if frame.type == types.historicalData {
            recordCount += 1
            lastActivity = now
            return .none
        }

        guard frame.type == types.metadata else { return .none }
        lastActivity = now

        // §4: the metadata sub-type is `inner[2]`, which `WhoopRawFrame` already exposes as `cmd`.
        switch frame.cmd {
        case 1:  // HISTORY_START — informational
            return .none

        case 2:  // HISTORY_END — ack it and keep listening
            batchCount += 1
            guard let token = continuationToken(from: frame) else { return .none }
            if isAtLiveEdge(frame, now: now) {
                finishReason = .liveEdge
                return .acknowledgeAndFinish(token: token)
            }
            return .acknowledge(token: token)

        case 3:  // HISTORY_COMPLETE — stop, and do not ack
            finishReason = .complete
            return .finish

        default:
            return .none
        }
    }

    /// Whether the drain has waited longer than its generation's window. Sets the finish reason when it
    /// fires, so a caller polling it repeatedly gets `true` once and the session is finished after.
    public mutating func checkIdleTimeout(now: Date) -> Bool {
        guard !isFinished else { return false }
        guard now.timeIntervalSince(lastActivity) >= idleTimeoutSeconds else { return false }
        finishReason = .idleTimeout
        return true
    }

    /// Ends the session from this side and records why.
    ///
    /// **The session's own reason wins if it already has one.** A drain that ended because the strap
    /// sent `HISTORY_COMPLETE` and is *then* disconnected must stay `.complete`: relabelling it
    /// `.aborted` would describe a completed sync as an interrupted one, and the count beside it would
    /// read as the records fetched before giving up.
    public mutating func conclude(_ reason: FinishReason) {
        guard !isFinished else { return }
        finishReason = reason
    }

    /// Ends the session from this side — the strap was disconnected, or the user cancelled.
    public mutating func abort() {
        conclude(.aborted)
    }

    /// The eight bytes at `continuationTokenFrameOffset`, read out of a validated payload.
    ///
    /// Returns `nil` rather than a short or padded token when the marker is too short to hold one: a
    /// padded token would be an invented eight bytes, and §4's whole point is that a **wrong** token is
    /// worse than none — it leaves the strap re-sending while this app believes it acknowledged.
    private func continuationToken(from frame: WhoopRawFrame) -> Data? {
        let payloadOrigin = profile.innerOrigin + profile.innerPrefixBytes
        let start = Self.continuationTokenFrameOffset - payloadOrigin
        guard start >= 0, frame.payload.count >= start + Self.continuationTokenBytes else { return nil }
        return frame.payload.subdata(in: start ..< (start + Self.continuationTokenBytes))
    }

    /// Whether the batch that just ended is the present moment.
    ///
    /// **5.0 only, and a heuristic even there.** The marker's own `unix` field is published for that
    /// generation (§4: frame byte 11, so payload byte 0) and is not published for the 4.0, whose marker
    /// layout the reference gives no further than the token — so a 4.0 always answers `false` here and
    /// relies on `HISTORY_COMPLETE` or the idle window to end. Read as "this drain has caught up"
    /// rather than as a timestamp: a strap with an RTC hours out simply never trips it, and the drain
    /// then ends the way it otherwise would.
    private func isAtLiveEdge(_ frame: WhoopRawFrame, now: Date) -> Bool {
        guard profile.headerChecksum == .crc16ModbusOverHeader else { return false }
        let unix = WhoopPacketDecoder.littleEndianUInt32(in: frame.payload)
        guard unix > 0 else { return false }
        let stamp = Date(timeIntervalSince1970: TimeInterval(unix))
        return abs(stamp.timeIntervalSince(now)) <= Self.liveEdgeWindowSeconds
    }
}
