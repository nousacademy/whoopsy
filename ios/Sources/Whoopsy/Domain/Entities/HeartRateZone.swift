import Foundation

/// Heart Rate Zones calculated using Heart Rate Reserve (Karvonen method).
public enum HeartRateZoneIndex: Int, CaseIterable, Identifiable, Sendable {
    case zone1 = 1 // 50-60% (Active Recovery)
    case zone2 = 2 // 60-70% (Aerobic / Base Building)
    case zone3 = 3 // 70-80% (Tempo / Threshold)
    case zone4 = 4 // 80-90% (Anaerobic Capacity)
    case zone5 = 5 // 90-100% (Maximal Effort)

    public var id: Int { rawValue }

    public var name: String {
        switch self {
        case .zone1: return "Active Recovery"
        case .zone2: return "Aerobic Base"
        case .zone3: return "Tempo / Threshold"
        case .zone4: return "Anaerobic"
        case .zone5: return "Max Effort"
        }
    }

    /// Non-linear Borg exponential multiplier used in Strain accumulation
    public var strainWeight: Double {
        switch self {
        case .zone1: return 1.0
        case .zone2: return 2.0
        case .zone3: return 4.5
        case .zone4: return 9.0
        case .zone5: return 16.0
        }
    }
}

public struct HeartRateZone: Identifiable, Equatable, Sendable {
    public let index: HeartRateZoneIndex
    public let lowerBpm: Int
    public let upperBpm: Int
    public let durationSeconds: TimeInterval

    public var id: Int { index.rawValue }

    public init(
        index: HeartRateZoneIndex,
        lowerBpm: Int,
        upperBpm: Int,
        durationSeconds: TimeInterval = 0
    ) {
        self.index = index
        self.lowerBpm = lowerBpm
        self.upperBpm = upperBpm
        self.durationSeconds = max(0, durationSeconds)
    }
}
