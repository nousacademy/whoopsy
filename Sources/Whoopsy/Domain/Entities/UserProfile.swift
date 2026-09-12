import Foundation

/// User physiological profile for baseline calibration.
public struct UserProfile: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let birthDate: Date
    public let maxHeartRate: Int
    public let restingHeartRate: Int
    public let baselineHrvRmssd: Double
    public let baselineRhr: Double
    public let targetSleepHours: Double
    public let weightKg: Double
    public let heightCm: Double

    public init(
        id: UUID = UUID(),
        name: String = "Athlete",
        birthDate: Date = Calendar.current.date(byAdding: .year, value: -28, to: Date()) ?? Date(),
        maxHeartRate: Int = 195,
        restingHeartRate: Int = 54,
        baselineHrvRmssd: Double = 65.0,
        baselineRhr: Double = 54.0,
        targetSleepHours: Double = 8.0,
        weightKg: Double = 75.0,
        heightCm: Double = 178.0
    ) {
        self.id = id
        self.name = name
        self.birthDate = birthDate
        self.maxHeartRate = maxHeartRate
        self.restingHeartRate = restingHeartRate
        self.baselineHrvRmssd = baselineHrvRmssd
        self.baselineRhr = baselineRhr
        self.targetSleepHours = targetSleepHours
        self.weightKg = weightKg
        self.heightCm = heightCm
    }

    public var age: Int {
        let years = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 28
        return max(14, years)
    }

    /// Default calculated Max HR if uncalibrated (Gellish formula: 207 - 0.7 * age)
    public static func estimatedMaxHeartRate(age: Int) -> Int {
        Int((207.0 - (0.7 * Double(age))).rounded())
    }

    public static let `default` = UserProfile()
}
