import SwiftUI

/// The **Health Monitor** row on Home, above `My Day`: the five vitals WHOOP's monitor tracks, and how
/// many of them this day holds a reading for.
///
/// **The number is real and the words are the app's, not the reference's.** The reference draws
/// `5/5 METRICS` over `WITHIN RANGE` with a green check — a claim that each vital sits inside the
/// wearer's own normal. This app holds the five values on the day's `recoveries` row but has a band for
/// only some of them, so the row counts what it can prove and says `ALL MEASURED` rather than a verdict
/// it cannot support. That is `ui-data-provenance`'s rule, and it is why `HealthMonitorSummary` counts
/// readings rather than ranges; **flipping the copy without building the bands is the fabrication the
/// repo's absence rules exist to prevent.**
///
/// **It draws on every day, including a day with no reading**, and shows `0/5` there. A monitor whose
/// subject is "which of my vitals do I have" has an honest answer for an empty day — none of them — and
/// hiding the card would leave a reader unable to tell an unmeasured day from a feature that is not
/// there.
///
/// **It is not a link.** No Health Monitor page exists, and this repo does not draw a control with no
/// destination — the card is a `glassCard` row, not a `NavigationLink`.
public struct HealthMonitorCard: View {

    private let summary: HealthMonitorSummary

    public init(summary: HealthMonitorSummary) {
        self.summary = summary
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("HEALTH")
                Text("MONITOR")
            }
            .font(.system(size: 13, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(summary.measuredCount)/\(HealthMonitorSummary.total) METRICS")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()

                Text(summary.isComplete ? Self.completeCaption : Self.incompleteCaption)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.4)
                    .foregroundStyle(summary.isComplete ? Theme.recoveryGreen : Theme.textSecondary)
            }

            checkmark
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken))
    }

    /// The green state's word, and the honest replacement for the reference's `WITHIN RANGE`.
    private nonisolated static let completeCaption = "ALL MEASURED"

    /// The other state's word. Short because the count beside it already says how many.
    private nonisolated static let incompleteCaption = "SOME MISSING"

    /// The reference's badge: a small rounded square with a tick, in the same green as the caption.
    ///
    /// **Only in the complete state.** A tick beside `0/5` would be the "all good" claim the card
    /// exists to avoid; the empty square it would otherwise draw is the dash-as-placeholder mistake,
    /// so the badge is simply absent until there is something to tick.
    @ViewBuilder
    private var checkmark: some View {
        if summary.isComplete {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.backgroundDark)
                .frame(width: 20, height: 20)
                .background(Theme.recoveryGreen, in: RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
        }
    }

    /// `Health monitor, 3 of 5 metrics measured, missing respiratory rate and blood oxygen`.
    ///
    /// The missing vitals are named rather than counted: a listener told "2 missing" without being told
    /// which two has to open another screen to find out, and there is no other screen.
    private var spoken: String {
        let count = "\(summary.measuredCount) of \(HealthMonitorSummary.total) metrics measured"
        guard !summary.isComplete else { return "Health monitor, \(count)" }
        let names = summary.missing.map(\.displayName).joined(separator: ", ")
        return "Health monitor, \(count), missing \(names)"
    }
}
