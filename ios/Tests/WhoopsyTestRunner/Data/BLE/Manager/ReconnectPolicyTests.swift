import Foundation
import Whoopsy

// MARK: - 23. The reconnect policy

/// The one piece of the connection lifecycle that can be asserted without a `CBCentralManager`.
///
/// **Everything else in the lifecycle is a callback.** `didDisconnectPeripheral`, `didFailToConnect`
/// and `willRestoreState` cannot be invoked here: constructing a central raises the system Bluetooth
/// prompt, which is the same reason `WhoopBLEManager.resolvedGeneration` is a static. So the decision
/// they all defer to is a value-typed function, and these are its cases — including the one a
/// screenshot could never show, that a drop is *never* delayed however quickly the previous attempt
/// failed.
enum ReconnectPolicyTests {
    static func run() {
        /// A fixed instant, so every case is arithmetic on a number this test wrote down rather than on
        /// the wall clock. `Date` is only the carrier `ReconnectPolicy` takes.
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        /// The decision for an event whose previous standing connect began `secondsAgo` ago.
        ///
        /// `nil` means there has not been one.
        func decision(
            _ reason: ReconnectReason,
            after secondsAgo: TimeInterval?,
            priorRefusals: Int = 0,
            generation: WhoopHardwareGeneration = .whoop4
        ) -> ReconnectDecision {
            ReconnectPolicy.decision(
                for: reason,
                previousAttemptStartedAt: secondsAgo.map { now.addingTimeInterval(-$0) },
                now: now,
                priorRefusals: priorRefusals,
                generation: generation)
        }

        /// The step for a failure whose previous standing connect began `secondsAgo` ago.
        func failure(
            after secondsAgo: TimeInterval?,
            priorRefusals: Int = 0,
            generation: WhoopHardwareGeneration = .whoop4
        ) -> ReconnectStep {
            decision(
                .failedToConnect,
                after: secondsAgo,
                priorRefusals: priorRefusals,
                generation: generation).step
        }

        /// A delayed step, compared to a tenth of a millisecond.
        ///
        /// **Not `==` on the interval.** `Date` is a `Double` of seconds since 2001, and at a
        /// 1.8-billion-second epoch two values 1.9 s apart do not subtract to exactly 1.9 — so an
        /// equality here would fail on rounding and pass on nothing. The tolerance is three orders of
        /// magnitude below the smallest difference these cases turn on (half a second).
        func assertDelay(_ step: ReconnectStep, _ expected: TimeInterval, _ message: String,
                         file: String = #file, line: Int = #line) {
            guard case .standingConnectAfter(let seconds) = step else {
                assertTest(false, "\(message) — got \(step)", file: file, line: line)
                return
            }
            assertTest(abs(seconds - expected) < 0.0001, message, file: file, line: line)
        }

        // MARK: A drop is answered at once

        assertTest(
            decision(.disconnected, after: nil).step == .standingConnect,
            "a first drop reconnects immediately")

        // The case that separates the two reasons. A link that was up and went away is not a refusal,
        // and applying the floor here would delay every ordinary recovery by half a minute.
        assertTest(
            decision(.disconnected, after: 0.1).step == .standingConnect,
            "a drop reconnects immediately even when the previous attempt had just failed")

        assertTest(
            decision(.disconnected, after: 6).step == .standingConnect,
            "a drop reconnects immediately after a long-lived link")

        // MARK: A refusal is spaced out

        assertTest(
            failure(after: nil) == .standingConnect,
            "a failure with no previous standing connect retries immediately")

        // The floor is measured from the *start* of the previous attempt, not from its failure: the
        // half-second that attempt spent failing is already part of the 30 s.
        assertDelay(
            failure(after: 0.5), 29.5,
            "a refusal half a second in waits out the remainder of the 30 s floor")

        assertDelay(
            failure(after: 1.9), 28.1,
            "a refusal inside the fast-failure window waits the remainder")

        // The boundary itself is the other side: two seconds is the edge of *fast*, so an attempt that
        // took exactly that long is not a refusal and is retried at once. Written at the exact figure
        // rather than near it, so a `<` changed to a `<=` fails here.
        assertTest(
            failure(after: 2) == .standingConnect,
            "a failure at exactly the fast-failure boundary retries immediately")

        assertTest(
            failure(after: 10) == .standingConnect,
            "a slow failure — the strap answered after ten seconds — retries immediately")

        // The other end of the window: a refusal that came back with no measurable delay waits the
        // whole floor. Fifteen seconds would *not* do this — it is outside the fast-failure window and
        // retries at once with the case above, which is why the window is written as a range rather
        // than as "slower than a refusal is fine".
        assertDelay(
            failure(after: 0), ReconnectPolicy.retryFloorSeconds,
            "a refusal that came back at once waits the whole floor")

        // MARK: The floor is clamped against a clock that moves

        // A backward clock jump — NTP, a manual change — makes `now` earlier than the attempt. Without
        // the upper clamp the wait would exceed the floor by the size of the jump, which is the one
        // direction a clock correction can make the app stop reconnecting for a long time.
        assertDelay(
            failure(after: -100), ReconnectPolicy.retryFloorSeconds,
            "a clock that moved backwards cannot push the wait past the floor")

        assertTest(
            ReconnectPolicy.retryFloorSeconds == 30 && ReconnectPolicy.fastFailureSeconds == 2,
            "the two figures are the ones the reconnect design is argued from")

        // MARK: The refusal cap

        // The count is the policy's output, not the caller's arithmetic: it is the same comparison
        // that decided the floor, so a manager cannot disagree with it about what a refusal is.
        assertTest(
            failure(after: 0, priorRefusals: 0) == failure(after: 0),
            "the cap changes no step before it is reached")

        let fourth = decision(.failedToConnect, after: 0, priorRefusals: 3, generation: .whoop5)
        assertTest(
            fourth.consecutiveRefusals == 4,
            "the fourth fast refusal on a 5.0 is counted")
        assertDelay(
            fourth.step, ReconnectPolicy.retryFloorSeconds,
            "the fourth refusal still waits the floor rather than giving up")

        let fifth = decision(.failedToConnect, after: 0, priorRefusals: 4, generation: .whoop5)
        assertTest(
            fifth.step == .giveUp,
            "the fifth consecutive fast refusal on a 5.0 stops the loop")
        assertTest(
            fifth.consecutiveRefusals == 5,
            "...and the count it stops at is the cap")

        assertTest(
            decision(.failedToConnect, after: 0, priorRefusals: 4, generation: .whoop5MG).step == .giveUp,
            "the MG is capped with the 5.0 — it is the same bond")

        // The cap is the one generation-specific branch, and the 4.0 is deliberately outside it: a
        // 4.0 that keeps refusing is far more likely to be out of range than looped on a bond, and
        // that is the state a standing connect exists to wait out.
        assertTest(
            failure(after: 0, priorRefusals: 99, generation: .whoop4) != .giveUp,
            "a 4.0 is never given up on, however many refusals precede it")

        assertTest(
            ReconnectPolicy.consecutiveRefusalCap(for: .whoop4) == nil
                && ReconnectPolicy.consecutiveRefusalCap(for: .whoop5) == ReconnectPolicy.refusalCap
                && ReconnectPolicy.consecutiveRefusalCap(for: .whoop5MG) == ReconnectPolicy.refusalCap,
            "only the bond-gated generations carry a cap")
        assertTest(
            ReconnectPolicy.refusalCap == 5,
            "the cap is noop's measured five")

        // Every non-refusal event resets the count, because each one says the strap is reachable
        // again. Without this, one bad streak would cap a link that later worked.
        assertTest(
            decision(.disconnected, after: 0.1, priorRefusals: 5, generation: .whoop5).consecutiveRefusals == 0,
            "a drop resets the refusal count")
        assertTest(
            decision(.failedToConnect, after: 10, priorRefusals: 5, generation: .whoop5).consecutiveRefusals == 0,
            "a slow failure is range rather than a refusal, and resets the count")
        assertTest(
            decision(.failedToConnect, after: nil, priorRefusals: 5, generation: .whoop5).consecutiveRefusals == 0,
            "a failure with no previous attempt resets the count")
    }
}
