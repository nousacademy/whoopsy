import SwiftUI

/// One reading's trend over a window — the page Home's `RHR` and `HRV` panels push.
///
/// The two pages are one view because they are one quantity-shaped question: a daily reading, a mean,
/// a comparison with the window before, and a band the priors describe. What differs is a unit, a
/// direction of "better", and the words — all `ReadingTrend.Kind`'s. Writing the page twice would put
/// the window arithmetic and the chart rules in two places.
///
/// **The band is this app's own derivation**, not WHOOP's — the prior window's mean ± one standard
/// deviation, stated in the footnote, because WHOOP's baseline is anchored to physiological events this
/// app cannot measure. **A gap breaks the line**: a day with no measured reading is neither a zero nor
/// an interpolation, and either would draw a reading the app never took.
struct ReadingTrendDetailView: View {
    @State private var viewModel: ReadingTrendViewModel

    public init(viewModel: ReadingTrendViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    private var kind: ReadingTrend.Kind { viewModel.kind }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                averageRow
                comparisonRow
                Text(sentence)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let trend = viewModel.trend {
                    legend
                    ReadingTrendChartView(trend: trend)
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
        // flexible lays out at its content's width and paints a column.
        .frame(maxWidth: .infinity)
        .background(Theme.backgroundDark)
        .navigationTitle(kind.title)
        .preferredColorScheme(.dark)
        .task { await viewModel.load() }
    }

    private var averageRow: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text("AVERAGE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)

                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(averageText)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(viewModel.trend?.average == nil ? Theme.textMuted : Theme.textPrimary)
                        .monospacedDigit()
                    Text(kind.unit)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer(minLength: 12)

            periodPicker
        }
    }

    private var averageText: String {
        guard let average = viewModel.trend?.average else { return "—" }
        return String(format: "%.0f", average)
    }

    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(ReadingTrend.Period.allCases) { period in
                let selected = viewModel.period == period
                Button {
                    Task { await viewModel.select(period) }
                } label: {
                    Text(period.rawValue)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .frame(width: 36, height: 24)
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

    private var comparisonRow: some View {
        HStack(spacing: 10) {
            if let change = viewModel.trend.flatMap(comparisonChange) {
                HStack(spacing: 4) {
                    Image(systemName: change.symbolName)
                        .font(.system(size: 9))
                    Text(percentText(change))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(change.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(change.color.opacity(0.14)))
            }

            Spacer(minLength: 8)

            Button {
                Task { await viewModel.move(by: -1) }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 30, height: 30)
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(viewModel.canMoveForward ? Theme.textPrimary : Theme.textMuted)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canMoveForward)
            .accessibilityLabel("Next period")
        }
    }

    private func comparisonChange(_ trend: ReadingTrend) -> MetricChange? {
        // The verdict is `MetricChange`'s, and the direction is the **kind's**: an HRV rise is green
        // and an RHR rise is not, which is the same split the two panels on Home already make.
        guard trend.percentChange != nil else { return nil }
        return MetricChange.between(
            current: trend.average,
            previous: trend.previousAverage,
            higherIsBetter: kind.higherIsBetter,
            formatted: { String(format: "%.0f", $0) })
    }

    private func percentText(_ change: MetricChange) -> String {
        guard let percent = viewModel.trend?.percentChange else { return "" }
        let sign = percent > 0 ? "+" : ""
        return "\(sign)\(percent)% vs. \(viewModel.trend?.period.priorNoun ?? "previous period")"
    }

    /// The reference's sentence, drawn from the two means the trend already holds.
    private var sentence: String {
        guard let trend = viewModel.trend else { return "" }
        guard let average = trend.average else {
            return "No measured \(kind.spokenName) in this \(trend.period.noun)."
        }
        let averageText = String(format: "%.0f", average)
        guard let previous = trend.previousAverage else {
            return "Your average \(kind.spokenName) this \(trend.period.noun) was \(averageText) "
                + "\(kind.unit). There is no measured \(trend.period.priorNoun) to compare it with."
        }
        let previousText = String(format: "%.0f", previous)
        switch trend.percentChange {
        case .some(0):
            return "Your average \(kind.spokenName) this \(trend.period.noun) (\(averageText) "
                + "\(kind.unit)) matched the \(trend.period.priorNoun)'s average."
        case let percent? where percent > 0:
            return "Your average \(kind.spokenName) this \(trend.period.noun) (\(averageText) "
                + "\(kind.unit)) was above the \(trend.period.priorNoun)'s average of \(previousText) "
                + "\(kind.unit)."
        default:
            return "Your average \(kind.spokenName) this \(trend.period.noun) (\(averageText) "
                + "\(kind.unit)) was below the \(trend.period.priorNoun)'s average of \(previousText) "
                + "\(kind.unit)."
        }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.ringTrack.opacity(0.55))
                .frame(width: 10, height: 10)
            Text("TYPICAL RANGE")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func footnote(_ trend: ReadingTrend) -> some View {
        // The HRV page names its quantity — SDNN and RMSSD are different measurements, and a page of
        // numbers has to say which one it is. Resting rate has no such split and says nothing.
        let metric = trend.hrvMetric.map { ", in \($0.displayName)" } ?? ""
        // **The VO₂ page's first sentence is that it is not a measurement.** The reference draws two
        // series — a manual entry and WHOOP's estimate — and this app has neither the manual entry
        // nor WHOOP's model: it has `Vo2MaxMath`'s ratio, whose error bar is quoted in whole
        // mL·kg⁻¹·min⁻¹. Saying that where the legend would be is the honest version of the mock.
        let estimate = kind.isEstimate
            ? "Estimated as 15.3 × the profile's maximum heart rate ÷ the day's resting rate — "
                + "this app's estimate, with a 4.7 mL/kg/min standard error, not a measurement. "
            : ""
        return Text(
            estimate
                + "\(trend.measuredDays) of \(trend.points.count) days measured\(metric). "
                + "The typical range is the \(trend.period.priorNoun)'s mean ± one standard "
                + "deviation — this app's own band, not the strap maker's. A break in the line is a day with no "
                + "measured reading.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
