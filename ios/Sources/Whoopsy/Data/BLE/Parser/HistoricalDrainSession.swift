import Foundation

/// The state machine a flash drain runs through, and the reason a drain is a loop rather than a
/// request.
///
/// **A drain that is started and not answered leaves the strap re-sending the same batch forever.**
/// `docs/BLE_PROTOCOL.md` §4's reference calls it the Groundhog Day bug: records stream back in batches,
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

    /// `HISTORY_END`'s continuation token — the eight bytes the drain must echo to advance the strap's
    /// trim cursor.
    ///
    /// **Payload 10, not payload 6.** NOOP reads the ack's `end_data` as `metadata.data[10:18]`, and
    /// `metadata.data` begins at frame 7 on the 4.0 and frame 11 on the 5.0 — so the token is at payload
    /// 10 on both, frame **17** on the 4.0 and frame **21** on the 5.0. This app used to read payload 6
    /// on the 5.0 (a reconciliation of `inner[13:21]` with a `[6,14)` payload form), which is four bytes
    /// early: the strap accepted the acknowledged write and never advanced its trim cursor, so every
    /// drain re-sent the same two August batches for as long as it was left running — measured on the
    /// owner's 5.0 on 2026-10-23, and NOOP's WHOOP5 slice is hardware-verified as `frame[21..25]`.
    public static let continuationTokenPayloadOffset = 10

    /// Eight bytes, at `continuationTokenPayloadOffset`.
    public static let continuationTokenBytes = 8

    /// The token's frame offset for a profile — the payload origin plus the payload offset.
    ///
    /// Exposed as a function rather than a constant because the two generations' frame offsets differ
    /// by the four bytes their envelopes differ by, which is exactly the confusion that put the reader
    /// four bytes early.
    public static func continuationTokenFrameOffset(for profile: WhoopProtocolProfile) -> Int {
        profile.innerOrigin + profile.innerPrefixBytes + continuationTokenPayloadOffset
    }

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

    /// The newest record stamp seen since the last `HISTORY_END`.
    ///
    /// **This, not the marker's own head, is what says whether the drain has caught up.** Measured on
    /// the owner's 5.0 on 2026-10-23: every drain returned the same 59 `R18` records stamped
    /// `2026-08-24 12:51:13` onward, and every `HISTORY_END` closing them carried the phone's current
    /// time in its head — because that field is the drain's clock, not the records'. The old test read
    /// the marker and ended the drain after one batch, leaving two months of backlog unread while
    /// reporting `caughtUpToLiveEdge`. The records decide; the marker is only the fallback for a batch
    /// that carried none.
    private var newestRecordTimestamp: Date?

    /// The layout selector of the record that set `newestRecordTimestamp`.
    ///
    /// **The buffer carries more than one layout under the same packet type**, and a drain's batches
    /// alternate between them on this strap — so a log that shows only the newest stamp can look like
    /// a cursor going backwards when it is two streams' cursors interleaving. This says which stream.
    private var newestRecordLayout: UInt8?

    /// The first record stamp of the batch currently being collected, for the per-batch log line.
    ///
    /// **The newest stamp alone cannot prove the cursor advances** when batches interleave layouts; the
    /// pair (first, newest) can. Logged once per batch rather than once per record.
    private var firstRecordTimestamp: Date?

    /// The newest record stamp seen anywhere in this drain, for the stall guard.
    ///
    /// **The whole drain's maximum, not the previous batch's.** A strap with two buffered bursts
    /// alternates them — A, B, A, B — so each batch is newer than the one immediately before it and a
    /// pairwise comparison never sees a repeat. Measured on the owner's 5.0 on 2026-10-23: two batches
    /// stamped `12:52:11` and `12:58:41` replayed in exactly that order for as long as the drain ran.
    /// Against the maximum, the second pass is a stall on every batch.
    ///
    /// Exposed as well as used: `WhoopBLEDeviceRepositoryImpl` reports it as the drain's newest record,
    /// which is what `RefreshStrainUseCase` backfills up to.
    public private(set) var highestRecordTimestamp: Date?

    /// The oldest record stamp seen anywhere in this drain.
    ///
    /// **The other half of the range, and without it a drain cannot say which days it touched.** The
    /// strain refresh scores the days a drain delivered, and the newest stamp alone would name one end
    /// of a span that can cover a fortnight of backlog. A 4.0's flash has no other index of it.
    public private(set) var lowestRecordTimestamp: Date?

    /// The newest stamp of a **completed** batch — the stall guard's comparison, which must not see the
    /// batch it is judging.
    ///
    /// **Separate from `highestRecordTimestamp` now that the latter is per record.** Comparing a
    /// batch's newest stamp against a drain-wide maximum that already includes that same record makes
    /// every batch look like a repeat, and the drain then stops after three batches on a strap that was
    /// advancing the whole time. This one advances only at `HISTORY_END`, so a batch is measured
    /// against the batches before it — the semantics the guard was written with.
    private var highestCompletedBatchTimestamp: Date?

    /// How many consecutive batches have failed to advance the newest record stamp.
    private var stalledBatchCount = 0

    /// How many repeated batches end a drain.
    ///
    /// A strap that re-sends one batch forever would otherwise be a drain with no end at all: records
    /// keep arriving, so the idle window never fires. Three is the first count at which a repeat is a
    /// stall rather than two batches whose newest records happen to share a second.
    public static let maximumStalledBatches = 3

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
            // Every record's stamp, not only the five the log prints: the newest one is what decides
            // whether the batch that ends after it reached the live edge. See `newestRecordTimestamp`.
            if let stamp = Self.recordTimestamp(frame) {
                if firstRecordTimestamp == nil { firstRecordTimestamp = stamp }
                if let current = newestRecordTimestamp {
                    if stamp > current {
                        newestRecordTimestamp = stamp
                        newestRecordLayout = frame.seq
                    }
                } else {
                    newestRecordTimestamp = stamp
                    newestRecordLayout = frame.seq
                }
                // The drain-wide span, updated per record rather than per batch: the stall guard rides
                // on the maximum, and the refresh's backfill rides on both ends.
                if let lowest = lowestRecordTimestamp {
                    if stamp < lowest { lowestRecordTimestamp = stamp }
                } else {
                    lowestRecordTimestamp = stamp
                }
                if let highest = highestRecordTimestamp {
                    if stamp > highest { highestRecordTimestamp = stamp }
                } else {
                    highestRecordTimestamp = stamp
                }
            }
            // **The drain's only per-record line, and it is rate-limited to the first five.** A
            // completed sync reports a count and nothing else, so "59 records" cannot say whether the
            // strap handed back heart rate, motion, or fifty-nine records of an unmapped type — the
            // three outcomes that need three different next steps. The layout selector at `inner[1]`
            // is what chooses the walk, so it and the payload length are the two fields worth seeing.
            if recordCount <= 5 {
                let index = recordCount
                let payloadBytes = frame.payload.count
                let layout = frame.seq
                let type = String(frame.type, radix: 16, uppercase: true)
                // **The record's own clock, and it is the question a count cannot answer.** A drain
                // that keeps returning ~60 records could be reading the live edge (records stamped
                // now) or a backlog (records stamped hours ago) — the two need opposite next steps.
                // `R18`'s unix is a u32 little-endian at payload `[4]`, the field its decoder files the
                // sample by; anything else is left as `-`.
                let stamp = Self.recordTimestamp(frame)?.description ?? "-"
                AppLogger.ble.notice("""
                    Drain record #\(index, privacy: .public): type=0x\(type, privacy: .public) \
                    layout=\(layout, privacy: .public) payload=\(payloadBytes, privacy: .public) B \
                    stamp=\(stamp, privacy: .public)
                    """)
            }
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
            // **The marker's own contents, and the answer this log was built to get.** The live-edge
            // test used to read a u32 at the payload's head and compare it with the wall clock — and
            // that field is the *drain's* time, not the buffer's. On the owner's 5.0 on 2026-10-23
            // every drain returned records stamped two months earlier and a marker stamped now, so
            // the test declared the live edge after one batch and the backlog was never read. The
            // records now decide (`isAtLiveEdge`); the marker remains the fallback for a batch with
            // none, and both are in this line so the next run can show which answer was used.
            let payloadHex = [UInt8](frame.payload.prefix(24))
                .map { String(format: "%02X", $0) }
                .joined(separator: " ")
            let markerUnix = WhoopPacketDecoder.littleEndianUInt32(in: frame.payload)
            let batchNewest = newestRecordTimestamp
            let batchFirst = firstRecordTimestamp
            let batchLayout = newestRecordLayout
            let atEdge = isAtLiveEdge(frame, now: now)
            let seen = recordCount

            // A batch that does not beat the drain's highest stamp is the strap re-sending, and an
            // unguarded loop of those never idles out because the records keep arriving.
            if let batchNewest, let highest = highestCompletedBatchTimestamp, batchNewest <= highest {
                stalledBatchCount += 1
            } else {
                stalledBatchCount = 0
                if let batchNewest { highestCompletedBatchTimestamp = batchNewest }
            }
            newestRecordTimestamp = nil
            newestRecordLayout = nil
            firstRecordTimestamp = nil
            let stalled = stalledBatchCount

            AppLogger.ble.notice("""
                HISTORY_END: payload=\(payloadHex, privacy: .public) \
                headAsUnix=\(markerUnix, privacy: .public) liveEdge=\(atEdge, privacy: .public) \
                firstRecord=\(batchFirst?.description ?? "none", privacy: .public) \
                newestRecord=\(batchNewest?.description ?? "none", privacy: .public) \
                newestLayout=\(batchLayout.map { String($0) } ?? "none", privacy: .public) \
                recordsSoFar=\(seen, privacy: .public) stalled=\(stalled, privacy: .public)
                """)
            guard let token = continuationToken(from: frame) else { return .none }
            if stalledBatchCount >= Self.maximumStalledBatches {
                // Acknowledged either way — the strap is waiting — but the drain stops rather than
                // reading one batch forever. The reason is set here so `concludeDrain(reason:)`'s
                // relabel is a no-op.
                finishReason = .idleTimeout
                return .acknowledgeAndFinish(token: token)
            }
            if atEdge {
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
        // Payload-relative and identical on both generations — see `continuationTokenPayloadOffset`.
        let start = Self.continuationTokenPayloadOffset
        guard frame.payload.count >= start + Self.continuationTokenBytes else { return nil }
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
        // **The records first, the marker only as a fallback.** The marker's head is the drain's own
        // clock on a 5.0 — measured on the owner's strap, where it was current while the records it
        // closed were two months old — so trusting it ends a backlog drain after one batch.
        let stamp: Date?
        if let newest = newestRecordTimestamp {
            stamp = newest
        } else if let highest = highestRecordTimestamp {
            // **An empty batch is the end of the buffer, not the live edge.** The strap closes its
            // last chunk with a marker carrying no records, and that marker's head is the drain's
            // clock — now — so reading it declared a two-month-old buffer "caught up" on the owner's
            // 5.0 on 2026-10-23. The drain-wide highest record is the honest test; the marker is only
            // for a session that has seen no record at all.
            stamp = highest
        } else {
            let unix = WhoopPacketDecoder.littleEndianUInt32(in: frame.payload)
            stamp = unix > 1_000_000_000
                ? Date(timeIntervalSince1970: TimeInterval(unix))
                : nil
        }
        guard let stamp else { return false }
        return abs(stamp.timeIntervalSince(now)) <= Self.liveEdgeWindowSeconds
    }

    /// The record's own unix stamp: a `u32` at payload `[4]` in every historical layout this app
    /// walks — `R18`, `R21` and the 4.0's type 24.
    ///
    /// `nil` when the record is too short to carry it or the value is not a real date. The `> 1e9`
    /// floor is 2001-09-09, the same one the per-record log used before this became load-bearing: a
    /// lost RTC's `2000-01-03` is a stamp, but it is not evidence of catching up to the present.
    static func recordTimestamp(_ frame: WhoopRawFrame) -> Date? {
        guard frame.payload.count >= 8 else { return nil }
        let p = [UInt8](frame.payload.prefix(8))
        let seconds = UInt32(p[4]) | (UInt32(p[5]) << 8)
            | (UInt32(p[6]) << 16) | (UInt32(p[7]) << 24)
        guard seconds > 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
