import SwiftUI

/// Whether a connection state means the strap is linked, and the colour that draws it on Home.
///
/// A strap is **linked** when this app and the strap are talking to each other: `.connected`, or
/// `.syncing`, which is a connected strap draining its history. Every other state is not linked —
/// including `nil`, which is no strap object at all.
///
/// **Three colours, and the split is by what the state means rather than by `isLinked` alone.**
/// `.connected` and `.syncing` draw green — a strap that is *there*. `.disconnected` draws yellow —
/// a strap that was linked and is no longer, which the user named the "stale connected" state and
/// asked to see in yellow rather than red. `.scanning`, `.connecting` and `.error` keep red — the app
/// hunting for a strap, or a link that failed, is neither there nor stale, and red is the arm that
/// means "not linked and not yet a warning." The earlier two-colour rule — green for `isLinked`, red
/// for everything else — drew a disconnected strap in red, and the user corrected that to yellow.
///
/// `.syncing` is the case that makes the rule worth stating rather than assuming: its raw value is
/// `Syncing History`, so a red dot beside those words would be the app calling a working strap absent.
/// **Neither `.syncing` nor `.error` is constructed anywhere in this build** — `WhoopBLEManager`
/// assigns `.scanning`, `.connecting`, `.connected` and `.disconnected` only — so the `.syncing` and
/// `.error` arms are unreachable today; the `switch` is exhaustive regardless, so a writer that starts
/// producing one is a compile error here rather than a blank dot.
///
/// The three colours are borrowed rather than given tokens of their own, and that is recorded rather
/// than glossed. `.connected` already drew `recoveryGreen` on this badge before this file existed, so
/// a `connectionOnline` token would be a second name for one value — the drift the dedicated tokens
/// exist to prevent, arrived at from the other side. `recoveryYellow` and `recoveryRed` are *verdict*
/// tokens borrowed for a link, a borrowing this file owns as one place to revisit, not a claim that a
/// disconnected or failed strap is good or bad news.
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

    /// The colour of Home's connection dot.
    public var linkColor: Color {
        switch self {
        case .connected, .syncing: return Theme.recoveryGreen
        case .disconnected: return Theme.recoveryYellow
        case .scanning, .connecting, .error: return Theme.recoveryRed
        }
    }
}
