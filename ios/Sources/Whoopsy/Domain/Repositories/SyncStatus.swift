import Foundation

/// What the last cloud read could not reach — the record behind the one line a screen draws when the
/// database is down.
///
/// **There is one honest outcome now where there used to be two, and the paragraph that went is worth
/// recording because its absence is the whole shape of this protocol.** A failing read used to have two
/// answers: on a day whose local copy the user had *kept*, the copy was drawn and the reader was told it
/// might be behind; on a day whose copy had been *deleted* on the way up, there was nothing to draw and
/// the reader was told a connection was needed. Those were `markStale(_:)` and `markUnavailable(_:)`, and
/// the first of them is gone — because the delete that created it is gone. A destination now switches
/// where a day is stored and purges nothing, so every day this phone ever had, it still has: a failed
/// read draws the local copy, and the only thing left to say is about the days the *database* holds and
/// the phone never did.
///
/// **The record is a set of days rather than a flag, and that survives the reduction.** A phone synced
/// over a span holds a copy of some of the database's days and not others, so which days cannot be shown
/// is a per-day fact and a single "the cloud is down" boolean would have to pick one answer for a window
/// where it is true of some days and not others.
///
/// **Every day is snapped on the way in, and that is this protocol's contract rather than its callers'.**
/// The reader of `getRecovery(for:)` passes the `Date` the screen is showing, which is an instant and on
/// every day this app runs is hours after midnight; the same day reached from the month grid or the week
/// chart arrives as a different instant. Un-snapped, one afternoon's re-read of one day would be two
/// entries in the set and the screen would report two problems where there is one.
///
/// **Neither read has a production caller yet and neither is dead code.** The screens that draw the line
/// are the next pass, and §22 of the runner drives the marking directly — an `.unreachable` read on a day
/// the phone does not hold must mark that day unavailable, and a read that later succeeds must clear it.
/// That is the `ActivityDurationBar` precedent exactly: this suite has no test discovery, so deleting a
/// type an assertion reaches would drop a passing guarantee with a falling `assertions=` count as its
/// only trace.
public protocol SyncStatus: Sendable {
    /// The cloud could not be reached and the phone holds no copy of this day, so there is nothing to
    /// draw and the reader is owed a sentence saying a connection is needed.
    func markUnavailable(_ day: Date) async

    /// The cloud answered for this day, so whatever was recorded before is no longer true.
    ///
    /// **Not tidying, and the reason is the one that makes the mark worth having at all.** A phone
    /// regains its connection and the reader re-opens the same day; without this, the line would go on
    /// saying the day cannot be shown about a day that was just fetched. A record that can only be
    /// written is a record that is wrong for the rest of the session.
    func clear(_ day: Date) async

    /// The days the database holds that this phone cannot show while it is offline.
    func unavailableDays() async -> Set<Date>
}
