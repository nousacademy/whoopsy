import Foundation

public protocol WhoopBLEDeviceRepository: Sendable {
    /// Stream of peripheral device status changes
    var deviceStream: AsyncStream<WhoopDevice> { get }

    /// Stream of incoming decoded biometric samples
    var liveTelemetryStream: AsyncStream<BiometricSample> { get }

    /// Stream of decoded 100 Hz motion, one batch per `REALTIME_RAW_DATA` / R21 record.
    ///
    /// **A second stream rather than a field on `BiometricSample`**, because the two arrive on
    /// different records, at different rates, and neither is derivable from the other: a heart-rate
    /// notification carries no motion and a motion record carries no heart rate. Folding them would
    /// force every consumer of either to buffer for the other.
    ///
    /// Both generations feed this. The 4.0's live R10 record and the 5.0/MG's R21 record — live on
    /// packet 43 or drained from flash as packet 47 — decode to the same `MotionBatch`, which is what
    /// lets one step counter serve all three straps.
    ///
    /// The stream is **empty until the motion decoder is wired to the proprietary branch**, which is
    /// the honest answer rather than a fabricated one: nothing has been decoded, so nothing is
    /// yielded.
    var motionStream: AsyncStream<MotionBatch> { get }

    /// The strap's own cumulative pedometer, one sample per drained **R18** record — 5.0/MG only.
    ///
    /// **A fourth stream rather than a field on `MotionBatch`**, because the two are different
    /// sensors' answers: a motion record is 100 Hz of acceleration, a counter record is the firmware's
    /// own tally. `MotionBatch` is the input a peak detector needs; this is the answer that makes the
    /// peak detector unnecessary where it exists.
    ///
    /// **The stream is empty until a drain runs**, because the field lives in the historical record.
    /// A strap that is connected but never drained therefore contributes no counter samples and the
    /// detector remains the day's source — which is the honest fallback rather than a fabricated
    /// counter. Unlike `historicalTelemetryStream` it is **not finished at the drain's end**: the
    /// consumer is the long-lived step writer, and a stream that ends would have to be re-attached.
    var stepCounterStream: AsyncStream<StepCounterSample> { get }

    /// Heart-rate samples recovered by a historical drain, one per R18 record, stamped with the
    /// **moment the strap stored them** rather than with their arrival.
    ///
    /// **A separate stream from `liveTelemetryStream`, not a second source into it.** A drained sample
    /// is a day or more old, and every live consumer draws "now" from what it receives — merging the
    /// two would put a three-day-old pulse on the Home badge. The stream ends when the drain ends:
    /// `requestHistoricalSync` and this stream describe one operation, and the consumer reads both at
    /// once.
    ///
    /// **This is the producer that used to be missing entirely.** A drained R18 record carried a heart
    /// rate and R-R intervals and nothing decoded it, so the strap's history — the only place its
    /// stored biometrics live — reached the store as counts and no rows.
    var historicalTelemetryStream: AsyncStream<BiometricSample> { get }

    /// Scan for nearby WHOOP straps
    func startScanning() async throws

    /// Stop scanning
    func stopScanning() async

    /// Connect to a specific WHOOP device ID
    func connect(to deviceId: String) async throws

    /// Disconnect from the current strap
    func disconnect() async

    /// Re-arm the link after the app returns to the foreground.
    ///
    /// **Not the same action as `startScanning`.** It leaves a live link alone, re-issues a standing
    /// connect for one that is down, and scans only when no strap has ever been found in this process.
    /// It also does nothing after an explicit `disconnect()`, which is the user's own instruction.
    func rearmConnection() async

    /// Send a haptic vibration alert command to the strap
    func sendHapticAlert(durationSeconds: Int, pattern: Int) async throws

    /// Drains the strap's flash buffer, and **returns when the drain ends rather than when the
    /// request is written.**
    ///
    /// The distinction is the whole reason this returns a value. A drain is a loop, not a request:
    /// records arrive in batches, each one is acknowledged, and the strap decides when there is
    /// nothing left. A caller told "sent" would be reporting a sync that had not happened — which is
    /// what `DeviceViewModel` printed until this signature existed.
    ///
    /// Throws `WhoopSyncError` when there is no path to a drain at all, so "nothing was sent" cannot
    /// be reported as a completed sync by a caller that only reads the absence of a throw.
    func requestHistoricalSync(from startDate: Date, to endDate: Date) async throws -> HistoricalSyncOutcome

    /// Restarts the strap's firmware — `0x1D REBOOT_STRAP`.
    ///
    /// **A recovery, not a routine command.** It exists because a strap whose RTC was lost is
    /// documented to stop writing history to flash, and a reboot is the way to re-initialise that
    /// path; it erases nothing. The link drops when the strap restarts, and the standing connect
    /// re-establishes it when the strap comes back.
    ///
    /// Throws when there is no command path, so a caller cannot report a reboot that was never sent.
    func rebootStrap() async throws

    /// Sends the 5.0/MG's `0x9A TOGGLE_PERSISTENT_R21` with state `enabled`, and nothing else.
    ///
    /// **A deliberate experiment, not a setting.** It exists only because the flash recorder stopped
    /// with no other explanation (`docs/TODO.md` §7.2), it is reachable only from the device page's
    /// ADVANCED tab, and no connect path may call it. The strap acknowledges the write and **does not
    /// confirm the programming** — a caller must say *requested*, never *enabled*, and point at a
    /// drain as the verification.
    ///
    /// Throws `WhoopSyncError.commandUnavailable` when the connected strap is not a command-capable
    /// 5.0/MG, and `noCommandPath` when nothing was sent — never a `false` a caller could read as
    /// "off".
    func setPersistentRecording(_ enabled: Bool) async throws

    /// Asks the strap to advertise a different name — see `WhoopCommandFrames.setAdvertisingName`.
    ///
    /// A throw means nothing was written. A return means the frame reached the link and **nothing
    /// more**: the write is unconfirmed on both generations, so the caller reports it as requested.
    func setAdvertisingName(_ name: String) async throws

    /// Asks the strap for the name it has stored, logging the reply for a capture.
    func requestAdvertisingName() async

    /// Get the current connected device state
    func getCurrentDevice() async -> WhoopDevice?

    /// Re-reads the stored per-strap model and re-resolves the connected strap's generation.
    ///
    /// The generation decides which envelope a command is framed with and whether one can be framed
    /// at all, so a change to it has to reach the BLE layer before the next command is sent. This is
    /// what the device screen calls the moment the user picks a model — without it the choice would
    /// not take effect until the strap was rediscovered.
    func refreshStrapModel() async
}

/// What a historical drain actually did.
///
/// **A count and an ending, because those are the two things a caller can honestly say about a sync.**
/// The alternative — a `Bool` or a `Void` — cannot distinguish the strap reporting that it is done
/// from this side giving up on it, and those are different sentences on a screen: "History sync
/// complete." over a drain that hit the idle window is a claim about the strap's buffer that nothing
/// verified.
///
/// `ending` is a `Domain` enum rather than the BLE layer's `HistoricalDrainSession.FinishReason` for
/// the reason the layer rule gives: `Domain/` imports `Foundation` and nothing else, so a type in
/// `Data/BLE/` cannot appear in a protocol here. The two are mapped in the repository, which is the
/// seam that already knows both.
public struct HistoricalSyncOutcome: Sendable, Equatable {
    /// The ways a drain stops. Three of them are the strap's or the wire's; one is this app's.
    public enum Ending: Sendable, Equatable {
        /// The strap sent `HISTORY_COMPLETE`: its buffer has nothing further to give.
        case strapReportedComplete

        /// The records caught up to the present moment, so there is nothing behind them to fetch.
        /// **5.0 only** — the 4.0's marker carries no timestamp to compare.
        case caughtUpToLiveEdge

        /// No frame arrived within the generation's idle window. The cursor the strap holds is still
        /// valid, so a later drain resumes from it rather than restarting.
        case idleTimeout

        /// Ended from this side: the link dropped, the user cancelled, or a second drain started.
        case aborted

        /// Whether the strap itself said it was finished, which is the only ending that supports the
        /// word "complete" on a screen without qualification.
        public var isStrapConfirmed: Bool {
            self == .strapReportedComplete || self == .caughtUpToLiveEdge
        }
    }

    /// Records seen — one per flash record, which for a motion drain is one `MotionBatch`.
    public let recordCount: Int

    /// Batches ended, which is what the acknowledgements are counted against. Zero on a drain that
    /// never got a marker back, and that is the number that says a strap did not answer.
    public let batchCount: Int

    public let ending: Ending

    /// The oldest record stamp the drain carried, or `nil` when it carried none.
    ///
    /// **The days a drain touched, which a count cannot say.** `RefreshStrainUseCase` scores the days
    /// between these two instants — a backlog drain can cover a fortnight, and without the range the
    /// records would be stored but never scored until each day's own page happened to be opened.
    public let oldestRecord: Date?

    /// The newest record stamp the drain carried, or `nil` when it carried none.
    public let newestRecord: Date?

    public init(
        recordCount: Int,
        batchCount: Int,
        ending: Ending,
        oldestRecord: Date?,
        newestRecord: Date?
    ) {
        self.recordCount = recordCount
        self.batchCount = batchCount
        self.ending = ending
        self.oldestRecord = oldestRecord
        self.newestRecord = newestRecord
    }

    /// The calendar days this drain spans, or `nil` when it did not say.
    ///
    /// `nil` and not a fallback: a strap that reported no record stamps is not evidence for any day,
    /// and scoring "today" because a drain returned nothing would be a recomputation invented from an
    /// absence.
    public var touchedRange: (oldest: Date, newest: Date)? {
        guard let oldestRecord, let newestRecord else { return nil }
        return (oldestRecord, newestRecord)
    }
}

/// Why a historical drain could not be started, or could not be run to a conclusion.
///
/// A distinct type rather than a `nil` because the two failures a caller can act on differently are
/// "this build cannot write to this strap at all" and "we wrote the request and the strap went quiet"
/// — and only the second is worth retrying.
public enum WhoopSyncError: Error, LocalizedError, Equatable {
    /// No envelope, no opcode table, or a builder that refused the profile. **Nothing was sent**, so
    /// this must never be reported as a sync that returned empty.
    case noCommandPath(generation: String)

    /// The request went out and the drain ended without the strap confirming it finished — an idle
    /// window or an abort. The records counted before that are real; the claim that there are no more
    /// is not.
    ///
    /// **The record range rides with the error**, because the records were still written and the strain
    /// refresh still has to score the days they cover: a 4.0 whose drain times out would otherwise be
    /// left with stored heart rate and no strain for it, and nothing would ever revisit the day. A
    /// drain that carried no stamps reports `nil` for both, which the refresh reads as "no evidence for
    /// any day" rather than as an empty range at today.
    case endedWithoutConfirmation(
        records: Int, batches: Int, oldestRecord: Date?, newestRecord: Date?)

    /// A command that is **not** the drain's was refused because the connected strap is not a
    /// generation this build can write it to — today that is `0x9A TOGGLE_PERSISTENT_R21`, which is
    /// 5.0/MG only.
    ///
    /// Separate from `noCommandPath` rather than reusing it for the enum's sake: that case's message
    /// names a *history request*, and a sentence about history over a persistent-recording tap is a
    /// false explanation of what failed.
    case commandUnavailable(generation: String)

    public var errorDescription: String? {
        switch self {
        case .noCommandPath(let generation):
            return "This build cannot send a history request to a \(generation) strap."
        case .endedWithoutConfirmation(let records, let batches, _, _):
            return "The strap stopped responding after \(records) record(s) in \(batches) batch(es). "
                + "Sync again to continue from where it left off."
        case .commandUnavailable(let generation):
            return "This build cannot send that command to a \(generation) strap."
        }
    }

    /// The days an unconfirmed drain nevertheless delivered records for.
    ///
    /// `nil` for every other case and for a drain that carried no stamps. The caller that catches this
    /// error is expected to score these days — the records were written before the drain stopped, and
    /// a timeout is not an absence of data.
    public var recordRange: (oldest: Date, newest: Date)? {
        guard case let .endedWithoutConfirmation(_, _, oldest, newest) = self,
              let oldest, let newest else { return nil }
        return (oldest, newest)
    }
}
