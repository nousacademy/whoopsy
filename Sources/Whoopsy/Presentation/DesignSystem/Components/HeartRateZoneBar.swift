import SwiftUI

/// Visual representation of time distribution across the 5 Heart Rate Zones.
public struct HeartRateZoneBar: View {
    public let zones: [HeartRateZone]

    public init(zones: [HeartRateZone]) {
        self.zones = zones
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HEART RATE ZONES")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(Theme.textSecondary)
                .tracking(1.0)

            // Stacked Bar
            GeometryReader { geometry in
                let totalSeconds = max(1.0, zones.reduce(0.0) { $0 + $1.durationSeconds })
                HStack(spacing: 3) {
                    ForEach(zones) { zone in
                        let ratio = CGFloat(zone.durationSeconds / totalSeconds)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(colorForZone(zone.index))
                            .frame(width: max(2, geometry.size.width * ratio))
                    }
                }
            }
            .frame(height: 10)

            // Zone Rows
            VStack(spacing: 6) {
                ForEach(zones) { zone in
                    HStack {
                        Circle()
                            .fill(colorForZone(zone.index))
                            .frame(width: 8, height: 8)

                        Text("Zone \(zone.index.rawValue): \(zone.index.name)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Theme.textPrimary)

                        Text("(\(zone.lowerBpm)–\(zone.upperBpm) BPM)")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundColor(Theme.textMuted)

                        Spacer()

                        Text(zone.durationSeconds.formattedHoursMinutes())
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.textSecondary)
                    }
                }
            }
        }
        .glassCard(cornerRadius: 16, padding: 14)
    }

    /// Forwards to `HeartRateZoneIndex.color`, which is now the single zone-to-`Color` mapping.
    ///
    /// It was a `switch` in this file while this bar was the mapping's only reader. The live session
    /// screen's band row is the second, and a second `switch` is exactly the drift
    /// `SleepStageType.color` was extracted to prevent — so the mapping moved to
    /// `DesignSystem/HeartRateZoneIndex+Extensions.swift` and this is a forwarder rather than a copy.
    private func colorForZone(_ index: HeartRateZoneIndex) -> Color { index.color }
}
