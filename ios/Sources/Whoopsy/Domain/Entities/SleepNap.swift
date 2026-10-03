import Foundation

/// A nap: a sleep the user took that was not the night.
///
/// **It is a separate type from `SleepSession` rather than a flagged one, because almost nothing on
/// that entity applies to it.** A session has a need, a performance and an efficiency — all three are
/// ratios against the amount of sleep a *night* requires, and a nap is by definition a fraction of
/// one. That is not a subtlety: the export's own eight nap rows carry a `Sleep performance %` of 6 to
/// 43, because its denominator is a full night's need (526–617 minutes) and its numerator is 33 to 237
/// minutes of nap. Reading that number as a performance would file a deliberate 33-minute nap as a 6%
/// night. So a nap carries the two things that are true of it — when it happened and how long the
/// user was asleep in it — and nothing derived from a need it does not have.
///
/// `id` is a `String` and not a `UUID`, which is the one place this type deliberately differs from
/// `SleepSession`. That entity mints a fresh `UUID()` per initialisation, which is why two reads of
/// one unchanged night never compare equal — the trap `CLAUDE.md` records. A nap's identity is its
/// own start instant and comes from the row, so two reads of one nap *are* the same nap, and the
/// import can be idempotent without a separate de-duplication step.
public struct SleepNap: Identifiable, Equatable, Sendable {
    /// The nap's start instant as a stable string — see `NapRecord.id`.
    public let id: String
    /// `startOfDay(startTime)`: the day the nap was taken. See `WhoopExportImporter.makeNap` for why
    /// a nap is keyed on its onset where a night is keyed on its wake.
    public let date: Date
    public let startTime: Date
    public let endTime: Date
    /// Minutes asleep, which is not the length of the window — the export's eight naps spend 5 to 27
    /// minutes awake inside theirs.
    public let asleepSeconds: TimeInterval

    public init(
        id: String,
        date: Date,
        startTime: Date,
        endTime: Date,
        asleepSeconds: TimeInterval
    ) {
        self.id = id
        self.date = date
        self.startTime = startTime
        self.endTime = endTime
        self.asleepSeconds = asleepSeconds
    }
}
