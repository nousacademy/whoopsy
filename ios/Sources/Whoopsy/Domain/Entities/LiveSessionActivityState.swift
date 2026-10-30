import Foundation

/// What a **Live Activity** — the lock-screen card for a running session — is told to display.
///
/// It is a plain `Sendable` value and not an `ActivityKit` type on purpose. `Activity` and
/// `ActivityAttributes` are `@available(macOS, unavailable)`, and `swift build` compiles this module
/// for macOS: an unguarded reference to either would break `make build`, `make test` and `make verify`
/// at once. So the card's vocabulary is defined here in `Domain`, the platform type lives behind
/// `LiveActivityControlling`, and the only file that knows both is `Data/Services/LiveActivityController.swift`.
///
/// ### Every figure here is optional, and the card draws a dash
///
/// The same rule the screen follows. A session on a machine with no strap accepts no samples, so
/// `strain`, `heartRate` and `calories` are all `nil` and the card says so rather than showing `0.0`.
/// `calories` is additionally `nil` whenever no body weight is on file, and `strain` is `0.0` — a real
/// reading — only once a sample has arrived that never reached zone 1. See `LiveSessionAccumulator`.
public struct LiveSessionActivityState: Sendable, Equatable {

    /// The instant the session began, and **the whole of the timer's implementation**.
    ///
    /// The card renders `Text(startedAt, style: .timer)`, which the system draws from the wall clock
    /// in the widget's own process. That is why the lock screen keeps counting while the app is
    /// suspended and the heart rate does not: the timer is not an update this app pushes, so it cannot
    /// be starved by a suspended process. Nothing may compute elapsed time from a sample count.
    public let startedAt: Date

    /// `nil` before the first sample; `0.0` for a measured session that never left zone 1.
    public let strain: Double?
    /// The most recent reading. `nil` when no sample has arrived.
    public let heartRate: Int?
    /// `nil` when no weight is on file. See the type's note on absence.
    public let calories: Double?
    /// `false` once the session has ended, which is what the card's "ended" wording keys on.
    ///
    /// `Activity.content` cannot be replaced after `end`, so the last state pushed is the one the card
    /// keeps while the system counts down its dismissal — this field is what stops a finished session
    /// from still reading as live for those four hours.
    public let isRunning: Bool

    /// Where `heartRate` sits across the five-band scale, as a `0…1` fraction — the lock-screen bar's
    /// marker, resolved by `LiveSessionAccumulator` so the card and the session screen place the same
    /// dot on the same scale. `nil` before any reading.
    public let bandScalePosition: Double?

    /// How far the session's route has gone, in metres, or `nil` with fewer than two plausible fixes.
    /// Measured by `RouteDistance`, the rule the route card prints from.
    public let distanceMeters: Double?

    /// The route's average speed over its **own** span, or `nil` when there is no distance or no
    /// span to divide by — never the session's elapsed time, which would report an average over
    /// distance the app never measured.
    public let averageSpeedMetersPerSecond: Double?

    /// The session's activity mark, resolved through `ActivityMarkCatalog` — the app's one
    /// name → symbol mapping — so the lock-screen card draws the same glyph the `ACTIVITIES` card does.
    /// `nil` only for a session with no name yet, where the card draws the fallback's absence.
    public let glyphSymbol: String?
    /// The second symbol of a composite mark (`Fast` is `fork.knife` then `timer`), or `nil`.
    public let glyphSecondarySymbol: String?

    public init(
        startedAt: Date,
        strain: Double? = nil,
        heartRate: Int? = nil,
        calories: Double? = nil,
        isRunning: Bool = true,
        bandScalePosition: Double? = nil,
        distanceMeters: Double? = nil,
        averageSpeedMetersPerSecond: Double? = nil,
        glyphSymbol: String? = nil,
        glyphSecondarySymbol: String? = nil
    ) {
        self.startedAt = startedAt
        self.strain = strain
        self.heartRate = heartRate
        self.calories = calories
        self.isRunning = isRunning
        self.bandScalePosition = bandScalePosition
        self.distanceMeters = distanceMeters
        self.averageSpeedMetersPerSecond = averageSpeedMetersPerSecond
        self.glyphSymbol = glyphSymbol
        self.glyphSecondarySymbol = glyphSecondarySymbol
    }
}
