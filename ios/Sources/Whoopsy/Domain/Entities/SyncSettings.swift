import Foundation

/// Which store this install's data belongs to, and the span the one button walks.
///
/// **A destination is a switch, not a move.** The rule, in the user's own words: *if a DB is selected,
/// it doesn't purge anything, it just switches where data will be stored to.* So turning `destination`
/// to `.cloud` transfers nothing — it decides where a **future** write goes and which store answers a
/// read — and turning it back to `.device` retrieves nothing, because nothing left. `SYNC` is the one
/// control that moves an existing span, and it is the only thing on this pane that is a transfer rather
/// than a preference.
///
/// **There is no provenance here, and its absence is a decision rather than an omission.** An earlier
/// model kept a second boundary — the one the database had actually been brought up to — so a failed or
/// half-finished transfer could be resumed and a day could be known to exist in one store and not the
/// other. All of that machinery existed to answer *what has to be fetched back after a delete*, and
/// there is no delete: with both stores always holding their rows, "the cloud has this day" is a
/// question nothing acts on. The one place it was load-bearing was the importer declining to re-import
/// a day the database owned, and that contention went with the delete that created it — an import and a
/// sync can no longer fight over a day, because neither one removes it. `SyncSettings.uploadedCutoff`,
/// `cloudHolds(_:)`, `isCloudDay(_:)`, `pendingWork` and `Direction` are all gone for this one reason,
/// and none of them may come back without a purge to justify it.
public struct SyncSettings: Equatable, Sendable {

    /// **Where a day is stored** — the one question this pane answers, and a switch rather than a move.
    ///
    /// `rawValue` is the drawn title, on `ProfileDashboardView.Tab`'s rule that the order **is** the
    /// drawing: `device` is first because it is the default and the state a fresh install is in.
    ///
    /// **The two are not two places a day can be.** Nothing is deleted from either store. `device` says
    /// *this phone is where my days live*; `cloud` says *send them to the database and read them back
    /// from there*. Both leave the phone's own copy in place, which is the whole of why there is no
    /// third arm and no "both" arm: a third would be a direction to move in, and there is no move.
    public enum Destination: String, Equatable, Sendable, CaseIterable {
        case device = "DEVICE STORAGE"
        case cloud = "WHOOPSY SYNC API"
    }

    /// A span of days, with both ends snapped to `startOfDay` on the way in.
    ///
    /// Half-open — `[from, to)` — so the two ends are two positions and never the same day twice. That
    /// is the sync's own convention everywhere it appears: `CloudSync.recoveries(from:to:)`,
    /// `RecoverySyncStore.syncRows(from:to:)` and the chunk loop built on them all walk
    /// `startOfNextDay`, because two chunks sharing an instant would write one day twice. It is
    /// deliberately **not** the convention of `getRecoveryHistory(days:endingOn:)`, which is inclusive
    /// at both ends — a chunk boundary is a position, a screen's window is a set of days.
    ///
    /// **The snap is this type's job rather than its callers'**, exactly as it was for the boundary the
    /// date picker used to write: the day keys it is compared against are snapped by
    /// `LocalDatabaseManager`, so a range carrying a clock time would make the set of days a sync walks
    /// depend on the minute the user tapped the picker.
    public struct SyncRange: Equatable, Sendable {
        public let from: Date
        public let to: Date

        public init(from: Date, to: Date) {
            self.from = from.startOfDay
            self.to = to.startOfDay
        }

        /// Nothing to walk — an empty range, or a pair the user has drawn backwards.
        ///
        /// Written as `>=` rather than `>` so that `from == to` is empty: a range of one day is
        /// `[from, from + 1 day)`, and a picker showing the same date twice asks for no days at all.
        /// A reversed pair is empty for the same reason it is not an error — the user is mid-edit, and
        /// the button is gated on this rather than the range being refused.
        public var isEmpty: Bool { from >= to }

        /// How many days the span covers. `[Jan 1, Jan 2)` is one day; an empty range is zero.
        ///
        /// **Counted in calendar days rather than in seconds divided by 86,400**, because the two
        /// disagree twice a year: a span across a daylight-saving change is not a whole number of days,
        /// and `Calendar` is the only thing here that knows where the boundaries are. This is the number
        /// the sync checks a resource's window ceiling against, and a ceiling checked against a
        /// seconds-derived count would be off by one for part of every year.
        public var dayCount: Int {
            Calendar.current.dateComponents([.day], from: from, to: to).day ?? 0
        }
    }

    /// **Which store new days go to, and which store answers a read.**
    ///
    /// **`.device` is the default, and that is a safety property rather than a preference.** A fresh
    /// install sends nothing anywhere until its owner asks it to, so the state a user who never opens
    /// this pane stays in for the life of the install is the state that has no server in it.
    public var destination: Destination

    /// The span `SYNC` walks. `nil` until the user draws one, and a fresh install draws none.
    public var range: SyncRange?

    /// **Stored now, drawn by nothing in this pass, and that is deliberate.**
    ///
    /// Biometric samples are the eighth resource and the only one whose read window is measured in
    /// seconds rather than days — a single day of it is up to 86,400 rows — so it gets its own control
    /// and defaults to staying on the phone. Deferring that control ships the behaviour it would have
    /// had on arrival, and keeping the field here means the later pass is a view change rather than a
    /// migration: the stored value and the drawn control arrive at different times, which is the one
    /// thing a settings record can do that a schema cannot.
    public var uploadsBiometricSamples: Bool

    public init(
        destination: Destination = .device,
        range: SyncRange? = nil,
        uploadsBiometricSamples: Bool = false
    ) {
        self.destination = destination
        self.range = range
        self.uploadsBiometricSamples = uploadsBiometricSamples
    }
}
