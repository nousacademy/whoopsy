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
            deviceViewModel: DeviceViewModel(
                manage: container.manageBLEConnectionUseCase,
                sync: container.syncHistoricalDataUseCase,
                preferencesRepository: container.preferencesRepository,
                strapModels: container.strapModelRepository,
                protocols: container.protocolCatalog,
                biometrics: container.biometricRepository
            ),
            profileViewModel: ProfileViewModel(repository: container.userProfileRepository),
            liveSessionUseCase: container.liveSessionUseCase,
            makeActivityDetailViewModel: { session, liveFast in
                ActivityDetailViewModel(
                    session: session,
                    workoutRepository: container.workoutRepository,
                    userProfileRepository: container.userProfileRepository,
                    biometricRepository: container.biometricRepository,
                    recoveryRepository: container.recoveryRepository,
                    offlineMaps: container.offlineMaps,
                    liveFast: liveFast)
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
                    biometricRepository: container.biometricRepository,
                    recoveryRepository: container.recoveryRepository,
                    offlineMaps: container.offlineMaps),
                // A preview has no Home behind it to notify, so both callbacks are no-ops here. The real
                // call site is `HomeDashboardView`, which drops the row from `workouts` on a delete and
                // replaces it on a save. The edit sheet still opens and still writes — the page's own
                // view model owns that — so only the callback Home receives is stubbed.
                onDeleted: { _ in },
                onSaved: { _ in },
                // The fast-ending seam, stubbed for `onDeleted`'s own reason: a preview has no Home
                // behind it and no live use case, so there is nothing for `END FAST` to end. The real
                // call site is `HomeDashboardView`, which ends the fast through `LiveSessionUseCase`
                // and hands the row back to the day.
                onEndFast: {})
        }
        .preferredColorScheme(.dark)
    }
}

/// The one preview that draws a **composite** mark. `Fast` is the only name in `ActivityGlyph`'s
/// table whose `Drawing` holds two symbols, so it is the only place the header's `minWidth` and the
/// pair's own spacing can be looked at — and this file is the only renderer this repo has, since the
/// runner has no renderer and `drawnWidth` is a bound rather than a measurement.
///
/// **Two things to look at.** The `fork.knife` and the `timer` should read as one mark rather than as
/// two, which is what `compositeScale` and `compositeSpacingRatio` are for; and the title beside them
/// should not have moved for a *single*-symbol session, which is the `Basketball` preview above.
///
/// **The three figures are `nil`, and that is the whole point of this being a fast.** A fasting window
/// has no sensor behind it, so it has no strain and no heart rate to report — and since `v18` the type
/// can say so rather than being forced to write a `0`, which would read as *measured, and no strain at
/// all*. This preview is the app's only drawn example of that absence, and of the dash the activity page
/// prints for it.
///
/// Nothing on the page draws either heart rate today: the two readers are `ActivityEditDraft`'s
/// pass-through and `ActivityDetailViewModel`'s **profile** `maxHeartRate`, which builds the zone edges
/// — so this pair cannot move the picture. The strain *is* drawn, by `ACTIVITY STRAIN`.
struct ActivityDetailView_CompositeGlyph_Previews: PreviewProvider {
    static var previews: some View {
        let container = DIContainer.preview
        NavigationStack {
            ActivityDetailView(
                viewModel: ActivityDetailViewModel(
                    session: WorkoutSession(
                        startedAt: Date().addingTimeInterval(-57600),
                        endedAt: Date(),
                        strain: nil,
                        averageHeartRate: nil,
                        maxHeartRate: nil,
                        route: [],
                        splits: [],
                        activityName: WhoopActivityCatalog.fastingName,
                        hrZonePercents: nil),
                    workoutRepository: container.workoutRepository,
                    userProfileRepository: container.userProfileRepository,
                    biometricRepository: container.biometricRepository,
                    recoveryRepository: container.recoveryRepository,
                    offlineMaps: container.offlineMaps),
                onDeleted: { _ in },
                onSaved: { _ in },
                // The fast-ending seam, stubbed for `onDeleted`'s own reason: a preview has no Home
                // behind it and no live use case, so there is nothing for `END FAST` to end. The real
                // call site is `HomeDashboardView`, which ends the fast through `LiveSessionUseCase`
                // and hands the row back to the day.
                onEndFast: {})
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
