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

    /// The body weight the calorie estimate needs, or `nil` when the user has not supplied one.
    ///
    /// **Optional because it is the one profile field this app drew a figure from.** The others are
    /// either consumed by a model that has a defined answer without them (`targetSleepHours` is a
    /// baseline the sleep-need formula is written against, the heart rates are the inputs a Karvonen
    /// zone table cannot be built without) or read by nothing at all (`heightCm`, `name`, `birthDate`,
    /// the two `baseline*` fields). Weight was neither: `CalculateStrainUseCase` passed it to
    /// `StrainAccumulatorMath.estimateCalories`, so a default here became a calorie count on a screen.
    ///
    /// A defaulted `75.0` is therefore not a neutral starting point — it is a measurement this app
    /// would be inventing about the user's body and then reporting back to them. `nil` is the honest
    /// value, and it propagates: `estimateCalories` returns `nil`, and the session screen draws a dash
    /// where the figure would go. Supplied by the profile page, persisted in `user_profiles.weightKg`
    /// since `v16`.
    public let weightKg: Double?

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
        weightKg: Double? = nil,
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
