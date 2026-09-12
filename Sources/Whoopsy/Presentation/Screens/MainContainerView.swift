import SwiftUI

public struct MainContainerView: View {
    private let container: DIContainer
    public init(container: DIContainer = .preview) { self.container = container }
    public var body: some View {
        // One instance for both Home's "+" and the Workout tab, so the two are views of a single live
        // session rather than two that could each believe they were recording.
        let workoutViewModel = ActiveWorkoutViewModel(
            stream: container.streamBiometricsUseCase, save: container.saveWorkoutUseCase,
            location: container.locationTracking)

        TabView {
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
                    streamUseCase: container.streamBiometricsUseCase),
                workoutViewModel: workoutViewModel,
                recoveryViewModel: RecoveryViewModel(
                    calculate: container.calculateRecoveryUseCase,
                    repository: container.recoveryRepository,
                    sleepRepository: container.sleepRepository)
            )
            .tabItem { Label("Home", systemImage: "house.fill") }
            StrainDashboardView(
                viewModel: StrainViewModel(
                    calculate: container.calculateStrainUseCase,
                    repository: container.strainRepository)
            ).tabItem { Label("Strain", systemImage: "flame.fill") }
            ActiveWorkoutHUDView(viewModel: workoutViewModel)
                .tabItem { Label("Workout", systemImage: "figure.run") }
            SleepDashboardView(
                viewModel: SleepViewModel(
                    analyze: container.analyzeSleepUseCase,
                    repository: container.sleepRepository)
            ).tabItem { Label("Sleep", systemImage: "moon.fill") }
            RecoveryDashboardView(
                viewModel: RecoveryViewModel(
                    calculate: container.calculateRecoveryUseCase,
                    repository: container.recoveryRepository,
                    sleepRepository: container.sleepRepository)
            ).tabItem { Label("Recovery", systemImage: "waveform.path.ecg") }
            MoreView(container: container).tabItem { Label("More", systemImage: "ellipsis.circle") }
        }.tint(Theme.livePulseCyan).preferredColorScheme(.dark)
    }
}

private struct MoreView: View {
    let container: DIContainer
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Coach") {
                    CoachDashboardView(
                        viewModel: CoachViewModel(
                            generate: container.generateCoachInsightsUseCase,
                            recovery: container.calculateRecoveryUseCase,
                            strain: container.calculateStrainUseCase,
                            sleep: container.analyzeSleepUseCase))
                }
                NavigationLink("Device") {
                    DeviceSettingsView(
                        viewModel: DeviceViewModel(
                            manage: container.manageBLEConnectionUseCase,
                            sync: container.syncHistoricalDataUseCase,
                            preferencesRepository: container.preferencesRepository))
                }
                NavigationLink("Settings") {
                    SettingsDashboardView(
                        viewModel: SettingsViewModel(
                            repository: container.preferencesRepository,
                            healthKit: container.healthKitSync,
                            whoopExport: container.whoopExportImport,
                            exportUseCase: container.exportLocalDataUseCase))
                }
            }.navigationTitle("More")
        }.preferredColorScheme(.dark)
    }
}
