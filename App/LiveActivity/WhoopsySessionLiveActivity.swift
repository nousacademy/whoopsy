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
            SessionCard(state: context.state)
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
