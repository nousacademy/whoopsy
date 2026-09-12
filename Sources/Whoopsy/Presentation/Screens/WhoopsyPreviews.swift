import SwiftUI

/// Xcode Canvas entry points. Every preview uses the hardware-free DI graph.
@MainActor
public enum WhoopsyPreviewSupport {
    public static func environment() -> AppEnvironment {
        AppEnvironment(container: .preview)
    }
}

#if DEBUG
struct WhoopsyAppView_Previews: PreviewProvider {
    static var previews: some View {
        WhoopsyAppView(environment: WhoopsyPreviewSupport.environment())
            .previewDevice("iPhone 16 Pro")
            .preferredColorScheme(.dark)
    }
}

struct HomeDashboardView_Previews: PreviewProvider {
    static var previews: some View {
        let container = DIContainer.preview
        HomeDashboardView(
            viewModel: HomeViewModel(
                recoveryRepository: container.recoveryRepository,
                sleepRepository: container.sleepRepository,
                strainRepository: container.strainRepository,
                workoutRepository: container.workoutRepository,
                userProfileRepository: container.userProfileRepository,
                healthKit: container.healthKitSync,
                analyzeStress: container.analyzeStressUseCase,
                manage: container.manageBLEConnectionUseCase,
                streamUseCase: container.streamBiometricsUseCase
            ),
            workoutViewModel: ActiveWorkoutViewModel(
                stream: container.streamBiometricsUseCase,
                save: container.saveWorkoutUseCase,
                location: container.locationTracking
            ),
            recoveryViewModel: RecoveryViewModel(
                calculate: container.calculateRecoveryUseCase,
                repository: container.recoveryRepository,
                sleepRepository: container.sleepRepository
            )
        )
        .preferredColorScheme(.dark)
    }
}

struct ActiveWorkoutHUDView_Previews: PreviewProvider {
    static var previews: some View {
        let container = DIContainer.preview
        ActiveWorkoutHUDView(
            viewModel: ActiveWorkoutViewModel(
                stream: container.streamBiometricsUseCase,
                save: container.saveWorkoutUseCase,
                location: container.locationTracking
            )
        )
        .previewDevice("iPhone 16 Pro")
        .preferredColorScheme(.dark)
    }
}
#endif
