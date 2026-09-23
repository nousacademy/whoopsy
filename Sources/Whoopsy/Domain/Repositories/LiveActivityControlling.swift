import Foundation

/// The seam between a running session and the lock-screen card that outlives its screen.
///
/// `ActivityKit` is `@available(macOS, unavailable)` and this module is built for macOS by
/// `make build` / `make test`, so `Domain` cannot name it. This protocol is what the use case depends
/// on instead; `Data/Services/LiveActivityController.swift` holds the real implementation behind
/// `#if os(iOS)` and a no-op in the `#else`, **under one type name on both platforms** so
/// `DIContainer` contains no `#if` at all. That is `LocationTracking`'s arrangement and
/// `HealthStoreClient`'s before it.
///
/// ### `@MainActor` and `Sendable` together, which is not decoration
///
/// `Activity` is not `Sendable`, so the handle needs an isolated home. `LocationTracking` is
/// `@MainActor … AnyObject` for the same reason, and a `@MainActor @Observable` class cannot hold it as
/// a plain `let` — the stored property must be `private nonisolated let controller: any LiveActivityControlling`,
/// which requires the protocol to refine `Sendable`. Dropping either refinement is a compile error at
/// the use case rather than a silent data race, which is the only reason this note is short.
///
/// ### A refusal here must never stop the session
///
/// `Activity.request` throws when Live Activities are switched off, when the app has too many, or when
/// `NSSupportsLiveActivities` is missing from the bundle — all of which are properties of the *device
/// and the build*, none of which is a reason to stop recording. So `start` declares `throws` and
/// `LiveSessionUseCase` catches it into `liveActivityError` while the session keeps running and the
/// screen keeps drawing. The absence rule, applied to a capability: a card that cannot be shown is a
/// missing card, not a missing session.
@MainActor
public protocol LiveActivityControlling: AnyObject, Sendable {

    /// Whether this platform and build can show a card at all.
    ///
    /// `false` on every platform but iOS, so no caller branches on `os`. **It is not a promise that
    /// `start` will succeed**: the API can exist and still refuse. Treat it as "do not offer the
    /// feature", never as permission.
    var isSupported: Bool { get }

    /// Requests a card for a newly started session.
    ///
    /// Throws rather than returning a `Bool` so the reason survives to `liveActivityError`. Called
    /// once per session; a second call while one is active is refused by the system rather than
    /// replacing the first, which is why `LiveSessionUseCase.start()` is idempotent.
    func start(state: LiveSessionActivityState) throws

    /// Replaces the card's content. Already throttled by the caller — see `LiveSessionUseCase`.
    ///
    /// A no-op when no card is active, because a session whose `start` was refused still updates its
    /// screen and must not have to ask first.
    func update(state: LiveSessionActivityState) async

    /// Ends the card, pushing `state` as its final content.
    ///
    /// `Activity.content` cannot be replaced after `end`, so the state handed here is what the card
    /// shows for the whole of its dismissal window — it must carry `isRunning == false`, or a finished
    /// session reads as live for the next four hours.
    func end(state: LiveSessionActivityState) async

    /// Ends any card of this app's session type left behind by a process that died mid-session.
    ///
    /// Returns how many were ended, for the log and for the suite. A card has no tie to a process
    /// lifetime: killing the app leaves the lock screen counting up from `startedAt` forever, and
    /// because this build deliberately has no BLE state restoration and no in-flight persistence, a
    /// relaunch cannot adopt it — the only honest option is to end it. Called once from
    /// `MainContainerView`'s root task. Never called while a session is running.
    func endOrphans() async -> Int
}
