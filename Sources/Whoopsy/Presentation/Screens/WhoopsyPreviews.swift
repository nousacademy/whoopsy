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
                stepRepository: container.stepRepository,
                analyzeStress: container.analyzeStressUseCase,
                manage: container.manageBLEConnectionUseCase,
                streamUseCase: container.streamBiometricsUseCase
            ),
            recoveryViewModel: RecoveryViewModel(
                calculate: container.calculateRecoveryUseCase,
                repository: container.recoveryRepository,
                sleepRepository: container.sleepRepository
            ),
            sleepViewModel: SleepViewModel(
                analyze: container.analyzeSleepUseCase,
                repository: container.sleepRepository,
                napRepository: container.napRepository,
                biometricRepository: container.biometricRepository,
                analyzeSleepStress: container.analyzeSleepStressUseCase
            ),
            strainViewModel: StrainViewModel(
                calculate: container.calculateStrainUseCase,
                repository: container.strainRepository,
                workoutRepository: container.workoutRepository,
                stepRepository: container.stepRepository
            ),
            deviceDetailViewModel: DeviceDetailViewModel(
                manage: container.manageBLEConnectionUseCase,
                strapModels: container.strapModelRepository,
                protocols: container.protocolCatalog
            ),
            liveSessionUseCase: container.liveSessionUseCase,
            makeActivityDetailViewModel: { session in
                ActivityDetailViewModel(
                    session: session,
                    workoutRepository: container.workoutRepository,
                    userProfileRepository: container.userProfileRepository,
                    biometricRepository: container.biometricRepository)
            }
        )
        .preferredColorScheme(.dark)
    }
}

struct ActivityDetailView_Previews: PreviewProvider {
    static var previews: some View {
        let container = DIContainer.preview
        NavigationStack {
            ActivityDetailView(
                viewModel: ActivityDetailViewModel(
                    session: WorkoutSession(
                        startedAt: Date().addingTimeInterval(-958),
                        endedAt: Date(),
                        strain: 4.1,
                        averageHeartRate: 121,
                        maxHeartRate: 164,
                        route: [],
                        splits: [],
                        activityName: "Basketball",
                        hrZonePercents: [0, 0, 0, 0, 0]),
                    workoutRepository: container.workoutRepository,
                    userProfileRepository: container.userProfileRepository,
                    biometricRepository: container.biometricRepository))
        }
        .preferredColorScheme(.dark)
    }
}

struct LiveSessionView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            LiveSessionView(useCase: DIContainer.preview.liveSessionUseCase)
        }
        .preferredColorScheme(.dark)
    }
}

#endif
