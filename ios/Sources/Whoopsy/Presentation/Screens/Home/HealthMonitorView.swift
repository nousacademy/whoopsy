import Foundation
import SwiftUI

/// The Health Monitor sheet: the night's five vitals against the bands this app can defend, and the
/// night's average heart rate above them.
///
/// **It is a sheet, not a pushed page**, because the reference draws one: an `✕` at the leading edge,
/// `HEALTH MONITOR` centred, the whole screen a modal over Home. That is `ActivityEditSheet`'s chrome,
/// and the same rule applies — a sheet draws on the system's own background, so it states
/// `Theme.backgroundDark` and `.preferredColorScheme(.dark)` itself or it is a light card in front of a
/// dark app.
///
/// **Two elements of the reference are not drawn.** The `?` beside the section title has no destination,
/// and the `SHARE YOUR HEALTH REPORT` row was excluded by the user (*"can be excluded for now"*) — a
/// control that looks tappable and is not reads as broken, which is the rule every screen here follows.
/// The report itself stays listed as work in `docs/TODO.md` §8; when it lands, the row comes back with
/// the same §8 entry to point at.
///
/// **The heart rate is the night's mean, and only when the night has samples.** The reference prints a
/// single `75 BPM`; this app has no stored nightly average, so it averages the `biometric_samples` the
/// night's window holds — the same rows the sleep page's trace is drawn from. An imported night has no
/// samples, so the figure is absent rather than invented, and the circle says so.
public struct HealthMonitorView: View {

    @State private var viewModel: HealthMonitorViewModel

    /// The night being shown — the day Home is displaying, passed in as a plain `let` on the
    /// pushed-page rule.
    private let date: Date

    public init(viewModel: HealthMonitorViewModel, date: Date) {
        _viewModel = State(initialValue: viewModel)
        self.date = date
    }

    private static let gutter: CGFloat = 16
    private static let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    heartRateHeader
                    readingsSection
                }
                .padding(.horizontal, Self.gutter)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.backgroundDark)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { closeButton }
                ToolbarItem(placement: .principal) { titleLabel }
            }
        }
        .preferredColorScheme(.dark)
        .task { await viewModel.load(for: date) }
    }

    // MARK: - The night's average

    /// The reference's circle: a heart, the night's mean heart rate, `BPM`, and a rule through it.
    ///
    /// **The rule is drawn behind the circle and runs the page's whole width**, which is the one piece
    /// of the reference's composition that is not a card. It sits at the circle's centre, so the number
    /// reads as a reading on a scale rather than as a badge.
    private var heartRateHeader: some View {
        ZStack {
            Rectangle()
                .fill(Theme.weekLine)
                .frame(height: 1)

            VStack(spacing: 2) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)

                Text(viewModel.averageHeartRate.map(String.init) ?? "—")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()

                Text("BPM")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 116, height: 116)
            // The reference's disc is a plain black circle over the rule — no ring of its own, which
            // would read as a gauge with no scale behind it.
            .background(Circle().fill(Theme.backgroundDark))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(heartRateSpoken))
    }

    private var heartRateSpoken: String {
        guard let average = viewModel.averageHeartRate else {
            return "Average heart rate, no reading for this night"
        }
        return "Average heart rate, \(average) beats per minute"
    }

    // MARK: - The five readings

    private var readingsSection: some View {
        VStack(spacing: 12) {
            SectionLabel("Last night's readings")

            if viewModel.readings.isEmpty {
                Text("No vitals were recorded for this night.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: Self.columns, spacing: 12) {
                    ForEach(viewModel.readings) { reading in
                        readingCard(reading)
                    }
                }
            }

            footnote
        }
    }

    private func readingCard(_ reading: HealthMonitorReadings.Reading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(for: reading.vital))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)

                Text(Self.title(for: reading.vital))
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(reading.valueText)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(reading.unit)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }

            chip(reading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken(reading)))
    }

    /// The comparison chip. **The tick is `isWithin`'s, not the text's**, so a chip cannot show a tick
    /// over a figure outside its band — and a reading with no band says so and draws no tick.
    private func chip(_ reading: HealthMonitorReadings.Reading) -> some View {
        HStack(spacing: 4) {
            if reading.isWithin {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
            }

            Text(reading.chipText)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(reading.isWithin ? Theme.recoveryGreen : Theme.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill((reading.isWithin ? Theme.recoveryGreen : Theme.textSecondary).opacity(0.12)))
    }

    private var footnote: some View {
        Text(
            "Each band is the mean ± one standard deviation of your last "
                + "\(viewModel.baselineNights) measured night\(viewModel.baselineNights == 1 ? "" : "s") — "
                + "this app's own band, not the strap maker's. Blood oxygen is read against the clinical "
                + "\(Int(HealthMonitorReadings.oxygenFloor))–100% range rather than a personal one, "
                + "because a personal band on a metric that barely moves would call a normal night low.")
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - The chrome

    private var titleLabel: some View {
        Text("HEALTH MONITOR")
            .font(.system(size: 14, weight: .bold))
            .tracking(1.0)
            .foregroundStyle(Theme.textPrimary)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityLabel("Close")
    }

    @Environment(\.dismiss) private var dismiss

    // MARK: - Words

    /// The card's own label, named here rather than on the enum: the enum feeds the Home row, whose
    /// labels are part of its spoken sentence, and this is a card title.
    nonisolated static func title(for vital: HealthMonitorSummary.Vital) -> String {
        switch vital {
        case .heartRateVariability: return "HRV"
        case .restingHeartRate: return "RHR"
        case .respiratoryRate: return "RESPIRATORY RATE"
        case .bloodOxygen: return "BLOOD OXYGEN"
        case .skinTemperature: return "SKIN TEMP (FROM BASELINE)"
        }
    }

    nonisolated static func symbol(for vital: HealthMonitorSummary.Vital) -> String {
        switch vital {
        case .heartRateVariability: return "waveform.path.ecg"
        case .restingHeartRate: return "arrow.down.heart"
        case .respiratoryRate: return "lungs"
        case .bloodOxygen: return "drop"
        case .skinTemperature: return "thermometer.medium"
        }
    }

    /// One card, one sentence: the figure, its unit, and what it is read against.
    nonisolated static func spoken(_ reading: HealthMonitorReadings.Reading) -> String {
        let name = reading.vital.displayName
        let unit = reading.vital == .respiratoryRate ? "breaths per minute" : reading.unit
        return "\(name), \(reading.valueText) \(unit), \(reading.chipText)"
    }
}
