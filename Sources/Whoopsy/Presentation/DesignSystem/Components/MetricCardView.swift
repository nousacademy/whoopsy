import SwiftUI

public struct MetricCardView: View {
    public let title: String
    public let value: String
    public let unit: String
    public let iconName: String
    public let accentColor: Color
    public var deltaText: String?

    public init(
        title: String,
        value: String,
        unit: String,
        iconName: String,
        accentColor: Color,
        deltaText: String? = nil
    ) {
        self.title = title
        self.value = value
        self.unit = unit
        self.iconName = iconName
        self.accentColor = accentColor
        self.deltaText = deltaText
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(accentColor)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.textSecondary)
                    .tracking(0.8)

                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.textPrimary)

                Text(unit)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.textMuted)
            }

            if let delta = deltaText {
                Text(delta)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(delta.contains("+") ? Theme.recoveryGreen : Theme.textSecondary)
            }
        }
        .glassCard(cornerRadius: 14, padding: 12)
    }
}
