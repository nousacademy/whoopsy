import SwiftUI

public struct MainContainerView: View {
    private let container: DIContainer
    public init(container: DIContainer = .preview) { self.container = container }
    public var body: some View {
        TabView {
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
                    streamUseCase: container.streamBiometricsUseCase),
                recoveryViewModel: RecoveryViewModel(
                    calculate: container.calculateRecoveryUseCase,
                    repository: container.recoveryRepository,
                    sleepRepository: container.sleepRepository),
                // A second `SleepViewModel` beside the Sleep tab's below, and for the same reason
                // Home's `recoveryViewModel` is a second one beside the Recovery tab's: they are two
                // screens with two days, and sharing one would make the pushed copy move the tab's
                // night underneath it.
                sleepViewModel: SleepViewModel(
                    analyze: container.analyzeSleepUseCase,
                    repository: container.sleepRepository,
                    napRepository: container.napRepository,
                    biometricRepository: container.biometricRepository,
                    analyzeSleepStress: container.analyzeSleepStressUseCase),
                // A third second-instance view model, on the same reasoning as the two above: Home's
                // strain ring pushes a copy seeded with the day on screen, and the Strain tab's own
                // `StrainViewModel` below keeps a private day it would otherwise share.
                strainViewModel: StrainViewModel(
                    calculate: container.calculateStrainUseCase,
                    repository: container.strainRepository,
                    workoutRepository: container.workoutRepository,
                    stepRepository: container.stepRepository),
                // Built here rather than inside the badge's `NavigationLink` destination: that
                // closure is re-evaluated on each push, so a view model constructed in it would be a
                // fresh one every time — losing the device subscription each push and starting
                // another.
                deviceDetailViewModel: DeviceDetailViewModel(
                    manage: container.manageBLEConnectionUseCase,
                    strapModels: container.strapModelRepository,
                    protocols: container.protocolCatalog),
                // The app's one live session, handed down rather than built here: it has to outlive
                // every screen that draws it, so it is the container's and this passes the reference
                // through. See `LiveSessionUseCase`.
                liveSessionUseCase: container.liveSessionUseCase,
                // The activity detail page's view model, built here and handed over as a factory
                // rather than as an instance.
                //
                // **This is the one screen whose subject is not the day Home is showing.** The three
                // rings push a page about `selectedDate`, so one view model built up front serves every
                // push; an activity row's subject is the row, and which row is not known until it is
                // tapped. Building it here keeps `MainContainerView` the only place a view model is
                // constructed — the closure closes over `container` and nothing else, and the screen
                // supplies the session.
                makeActivityDetailViewModel: { session in
                    ActivityDetailViewModel(
                        session: session,
                        workoutRepository: container.workoutRepository,
                        userProfileRepository: container.userProfileRepository,
                        biometricRepository: container.biometricRepository)
                }
            )
            .tabItem { Label("Home", systemImage: "house.fill") }
            StrainDashboardView(
                viewModel: StrainViewModel(
                    calculate: container.calculateStrainUseCase,
                    repository: container.strainRepository,
                    workoutRepository: container.workoutRepository,
                    stepRepository: container.stepRepository)
            ).tabItem { Label("Strain", systemImage: "flame.fill") }
            SleepDashboardView(
                viewModel: SleepViewModel(
                    analyze: container.analyzeSleepUseCase,
                    repository: container.sleepRepository,
                    napRepository: container.napRepository,
                    biometricRepository: container.biometricRepository,
                    analyzeSleepStress: container.analyzeSleepStressUseCase)
            ).tabItem { Label("Sleep", systemImage: "moon.fill") }
            RecoveryDashboardView(
                viewModel: RecoveryViewModel(
                    calculate: container.calculateRecoveryUseCase,
                    repository: container.recoveryRepository,
                    sleepRepository: container.sleepRepository)
            ).tabItem { Label("Recovery", systemImage: "waveform.path.ecg") }
            MoreView(container: container).tabItem { Label("More", systemImage: "ellipsis.circle") }
        }.tint(Theme.livePulseCyan).preferredColorScheme(.dark)
        // The strap's step counter, started once for the life of the app.
        //
        // **Here and nowhere else.** `TrackStepsUseCase` consumes a multicast stream, so a
        // subscription opened per screen — or worse, per day-step tap inside `HomeViewModel.load` —
        // would either orphan the previous consumer or accumulate one per call, and the failure is
        // silent: a `for await` that stops receiving looks exactly like a strap that went quiet. This
        // is the root view, so its `.task` lives as long as the process does, and the use case's own
        // `isRunning` guard makes a second call a no-op rather than a second consumer.
        //
        // It writes nothing until a motion batch arrives, and no motion batch arrives on any build
        // without a strap — so on every machine here this task attaches a consumer to an empty stream
        // and idles. See `WhoopBLEDeviceRepository.motionStream`.
        //
        // The orphan sweep runs **first**, and it has to run somewhere: a Live Activity outlives the
        // process that requested it, so an app killed mid-session leaves a lock-screen card counting up
        // from a start instant nothing is recording. This build has no BLE state restoration and no
        // in-flight persistence, so a relaunch cannot adopt one — it can only end it. Ordered ahead of
        // the step counter because that call never returns.
        .task {
            await container.liveSessionUseCase.endOrphanedLiveActivities()
            await container.trackStepsUseCase.start()
        }
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
                NavigationLink("Profile") {
                    ProfileDashboardView(
                        viewModel: ProfileViewModel(repository: container.userProfileRepository))
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
