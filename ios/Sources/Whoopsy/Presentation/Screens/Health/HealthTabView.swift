import SwiftUI

/// The **Health** tab: the reference's four cards, and the one of them this app can fill.
///
/// **Three of the four have no producer and say so.** WHOOP's Health tab draws a Healthspan (WHOOP Age
/// and Pace of Aging), a Health Monitor, a Blood Pressure Insights estimate and a Heart Screener; this
/// app can compute **only the second** — the five vitals from `recoveries` — because the other three
/// need models and sensors it does not have: `docs/TODO.md` §8 records WHOOP Age as unbuilt, blood
/// pressure as **not coverable** from local data at all, and the MG's ECG as blocked on a capture. The
/// cards are drawn anyway, with a dash and a sentence each, because the alternative is a tab that
/// hides three of the four things the wearer's own strap is sold on — and the sentence is the honest
/// form of "not yet".
///
/// **No chevron is drawn on the three that lead nowhere**, and the Health Monitor card has one because
/// it does: the same rule that keeps the `•••` menus honest.
public struct HealthTabView: View {

    @State private var healthMonitor: HealthMonitorViewModel

    /// Whether the Health Monitor sheet is up.
    @State private var isPresentingHealthMonitor = false

    public init(healthMonitor: HealthMonitorViewModel) {
        _healthMonitor = State(initialValue: healthMonitor)
    }

    private static let gutter: CGFloat = 16

    /// The reference's order for the five vitals — a different order from the sheet's, which lists the
    /// personal ones first. The card is a status strip, so it runs left to right as the reference does.
    private static let monitorOrder: [HealthMonitorSummary.Vital] = [
        .respiratoryRate, .bloodOxygen, .restingHeartRate, .heartRateVariability, .skinTemperature,
    ]

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    healthspanCard
                    riskProfileCard
                    healthMonitorCard
                    bloodPressureCard
                    heartScreenerCard
                }
                .padding(.horizontal, Self.gutter)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
            .background(Theme.backgroundDark)
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .principal) { titleLabel } }
        }
        .task { await healthMonitor.load(for: Date()) }
        .sheet(isPresented: $isPresentingHealthMonitor) {
            HealthMonitorView(viewModel: healthMonitor, date: Date())
        }
    }

    /// What the dial is waiting on, in the reader's own terms.
    ///
    /// **Three absences, three instructions.** A dash cannot tell them apart, and one of them is a field
    /// the reader can fill in right now rather than a model this app has not built.
    static func absenceSentence(_ absence: HealthMonitorViewModel.LongevityAbsence) -> String {
        switch absence {
        case .noMeasuredNight:
            return "A Whoopsy Age needs a night with a resting rate to read. The strap has not recorded "
                + "one in the last year, so there is nothing to place against a life table yet."
        case .noBirthDate:
            return "Add your birthday in Profile → BIOMETRICS. Without an age there is no reference "
                + "point for your risk to be compared with."
        case .noLifeTable:
            return "No life table is bundled for your region yet, so your risk cannot be turned into years."
        }
    }

    private var titleLabel: some View {
        Text("HEALTH")
            .font(.system(size: 14, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Theme.textPrimary)
    }

    // MARK: - Healthspan

    /// The reference's Healthspan card: a pace-of-aging figure on the left, the Whoopsy Age dial on the
    /// right, and a line under them.
    ///
    /// **The pace of aging is a dash and the dial is not**: this app has no pace-of-aging model, but it
    /// can turn a measured profile into an age — see `LongevityEstimate` — so only the first is a
    /// permanent absence. The dial draws `—` until it has the three things it needs, and
    /// `longevityAbsence` says which one is missing rather than leaving the reader to guess.
    private var healthspanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Healthspan")

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PACE OF AGING")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.textSecondary)

                    Text("—")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textMuted)
                        .monospacedDigit()
                }

                Spacer(minLength: 8)

                VStack(spacing: 2) {
                    if let equivalent = healthMonitor.longevity?.equivalentAgeYears {
                        Text(String(format: "%.0f", equivalent))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                    } else {
                        Text("—")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textMuted)
                            .monospacedDigit()
                    }

                    Text("WHOOPSY AGE")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(width: 84, height: 84)
                .overlay(Circle().strokeBorder(Theme.textMuted.opacity(0.4), lineWidth: 2))
            }

            if let longevity = healthMonitor.longevity, let equivalent = longevity.equivalentAgeYears {
                let difference = Double(longevity.age) - equivalent
                Text(
                    String(format: "%.0f years %@ than your %d", abs(difference),
                           difference >= 0 ? "younger" : "older", longevity.age))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(difference >= 0 ? Theme.recoveryGreen : Theme.recoveryRed)
                    .monospacedDigit()

                // **A figure from an older night says so.** The dial survives a gap in the record by
                // standing on the most recent measured day; printing that day is what keeps the number
                // from reading as today's.
                if let day = healthMonitor.healthspanDay {
                    Text("From your last measured day, "
                        + day.formatted(.dateTime.day().month(.abbreviated).year()))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
            } else if let absence = healthMonitor.longevityAbsence {
                // **A dash is not an answer.** Three different things can leave the dial empty and each
                // one needs a different action from the reader — so the card names the one it is.
                Text(Self.absenceSentence(absence))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let mass = healthMonitor.leanBodyMass {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("LEAN BODY MASS (EST.)")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.textSecondary)

                    Spacer(minLength: 8)

                    Text(String(format: "≈%.0f kg", mass.medianKg))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()

                    Text(String(format: "%.0f–%.0f", mass.lowKg, mass.highKg))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                        .monospacedDigit()
                }
            }

            Text("A risk-equivalent age, not WHOOP's model: your measured profile's mortality risk, run "
                + "through the life table, is the risk of the average person that age in that population. "
                + "Three of WHOOP's nine inputs feed it — fitness, steps and resting rate; the six it does "
                + "not use, and the coefficient table WHOOP has not published, are what its own WHOOP Age "
                + "would add.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Healthspan, not computed yet"))
    }

    // MARK: - The mortality-risk profile

    /// The half of a longevity estimate this app can actually compute: three published relative risks
    /// multiplied together, with no life table and no age.
    @ViewBuilder
    private var riskProfileCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Mortality risk profile")

            if let profile = healthMonitor.riskProfile {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.2f", profile.multiplier))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()

                    Text("× the reference profile's all-cause mortality risk")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let longevity = healthMonitor.longevity {
                    Divider().overlay(Theme.cardBorder)

                    HStack(spacing: 8) {
                        Text("Life expectancy at \(longevity.age)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)

                        Spacer(minLength: 8)

                        Text(String(format: "%.1f yrs", longevity.baselineYears))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }

                    HStack(spacing: 8) {
                        Text("With your profile")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)

                        Spacer(minLength: 8)

                        Text(String(format: "%.1f yrs", longevity.adjustedYears))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()

                        Text(String(format: "%+.1f", longevity.deltaYears))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(longevity.deltaYears >= 0
                                ? Theme.recoveryGreen : Theme.recoveryRed)
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                } else {
                    Text("No life table for this region yet, so the multiplier above is all this app "
                        + "can say — turning it into years needs a published table for where you live.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 6) {
                    ForEach(profile.factors) { factor in
                        HStack(spacing: 8) {
                            Text(factor.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)

                            Spacer(minLength: 8)

                            Text(factor.valueText)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .monospacedDigit()

                            Text(String(format: "×%.2f", factor.relativeRisk))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(factor.relativeRisk <= 1
                                    ? Theme.recoveryGreen : Theme.recoveryRed)
                                .monospacedDigit()
                                .frame(width: 48, alignment: .trailing)
                        }
                    }
                }
            } else {
                Text("No reading in the last year — this profile needs a resting rate, a fitness "
                    + "estimate and a step count, and none of them is stored yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            footnoteForRisk
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(riskProfileSpoken))
    }

    /// The sentence that keeps the number honest: what it is anchored to, what it is not, and what was
    /// left out of it.
    private var footnoteForRisk: some View {
        let table = healthMonitor.longevity.map {
            " The years are \($0.countryName), \($0.year) — \($0.source) — with your multiplier "
                + "applied to every remaining year, which assumes a relative risk holds for a lifetime "
                + "and no cohort has shown that."
        } ?? ""
        // The three readings are one day's, and it is not necessarily the day on screen — see
        // `HealthMonitorViewModel.healthspanLookbackDays`. Naming it keeps an older night's numbers
        // from reading as this morning's.
        let readings = healthMonitor.healthspanDay.map {
            " The readings are from \($0.formatted(.dateTime.day().month(.abbreviated).year())), the most "
                + "recent day measured."
        } ?? ""
        return Text(
            "The product of three published relative risks, each against \(MortalityRiskProfile.referenceDescription), "
                + "clamped to \(String(format: "%.1f", MortalityRiskProfile.multiplierRange.lowerBound))–"
                + "\(String(format: "%.1f", MortalityRiskProfile.multiplierRange.upperBound)). "
                + "It is not a biological age." + table + readings + " "
                + MortalityRiskProfile.unusedFactors.joined(separator: " "))
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var riskProfileSpoken: String {
        guard let profile = healthMonitor.riskProfile else {
            return "Mortality risk profile, no reading yet"
        }
        let factors = profile.factors
            .map { "\($0.name) \($0.valueText)" }
            .joined(separator: ", ")
        return "Mortality risk profile, \(String(format: "%.2f", profile.multiplier)) times the "
            + "reference profile's all-cause mortality risk. " + factors
    }

    // MARK: - Health Monitor

    /// The one card with real data: five vitals, each ticked when it sits inside its own band, over the
    /// count the sheet's bands produce. Tapping it opens that sheet.
    private var healthMonitorCard: some View {
        Button {
            isPresentingHealthMonitor = true
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Health Monitor")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                }

                HStack(alignment: .top, spacing: 0) {
                    ForEach(Self.monitorOrder, id: \.self) { vital in
                        monitorColumn(vital)
                            .frame(maxWidth: .infinity)
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: withinRangeCount == HealthMonitorSummary.total
                        ? "checkmark.square.fill" : "square.dashed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(withinRangeColor)

                    Text("\(withinRangeCount)/\(HealthMonitorSummary.total) metrics within range")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(withinRangeColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(
            "Health monitor, \(withinRangeCount) of \(HealthMonitorSummary.total) metrics within range. Opens the readings."))
    }

    private func monitorColumn(_ vital: HealthMonitorSummary.Vital) -> some View {
        let reading = healthMonitor.readings.first { $0.vital == vital }

        return VStack(spacing: 5) {
            Image(systemName: HealthMonitorView.symbol(for: vital))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(height: 18)
                .accessibilityHidden(true)

            Text(Self.columnLabel(vital))
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // A tick only where a band was cleared. No reading, no band and an out-of-range value all
            // draw the same muted square-dash — the card is a status strip, and the sheet is where the
            // difference between "not measured" and "outside" is spelled out.
            Image(systemName: reading?.isWithin == true ? "checkmark.square.fill" : "square.dashed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(reading?.isWithin == true ? Theme.recoveryGreen : Theme.textMuted)
        }
    }

    private static func columnLabel(_ vital: HealthMonitorSummary.Vital) -> String {
        switch vital {
        case .respiratoryRate: return "RESP"
        case .bloodOxygen: return "SPO2"
        case .restingHeartRate: return "RHR"
        case .heartRateVariability: return "HRV"
        case .skinTemperature: return "TEMP"
        }
    }

    /// How many of the five sit inside their band — the count the sheet's bands produce, not a second
    /// calculation. A vital with no reading contributes nothing.
    private var withinRangeCount: Int {
        healthMonitor.readings.filter(\.isWithin).count
    }

    private var withinRangeColor: Color {
        withinRangeCount == HealthMonitorSummary.total ? Theme.recoveryGreen : Theme.textSecondary
    }

    // MARK: - The two cards with no producer

    private var bloodPressureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Blood Pressure Insights")

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("TODAY'S ESTIMATE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textSecondary)

                Text("—/—")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
            }

            Text("Not estimated. The strap maker computes this on its servers from overnight PPG and calibrates it "
                + "against a cuff reading; this app has neither the waveform nor a calibration input, "
                + "and a made-up number here would be the worst thing the screen could do.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Blood pressure insights, not available"))
    }

    private var heartScreenerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Heart Screener")

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("LAST ECG REPORT")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textSecondary)

                Text("—")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
            }

            Text("No ECG has been recorded. Your strap's ECG command family is documented but unverified, "
                + "and a rhythm statement is a medical claim this app will not make without a capture "
                + "from the strap.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Heart screener, no ECG recorded"))
    }
}
