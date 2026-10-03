import Foundation

/// Where a running fast is kept so it survives the process that started it.
///
/// **A fast is the only live session that is persisted, and the reason is its length.** A run is
/// minutes; a fast is a day, or three, and the phone in a pocket is restarted, updated and
/// force-quit inside that window. `LiveSessionUseCase` keeps the fast in memory as well, so every
/// read on the hot path is free — this seam exists for the one moment memory does not cover.
///
/// **A run cannot be stored this way and must not be made to look as though it could.** A session's
/// figures live in a `LiveSessionAccumulator` fed by a live BLE stream; a relaunch has no samples to
/// rebuild it from, and reconstructing one would be inventing measurements. A fast has no such state:
/// `ActiveFast` is one instant, so storing that instant and reading it back restores the fast exactly
/// as it was. The asymmetry is a property of what the two sessions measure, not a gap to close.
///
/// Protocol only, and `Foundation` only — the concrete store lives in `Data/`, which is what keeps
/// `Domain` free of `UserDefaults` and of GRDB alike.
///
/// **Every operation is synchronous, and `load()` has to be.** The restore happens inside
/// `LiveSessionUseCase`'s `nonisolated init`, which cannot `await`, so that one is a hard requirement
/// rather than a style choice — and once one member is synchronous, making the other two `async` would
/// imply a distinction between reading and writing that does not exist here. This is one instant in
/// `UserDefaults`, an in-memory dictionary read, so there is nothing to await in the first place. A
/// store that had to block would be the wrong store for a single date.
public protocol ActiveFastRepository: Sendable {

    /// The running fast, or `nil` when none is running.
    ///
    /// `nil` is the honest answer for "no fast", and it is not the same as a fast started at
    /// `Date(timeIntervalSince1970: 0)`: a zero instant would draw a bar counting fifty-six years.
    func load() -> ActiveFast?

    /// Records the running fast, replacing any previously stored one.
    func save(_ fast: ActiveFast)

    /// Removes the stored fast. Called when one ends, and safe to call when none is stored.
    func clear()
}
