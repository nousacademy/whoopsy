import SwiftUI

public struct HypnogramChartView: View {
    public let stages: [SleepStageSegment]
    public init(stages: [SleepStageSegment]) { self.stages = stages }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Sleep stages")
            GeometryReader { proxy in
                let duration = max(stages.reduce(0) { $0 + $1.durationSeconds }, 1)
                HStack(alignment: .bottom, spacing: 2) { ForEach(stages) { stage in RoundedRectangle(cornerRadius: 2).fill(color(stage.stage)).frame(width: max(2, proxy.size.width * CGFloat(stage.durationSeconds / duration)), height: height(stage.stage, proxy.size.height)) } }
            }.frame(height: 88)
            HStack { ForEach(SleepStageType.allCases) { stage in Label(stage.rawValue, systemImage: "circle.fill").font(.caption2).foregroundStyle(color(stage)) } }
        }.glassCard()
    }
    private func height(_ stage: SleepStageType, _ total: CGFloat) -> CGFloat { switch stage { case .awake: total * 0.28; case .rem: total * 0.5; case .light: total * 0.72; case .deep: total } }
    private func color(_ stage: SleepStageType) -> Color { switch stage { case .awake: Theme.sleepAwake; case .light: Theme.sleepLight; case .deep: Theme.sleepDeep; case .rem: Theme.sleepRem } }
}
