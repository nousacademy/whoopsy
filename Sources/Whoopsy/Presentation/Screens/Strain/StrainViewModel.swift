import Foundation
import SwiftUI

@MainActor @Observable public final class StrainViewModel {
    public var strain: StrainScore?; public var target = 12.0; public var isLoading = false; public var errorMessage: String?
    private let calculate: CalculateStrainUseCase; private let repository: any StrainRepository
    public init(calculate: CalculateStrainUseCase, repository: any StrainRepository) { self.calculate = calculate; self.repository = repository }

    /// Loads the day the screen is showing by reading it — see
    /// `RecoveryViewModel.load(for:)` for why the read is the point.
    ///
    /// `repository` was already a stored property here and was never called, so this screen could not
    /// display a stored strain at all.
    ///
    /// The recompute test is the **measurement**, not the row, which is what
    /// `RecoveryViewModel.shouldCompute` has always tested — the two tabs used to disagree.
    /// `CalculateStrainUseCase` no longer writes a row for a day it could not measure, so a test on
    /// `nil` would now mostly agree by accident; what it still gets wrong is a placeholder row left on
    /// disk by an older build, which reads as a settled day and never recomputes, pinning the tab to
    /// "No data" for the rest of the day even once samples arrive.
    public func load(for date: Date) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var stored = try await repository.getStrain(for: date)
            if Calendar.current.isDateInToday(date), stored?.hasMeasurement != true {
                stored = try await calculate.execute(for: date)
            }
            strain = stored
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
