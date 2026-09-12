import SwiftUI

/// Real-time animated sparkline wave visualizing live heart rate telemetry.
public struct LiveHRWaveformView: View {
    public let heartRateHistory: [Int]
    public let currentBPM: Int
    public let isOnBody: Bool

    public init(heartRateHistory: [Int], currentBPM: Int, isOnBody: Bool = true) {
        self.heartRateHistory = heartRateHistory
        self.currentBPM = currentBPM
        self.isOnBody = isOnBody
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isOnBody ? Theme.livePulseCyan : Theme.textMuted)
                        .frame(width: 8, height: 8)
                        .shadow(color: isOnBody ? Theme.livePulseCyan.opacity(0.8) : Color.clear, radius: 4)

                    Text(isOnBody ? "LIVE TELEMETRY" : "STRAP OFF BODY")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(isOnBody ? Theme.livePulseCyan : Theme.textMuted)
                        .tracking(1.0)
                }

                Spacer()

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(currentBPM)")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .foregroundColor(Theme.textPrimary)

                    Text("BPM")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.livePulseCyan)
                }
            }

            // Real-time sparkline graph
            GeometryReader { geometry in
                let points = normalizedPoints(in: geometry.size)
                Path { path in
                    guard points.count > 1 else { return }
                    path.move(to: points[0])
                    for i in 1..<points.count {
                        path.addLine(to: points[i])
                    }
                }
                .stroke(
                    LinearGradient(
                        gradient: Gradient(colors: [Theme.livePulseCyan.opacity(0.3), Theme.livePulseCyan]),
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: Theme.livePulseCyan.opacity(0.5), radius: 4, x: 0, y: 0)
            }
            .frame(height: 54)
        }
        .glassCard(cornerRadius: 16, padding: 14)
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard !heartRateHistory.isEmpty else { return [] }
        let minHR = Double(heartRateHistory.min() ?? 50) - 5.0
        let maxHR = Double(heartRateHistory.max() ?? 100) + 5.0
        let range = max(10.0, maxHR - minHR)

        let stepX = size.width / CGFloat(max(1, heartRateHistory.count - 1))

        return heartRateHistory.enumerated().map { index, bpm in
            let normalizedY = 1.0 - CGFloat((Double(bpm) - minHR) / range)
            let clampedY = max(0.05, min(0.95, normalizedY))
            return CGPoint(x: CGFloat(index) * stepX, y: clampedY * size.height)
        }
    }
}
