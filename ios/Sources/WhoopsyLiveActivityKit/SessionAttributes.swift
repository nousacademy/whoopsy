// Every line of this target is inside `#if os(iOS)`.
//
// `ActivityAttributes` is `@available(macOS, unavailable)`, and `make build` / `make test` compile
// `Sources/` for macOS — so an unguarded reference here would break the host build, the test runner
// and `make verify` together. Guarded, the target compiles to an **empty module** on macOS, which
// SwiftPM links without complaint; that was verified with a throwaway package before this target was
// added rather than assumed. The `#else` below exists only so the file is never an empty translation
// unit, which some toolchains warn on.
//
// This module has **no `resources:`**, deliberately: SwiftPM then generates no `Bundle.module`
// accessor for it, so referencing one is a compile error rather than a runtime trap. `Bundle.module`
// *traps* when the resource bundle is missing — that is what `CLAUDE.md` records about the bundled
// CSVs — and a widget extension is exactly where a trap would be invisible.
//
// It defines the card's vocabulary a second time, structurally identical to
// `Domain/Entities/LiveSessionActivityState.swift`. That duplication is the build boundary and not an
// oversight: the extension links **this product and not `Whoopsy`** — pulling in `Whoopsy` would carry
// GRDB, CoreBluetooth and all three bundled CSVs (~1 MB the widget can never read) into a process with
// a hard memory budget — and a module that cannot see the app's types cannot share one. The mapping
// between the two is `LiveActivityController`'s, in three lines, in one file.

#if os(iOS)
import ActivityKit
import Foundation

/// The attributes and content of the session card — the one type the widget extension and the app
/// must agree on, which is why it lives in the product they both link.
public struct WhoopsySessionAttributes: ActivityAttributes {

    /// The card's changing half.
    ///
    /// `Codable` and `Hashable` are `ActivityAttributes.ContentState`'s requirements, not choices.
    /// Every measurement is optional for `LiveSessionActivityState`'s reason: a session with no strap
    /// accepts no samples, and the card draws a dash rather than a `0.0` this app invented.
    ///
    /// **`Sendable` is not decorative either, and the error it fixes is one the host build cannot
    /// see.** `ActivityContent<State>` is `Sendable` only when `State` is, and `Activity.update`/
    /// `.end` are `async` — so without this conformance Swift 6 rejects the `await` at the call site
    /// with *"sending value of non-Sendable type `ActivityContent<…>` risks causing data races"*. It
    /// compiles on macOS regardless, because `LiveActivityController`'s `#if os(iOS)` branch is never
    /// compiled there: the sibling of `.toolbar(_:for: .tabBar)` that `CLAUDE.md` records, where a
    /// green `swift build` says nothing about the iOS one.
    ///
    /// Every stored property here is a `Date`, a `Double?`, an `Int?` or a `Bool`, so the conformance
    /// is automatic and needs no `@unchecked`.
    public struct ContentState: Codable, Hashable, Sendable {
        /// The whole of the timer. `Text(startedAt, style: .timer)` is drawn by the system from the
        /// wall clock in the widget's own process, so it keeps counting while the app is suspended —
        /// which is the entire reason the lock-screen requirement survives a backgrounded app.
        public var startedAt: Date
        public var strain: Double?
        public var heartRate: Int?
        public var calories: Double?
        public var isRunning: Bool

        public init(
            startedAt: Date,
            strain: Double? = nil,
            heartRate: Int? = nil,
            calories: Double? = nil,
            isRunning: Bool = true
        ) {
            self.startedAt = startedAt
            self.strain = strain
            self.heartRate = heartRate
            self.calories = calories
            self.isRunning = isRunning
        }
    }

    /// Fixed for the card's life. Empty: a session has no name, and inventing one here would put a
    /// label on the lock screen that no screen in the app shows.
    public init() {}
}
#endif
