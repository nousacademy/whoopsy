import Foundation

/// What a local purge removed, one number per table it touched.
///
/// **A tally rather than a total, because the tables answer different questions.** `biometric_samples`
/// is the one that matters — a day of the strap's 1 Hz record is tens of thousands of rows, and a purge
/// that reported "5 rows" while quietly leaving the samples behind would be a purge that the next
/// foreground re-derives into a recovery and a strain. The numbers are reported so the reader can see
/// which half happened.
///
/// **Activities, fasts and notes are absent from this type on purpose.** The purge is scoped to
/// measured data: a session the owner recorded is not a calibration artefact, and `workouts` and
/// `receptive_inactivities` are not in the table list `LocalDatabaseManager.purgeMeasuredDays` touches.
public struct DayPurgeTally: Equatable, Sendable {

    public var recoveries = 0
    public var sleeps = 0
    public var strains = 0
    public var stepCounts = 0
    public var naps = 0
    public var motionEpochs = 0
    public var samples = 0

    public init() {}

    public var total: Int {
        recoveries + sleeps + strains + stepCounts + naps + motionEpochs + samples
    }

    /// Whether anything at all was removed — the fact that separates "these days are gone" from "these
    /// days held nothing", which are different answers to the same press.
    public var isEmpty: Bool { total == 0 }
}
