import SwiftUI

public struct SleepDashboardView: View {
    @State private var viewModel: SleepViewModel

    /// This tab's own day, independent of the other tabs by design — see `RecoveryDashboardView`.
    @State private var selectedDate: Date = Date()
    public init(viewModel: SleepViewModel) { _viewModel = State(initialValue: viewModel) }
    public var body: some View { NavigationStack { ScrollView { VStack(spacing: 16) { DashboardHeader("Sleep", subtitle: hasSession ? "Nightly review" : "No data recorded")
        DayNavigationBar(date: $selectedDate)
        GaugeRingView(progress: gaugeProgress, scoreText: gaugeText, label: gaugeLabel, ringColor: gaugeColor, lineWidth: 18, size: 190).glassCard()
        HStack { MetricCardView(title: "Sleep deficit", value: nightDeficit, unit: "", iconName: "bed.double.fill", accentColor: Theme.sleepAwake); MetricCardView(title: "Efficiency", value: efficiency, unit: hasSession ? "%" : "", iconName: "checkmark.circle.fill", accentColor: Theme.sleepRem) }
        if let session = viewModel.session, !session.sleepStages.isEmpty { HypnogramChartView(stages: session.sleepStages) }
        else { VStack(alignment: .leading, spacing: 8) { SectionLabel("Sleep stages"); Text("No stages recorded.").font(.caption).foregroundStyle(Theme.textSecondary) }.glassCard() }
        VStack(spacing: 10) { stage("Awake", viewModel.session?.awakeSeconds, Theme.sleepAwake); stage("Light", viewModel.session?.lightSleepSeconds, Theme.sleepLight); stage("Deep", viewModel.session?.deepSleepSeconds, Theme.sleepDeep); stage("REM", viewModel.session?.remSleepSeconds, Theme.sleepRem) }.glassCard()
    }.padding() }.background(Theme.backgroundDark).task { await viewModel.load(for: selectedDate) }
    .onChange(of: selectedDate) { _, newDate in Task { await viewModel.load(for: newDate) } } }.preferredColorScheme(.dark) }

    /// A night `AnalyzeSleepUseCase` could not classify comes back `nil` and is written nowhere, so
    /// there is no session to describe. Every number on this screen is a measurement of a specific
    /// night — the deficit, the efficiency and the stage breakdown all mean "for that night" — and
    /// there is no night. Substituting a plausible default would report a fabricated night as
    /// recorded sleep, which is the one thing this screen exists to measure.
    private var hasSession: Bool { viewModel.session != nil }
    private var dash: String { "—" }
    private var gaugeProgress: Double { hasSession ? Double(viewModel.session?.sleepPerformancePercentage ?? 0) / 100 : 0 }
    private var gaugeText: String { hasSession ? "\(viewModel.session?.sleepPerformancePercentage ?? 0)%" : dash }
    private var gaugeLabel: String { hasSession ? "Performance" : "No data" }
    private var gaugeColor: Color { hasSession ? Theme.sleepIndigo : Theme.textSecondary }
    private var efficiency: String { hasSession ? "\(viewModel.session?.sleepEfficiencyPercentage ?? 0)" : dash }
    /// This night's shortfall against this night's need — **not** WHOOP's Sleep Debt, which accumulates
    /// across nights and is deliberately not modelled here (`ALGORITHMS.md` §4 says why). The two share
    /// the word "debt" and nothing else, so the card is labelled with the quantity it actually shows:
    /// a reader who takes it for the accumulated figure would be reading a one-night number as a
    /// week's.
    private var nightDeficit: String {
        guard let session = viewModel.session else { return dash }
        return max(0, session.targetSleepNeedSeconds - session.totalTimeAsleepSeconds).formattedHoursMinutes()
    }
    private func stage(_ title: String, _ seconds: TimeInterval?, _ color: Color) -> some View { HStack { Circle().fill(color).frame(width: 9); Text(title); Spacer(); Text(seconds?.formattedHoursMinutes() ?? dash).foregroundStyle(Theme.textSecondary) } }
}
