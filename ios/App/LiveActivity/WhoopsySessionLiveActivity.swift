import ActivityKit
import SwiftUI
import WidgetKit
import WhoopsyLiveActivityKit

/// The lock-screen card for a running session.
///
/// The user's requirement was *"if phone is closed, it will show a preview on lock screen while running
/// with timer"*, and the timer is the whole of why this is a Live Activity rather than a notification:
/// `Text(state.startedAt, style: .timer)` is rendered by the **system**, in this process, off the wall
/// clock. It keeps counting while the app is suspended, while this extension is not running, and with
/// no pushes from anywhere.
///
/// ### What that means about the other three figures
///
/// They are pushed from the app, so **they freeze when the app is suspended while the timer does not**.
/// `bluetooth-central` buys wake-ups, not a background lifetime: Apple's own documentation says the
/// system wakes the app when a peripheral sends updated values, gives it around ten seconds, and that
/// it cannot run forever. So a card reading `12:04` beside a heart rate from twelve minutes ago is a
/// real possibility, and it is the honest outcome rather than a bug to paper over. Pausing the timer
/// to match would be worse: it would make the two agree by making both wrong.
///
/// ### `dynamicIsland:` is required, and the card is drawn on both surfaces
///
/// There is exactly **one** `ActivityConfiguration` initialiser in the SDK — verified in
/// `WidgetKit.swiftinterface` for the iOS 27 SDK, which declares a single `init(for:content:dynamicIsland:)`
/// and no second overload — so the closure is not an optional flourish that a lock-screen-only card can
/// drop. It returns a concrete `DynamicIsland`, whose own single initialiser requires all four of
/// `expanded`, `compactLeading`, `compactTrailing` and `minimal`. Omitting it is a compile error rather
/// than a card without an island.
///
/// So the island is drawn, and it obeys the same absence rule as the card below: the compact leading
/// slot carries strain because it has room for roughly three characters, and any figure with no
/// measurement is `–` rather than a `0.0` this app invented.
///
/// ### The palette is restated here, and it is forced
///
/// `CLAUDE.md` says colours live in `Theme.swift` and a view must not hardcode one. This extension
/// **cannot import `Theme`**: it links the `WhoopsyLiveActivityKit` product and not `Whoopsy`, because
/// linking the app module would carry GRDB, CoreBluetooth and all three bundled CSVs — roughly a
/// megabyte the widget can never read — into a process with a hard memory budget. So the three tokens
/// used below are copied by value, and **changing one without the other is drift**: the values are
/// `Theme.homeBackground`, `Theme.strainRing` and `Theme.textPrimary`.
struct WhoopsySessionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WhoopsySessionAttributes.self) { context in
            Group {
                // **The live panel while the session is recording.** The ended branch is kept for the
                // transient card the system is tearing down: both `end` paths now dismiss
                // `.immediate`, so a finished session's summary is no longer left on the lock screen.
                if context.state.isRunning {
                    LivePanel(state: context.state)
                } else {
                    SessionCard(state: context.state)
                }
            }
            .activityBackgroundTint(Palette.background)
            .activitySystemActionForegroundColor(Palette.strainRing)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusLabel(isRunning: context.state.isRunning)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SessionTimer(startedAt: context.state.startedAt, size: 20)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        Figure(label: "STRAIN", value: strainText(context.state), size: 15)
                        Figure(label: "HEART RATE", value: context.state.heartRate.map(String.init), size: 15)
                        Figure(label: "CALORIES", value: calorieText(context.state), size: 15)
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Text(strainText(context.state) ?? "–")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.strainRing)
            } compactTrailing: {
                SessionTimer(startedAt: context.state.startedAt, size: 13)
            } minimal: {
                // The smallest slot there is: a few points across, sharing the pill with the system's
                // own content. The timer is the one figure that is correct without an update, which is
                // what makes it the right thing to keep when only one thing fits.
                SessionTimer(startedAt: context.state.startedAt, size: 12)
            }
        }
    }

    /// `nil` when nothing has been measured, so the island draws `–` beside the card's `–`.
    ///
    /// Shared with `SessionCard` rather than written twice, because the two surfaces showing a
    /// different figure for the same session is the drift this file's palette note already warns about.
    private func strainText(_ state: WhoopsySessionAttributes.ContentState) -> String? {
        state.strain.map { String(format: "%.1f", $0) }
    }

    /// Absent when no body weight is on file — see `UserProfile.weightKg`. A `0` here would be a claim;
    /// the dash is the absence, exactly as it is on the session screen.
    private func calorieText(_ state: WhoopsySessionAttributes.ContentState) -> String? {
        state.calories.map { String(Int($0.rounded())) }
    }
}

/// The three `Theme` values this extension cannot import, named so drift is greppable.
///
/// See the type's note above: every one of these is a copy of a token in
/// `Presentation/DesignSystem/Theme.swift`, and the copy exists because linking `Whoopsy` would carry
/// GRDB, CoreBluetooth and three bundled CSVs into a widget.
private enum Palette {
    /// `Theme.homeBackground`.
    static let background = Color(red: 0.11, green: 0.13, blue: 0.15)
    /// `Theme.strainRing`.
    static let strainRing = Color(red: 0.00, green: 0.68, blue: 1.00)
    /// `Theme.textPrimary`.
    static let textPrimary = Color.white

    /// The five band colours, copied from `HeartRateZoneIndex+Extensions.swift` — the app's one
    /// zone-to-`Color` mapping — for the palette reason above. Zone 1 is a neutral grey on purpose:
    /// it is the band a session spends most of its time in and should not read as an alert.
    static let zone1 = Color(white: 0.5)
    /// `Theme.livePulseCyan`.
    static let zone2 = Color(red: 0.0, green: 0.95, blue: 1.0)
    /// `Theme.recoveryGreen`.
    static let zone3 = Color(red: 0.0, green: 0.90, blue: 0.46)
    /// `Theme.recoveryYellow`.
    static let zone4 = Color(red: 1.0, green: 0.84, blue: 0.0)
    /// `Theme.recoveryRed`.
    static let zone5 = Color(red: 1.0, green: 0.09, blue: 0.27)

    static let bands: [Color] = [zone1, zone2, zone3, zone4, zone5]
}

/// The lock-screen panel for a **running** session: timer, mark, heart rate, the five-band scale and
/// the route's two figures.
///
/// The user's own layout, supplied as a mock: *"when an activity is in progress … i want this panel to
/// be displayed, without whoop logo"*. The mark in the centre is **empty until this app has one of its
/// own** — see the TODO beside it — because the circle in the mock is the strap maker's logo and
/// drawing that would be another company's mark on our card.
private struct LivePanel: View {
    let state: WhoopsySessionAttributes.ContentState

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                // **The timer yields, the heart rate does not.** A three-digit reading (137) beside a
                // long elapsed time (`10:24:59`) is the case that truncated, and the reading is the
                // figure a glance needs whole — a timer that shrinks a little still counts, a heart
                // rate showing `1…` does not. See the figures' `.fixedSize()` below.
                SessionTimer(startedAt: state.startedAt, size: 30)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(0)

                Spacer(minLength: 6)

                // **The activity's own mark, and the app resolves it.** The circle is the card's
                // centre ornament; what is inside is the glyph the `ACTIVITIES` card draws for this
                // session's name — pushed as symbol names, because this process cannot import the
                // app's one name → symbol table. A composite (`Fast`) draws both symbols, smaller.
                ZStack {
                    Circle()
                        .stroke(Palette.textPrimary.opacity(0.22), lineWidth: 1.5)

                    if let primary = state.glyphSymbol {
                        HStack(spacing: 1) {
                            Image(systemName: primary)
                            if let secondary = state.glyphSecondarySymbol {
                                Image(systemName: secondary)
                            }
                        }
                        .font(.system(
                            size: state.glyphSecondarySymbol == nil ? 17 : 12,
                            weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    }
                }
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

                Spacer(minLength: 8)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary.opacity(0.55))

                    // **`fixedSize` and the row's priority are what keep 137 whole.** Without them the
                    // flexible text truncates to `1…` as soon as the timer and the mark have taken
                    // their room, and the truncation is invisible to every build — a Live Activity is
                    // only laid out on a phone.
                    Text(state.heartRate.map(String.init) ?? "–")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(Palette.textPrimary)

                    Text("bpm")
                        .font(.system(size: 12, weight: .bold))
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(Palette.textPrimary.opacity(0.55))
                }
                .layoutPriority(1)
            }

            ZoneScale(position: state.bandScalePosition)

            HStack(alignment: .top) {
                UnitFigure(
                    value: Self.distanceValue(state.distanceMeters),
                    unit: Self.distanceUnit,
                    label: "DISTANCE")
                Spacer()
                UnitFigure(
                    value: Self.speedValue(state.averageSpeedMetersPerSecond),
                    unit: Self.speedUnit,
                    label: "SPEED")
            }
        }
        .padding(14)
    }

    // MARK: - The two route figures

    /// Two decimal places, as the mock prints them — `0.82 mi`.
    private static func distanceValue(_ meters: Double?) -> String? {
        guard let meters else { return nil }
        let value = Locale.current.measurementSystem == .metric ? meters / 1_000 : meters / 1_609.344
        return String(format: "%.2f", value)
    }

    /// One decimal place — `4.0 mph`. `nil` when the route has no span to divide by.
    private static func speedValue(_ metersPerSecond: Double?) -> String? {
        guard let metersPerSecond else { return nil }
        let value = Locale.current.measurementSystem == .metric
            ? metersPerSecond * 3.6
            : metersPerSecond * 3_600 / 1_609.344
        return String(format: "%.1f", value)
    }

    /// The unit follows the phone's measurement system, which is the same rule `ActivityRoute.Unit`
    /// applies to the card's caption — restated here because this process cannot import that type.
    private static var distanceUnit: String {
        Locale.current.measurementSystem == .metric ? "km" : "mi"
    }

    private static var speedUnit: String {
        Locale.current.measurementSystem == .metric ? "km/h" : "mph"
    }
}

/// The five-band scale with the current heart rate's marker on it.
///
/// **A position scale, not a distribution** — the same quantity the session screen's band row draws,
/// and the reason the marker is a dot rather than a filled share: the bar says *where the reading is*,
/// not how long the session has spent there. Each band is drawn in its own colour, dimmed, with the
/// band holding the marker at full strength; that is what makes the dot readable without a second
/// legend.
private struct ZoneScale: View {
    let position: Double?

    private var activeBand: Int? {
        guard let position, position.isFinite else { return nil }
        return min(Palette.bands.count - 1, max(0, Int(position * Double(Palette.bands.count))))
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let spacing: CGFloat = 2
                let segment = (width - spacing * CGFloat(Palette.bands.count - 1))
                    / CGFloat(Palette.bands.count)

                ZStack(alignment: .leading) {
                    HStack(spacing: spacing) {
                        ForEach(Palette.bands.indices, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Palette.bands[index].opacity(activeBand == index ? 1 : 0.45))
                                .frame(width: max(1, segment))
                        }
                    }

                    if let position {
                        Circle()
                            .fill(Palette.textPrimary)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(Palette.background, lineWidth: 1.5))
                            .offset(x: min(max(position, 0), 1) * width - 4.5)
                    }
                }
            }
            .frame(height: 6)

            HStack(spacing: 2) {
                ForEach(Palette.bands.indices, id: \.self) { index in
                    Text("Zone \(index + 1)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(
                            Palette.bands[index].opacity(activeBand == index ? 1 : 0.45))
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let activeBand {
            return "Heart rate in zone \(activeBand + 1) of \(Palette.bands.count)"
        }
        return "No heart rate yet"
    }
}

/// A figure with its unit inline and its label under it — `0.82 mi` over `DISTANCE`.
private struct UnitFigure: View {
    let value: String?
    let unit: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "–")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textPrimary)

                if value != nil {
                    Text(unit)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary.opacity(0.55))
                }
            }

            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(Palette.textPrimary.opacity(0.45))
        }
    }
}

/// The dot and word that say whether the session is still recording.
private struct StatusLabel: View {
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isRunning ? Palette.strainRing : Color(white: 0.45))
                .frame(width: 8, height: 8)

            Text(isRunning ? "ACTIVITY" : "ACTIVITY ENDED")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .tracking(1.0)
                .foregroundStyle(Palette.textPrimary.opacity(0.70))
        }
    }
}

/// The timer, and the only element in this file that needs no update to stay correct.
///
/// `style: .timer` is drawn from the wall clock by the system in this process, so it keeps counting
/// while the app is suspended. **Never compute elapsed time from a sample count here** — that would
/// freeze with the figures instead of ticking, which is the opposite of the requirement.
private struct SessionTimer: View {
    let startedAt: Date
    let size: CGFloat

    var body: some View {
        Text(startedAt, style: .timer)
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Palette.textPrimary)
    }
}

/// The card's layout.
private struct SessionCard: View {
    let state: WhoopsySessionAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                StatusLabel(isRunning: state.isRunning)
                Spacer()
                SessionTimer(startedAt: state.startedAt, size: 20)
            }

            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Figure(label: "STRAIN", value: state.strain.map { String(format: "%.1f", $0) }, size: 22)
                Figure(label: "HEART RATE", value: state.heartRate.map(String.init), size: 22)
                Figure(label: "CALORIES", value: state.calories.map { String(Int($0.rounded())) }, size: 22)
            }
        }
        .padding(14)
    }
}

/// One of the card's three figures, drawing `–` when its value is `nil`.
private struct Figure: View {
    let label: String
    let value: String?
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(Palette.textPrimary.opacity(0.45))

            Text(value ?? "–")
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
        }
    }
}
