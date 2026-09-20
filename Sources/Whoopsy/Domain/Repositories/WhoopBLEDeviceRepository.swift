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

    /// Scan for nearby WHOOP straps
    func startScanning() async throws

    /// Stop scanning
    func stopScanning() async

    /// Connect to a specific WHOOP device ID
    func connect(to deviceId: String) async throws

    /// Disconnect from the current strap
    func disconnect() async

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

    public init(recordCount: Int, batchCount: Int, ending: Ending) {
        self.recordCount = recordCount
        self.batchCount = batchCount
        self.ending = ending
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
    case endedWithoutConfirmation(records: Int, batches: Int)

    public var errorDescription: String? {
        switch self {
        case .noCommandPath(let generation):
            return "This build cannot send a history request to a \(generation) strap."
        case .endedWithoutConfirmation(let records, let batches):
            return "The strap stopped responding after \(records) record(s) in \(batches) batch(es). "
                + "Sync again to continue from where it left off."
        }
    }
}
