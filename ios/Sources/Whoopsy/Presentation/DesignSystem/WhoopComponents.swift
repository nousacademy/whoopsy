import SwiftUI

public struct DashboardHeader: View {
    public let title: String
    public let subtitle: String
    public init(_ title: String, subtitle: String = Date.now.formatted(date: .abbreviated, time: .omitted)) { self.title = title; self.subtitle = subtitle }
    public var body: some View { VStack(alignment: .leading, spacing: 3) { Text(title.uppercased()).font(.system(size: 24, weight: .black, design: .rounded)); Text(subtitle.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary) } .frame(maxWidth: .infinity, alignment: .leading) }
}

/// The day stepper the day-keyed screens share: back a day, the day, forward a day.
///
/// Lifted out of `HomeDashboardView`, which had this private and inline, so that the screens showing
/// a day show one control instead of several that drift. Each screen owns its own `selectedDate` —
/// the tabs are deliberately independent, so paging Strain does not move Sleep.
///
/// **Three screens draw it, not four.** `RecoveryDetailView` has no stepper, because its four rows
/// are a reading of one night against one trailing window and paging away would leave the window
/// describing a day no longer on screen; its day is handed in instead, by the tab or by Home's ring
/// push. Anywhere the bar *is* drawn, the reader may move the day.
///
/// Two of the three things the bar does are rules about the **date** rather than about data, and so
/// they hold wherever it is drawn: the centre reads `TODAY` when the day is today, and the forward
/// chevron stops there. A day that has not happened is empty on every screen showing one, so leaving
/// the clamp to the screens that happen to pass a calendar would leave the app with two day steppers
/// that disagree about the future. Both rules live in `DayBarRules` rather than in this body,
/// because a rule written into a view is a rule nothing can assert — the runner has no renderer.
///
/// The third is not shared: `onTitleTap` is what turns the centre into a button, and only Home
/// passes one, because only Home has a calendar to open. Where it is `nil` the label stays the plain
/// `Text` it has always been — Strain and Sleep have no destination for that tap, and a title that
/// looks tappable and is not reads as broken.
public struct DayNavigationBar: View {
    @Binding public var date: Date
    public var onTitleTap: (() -> Void)?

    public init(date: Binding<Date>, onTitleTap: (() -> Void)? = nil) {
        _date = date
        self.onTitleTap = onTitleTap
    }

    public var body: some View {
        HStack {
            stepButton(systemName: "chevron.left", days: -1, label: "Previous day")
            Spacer()
            titleLabel
            Spacer()
            stepButton(systemName: "chevron.right", days: 1, label: "Next day")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.homeCard)
        .cornerRadius(24)
    }

    @ViewBuilder
    private var titleLabel: some View {
        if let onTitleTap {
            Button(action: onTitleTap) {
                titleText
                    // The glyphs alone are a ~90pt target between two chevrons, which reads as
                    // unresponsive. The bar's whole middle is what its appearance promises is
                    // tappable, so that is what is claimed.
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(titleAccessibilityLabel))
            .accessibilityHint("Opens the month calendar")
        } else {
            titleText
                .accessibilityLabel(Text(titleAccessibilityLabel))
        }
    }

    private var titleText: some View {
        Text(DayBarRules.label(for: date))
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
    }

    /// Spelled out rather than read off the screen, because `TODAY` is the one label whose visible
    /// text is not the date — a VoiceOver user hearing only the word loses which day is selected,
    /// which is the only thing the control reports.
    private var titleAccessibilityLabel: String {
        let spoken = date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        return DayBarRules.isToday(date) ? "Today, \(spoken)" : spoken
    }

    private func stepButton(systemName: String, days: Int, label: String) -> some View {
        // Read from the binding on each pass rather than cached, so the bar stays correct after any
        // other code moves `date` — selecting a day in the calendar writes it too.
        let blocked = days > 0 && !DayBarRules.canStepForward(from: date)
        return Button {
            // Not redundant with `.disabled`. The stop is an invariant of the stepper, and this is
            // what holds it if a later change adds a drag, a keyboard path or a test that drives the
            // action directly while something else decides what looks enabled.
            guard !blocked, let shifted = Calendar.current.date(byAdding: .day, value: days, to: date)
            else { return }
            date = shifted
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                // The dim is not decoration: a `.disabled` chevron left at full contrast reads as a
                // dead button rather than a bounded one. The enabled colour is untouched.
                .foregroundColor(blocked ? Theme.textMuted.opacity(0.4) : .gray)
        }
        .disabled(blocked)
        .accessibilityLabel(label)
    }
}

public struct SectionLabel: View {
    public let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View { Text(text.uppercased()).font(.caption2.weight(.bold)).tracking(1.1).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading) }
}

public struct MiniTrendView: View {
    public let values: [Double]
    public let color: Color
    public init(values: [Double], color: Color) { self.values = values; self.color = color }
    public var body: some View { GeometryReader { proxy in
        let maxValue = max(values.max() ?? 1, 1); let minValue = values.min() ?? 0; let range = max(maxValue - minValue, 1)
        Path { path in for index in values.indices { let x = proxy.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1)); let y = proxy.size.height * (1 - CGFloat((values[index] - minValue) / range)); index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y)) } }.stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    } .frame(height: 44) }
}
