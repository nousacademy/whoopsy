import SwiftUI

/// Whether a connection state means the strap is linked, and the colour that draws it on Home.
///
/// A strap is **linked** when this app and the strap are talking to each other: `.connected`, or
/// `.syncing`, which is a connected strap draining its history. Every other state is not linked —
/// including `nil`, which is no strap object at all.
///
/// **Two answers rather than three, and the amber arm the badge used to carry is deliberately gone.**
/// `WhoopConnectionState`'s six cases are not six kinds of link. `.scanning` and `.connecting` are the
/// two halves of *not connected yet*, `.error` is a link that failed and `.disconnected` is one that
/// ended; a yellow dot for the in-progress pair put a strap the app is still hunting for between green
/// and red, which is a distinction no reader asked for and which the app can act on in no different
/// way. Only `.connected` and `.syncing` describe a strap that is *there*.
///
/// `.syncing` is the case that makes the rule worth stating rather than assuming, and it is why the
/// two colours are not simply *connected* and *everything else*: `.syncing`'s raw value is
/// `Syncing History`, so a red dot beside those words would be the app calling a working strap absent.
/// A third state would be the honest drawing, but the two the user specified are what is drawn and
/// `.syncing` is a link that is up. **Neither `.syncing` nor `.error` is constructed anywhere in this
/// build** — `WhoopBLEManager` assigns `.scanning`, `.connecting`, `.connected` and `.disconnected`
/// only — so both arms are unreachable today; the `switch` is exhaustive regardless, so a writer that
/// starts producing one is a compile error here rather than a blank dot.
///
/// `recoveryGreen` and `recoveryRed` are borrowed rather than given tokens of their own, and that is
/// recorded rather than glossed. `.connected` already drew `recoveryGreen` on this badge before this
/// file existed, so a `connectionOnline` token would be a second name for one value — the drift the
/// dedicated tokens exist to prevent, arrived at from the other side. `recoveryRed` is new here: the
/// old mapping drew a disconnected strap in the neutral `textMuted`, and red is the user's own
/// specification. A *verdict* token meaning a link is a borrowing this file owns as one place to
/// revisit, not a claim that a disconnected strap is bad news.
///
/// It cannot live on the enum itself: `WhoopConnectionState` is in `Domain`, which imports only
/// `Foundation` and so cannot name a `Color`. `RecoveryState+Extensions.swift` is the shape.
extension WhoopConnectionState {
    /// Whether this state describes a strap that is linked to this app right now.
    public var isLinked: Bool {
        switch self {
        case .connected, .syncing: return true
        case .disconnected, .scanning, .connecting, .error: return false
        }
    }

    /// The colour of Home's connection dot, which draws `isLinked` and nothing finer.
    public var linkColor: Color {
        isLinked ? Theme.recoveryGreen : Theme.recoveryRed
    }
}
