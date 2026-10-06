import SwiftUI

public struct MainContainerView: View {
    private let container: DIContainer

    /// The device page's view model, built here and handed to Home's status badge.
    ///
    /// **It is a stored `let` and not a computed property, and that is a correctness requirement
    /// rather than a preference.** `MainContainerView.body` is a `ViewBuilder` and re-evaluates, so a
    /// computed one would build a fresh instance on every pass while `HomeDashboardView` holds it as a
    /// plain `let` — whose `.task` fires once and would never re-fire, leaving the badge blank and the
    /// device subscription attached to an object nothing draws. Building it in `init` is legal because
    /// `View` is `@MainActor`-isolated and this `init` already is — the `restoreFast()` call below is
    /// the proof, being a main-actor method that compiles here.
    ///
    /// **It had two routes and now has one**, since the user removed More's `Device` row. That is why
    /// it is stored rather than built at the destination: the two routes were two pages with two view
    /// models once, and they came to disagree about the same strap's battery. One page with one subject
    /// is the fix, and a `NavigationLink` closure is re-evaluated on every push, so a destination-side
    /// construction would still be a per-push instance.
    private let deviceViewModel: DeviceViewModel

    /// The profile page's view model, built here because Home's top bar is the page's only door.
    ///
    /// **It had a second door and that door is gone**, on the user's instruction: `MoreView`'s `List`
    /// no longer carries a `Profile` row. The view model is still built here rather than at the
    /// destination for the two reasons that survive that removal. `MainContainerView` is the only place
    /// a screen's view model is built, so constructing a `ProfileViewModel` inside the `NavigationLink`
    /// closure would put one construction outside the wiring point; and a destination closure is
    /// re-evaluated on every push, so the page would get a fresh instance per push and lose whatever it
    /// had loaded — the shape `deviceViewModel` is stored to avoid.
    ///
    /// It is a stored `let` rather than a computed property for `deviceViewModel`'s reason: `body` is a
    /// `ViewBuilder` and re-evaluates, so a computed one would be rebuilt on every pass.
    private let profileViewModel: ProfileViewModel

    /// The profile page's `LOGS` tab, built here and handed to Home and through it to the page.
    ///
    /// **It is a second view model rather than more state on `ProfileViewModel`**, because the two tabs
    /// are two subjects: `BIOMETRICS` is a form over `user_profiles`, and `LOGS` is four imports and an export
    /// over `AppPreferences` and the files on disk. One instance would give them one `status` string and
    /// one `isImporting` flag, so an import on `LOGS` could overwrite the sentence a save on `BIOMETRICS` had
    /// just written — which is why the move off Settings was a rename-with-shrink rather than a shared
    /// instance. See `LocalDataViewModel`'s own note.
    ///
    /// **It was `SettingsViewModel` and the type it is now is not the type `More → Settings` draws.**
    /// The four import/export methods moved here verbatim; what stayed behind is the Privacy toggle,
    /// which is the whole of that page now. So the app holds two instances of what used to be one type,
    /// and that is the deliberate part: `SettingsViewModel` is down to two dependencies and has no
    /// opinion about whoop history at all.
    ///
    /// Stored rather than computed, for `deviceViewModel`'s reason: `body` is a `ViewBuilder` and
    /// re-evaluates, so a computed property would be rebuilt on every pass.
    private let localDataViewModel: LocalDataViewModel

    /// The profile page's `STORAGE` tab, built here for `localDataViewModel`'s reason one pane over.
    ///
    /// **It is a third object rather than more state on either of the two above.** `BIOMETRICS` is a form
    /// over `user_profiles`, `LOGS` is five imports and an export over `AppPreferences` and the files on
    /// disk, and `STORAGE` is a boundary and a key over `SyncSettings` and the Keychain — three subjects
    /// with three `status` strings. Sharing one instance would let a failed upload rewrite the sentence a
    /// refused save had just written, under a pane that is no longer on screen.
    ///
    /// **It is built even on a build with no database behind it**, which is why `isCloudConfigured` is
    /// handed in rather than consulted here: the pane's whole content in that state is the sentence
    /// naming the missing `Info.plist` key, and a `nil` view model would make that state a special case
    /// at the destination instead of a value the pane reads. `UnconfiguredCloudSync` carries the same
    /// argument one layer down.
    ///
    /// Stored rather than computed, for `deviceViewModel`'s reason: `body` is a `ViewBuilder` and
    /// re-evaluates, so a computed property would be rebuilt on every pass — and this one would re-read
    /// the Keychain with it.
    private let syncViewModel: SyncStorageViewModel

    /// `More → Settings`, which is now the Privacy toggle and nothing else.
    ///
    /// **It is built here because `MoreView` stopped taking a container**, and that is a fix rather
    /// than a tidy-up: the row used to construct this inline in its `NavigationLink`'s destination
    /// closure, which is re-evaluated on every push, so the page got a fresh instance each time — the
    /// anti-pattern `MainContainerView`'s own comment on the deleted `Device` row names. Storing it
    /// here puts the construction back at the one wiring point, which is the rule.
    private let settingsViewModel: SettingsViewModel

    public init(container: DIContainer = .preview) {
        self.container = container
        // Two dependencies rather than one: the second is the `UNITS` preference, which is a
        // `UserDefaults` key rather than a `user_profiles` column and therefore arrives through a
        // different repository. See `ProfileViewModel.select(unit:)` for why the toggle writes there
        // while `SAVE` writes the profile row.
        self.profileViewModel = ProfileViewModel(
            repository: container.userProfileRepository,
            preferences: container.preferencesRepository)
        self.localDataViewModel = LocalDataViewModel(
            repository: container.preferencesRepository,
            healthKit: container.healthKitSync,
            whoopExport: container.whoopExportImport,
            fasting: container.fastingImport,
            inactivities: container.inactivityImport,
            exportUseCase: container.exportLocalDataUseCase)
        // One engine and a `Bool`, and the split between them is the pane's whole shape: the engine walks
        // all seven resources, so there is no per-resource object for this pane to hold — the selector
        // that chose between three use cases went with the three cutoffs that justified them. The `Bool`
        // is not a second object but a fact about this build — whether it was given a base URL at all —
        // and the container is the only thing that decides which `CloudSync` the engine got. See
        // `SyncStorageViewModel.isCloudConfigured`.
        self.syncViewModel = SyncStorageViewModel(
            engine: container.syncEngine,
            keyStore: container.syncKeyStore,
            isCloudConfigured: container.isCloudConfigured)
        self.settingsViewModel = SettingsViewModel(repository: container.preferencesRepository)
        self.deviceViewModel = DeviceViewModel(
            manage: container.manageBLEConnectionUseCase,
            sync: container.syncHistoricalDataUseCase,
            preferencesRepository: container.preferencesRepository,
            strapModels: container.strapModelRepository,
            protocols: container.protocolCatalog,
            biometrics: container.biometricRepository)
        // **The one live session that outlives the process is restored here**, in the initialiser
        // rather than in the `.task` below, because that task runs a frame late — and a frame with no
        // bar over a running fast is a lie about the state of the session. This is the earliest
        // main-actor moment the use case is reachable; see `restoreFast()` for why the use case cannot
        // do it for itself in its own `init`. Idempotent, so a re-created view is harmless, and it
        // cannot resurrect a fast the user has ended, since ending one clears the store.
        container.liveSessionUseCase.restoreFast()
    }
    public var body: some View {
        TabView {
            HomeDashboardView(
                viewModel: HomeViewModel(
                    recoveryRepository: container.recoveryRepository,
                    sleepRepository: container.sleepRepository,
                    strainRepository: container.strainRepository,
                    workoutRepository: container.workoutRepository,
                    receptiveInactivityRepository: container.receptiveInactivityRepository,
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
                // The one device view model, built in `init` above and shared with More → Device, so
                // pushing the page from either route reaches the same instance. See its declaration
                // for why it is stored rather than computed.
                deviceViewModel: deviceViewModel,
                // The one profile view model, built in `init` above and shared with More → Profile, so
                // the top bar's control and that row open one page with one subject. See its
                // declaration for why it is stored rather than constructed at either destination.
                profileViewModel: profileViewModel,
                // The profile page's second subject, handed down beside the first because they are
                // two tabbed panes of one pushed page. See its declaration for why they are two.
                localDataViewModel: localDataViewModel,
                // The profile page's third subject, handed down beside the other two because they are
                // three tabbed panes of one pushed page. See its declaration for why they are three.
                syncViewModel: syncViewModel,
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
                //
                // **The second parameter is the running fast, or `nil`.** A live fast has no stored row
                // to be handed, so Home projects one from the start instant it holds — and this closure
                // is where the two say the same thing: the page is *about* a session either way, and the
                // fast is the one thing that additionally knows it is still running. See
                // `ActivityDetailViewModel.liveFast` for why the projection cannot carry that itself.
                makeActivityDetailViewModel: { session, liveFast in
                    ActivityDetailViewModel(
                        session: session,
                        workoutRepository: container.workoutRepository,
                        userProfileRepository: container.userProfileRepository,
                        biometricRepository: container.biometricRepository,
                        recoveryRepository: container.recoveryRepository,
                        // The route card's map. `UnavailableOfflineMaps` unless the app target linked
                        // Mapbox — see `DIContainer.offlineMaps`, which carries the whole argument.
                        offlineMaps: container.offlineMaps,
                        liveFast: liveFast)
                }
            )
            .tabItem { Label("Home", systemImage: "house.fill") }
            // The Strain and Sleep tabs are gone, on the user's instruction. **Their pages went with
            // them and their view models did not**: `StrainViewModel` and `SleepViewModel` are still
            // built for the detail pages Home's own rings push, and the two `StrainDashboardView` /
            // `SleepDashboardView` files are deleted. Nothing either dashboard held was assertable —
            // both were a single `struct` whose rules lived in `private var`s — so the suite's
            // assertion count is unmoved by their removal, which is the one thing no renderer could
            // have told us.
            RecoveryDashboardView(
                viewModel: RecoveryViewModel(
                    calculate: container.calculateRecoveryUseCase,
                    repository: container.recoveryRepository,
                    sleepRepository: container.sleepRepository)
            ).tabItem { Label("Recovery", systemImage: "waveform.path.ecg") }
            MoreView(settingsViewModel: settingsViewModel)

            .tabItem { Label("More", systemImage: "ellipsis.circle") }
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

/// The `More` tab, which is one row and no longer needs the container.
///
/// **It took a `DIContainer` until this page's settings surface moved**, and the reason it no longer
/// does is worth keeping: its `Settings` row built a `SettingsViewModel` **inside the `NavigationLink`'s
/// destination closure**, which is the exact shape this file's own comment on the deleted `Device` row
/// calls out — a destination closure is re-evaluated on every push, so the page got a fresh view model
/// each time. There is now only one thing left to hand over, so the view model itself comes down as a
/// parameter, and the type that used to be constructed here is not constructed here at all.
private struct MoreView: View {
    let settingsViewModel: SettingsViewModel

    var body: some View {
        NavigationStack {
            List {
                // **This list held four rows and now holds one, on the user's instruction given a row
                // at a time: Profile, then Device, then one more.** Do not restore any of the three as a
                // convenience, and do not read their absence as an oversight:
                //
                // - **Profile** is reached from Home's day-bar row, and only from there now.
                // - **Device** is reached from Home's status badge, and only from there now — it was
                //   the row whose inline construction taught this file why a view model is passed to a
                //   destination rather than built inside its closure, and that lesson outlived the row.
                // - **The third** went with its page, and the page, its view model and the use case
                //   behind it are all deleted.
                //
                // The one rule this list still has to keep: `Settings` is here and nowhere else, so a
                // new row added above it needs its own door or it is a page nothing can reach.
                //
                // **What is behind it changed on the same instruction and the row did not.** The
                // imports and the export moved one tab deeper, onto the profile control at the other
                // end of Home's day bar, so this page is the Anonymous diagnostics toggle alone. The
                // row survives because the user kept it; do not read the shrunk page as the row
                // outliving its purpose, and do not move the toggle to the profile page to "finish"
                // the sweep — the LOGS tab is about data, and this is about the app.
                NavigationLink("Settings") {
                    SettingsDashboardView(viewModel: settingsViewModel)
                }
            }.navigationTitle("More")
        }.preferredColorScheme(.dark)
    }
}
