import SwiftUI

/// The calendar's key: one entry per recovery tier, with that tier's own boundary printed on it.
///
/// `<34%`, `34% - 66%` and `>66%` are arithmetic on `RecoveryState`'s ranges rather than three
/// strings typed here. That is the whole reason the ranges are `public`: a key that hardcoded `66`
/// while `RecoveryState.init(score:)` banded on some other number would colour a day green under a
/// label calling it yellow, and a key that lies about its own colours is worse than no key at all.
public struct RecoveryTierLegend: Equatable, Sendable {
    public let state: RecoveryMetric.RecoveryState
    public let text: String

    public static let entries: [RecoveryTierLegend] = {
        let red = RecoveryMetric.RecoveryState.redRange
        let yellow = RecoveryMetric.RecoveryState.yellowRange
        let green = RecoveryMetric.RecoveryState.greenRange
        return [
            // "below 34" is where red ends.
            RecoveryTierLegend(state: .red, text: "<\(red.upperBound)%"),
            // Yellow's inclusive span, both bounds off the one range.
            RecoveryTierLegend(
                state: .yellow, text: "\(yellow.lowerBound)% - \(yellow.upperBound - 1)%"),
            // "above 66" is the last day below green — `upperBound - 1`, not `lowerBound`, which is
            // exactly the off-by-one that reading `<34` and `>66` as "the same bound" produces.
            RecoveryTierLegend(state: .green, text: ">\(green.lowerBound - 1)%"),
        ]
    }()
}

/// A month of recovery tiers, for choosing the day the app is showing.
///
/// Dumb on purpose: values in, closures out. It holds no repository and no view model, and the only
/// state it owns is which month it is displaying — the day the app is on stays the caller's
/// `@State`, exactly as it does for `DayNavigationBar`'s chevrons.
///
/// **A day absent from `tiers` has no measurement, and that is a different thing from a low score.**
/// The caller builds the map from `RecoveryMetric.hasMeasurement`, never from a row existing: a
/// legacy placeholder row holds `score: 0` and would arrive here as `.red`, painting an unworn night
/// as a hard red day. Grey is the absence of a reading, so the map has to be absent where the
/// reading is.
///
/// **A day with no data is still selectable.** Home legitimately opens on an empty today, so an
/// unmeasured day has to stay reachable or the calendar could not navigate to most of a fresh
/// install. Only a day that has not happened yet is refused — not because it lacks data, but because
/// offering it would be a control whose destination is guaranteed to be empty.
public struct MonthCalendarView: View {
    /// The day the app is showing, for the selection ring.
    public let selected: Date
    /// The tier per day, keyed by `startOfDay`. Absent means no measurement — see the type's note.
    public let tiers: [Date: RecoveryMetric.RecoveryState]
    /// Whether the displayed month's rows are still being read. The grid draws either way: an empty
    /// month is not a loading month, and testing `tiers.isEmpty` to decide would spin forever on a
    /// month nothing was ever recorded in.
    public let isLoading: Bool
    public let onSelect: (Date) -> Void
    public let onMonthChange: (Date) async -> Void

    /// Seeded from the day the app is on, so every presentation opens on that day's month.
    ///
    /// Not merely tidy: a sheet that kept the month it was last paged to would reopen on a month the
    /// user had paged into and dismissed, which after a forward page is a grid that is entirely grey
    /// *and* entirely unselectable — a dead end with no way back except a chevron nothing points at.
    @State private var displayedMonth: Date

    public init(
        selected: Date,
        tiers: [Date: RecoveryMetric.RecoveryState],
        isLoading: Bool,
        onSelect: @escaping (Date) -> Void,
        onMonthChange: @escaping (Date) async -> Void
    ) {
        self.selected = selected
        self.tiers = tiers
        self.isLoading = isLoading
        self.onSelect = onSelect
        self.onMonthChange = onMonthChange
        _displayedMonth = State(initialValue: selected)
    }

    public var body: some View {
        VStack(spacing: 16) {
            monthHeader
            if let grid = MonthGrid.make(for: displayedMonth) {
                weekdayRow(grid)
                dayGrid(grid)
            }
            legend
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Theme.homeBackground)
        .preferredColorScheme(.dark)
        // Runs on appear and on every month change, which is the only thing that asks for a read.
        .task(id: displayedMonth) { await onMonthChange(displayedMonth) }
    }

    // MARK: - Header

    private var monthHeader: some View {
        HStack {
            monthStepButton(systemName: "chevron.left", months: -1, label: "Previous month")
            Spacer()
            // The year is carried because paging back is unbounded and the history spans four of
            // them — a bare "AUGUST" cannot say which, and the reference image's own month is only
            // unambiguous because it never pages.
            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .textCase(.uppercase)
            Spacer()
            monthStepButton(systemName: "chevron.right", months: 1, label: "Next month")
        }
    }

    /// The same no-future rule the day bar applies, one unit coarser: the current month is the last
    /// one there is anything to show.
    private var isAtCurrentMonth: Bool {
        Calendar.current.isDate(displayedMonth, equalTo: Date(), toGranularity: .month)
    }

    private func monthStepButton(systemName: String, months: Int, label: String) -> some View {
        let blocked = months > 0 && isAtCurrentMonth
        return Button {
            displayedMonth = Calendar.current.date(byAdding: .month, value: months, to: displayedMonth)
                ?? displayedMonth
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(blocked ? Theme.textMuted.opacity(0.4) : Theme.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .disabled(blocked)
        .accessibilityLabel(label)
    }

    // MARK: - Grid

    private func weekdayRow(_ grid: MonthGrid) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(grid.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textMuted)
                    .textCase(.uppercase)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    private func dayGrid(_ grid: MonthGrid) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
            spacing: 4
        ) {
            ForEach(Array(grid.cells.enumerated()), id: \.offset) { _, cell in
                if let day = cell {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 38)
                }
            }
        }
        .opacity(isLoading ? 0.5 : 1)
    }

    private func dayCell(_ day: Date) -> some View {
        let isFuture = DayBarRules.isFuture(day)
        let isSelected = Calendar.current.isDate(day, inSameDayAs: selected)
        return Button {
            onSelect(day)
        } label: {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(color(for: day))
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background {
                    if isSelected {
                        Circle().strokeBorder(Theme.textPrimary, lineWidth: 1.5)
                            .frame(width: 34, height: 34)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The rule itself, not just the disabled styling: a future day must not be selectable even
        // if a later change adds a drag or a keyboard path past `.disabled`.
        .disabled(isFuture)
        .accessibilityLabel(Text(accessibilityLabel(for: day)))
        .accessibilityHint(Text(isFuture ? "Not yet recorded" : "Selects this day"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The tier's colour, or one of the two greys.
    ///
    /// The two greys are deliberately different tokens. Grey already means "nothing was measured
    /// here", and a day that has not happened is not a statement about data at all — sharing one
    /// shade would make "we hold nothing for the 3rd" and "the 3rd has not occurred" the same
    /// sentence. The future grey is also the dimmer of the two, so the two absences stay apart at a
    /// glance and not only in the label.
    private func color(for day: Date) -> Color {
        if DayBarRules.isFuture(day) { return Theme.textMuted.opacity(0.4) }
        return tiers[day]?.color ?? Theme.textMuted
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(RecoveryTierLegend.entries, id: \.state) { entry in
                HStack(spacing: 5) {
                    Circle()
                        .fill(entry.state.color)
                        .frame(width: 6, height: 6)
                    Text(entry.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(entry.state.rawValue) recovery, \(entry.text)"))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Accessibility

extension MonthCalendarView {
    /// What a day is worth, said out loud.
    ///
    /// Colour carries the entire meaning of a cell on this screen, so the tier has to survive as
    /// words or the grid is a wall of numbers to a VoiceOver user. `state.description` rather than
    /// `state.rawValue` — "Primed for high strain" is what the colour *means*, and "Green" is only
    /// what it looks like.
    ///
    /// A day with no measurement never announces a score. A placeholder row's `score: 0` spoken as
    /// "0 percent recovery" is the same fabrication the dash convention exists to prevent, said
    /// instead of drawn.
    fileprivate func accessibilityLabel(for day: Date) -> String {
        let datePart = day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        if DayBarRules.isFuture(day) { return "\(datePart), not yet recorded" }
        guard let state = tiers[day] else { return "\(datePart), no recovery recorded" }
        return "\(datePart), \(state.rawValue) recovery, \(state.description)"
    }
}
