import SwiftUI

/// **Unrendered since the Sleep tab was deleted, and it is the third of three in that state.**
///
/// Its last caller was `SleepDashboardView`, one of the two dashboard files the user asked to go. It
/// is kept for `MetricCardView`'s reason and not on the `ActivityDurationBar` precedent — the runner
/// asserts nothing about it, so deleting it would drop no guarantee, and what keeps it here is that
/// the sweep went out on two *pages* while this is a chart component. It is worth knowing that **the
/// app still has no other hypnogram**: `v12` stores a timeline for a strap night, but the export
/// reports stage totals and no timeline, so no night this app can show has segments for this view to
/// draw. If a screen wants one, this is the only implementation and it needs no change. Several other
/// shapes' doc comments name it as the house exemplar of the hand-rolled-`Shape` style, and those
/// sentences stay true, but do not read them as evidence that something draws it.
public struct HypnogramChartView: View {
    public let stages: [SleepStageSegment]
    public init(stages: [SleepStageSegment]) { self.stages = stages }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Sleep stages")
            GeometryReader { proxy in
                let duration = max(stages.reduce(0) { $0 + $1.durationSeconds }, 1)
                HStack(alignment: .bottom, spacing: 2) { ForEach(stages) { stage in RoundedRectangle(cornerRadius: 2).fill(stage.stage.color).frame(width: max(2, proxy.size.width * CGFloat(stage.durationSeconds / duration)), height: height(stage.stage, proxy.size.height)) } }
            }.frame(height: 88)
            HStack { ForEach(SleepStageType.allCases) { stage in Label(stage.rawValue, systemImage: "circle.fill").font(.caption2).foregroundStyle(stage.color) } }
        }.glassCard()
    }
    /// The vertical position a stage is drawn at. The **colour** mapping this view used to carry
    /// beside it is now `SleepStageType.color` in `Presentation/DesignSystem`, because the sleep
    /// detail screen's typical-range card draws the same four stages and a second switch would have
    /// been a second answer to which colour is Deep. This function stays: it is a drawing decision
    /// about *this* chart's lanes and no other screen has an opinion about it.
    private func height(_ stage: SleepStageType, _ total: CGFloat) -> CGFloat { switch stage { case .awake: total * 0.28; case .rem: total * 0.5; case .light: total * 0.72; case .deep: total } }
}
