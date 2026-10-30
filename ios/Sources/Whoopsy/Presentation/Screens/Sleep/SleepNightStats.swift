import SwiftUI

/// The reference's two headline figures, side by side at the top of the sleep page: the night's
/// **hours of sleep** and its **restorative sleep**, each read against the mean of the window behind
/// it.
///
/// **The shape is the reference's, not a card's**: the figure large, a grey pill beside it carrying the
/// direction and the mean, and the label *beneath* the pair. The pill is why there is no
/// `MetricHeadline` here — that component puts the mean on a second line, which is right under a card
/// title and wrong in a row that has no title, where the two halves have to stand at one height. The
/// comparison itself is still `MetricChange`'s: same three states, same colour, same "these two print
/// alike" rule, so the verdict is the app's one verdict drawn in the reference's arrangement.
///
/// **The arrow keeps its colour and only the pill is grey.** The reference draws a grey triangle, but
/// this app's verdict scale is the one thing a reader can carry between screens, and dropping it here
/// would make the sleep page the only place where a short night and a long one look identical.
///
/// **The two figures do not need the window; only their pills do.** Hours of sleep and restorative
/// sleep come off the session and exist on every night, imported ones included, while the means need
/// `RecoveryScoring.minimumBaselineDays` usable nights. A thin window therefore draws the pair with no
/// pill, rather than hiding two real readings behind an absent one.
struct SleepNightStats: View {
    let asleepSeconds: TimeInterval
    let typicalAsleepSeconds: TimeInterval?
    let restorativeSeconds: TimeInterval
    let typicalRestorativeSeconds: TimeInterval?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            column(
                label: "HOURS OF SLEEP",
                seconds: asleepSeconds,
                typicalSeconds: typicalAsleepSeconds,
                spokenName: "Hours of sleep")
            column(
                label: "RESTORATIVE SLEEP",
                seconds: restorativeSeconds,
                typicalSeconds: typicalRestorativeSeconds,
                spokenName: "Restorative sleep")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func column(
        label: String,
        seconds: TimeInterval,
        typicalSeconds: TimeInterval?,
        spokenName: String
    ) -> some View {
        let change = MetricChange.between(
            current: seconds,
            previous: typicalSeconds,
            higherIsBetter: true,
            formatted: { $0.formattedCompactHoursMinutes() })

        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 7) {
                Text(seconds.formattedCompactHoursMinutes())
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                    // **One line, always.** Each column gets half a phone's width, and `7:46` plus its
                    // capsule is wider than that on a 390pt screen — without these three the figure
                    // wraps between `7:4` and `6`, which is what a screenshot of the first build showed.
                    // The capsule is the part that must not shrink (its widths are already tight), so
                    // the figure is what scales, and only down to a size still larger than the label.
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                // No mean, no pill: a grey capsule with a dash in it would be a comparison the window
                // did not support.
                if let change {
                    pill(change)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(spoken(spokenName, seconds: seconds, typical: typicalSeconds)))
    }

    /// The reference's capsule: the direction, then the mean it is read against.
    ///
    /// The `.same` verdict draws a dot rather than a triangle, which is `MetricChange`'s own rule and
    /// is why the glyph comes from `symbolName` rather than from a ternary written here.
    private func pill(_ change: MetricChange) -> some View {
        HStack(spacing: 3) {
            Image(systemName: change.symbolName)
                .font(.system(size: change.direction == nil ? 6 : 9))
                .foregroundStyle(change.color)

            Text(change.previousText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.ringTrack.opacity(0.55)))
    }

    /// `Hours of sleep, 6h 19m, typical 6h 51m`, and `…, no typical yet` on a thin window.
    ///
    /// The durations are spoken through `formattedHoursMinutes()` and not the compact form printed on
    /// screen, on the page's existing rule: `6:19` is a clock reading to VoiceOver, and `6h 19m` is a
    /// duration.
    private func spoken(_ name: String, seconds: TimeInterval, typical: TimeInterval?) -> String {
        let figure = seconds.formattedHoursMinutes()
        guard let typical else { return "\(name), \(figure), no typical yet" }
        return "\(name), \(figure), typical \(typical.formattedHoursMinutes())"
    }
}
