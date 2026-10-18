import Foundation

/// What one keep-alive tick should do.
///
/// Three independent answers rather than one enum, because a single tick can legitimately owe a
/// battery read and an activation re-send at once, and a strap that has gone quiet long enough to
/// bounce must be bounced **instead of** being poked.
public struct KeepAliveAction: Equatable, Sendable {
    /// Ask the strap for its battery level (`0x2A19`), at most once a minute.
    public let readBattery: Bool
    /// Write the telemetry and motion enables again, because nothing has arrived for a while.
    public let resendActivation: Bool
    /// Tear the link down so the standing connect re-establishes it. Supersedes the other two.
    public let bounceLink: Bool

    public init(readBattery: Bool = false, resendActivation: Bool = false, bounceLink: Bool = false) {
        self.readBattery = readBattery
        self.resendActivation = resendActivation
        self.bounceLink = bounceLink
    }

    public static let none = KeepAliveAction()
}

/// The rules for keeping an established link producing data, kept free of CoreBluetooth so they can be
/// asserted.
///
/// **A connected link is not a working one.** iOS reports `peripheral.state == .connected` from the
/// moment GATT is up, but the strap's producers — the 1 Hz heart-rate notifications and the
/// proprietary stream — are armed by commands that a dropped connection, a pre-bond refusal, or a
/// strap that went to sleep can take away without the link itself ever dropping. Every rule here is
/// about *data*, not about `CBPeripheral.state`, and that distinction is the whole reason this type
/// exists: a check on the connection state would stay green over a strap sending nothing.
///
/// The numbers are the references' own:
///
/// - **The tick is 30 s** (noop's keep-alive `DispatchSourceTimer`). A minute would let a stalled
///   producer stay stalled for a minute; a second would be a request storm over a link that costs
///   radio time per packet.
/// - **The battery read is floored at 60 s.** It doubles as the probe: a `0x2A19` read is the only
///   request this app makes that the strap must answer, so it is what turns "the app has not seen a
///   packet" into evidence about the link. Reading it more often would drain the coin cell for a
///   number that changes by one.
/// - **The activation re-send follows Asherlc's `WhoopBleDataWatchdog`**, 15 s of silence on a 4.0.
///   A strap that has stopped sending is a producer that was never armed or was disarmed, and the
///   enable sequence is idempotent — so re-sending it is the recovery, not a guess.
/// - **The 5.0/MG threshold is 60 s, not 15.** Their heart-rate notifications have documented at-rest
///   lulls even on a healthy link (noop `#580`, `#1414`; Edge `#191`), and a 15 s rule would re-arm a
///   producer that is merely quiet. Sixty seconds is still far inside the 10-minute fuse below, so a
///   producer that really has stopped is re-armed long before the link is bounced.
/// - **The liveness fuse is 120 s** on a 4.0 and **600 s** on a 5.0/MG, the same family split and the
///   same at-rest reason. A fuse shorter than a family's natural lull turns "resting" into a reconnect
///   loop; the honest fix for a link that is merely quiet is to wait, and the honest fix for one that
///   is dead is the bounce.
public enum KeepAlivePolicy {
    /// How often the manager looks at a link it believes is up.
    public static let tickSeconds: TimeInterval = 30

    /// No two battery reads are closer together than this.
    public static let batteryReadFloorSeconds: TimeInterval = 60

    /// Once the stream has gone silent, no two activation re-sends are closer together than this.
    ///
    /// Separate from the silence threshold on purpose. The threshold is *when to notice*; this floor
    /// is *how often to poke*, and without it a 30 s tick against a strap that is not streaming turns
    /// into a write every tick — the same storm the reconnect floor exists to prevent.
    public static let activationResendFloorSeconds: TimeInterval = 60

    /// A tick later than this was not a late tick, it was a suspended app.
    ///
    /// **The fuse must never count time this process could not observe.** A `DispatchSourceTimer`
    /// does not fire while the app is suspended; on resume it fires once, and the elapsed wall time
    /// since the previous tick can be hours. Treating that as silence would bounce a healthy link
    /// every time the app came back to the foreground. Three ticks is late enough that ordinary queue
    /// contention cannot reach it.
    public static let suspensionGapSeconds: TimeInterval = 90

    /// When the stream counts as silent on a generation.
    ///
    /// 15 s is Asherlc's `WhoopBleDataWatchdog`; 60 s is the same rule widened for the family whose
    /// heart rate genuinely lulls at rest. See the type's doc comment.
    public static func activationResendSilenceSeconds(
        for generation: WhoopHardwareGeneration
    ) -> TimeInterval {
        switch generation {
        case .whoop5, .whoop5MG:
            return 60
        case .whoop4, .standardBleHR, .simulator:
            return 15
        }
    }

    /// How long a link may send nothing before it is treated as dead rather than quiet.
    public static func livenessFuseSeconds(for generation: WhoopHardwareGeneration) -> TimeInterval {
        switch generation {
        case .whoop5, .whoop5MG:
            return 600
        case .whoop4, .standardBleHR, .simulator:
            return 120
        }
    }

    /// What this tick owes, given when anything was last heard.
    ///
    /// `lastActivityAt` is **not** when the last frame physically arrived — it is the start of the
    /// window the manager could observe. The two differ by exactly one case, a resumed tick after a
    /// suspension (see `suspensionGapSeconds`), and keeping them distinct is what stops the fuse from
    /// firing on time the process spent asleep.
    ///
    /// `isDraining` suppresses both the re-send and the bounce. A drain is a strap writing flash, and
    /// a flash write is exactly when a strap goes quiet for a while; re-arming producers mid-drain is
    /// the documented way to have the strap refuse its type-47 records, and bouncing the link would
    /// abort a sync the user asked for. The battery read is still safe.
    public static func action(
        for generation: WhoopHardwareGeneration,
        lastActivityAt: Date,
        lastActivationSentAt: Date?,
        lastBatteryReadAt: Date?,
        now: Date,
        isDraining: Bool
    ) -> KeepAliveAction {
        let silentFor = now.timeIntervalSince(lastActivityAt)

        // The fuse is the one action that ends the link, so it supersedes both of the smaller ones.
        if !isDraining, silentFor >= livenessFuseSeconds(for: generation) {
            return KeepAliveAction(bounceLink: true)
        }

        // The floor is measured from the later of "anything was heard" and "the enables were last
        // written": immediately after a re-send, the silence clock is naturally older than the write,
        // and counting from the frame would let the next tick poke again at once.
        let sinceActivation = now.timeIntervalSince(lastActivationSentAt ?? lastActivityAt)
        let resend = !isDraining
            && silentFor >= activationResendSilenceSeconds(for: generation)
            && sinceActivation >= activationResendFloorSeconds

        let readBattery = lastBatteryReadAt.map {
            now.timeIntervalSince($0) >= batteryReadFloorSeconds
        } ?? true

        return KeepAliveAction(readBattery: readBattery, resendActivation: resend)
    }
}
