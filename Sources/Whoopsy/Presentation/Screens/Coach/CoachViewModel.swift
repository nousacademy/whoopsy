import Foundation
import SwiftUI

@MainActor @Observable public final class CoachViewModel {
    public var insights: [CoachInsight] = []; public var isLoading = false
    private let generate: GenerateCoachInsightsUseCase; private let recovery: CalculateRecoveryUseCase; private let strain: CalculateStrainUseCase; private let sleep: AnalyzeSleepUseCase
    public init(generate: GenerateCoachInsightsUseCase, recovery: CalculateRecoveryUseCase, strain: CalculateStrainUseCase, sleep: AnalyzeSleepUseCase) { self.generate = generate; self.recovery = recovery; self.strain = strain; self.sleep = sleep }
    public func load() async { isLoading = true; defer { isLoading = false }; async let r = try? recovery.execute(); async let s = try? strain.execute(); async let sl = try? sleep.execute(); insights = generate.execute(recovery: await r, strain: await s, sleep: await sl) }
}
