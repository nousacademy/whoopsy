import Foundation

/// Why a link that should have been up is not.
///
/// The two are not the same event and they do not get the same answer. A link that was **up** and went
/// away has a strap at the other end that was working seconds ago, so the next move is immediate. An
/// attempt that was **answered with a failure** is the strap refusing — a bond the phone no longer
/// holds, a strap in a state that rejects the connection — and hammering it is the one way to make a
/// transient refusal permanent, since it never gets a quiet window to recover.
public enum ReconnectReason: Equatable, Sendable {
    /// The link was established and then dropped.
    case disconnected
    /// A connection attempt completed with `didFailToConnect`.
    case failedToConnect
}

/// What to do next after a link ends.
public enum ReconnectStep: Equatable, Sendable {
    /// Issue the standing connect now. It has no timeout and is not retried by a timer — see
    /// `WhoopBLEManager.issueStandingConnect`.
    case standingConnect
    /// Wait this long, then issue the same call.
    case standingConnectAfter(seconds: TimeInterval)
    /// Issue nothing. A strap that has refused every attempt in a row is not helped by another one,
    /// and the screen already carries the sentence that explains why a 5.0/MG may never answer.
    case giveUp
}

/// The step, and the refusal count the caller must remember for the next decision.
///
/// **The count is an output rather than a detail of the caller**, because "is this a refusal?" is the
/// policy's question — it is the same `elapsed < fastFailureSeconds` comparison that decides the floor
/// — and a manager re-deriving it would be a second place for that rule to drift.
public struct ReconnectDecision: Equatable, Sendable {
    public let step: ReconnectStep
    /// Consecutive fast refusals **including this event**. `0` whenever this event is not one.
    public let consecutiveRefusals: Int

    public init(step: ReconnectStep, consecutiveRefusals: Int) {
        self.step = step
        self.consecutiveRefusals = consecutiveRefusals
    }
}

/// The decision behind automatic reconnection, kept free of CoreBluetooth so it can be asserted.
///
/// **The floor an attempt is spaced by is about a failure's *duration*, not its count.** A `connect`
/// does not time out: an out-of-range strap leaves the call outstanding and it completes whenever the
/// strap comes back, which is exactly the behaviour the app wants. So a failure arriving at all means
/// the strap answered — and one that arrives almost immediately means the strap answered *no*. Only
/// that case gets a floor; everything else reconnects at once, because waiting on a strap that is
/// merely absent would be waiting for no reason.
///
/// **The count matters for one generation only, and it is a bond question.** A 5.0/MG whose command
/// characteristic refuses a pre-bond write can settle into a loop where each attempt is answered in
/// milliseconds and every retry is another refusal; noop pauses after five (`#747`). A 4.0 has no bond
/// to refuse and no measured loop to cap, so it keeps trying: giving up on a strap the phone was
/// merely out of range from turns a recoverable link into one that needs the Device page.
///
/// The count resets on every event that is not a fast refusal — a successful connection, an explicit
/// `connect`, a drop, or a failure that took longer than the fast window (that one is range, not a
/// refusal) — because those are the facts that say the strap is reachable again.
public enum ReconnectPolicy {
    /// A failure that arrives inside this window is the strap refusing rather than a strap that is
    /// gone. Two seconds is noop's measured figure (`standingConnectFastFailureS`), and the measured
    /// alternative is worse: a retry loop against a refusing strap pins the phone's radio.
    public static let fastFailureSeconds: TimeInterval = 2

    /// No two connection attempts are issued closer together than this.
    ///
    /// noop's `standingConnectRetryFloor`, and the number matters for the same reason a keep-alive's
    /// does: below it the attempt becomes the stimulus that keeps the strap refusing.
    public static let retryFloorSeconds: TimeInterval = 30

    /// How many fast refusals in a row a bond-gated generation may answer before this app stops.
    ///
    /// noop's `#747` figure. Five is deliberately small: the sequence this protects against is
    /// measured in milliseconds per attempt, so the cap is reached long after the loop is obvious and
    /// long before it has had time to matter to the radio.
    public static let refusalCap = 5

    /// The cap for a generation, or `nil` when it may be retried indefinitely.
    ///
    /// Only the 5.0/MG are capped, and that is not an omission. The loop being capped is the bond
    /// handshake's — a command characteristic that refuses pre-bond writes — and the 4.0 does not have
    /// one. A 4.0 that refuses is far more likely to be out of range, which is the state a standing
    /// connect exists to wait out.
    public static func consecutiveRefusalCap(for generation: WhoopHardwareGeneration) -> Int? {
        switch generation {
        case .whoop5, .whoop5MG:
            return refusalCap
        case .whoop4, .standardBleHR, .simulator:
            return nil
        }
    }

    /// The next move, given why the link ended, when the previous attempt began, and how many fast
    /// refusals precede this one.
    ///
    /// `previousAttemptStartedAt` is the start of the most recent **standing** connect, or `nil` when
    /// there has not been one. A `nil` is not "no history" for its own sake: it is the first drop after
    /// a link that was established some other way, and that is a strap worth answering immediately.
    public static func decision(
        for reason: ReconnectReason,
        previousAttemptStartedAt: Date?,
        now: Date,
        priorRefusals: Int = 0,
        generation: WhoopHardwareGeneration = .whoop4
    ) -> ReconnectDecision {
        switch reason {
        case .disconnected:
            // A link that was up resets the count, however many refusals preceded it.
            return ReconnectDecision(step: .standingConnect, consecutiveRefusals: 0)
        case .failedToConnect:
            guard let previousAttemptStartedAt else {
                return ReconnectDecision(step: .standingConnect, consecutiveRefusals: 0)
            }
            let elapsed = now.timeIntervalSince(previousAttemptStartedAt)
            // At or past the fast-failure window the first retry is already far enough from the last
            // attempt, and a failure that took this long is not a refusal.
            guard elapsed < fastFailureSeconds else {
                return ReconnectDecision(step: .standingConnect, consecutiveRefusals: 0)
            }
            let refusals = priorRefusals + 1
            if let cap = consecutiveRefusalCap(for: generation), refusals >= cap {
                return ReconnectDecision(step: .giveUp, consecutiveRefusals: refusals)
            }
            // Clamped at both ends. The lower clamp keeps a clock that moved forward across the
            // window from producing a negative wait; the upper one keeps a clock that moved backwards
            // from producing a wait longer than the floor itself.
            let remaining = min(retryFloorSeconds, max(0, retryFloorSeconds - elapsed))
            return ReconnectDecision(
                step: .standingConnectAfter(seconds: remaining),
                consecutiveRefusals: refusals)
        }
    }
}
