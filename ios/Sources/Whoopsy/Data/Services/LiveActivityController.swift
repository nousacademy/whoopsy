import Foundation

#if os(iOS)
// `@preconcurrency`, and it is load-bearing rather than a silencer. **`Activity` is not `Sendable`**
// — measured against `ActivityKit.swiftinterface` in the iOS 27 SDK, which carries a conditional
// `Sendable` on `ActivityContent` and none at all on `Activity` — while `update`/`end` are `nonisolated
// async`, so every call sends the handle off the main actor and Swift 6 rejects it outright:
//
//     sending 'activity' risks causing data races [#RegionIsolation::SendingRisksDataRace]
//
// There is no fix on this side of the boundary. The value cannot be made `Sendable` (it is Apple's),
// and `await MainActor.run` around it changes nothing because the send is the `await` itself. Apple's
// own sample code writes exactly these calls, so the honest reading is that the framework predates
// the diagnostic rather than that this file is racing: the handle is only ever touched from the main
// actor, and `@preconcurrency` records that the compiler cannot see it.
//
// **This is also the fifth member of the family `CLAUDE.md` records** — `.toolbar(_:for: .tabBar)`,
// `navigationBarTitleDisplayMode`, `keyboardType` and `#if canImport(HealthKit)` — where a green host
// build says nothing, because this whole branch is compiled only for iOS.
@preconcurrency import ActivityKit
import WhoopsyLiveActivityKit

/// The real lock-screen card, on the one platform that has one.
///
/// `ActivityKit` and `ActivityAttributes` are `@available(macOS, unavailable)` while `swift build`
/// compiles this module for macOS, so the whole implementation is behind `#if os(iOS)` and the `#else`
/// below stands in for it **under the same type name** — which is what lets `DIContainer` hold one
/// with no `#if` of its own. `LocationTrackingService` is the shape this copies.
///
/// ### The handle is the only state, and it is why `DIContainer` must store this
///
/// `activity` is the session's card. An `Activity` handle cannot be re-derived from anything, so a
/// caller that built a fresh controller per read — which is what `DIContainer.locationTracking`'s
/// computed property does — would lose it on the second access and strand the card until the system's
/// eight-hour limit. `DIContainer` therefore holds this as a **stored `let`**, and
/// `LiveSessionUseCase` holds that same instance for the life of the process.
///
/// ### The two `ActivityContent` constructions are not interchangeable
///
/// Every push carries a `staleDate` of the moment plus the system's own staleness window, so a card
/// whose app was suspended stops presenting its last reading as current. Nothing here is pushed on a
/// schedule: the caller throttles, and the timer needs no push at all because
/// `Text(startedAt, style: .timer)` is drawn from the wall clock in the widget's process.
@MainActor
public final class LiveActivityController: LiveActivityControlling {

    /// The card, or `nil` when none is active — including after a `start` the system refused.
    ///
    /// The `= nil` is required by the `nonisolated init` below, not decoration: a `@MainActor` class
    /// cannot assign an isolated stored property from a nonisolated initialiser, so the property has to
    /// carry its own initial value and the initialiser has to touch nothing.
    private var activity: Activity<WhoopsySessionAttributes>? = nil

    /// `nonisolated` because `DIContainer.init` is — the container is built outside any actor and holds
    /// this as a stored `let`. It assigns nothing, which is what makes that legal; the `activity`
    /// handle is written later, from the main actor, by `start`/`end`/`endOrphans`.
    public nonisolated init() {}

    /// A compile-time fact about the platform and the build, not a user setting.
    ///
    /// Always `true` here: this type does not exist off iOS, and the SDK it is built against carries
    /// the API. Deliberately **not** `ActivityAuthorizationInfo().areActivitiesEnabled` — that is a
    /// runtime refusal, and it arrives through `start` throwing rather than through a flag the caller
    /// has to remember to consult. One mechanism, not two. `NSSupportsLiveActivities` is in
    /// `App/iOS/Info.plist`; without it the request fails at runtime and this flag would be a lie.
    public var isSupported: Bool { true }

    public func start(state: LiveSessionActivityState) throws {
        guard activity == nil else { return }
        activity = try Activity.request(
            attributes: WhoopsySessionAttributes(),
            content: Self.content(for: state),
            pushType: nil
        )
    }

    public func update(state: LiveSessionActivityState) async {
        guard let activity else { return }
        await activity.update(Self.content(for: state))
    }

    public func end(state: LiveSessionActivityState) async {
        guard let activity else { return }
        self.activity = nil
        // `.default` rather than `.immediate`: the card is the user's record that the session
        // happened, and dismissing it the instant they tap END would take the summary with it.
        await activity.end(Self.content(for: state), dismissalPolicy: .default)
    }

    /// Ends every card of this app's session type, whoever started it.
    ///
    /// Read off `Activity<…>.activities` rather than off `self.activity`, because the case this exists
    /// for is precisely the one where `self` did not survive: a card outlives the process that
    /// requested it, and this build has no in-flight persistence and no BLE state restoration, so a
    /// relaunch cannot adopt one — only end it. The state pushed is the last one the card knows about,
    /// with `isRunning` cleared, so it stops reading as live while the system counts down.
    @discardableResult
    public func endOrphans() async -> Int {
        let orphans = Activity<WhoopsySessionAttributes>.activities
        for orphan in orphans {
            let content = orphan.content
            await orphan.end(
                ActivityContent(
                    state: WhoopsySessionAttributes.ContentState(
                        startedAt: content.state.startedAt,
                        strain: content.state.strain,
                        heartRate: content.state.heartRate,
                        calories: content.state.calories,
                        isRunning: false
                    ),
                    staleDate: nil
                ),
                dismissalPolicy: .default
            )
        }
        // The in-process handle is one of the cards just ended, so it must not outlive the loop.
        activity = nil
        return orphans.count
    }

    /// The one place the app's state type becomes ActivityKit's.
    ///
    /// Two structurally identical types exist because the widget extension links the Kit product and
    /// **not** this module — see `WhoopsyLiveActivityKit/SessionAttributes.swift`. So the copy is the
    /// build boundary's price, it is paid exactly once, and it is here rather than at three call
    /// sites. A field added to one side and not the other is a compile error at this initialiser,
    /// which is the reason it is written out longhand rather than in a loop over coding keys.
    private static func content(
        for state: LiveSessionActivityState
    ) -> ActivityContent<WhoopsySessionAttributes.ContentState> {
        ActivityContent(
            state: WhoopsySessionAttributes.ContentState(
                startedAt: state.startedAt,
                strain: state.strain,
                heartRate: state.heartRate,
                calories: state.calories,
                isRunning: state.isRunning
            ),
            staleDate: nil
        )
    }
}

#else

/// The no-op, on every platform that has no Live Activity.
///
/// **Same type name as the real one**, deliberately: `DIContainer` then holds
/// `any LiveActivityControlling` on both platforms with no `#if`, which is the whole point of the
/// seam. `isSupported` is `false` so nothing offers the feature, and every method is a no-op — a
/// session on macOS records exactly as it does on a phone, it simply has no card. That is the absence
/// rule rather than a degraded mode.
///
/// This is also what the test runner links, which is why §18 can drive `LiveSessionUseCase` end to end
/// on the host: the suite's assertions are about the session, not about a lock screen, and they are
/// made through a spy that conforms to the protocol rather than through this.
@MainActor
public final class LiveActivityController: LiveActivityControlling {
    /// `nonisolated` to match the iOS branch above, so `DIContainer` builds this identically on both
    /// platforms and needs no `#if` of its own — which is the whole point of the seam.
    public nonisolated init() {}
    public var isSupported: Bool { false }
    public func start(state: LiveSessionActivityState) throws {}
    public func update(state: LiveSessionActivityState) async {}
    public func end(state: LiveSessionActivityState) async {}
    public func endOrphans() async -> Int { 0 }
}

#endif
