import Foundation
import Whoopsy

// MARK: - 24. The keep-alive and liveness policy

/// The rules that keep a link CoreBluetooth calls connected from lying about itself.
///
/// This is §23's counterpart for the other half of the lifecycle. The reconnect decides what to do
/// after the link *ends*; this decides what to do while iOS still reports it up, and its inputs are
/// clocks rather than callbacks — which is exactly what makes it assertable here. The strap's own
/// silence is the failure a connection-state check cannot see.
enum KeepAlivePolicyTests {
    static func run() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        /// One tick's answer, for a link last heard from `silentFor` seconds ago.
        func action(
            _ generation: WhoopHardwareGeneration,
            silentFor seconds: TimeInterval,
            batteryAgo: TimeInterval? = nil,
            activationAgo: TimeInterval? = nil,
            draining: Bool = false
        ) -> KeepAliveAction {
            KeepAlivePolicy.action(
                for: generation,
                lastActivityAt: now.addingTimeInterval(-seconds),
                lastActivationSentAt: activationAgo.map { now.addingTimeInterval(-$0) },
                lastBatteryReadAt: batteryAgo.map { now.addingTimeInterval(-$0) },
                now: now,
                isDraining: draining)
        }

        // MARK: The constants

        assertTest(
            KeepAlivePolicy.tickSeconds == 30 && KeepAlivePolicy.batteryReadFloorSeconds == 60,
            "the tick and the battery floor are the figures the design is argued from")
        assertTest(
            KeepAlivePolicy.activationResendFloorSeconds == 60
                && KeepAlivePolicy.suspensionGapSeconds == 90,
            "the re-send floor and the suspension gap are separate clocks, and both are pinned")

        // The family split is the load-bearing one: a uniform fuse would either reconnect-loop a 5.0
        // at rest or leave a 4.0 dead for ten minutes.
        assertTest(
            KeepAlivePolicy.livenessFuseSeconds(for: .whoop4) == 120
                && KeepAlivePolicy.livenessFuseSeconds(for: .whoop5) == 600
                && KeepAlivePolicy.livenessFuseSeconds(for: .whoop5MG) == 600,
            "the fuse is 120 s on a 4.0 and 600 s on the 5.0 family")

        assertTest(
            KeepAlivePolicy.activationResendSilenceSeconds(for: .whoop4) == 15
                && KeepAlivePolicy.activationResendSilenceSeconds(for: .whoop5) == 60
                && KeepAlivePolicy.activationResendSilenceSeconds(for: .whoop5MG) == 60,
            "the 4.0 uses Asherlc's 15 s watchdog; the family with at-rest lulls gets 60 s")

        // MARK: The battery read

        let firstTick = action(.whoop4, silentFor: 0)
        assertTest(
            firstTick.readBattery && !firstTick.resendActivation && !firstTick.bounceLink,
            "a healthy first tick asks for the battery and nothing else")

        assertTest(
            !action(.whoop4, silentFor: 0, batteryAgo: 59).readBattery,
            "a battery read 59 s ago is inside the floor")
        assertTest(
            action(.whoop4, silentFor: 0, batteryAgo: 60).readBattery,
            "a battery read exactly at the floor is due — the boundary is inclusive")

        // MARK: Re-sending the activation

        assertTest(
            !action(.whoop4, silentFor: 14, activationAgo: 100).resendActivation,
            "a 4.0 heard from 14 s ago is not silent yet")
        assertTest(
            action(.whoop4, silentFor: 15, activationAgo: 100).resendActivation,
            "15 s of silence on a 4.0 is the watchdog's threshold")

        // The floor is a second clock: noticing is not the same as poking. Immediately after a re-send
        // the stream is still silent, and without this an every-30-s tick would write every tick.
        //
        // Written at 60 s of silence rather than longer because 120 s is the 4.0's fuse, and a case
        // past it would be asserting about a bounce rather than about the floor — which is exactly the
        // mistake this pair caught when it was first written at 200 s.
        assertTest(
            !action(.whoop4, silentFor: 60, activationAgo: 30).resendActivation,
            "a re-send 30 s ago is inside its own floor even though the stream is still silent")
        assertTest(
            action(.whoop4, silentFor: 60, activationAgo: 60).resendActivation,
            "a re-send at the floor is due")

        // The 5.0 family's longer threshold is why a healthy lull does not re-arm a working producer.
        assertTest(
            !action(.whoop5, silentFor: 59, activationAgo: 100).resendActivation,
            "59 s of silence on a 5.0 is a lull, not a stalled producer")
        assertTest(
            action(.whoop5, silentFor: 60, activationAgo: 100).resendActivation,
            "60 s of silence on a 5.0 is the widened watchdog's threshold")
        assertTest(
            !action(.whoop5MG, silentFor: 30, activationAgo: 100).resendActivation,
            "the MG shares the 5.0's threshold")

        // MARK: The fuse

        assertTest(
            !action(.whoop4, silentFor: 119, batteryAgo: 0, activationAgo: 120).bounceLink,
            "119 s is still inside a 4.0's fuse")
        let fourMinuteBounce = action(.whoop4, silentFor: 120, batteryAgo: 0, activationAgo: 120)
        assertTest(
            fourMinuteBounce.bounceLink,
            "120 s of silence bounces a 4.0 — the boundary is inclusive")
        assertTest(
            !fourMinuteBounce.readBattery && !fourMinuteBounce.resendActivation,
            "the bounce supersedes the smaller actions in the same tick")

        assertTest(
            !action(.whoop5, silentFor: 599, batteryAgo: 0, activationAgo: 600).bounceLink,
            "599 s is still inside a 5.0's fuse")
        assertTest(
            action(.whoop5, silentFor: 600, batteryAgo: 0, activationAgo: 600).bounceLink,
            "600 s of silence bounces a 5.0")
        assertTest(
            action(.whoop5MG, silentFor: 600, batteryAgo: 0, activationAgo: 600).bounceLink,
            "the MG shares the fuse")

        // MARK: A drain is left alone

        // A flash write is exactly when a strap goes quiet, so silence during a drain says nothing
        // about the link; re-arming producers mid-drain is the documented way to lose its records.
        let draining = action(.whoop4, silentFor: 500, batteryAgo: 5, activationAgo: 500, draining: true)
        assertTest(
            !draining.bounceLink && !draining.resendActivation && !draining.readBattery,
            "a draining link is not bounced and not poked, even past every threshold")

        // MARK: A clock that moves backwards

        // The same NTP correction §23 guards against. Here it must fail quiet: a negative silence is
        // not a reason to write, and certainly not one to bounce.
        let backwards = action(.whoop4, silentFor: -100, batteryAgo: 5)
        assertTest(
            !backwards.bounceLink && !backwards.resendActivation,
            "a backward clock jump produces no action rather than a bounce")
    }
}
