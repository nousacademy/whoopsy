import Foundation
import SwiftUI

@MainActor @Observable public final class SleepViewModel {
    public var session: SleepSession?; public var isLoading = false; public var errorMessage: String?
    private let analyze: AnalyzeSleepUseCase; private let repository: any SleepRepository
    public init(analyze: AnalyzeSleepUseCase, repository: any SleepRepository) { self.analyze = analyze; self.repository = repository }

    /// Loads the night the screen is showing by reading it — see
    /// `RecoveryViewModel.load(for:)` for why the read is the point.
    ///
    /// This view model had no repository at all, so the screen could not display a stored night even
    /// in principle: it recomputed from raw samples on every appearance, and a day with no samples —
    /// every imported day — had nothing to show.
    ///
    /// `AnalyzeSleepUseCase` is the mildest of the three writers, and the guard below is still not
    /// optional. It returns `nil` *before* writing when the overnight window holds fewer than
    /// `minimumEpochSamples`, which is what keeps it harmless for an imported day; but it has no
    /// existing-row check, so given samples it would happily overwrite a session that is already
    /// stored. Reading first removes the question.
    public func load(for date: Date) async {
        isLoading = true
        defer { isLoading = false }
        do {
            var stored = try await repository.getSleepSession(for: date)
            if Calendar.current.isDateInToday(date), stored == nil {
                stored = try await analyze.execute(for: date)
            }
            session = stored
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
