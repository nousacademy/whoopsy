import Foundation

public final class SaveWorkoutUseCase: Sendable {
    private let repository: any WorkoutRepository
    public init(repository: any WorkoutRepository) { self.repository = repository }
    public func execute(_ workout: WorkoutSession) async throws { try await repository.save(workout) }
}

public final class GenerateCoachInsightsUseCase: Sendable {
    public init() {}
    public func execute(recovery: RecoveryMetric?, strain: StrainScore?, sleep: SleepSession?) -> [CoachInsight] {
        let recoveryScore = recovery?.score ?? 0
        let strainScore = strain?.score ?? 0
        let sleepScore = sleep?.sleepPerformancePercentage ?? 0
        // Through the tier, not a `>= 67` of its own — see `RecoveryState.init(score:)`.
        let recoveryMessage = RecoveryMetric.RecoveryState(score: recoveryScore) == .green
            ? "You are primed. A challenging session is well supported today."
            : "Keep intensity flexible and prioritize recovery signals today."
        let activityMessage = strainScore < 8 ? "Build your day with a purposeful movement block." : "You have accumulated meaningful cardiovascular load."
        let sleepMessage = sleepScore >= 85 ? "Sleep need was largely met last night." : "An earlier wind-down can help reduce your sleep debt."
        return [CoachInsight(title: "Recovery review", message: recoveryMessage, tone: .recovery), CoachInsight(title: "Strain guidance", message: activityMessage, tone: .activity), CoachInsight(title: "Sleep coaching", message: sleepMessage, tone: .sleep)]
    }
}
