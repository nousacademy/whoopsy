import SwiftUI

/// Premium dark-mode-first aesthetic theme and color definitions.
public enum Theme {
    // Backgrounds
    public static let backgroundDark = Color(red: 0.05, green: 0.06, blue: 0.08)
    public static let cardBackground = Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.85)
    public static let cardBorder = Color.white.opacity(0.12)

    // Recovery Colors
    public static let recoveryGreen = Color(red: 0.0, green: 0.90, blue: 0.46) // #00E676
    public static let recoveryYellow = Color(red: 1.0, green: 0.84, blue: 0.0) // #FFD600
    public static let recoveryRed = Color(red: 1.0, green: 0.09, blue: 0.27) // #FF1744

    // Strain Colors
    public static let strainPrimary = Color(red: 1.0, green: 0.33, blue: 0.10)
    public static let strainGradientStart = Color(red: 1.0, green: 0.67, blue: 0.05)
    public static let strainGradientEnd = Color(red: 1.0, green: 0.12, blue: 0.16)

    // Sleep Colors
    public static let sleepIndigo = Color(red: 0.48, green: 0.30, blue: 1.0)
    public static let sleepDeep = Color(red: 0.30, green: 0.15, blue: 0.85)
    public static let sleepLight = Color(red: 0.45, green: 0.55, blue: 1.0)
    public static let sleepRem = Color(red: 0.10, green: 0.85, blue: 0.95)
    public static let sleepAwake = Color(red: 1.0, green: 0.40, blue: 0.40)

    // Home
    //
    // These four were literals inside `HomeDashboardView`, which is why `DayNavigationBar` carried a
    // private copy of the card grey with a comment apologising for the duplication: one screen's
    // palette was a private convention that a shared component had to guess at. Promoted rather than
    // re-picked, so the values on screen do not move.
    public static let homeBackground = Color(red: 0.11, green: 0.13, blue: 0.15)
    public static let homeCard = Color(red: 0.16, green: 0.18, blue: 0.21)

    /// The unfilled part of a Home ring.
    ///
    /// Its own token rather than the ring colour at low opacity, which is what `GaugeRingView` uses.
    /// The two read differently at a low fill: a faded tint of the ring colour disappears into the
    /// card, while a neutral track keeps the circle legible as one shape with a gap in it.
    public static let ringTrack = Color(red: 0.22, green: 0.24, blue: 0.27)

    /// The Sleep and Strain ring fills.
    ///
    /// Distinct from `sleepIndigo`/`strainPrimary` on purpose: those belong to the detail screens'
    /// gradient palette, and Home's mockup is flat. Recovery needs no token here — its ring is drawn
    /// in whichever of the three `recovery*` tiers the day scored, via `RecoveryState.color`.
    public static let sleepPerformance = Color(red: 0.42, green: 0.60, blue: 0.73)
    public static let strainRing = Color(red: 0.00, green: 0.68, blue: 1.00)

    // Telemetry Pulse
    public static let livePulseCyan = Color(red: 0.0, green: 0.95, blue: 1.0)
    public static let textPrimary = Color.white
    public static let textSecondary = Color(white: 0.70)
    public static let textMuted = Color(white: 0.45)
}
