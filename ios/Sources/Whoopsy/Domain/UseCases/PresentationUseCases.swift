import Foundation

public final class SaveWorkoutUseCase: Sendable {
    private let repository: any WorkoutRepository
    public init(repository: any WorkoutRepository) { self.repository = repository }
    public func execute(_ workout: WorkoutSession) async throws { try await repository.save(workout) }
}

/// **Unrendered: its only reader was `CoachDashboardView`, which the user deleted.**
///
/// Kept rather than deleted for the reason this repo keeps unrendered things — but note the reason
/// does *not* fully apply here, and the difference is worth stating. `ActivityDurationBar` and
/// `batteryText(for:)` are kept because the runner holds assertions about them and this suite has no
/// test discovery, so deleting one drops passing assertions with a falling `assertions=` count as the
/// only trace. **The runner asserts nothing about this type or about `CoachInsight`** — verified by
/// `grep -rc Coach Tests/WhoopsyTestRunner/` returning `0` — so it could be deleted with no
/// loss. It survives because removing Domain machinery is a wider change than the one the user asked
/// for (*"remove 'coach' link from 'more' and associated page"* names a link and a page), and because
/// `RecoveryMetric`'s own doc comment still cites this type by name as the incident that produced the
/// one-definition rule for the recovery tiers.
///
/// **Nothing constructs it but `DIContainer`, so this is dead code and should be read as such.** If a
/// later change wants the Coach feature back, this and `CoachInsight` are the whole of its logic; if it
/// does not, deleting both plus the container's `let` is a clean removal.
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
