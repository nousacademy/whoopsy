import SwiftUI

/// One metric's trend over a window — the steps page Home's `STEPS` tile pushes.
///
/// **The page is the reference's `TREND VIEW` with the metrics it can actually draw.** The mock's
/// dropdown offers a choice of metrics; this app has exactly one trend page, so the header names the
/// quantity instead of holding a control that would open a list of one. A picker that looks tappable
/// and leads nowhere is the inert-control defect every other screen here avoids.
///
/// **There is no goal line and no encouragement sentence.** The reference prints *"You've met your step
/// goal for the last two days, keep crushing it"*, and this app has no step goal to meet — nothing
/// stores one, and inventing a number to compare against would be the fabricated-value failure the
/// whole absence rule exists to prevent. What the page says instead is the honest fact the chart
/// cannot show by itself: how many of the window's days were measured. That is also what makes a gap
/// readable as an absence rather than as a day of no walking.
///
/// **The day is not a `let` and there is no day stepper.** Unlike the ring pages this one is about a
/// window rather than a day, so its chevrons move the window by one period and the period control
/// recomputes it from the same anchor.
struct StepsDetailView: View {
    @State private var viewModel: StepsViewModel

    public init(viewModel: StepsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                averageRow
                rangeRow
                if let trend = viewModel.trend {
                    StepsBarChartView(trend: trend)
                        .padding(.top, 4)
                    footnote(trend)
                } else if viewModel.isLoading {
                    ProgressView()
                        .tint(Theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                }
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.recoveryRed)
                }
            }
            .padding()
        }
        // `StrainDetailView`'s line, for its reason: a `ScrollView` whose content holds nothing
        // flexible lays out at its content's width, and the background would paint a column.
        .frame(maxWidth: .infinity)
        .background(Theme.backgroundDark)
        .navigationTitle("Steps")
        .preferredColorScheme(.dark)
        .task { await viewModel.load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "figure.walk")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
            Text("STEPS")
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var averageRow: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AVERAGE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)

                Text(viewModel.trend?.average.map { $0.formatted(.number.grouping(.automatic)) } ?? "—")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(viewModel.trend?.average == nil ? Theme.textMuted : Theme.textPrimary)
                    .monospacedDigit()
            }

            Spacer(minLength: 12)

            periodPicker
        }
    }

    /// `W / M / 6M`, drawn as three pills rather than a system segmented control because the reference
    /// draws one and the system control's selected fill is the platform's, not this page's surface.
    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(StepsTrend.Period.allCases) { period in
                let selected = viewModel.period == period
                Button {
                    Task { await viewModel.select(period) }
                } label: {
                    Text(period.rawValue)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .frame(width: 32, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selected ? Theme.ringTrack : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.homeCard))
    }

    private var rangeRow: some View {
        HStack {
            Button {
                Task { await viewModel.move(by: -1) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous period")

            Text(viewModel.rangeTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)

            Button {
                Task { await viewModel.move(by: 1) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(viewModel.canMoveForward ? Theme.textSecondary : Theme.textMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canMoveForward)
            .accessibilityLabel("Next period")
        }
    }

    /// The one sentence the reference spends on a goal, spent on what the chart cannot say instead.
    private func footnote(_ trend: StepsTrend) -> some View {
        let unit = trend.period.isWeekly ? "weeks" : "days"
        return Text(
            "\(trend.measuredSlots) of \(trend.points.count) \(unit) measured. "
                + "A day with no bar was not measured — the strap was not worn, "
                + "so it is a gap rather than a day of no walking.")
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
