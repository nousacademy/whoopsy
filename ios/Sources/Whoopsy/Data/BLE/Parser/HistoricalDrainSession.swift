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

    /// Where a Gen 5 `HISTORY_END` declares how many frames the burst carried.
    ///
    /// **Payload 6 is frame `inner[9]`, and it is a count only on a 5.0/MG.** [reported] OpenStrap's
    /// Gen 5 reference (`PROTOCOL-GEN5.md` §8) puts `expected_count`, a u32 LE, at `inner[9]`; that
    /// reference's Gen 4 document puts a "record-id / batch counter (not echoed)" at the same offset.
    /// The two generations number their fields alike and mean different things by this one, which is
    /// why `WhoopProtocolProfile.declaresBurstFrameCount` gates the read rather than a bare literal.
    ///
    /// Payload 6 sits between the strap clock at 0 and the continuation token at 10, so a marker long
    /// enough for the token is long enough for this. See `burstFrameCounts`.
    public static let expectedFrameCountPayloadOffset = 6

    /// The frame types a Gen 5 burst's declared count covers — **the membership, and getting it wrong
    /// makes the strap re-offer the same burst forever**.
    ///
    /// [reported] `PROTOCOL-GEN5.md` §8: count each complete frame once, for types 47, 48, 50, 53, 54
    /// and 55 only. Type 49 is the marker that carries the count and does not count itself; 51 and 52
    /// (the IMU stream) are excluded. Revision and byte length are irrelevant — a frame this build
    /// cannot decode still counts, which is the property that keeps a burst of unknown revisions from
    /// being trimmed past.
    public static let countedFrameTypes: Set<UInt8> = [47, 48, 50, 53, 54, 55]

    /// What one burst said it carried, against what this session counted — the evidence the next
    /// decision about the count gate needs.
    ///
    /// **Recorded, logged and not enforced.** Nothing about the acknowledgement depends on this yet:
    /// the session still ACKs success after every `HISTORY_END`. Turning a mismatch into the negative
    /// result (Gen 5 body `00 00`) is the step that makes the strap re-offer a short burst, and it
    /// waits until a capture shows `expected` and `counted` agreeing on an ordinary burst — a validator
    /// whose membership is wrong would refuse good bursts forever, which is worse than the silent loss
    /// it is meant to catch.
    public struct BurstFrameCounts: Equatable, Sendable {
        public let expected: Int
        public let counted: Int
        public init(expected: Int, counted: Int) {
            self.expected = expected
            self.counted = counted
        }
        public var matches: Bool { expected == counted }
        /// `expected - counted`, negative when more frames arrived than were declared.
        public var difference: Int { expected - counted }
    }

    /// The last completed burst's declared and counted frames, or `nil` on a generation that declares
    /// none and for a burst whose marker was too short to hold the field.
    public private(set) var lastBurstFrameCounts: BurstFrameCounts?

    /// The continued-read cursor the last `HISTORY_END` handed us, as the two words the references
    /// name, or `nil` for a marker too short to carry a token.
    ///
    /// **This is the value the acknowledgement echoes**, so it is the one number that can explain a
    /// rewind: a burst that begins at a stamp an earlier burst already covered is the strap reading
    /// from an earlier page, and a token that went backwards says so directly where the stamps only
    /// suggest it.
    public private(set) var lastTrimCursor: TrimCursor?

    /// The first record stamp of the previous **completed** batch, for the repeat test below.
    private var previousBatchFirstTimestamp: Date?

    /// Whether the batch that just ended began **at or before** the previous batch's first record, or
    /// `nil` before two batches have completed.
    ///
    /// **This is the rewind made observable rather than inferred.** A re-sent stretch shows up as two
    /// batches whose `first` stamps go backwards or repeat while both declared counts match — measured
    /// on 2026-10-25, where a drain produced `first=23:17:49` twice and then `first=23:38:49` after
    /// `23:38:53`. Reading that out of a capture by eye needs two lines side by side, and a rotation
    /// can separate them into different files; a flag on the line itself cannot be separated.
    ///
    /// It says *the stream went back*, not *why*. The trim cursor on the same line is the evidence that
    /// distinguishes a cursor that stalled from a strap re-sending on its own.
    public private(set) var lastBatchRepeatedStart: Bool?

    /// How many completed batches began at or before the batch before them.
    public private(set) var repeatedStartBatchCount = 0

    /// The eight-byte continuation token, read as the references describe it:
    /// `[u32 trim page][u32 wrap count]`, both little-endian.
    ///
    /// **[reported] The two names are OpenStrap's** (`PROTOCOL.md` §4.2 for the Gen 4 token, and the
    /// Gen 5 reference's marker layout at `inner[13:21]`). The wrap count is **not** a per-batch
    /// identifier — it changes only when the ring buffer wraps, so consecutive bursts routinely share
    /// it. A `trim` that does not move, or moves and returns between two bursts, is the rewind; a
    /// `wrap` that changes is the buffer having gone round, which makes a stamp comparison across it
    /// meaningless.
    public struct TrimCursor: Equatable, Sendable {
        public let trimPage: UInt32
        public let wrapCount: UInt32
        public init(trimPage: UInt32, wrapCount: UInt32) {
            self.trimPage = trimPage
            self.wrapCount = wrapCount
        }

        /// The two words of an eight-byte token, or `nil` for anything of another length — the same
        /// refusal `continuationToken(from:)` makes, applied to the value rather than to the marker.
        public static func decode(_ token: Data) -> TrimCursor? {
            guard token.count == continuationTokenBytes else { return nil }
            return TrimCursor(
                trimPage: WhoopPacketDecoder.littleEndianUInt32(in: token),
                wrapCount: WhoopPacketDecoder.littleEndianUInt32(in: token.dropFirst(4)))
        }
    }

    /// Every frame type the current batch carried, and how many of each, reset at each `HISTORY_END`.
    ///
    /// **This is instrumentation today and the count gate's input tomorrow.** It is recorded at the top
    /// of `accept`, before any revision or layout walk, because the reference's rule is one count per
    /// complete frame *independent of revision*. `countedFrameTypes` is the subset that would be
    /// validated; type 49 is in this histogram only so a burst's framing is visible in the log.
    private var batchTypeCounts: [UInt8: Int] = [:]

    /// The frame types whose presence in a burst is worth counting — `countedFrameTypes` plus the
    /// marker itself, so the log shows `31×2` on a burst that opened and closed.
    public static let countedBatchTypes: Set<UInt8> = countedFrameTypes.union([49])

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

    /// When the drain asked the strap, for the summary line that outlives the per-batch ones.
    ///
    /// **The per-batch lines rotate; the summary does not.** A night's drain is ~480 one-minute
    /// bursts, and `CaptureLog` keeps 64 KB plus one rotated file — enough for an ordinary night but
    /// not with room to spare, and the line a morning reader most needs is the **first** one. So the
    /// drain's own start, range and repeat count belong on the closing line rather than only in the
    /// batches a rotation can drop.
    public let startedAt: Date

    public init(profile: WhoopProtocolProfile, startedAt: Date) {
        self.profile = profile
        self.startedAt = startedAt
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

        // The six types OpenStrap's Gen 5 reference says a burst's declared count covers, plus the
        // metadata marker itself so a burst's framing is visible: 47 `historicalData`, 48 events,
        // 49 metadata, and 50/53/54/55. Live telemetry (43) is deliberately absent — it is the frame a
        // drain must not mistake for activity.
        if Self.countedBatchTypes.contains(frame.type) {
            batchTypeCounts[frame.type, default: 0] += 1
        }

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
            // **The cursor we are about to echo, read before the log rather than after it.** The
            // rewind this drain shows — a burst beginning at a stamp an earlier burst already
            // covered, with both sides' counts matching — is a trim-cursor question, and the token is
            // the cursor. Two words, as the references name them: a trim page and a wrap count.
            let token = continuationToken(from: frame)
            lastTrimCursor = token.flatMap(TrimCursor.decode)
            let batchNewest = newestRecordTimestamp
            let batchFirst = firstRecordTimestamp
            let batchLayout = newestRecordLayout
            let atEdge = isAtLiveEdge(frame, now: now)
            let seen = recordCount
            let batchTypes = batchTypeCounts
                .sorted { $0.key < $1.key }
                .map { String(format: "%02X\u{00D7}%d", $0.key, $0.value) }
                .joined(separator: ",")
            // **The count gate, read and not yet obeyed.** Gen 5 declares how many frames the burst
            // carried; Gen 4's field at the same offset is a batch counter, so the read is gated by the
            // envelope. What the log needs is both numbers side by side: `counted=47` against
            // `expected=55` is a burst we received two thirds of, and `expected == counted` on a burst
            // the strap re-offers would rule this whole hypothesis out, which no other line can do.
            let counts = profile.declaresBurstFrameCount
                ? Self.burstFrameCounts(in: frame, batchTypeCounts: batchTypeCounts)
                : nil
            lastBurstFrameCounts = counts
            let countsText = counts.map {
                "expected=\($0.expected) counted=\($0.counted)"
                    + ($0.matches ? "" : " delta=\($0.difference)")
            } ?? "expected=- counted=-"
            // The trim cursor itself, in the references' own terms. A page that does not advance
            // between two bursts, or advances and then comes back, is the rewind made visible.
            let cursorText = lastTrimCursor.map {
                "trim=\($0.trimPage) wrap=\($0.wrapCount)"
            } ?? "trim=- wrap=-"
            // **Did this batch start at or before the one before it?** The rewind, decided at the
            // marker rather than by comparing captures later.
            let repeated = batchFirst.map { first in
                previousBatchFirstTimestamp.map { first <= $0 } ?? false
            } ?? false
            lastBatchRepeatedStart = repeated
            if repeated { repeatedStartBatchCount += 1 }
            if let batchFirst { previousBatchFirstTimestamp = batchFirst }

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
            batchTypeCounts = [:]
            let stalled = stalledBatchCount

            AppLogger.ble.notice("""
                HISTORY_END: payload=\(payloadHex, privacy: .public) \
                headAsUnix=\(markerUnix, privacy: .public) liveEdge=\(atEdge, privacy: .public) \
                firstRecord=\(batchFirst?.description ?? "none", privacy: .public) \
                newestRecord=\(batchNewest?.description ?? "none", privacy: .public) \
                newestLayout=\(batchLayout.map { String($0) } ?? "none", privacy: .public) \
                recordsSoFar=\(seen, privacy: .public) stalled=\(stalled, privacy: .public) \
                \(countsText, privacy: .public) \(cursorText, privacy: .public) \
                repeat=\(repeated, privacy: .public) types=\(batchTypes, privacy: .public)
                """)
            // **The same line into the file that outlives the log's two-minute window.**
            // `CaptureLog.shared` is `Documents/capture.txt`, capped and rotating, and it exists
            // precisely because a drain is read minutes after the fact — `/usr/bin/log`'s device
            // archive had already rolled past three of these before they could be pulled. The batch
            // summary is the one line per minute of history that carries the stamps; the per-record
            // line stays in `os.log` so a long drain cannot rotate the file away.
            CaptureLog.shared.append(
                "DRAIN_BATCH first=\(batchFirst?.ISO8601Format() ?? "-") "
                    + "newest=\(batchNewest?.ISO8601Format() ?? "-") "
                    + "layout=\(batchLayout.map { String($0) } ?? "-") "
                    + "soFar=\(seen) stalled=\(stalled) liveEdge=\(atEdge) "
                    + "\(countsText) \(cursorText) repeat=\(repeated) types=\(batchTypes)")
            guard let token else { return .none }
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

    /// What a Gen 5 marker declared against what this burst actually carried.
    ///
    /// The declared side is a u32 LE at `expectedFrameCountPayloadOffset`; the counted side is the
    /// histogram restricted to `countedFrameTypes`, so 49's own framing never inflates it. `nil` when
    /// the marker is too short to hold the field — a marker that never declared a count cannot disagree
    /// with one, and inventing `0` there would read as a burst we received nothing of.
    static func burstFrameCounts(
        in frame: WhoopRawFrame,
        batchTypeCounts: [UInt8: Int]
    ) -> BurstFrameCounts? {
        let start = expectedFrameCountPayloadOffset
        guard frame.payload.count >= start + 4 else { return nil }
        let expected = Int(WhoopPacketDecoder.littleEndianUInt32(in: frame.payload.dropFirst(start)))
        let counted = batchTypeCounts.reduce(0) { total, entry in
            countedFrameTypes.contains(entry.key) ? total + entry.value : total
        }
        return BurstFrameCounts(expected: expected, counted: counted)
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

    /// The record layouts whose own stamp sits on the **1 Hz grid** — R18, R21 and the 4.0's type 24.
    ///
    /// **A type-47 frame is not automatically a one-second record, and R26 is the one that proves it.**
    /// [reported] The Gen 5 reference (§5) lists revision 26 as the *Pulse Information Packet* — an
    /// 88-byte frame among the 1 Hz records that carries its own event time rather than a slot on the
    /// grid. Measured on the owner's 5.0 on 2026-10-26: a burst of one `R26` record stamped
    /// `00:18:04` arrived after a batch that had already reached `00:18:43`, and the drain logged
    /// `stalled=1` for a strap that was advancing perfectly well.
    ///
    /// **That count is a fuse rather than a log line.** Three consecutive stalled batches end the
    /// drain as `.idleTimeout`, so a night with a few `R26` bursts would stop a good drain and report
    /// it as a stalled one. The live edge has the same problem in the other direction: an `R26` stamped
    /// *now* would end a drain that still had history behind it. So the stamp reader refuses every
    /// layout not in this set — the record still counts toward the burst and toward `recordCount`, it
    /// just cannot be the clock.
    public static let timestampedLayouts: Set<UInt8> = [
        HeartRatePayloadDecoder.historicalLayout,
        MotionPayloadDecoder.r21Layout,
        HeartRatePayloadDecoder.whoop4HistoricalLayout,
    ]

    /// The record's own unix stamp: a `u32` at payload `[4]` in every historical layout **on the 1 Hz
    /// grid** — `R18`, `R21` and the 4.0's type 24.
    ///
    /// `nil` for a layout outside `timestampedLayouts`, for a record too short to carry the field, and
    /// for a value that is not a real date. **The layout gate is the load-bearing part**: `R26` carries
    /// a stamp-like field at the same offset with a different meaning, and both the stall guard and the
    /// live edge treat a stamp as evidence about the drain's position. The `> 1e9` floor is 2001-09-09,
    /// the same one the per-record log used before this became load-bearing: a lost RTC's `2000-01-03`
    /// is a stamp, but it is not evidence of catching up to the present.
    public static func recordTimestamp(_ frame: WhoopRawFrame) -> Date? {
        guard timestampedLayouts.contains(frame.seq) else { return nil }
        guard frame.payload.count >= 8 else { return nil }
        let p = [UInt8](frame.payload.prefix(8))
        let seconds = UInt32(p[4]) | (UInt32(p[5]) << 8)
            | (UInt32(p[6]) << 16) | (UInt32(p[7]) << 24)
        guard seconds > 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
