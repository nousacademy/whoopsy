import Foundation

/// Dependency Injection Container managing lifecycle and resolving dependencies across Clean Architecture layers.
public final class DIContainer: @unchecked Sendable {
    public static let shared = DIContainer(useMockBLE: false)
    public static let preview = DIContainer(useMockBLE: true)

    // Repositories
    public let bleRepository: any WhoopBLEDeviceRepository
    public let biometricRepository: any BiometricRepository
    public let recoveryRepository: any RecoveryRepository
    public let strainRepository: any StrainRepository
    public let sleepRepository: any SleepRepository
    public let napRepository: any NapRepository
    public let userProfileRepository: any UserProfileRepository
    public let workoutRepository: any WorkoutRepository
    public let stepRepository: any StepRepository

    // Use Cases
    public let streamBiometricsUseCase: StreamBiometricsUseCase
    public let calculateRecoveryUseCase: CalculateRecoveryUseCase
    public let calculateStrainUseCase: CalculateStrainUseCase
    public let analyzeSleepUseCase: AnalyzeSleepUseCase
    public let analyzeStressUseCase: AnalyzeStressUseCase
    public let analyzeSleepStressUseCase: AnalyzeSleepStressUseCase
    public let manageBLEConnectionUseCase: ManageBLEConnectionUseCase
    public let syncHistoricalDataUseCase: SyncHistoricalDataUseCase
    public let exportLocalDataUseCase: ExportLocalDataUseCase
    public let saveWorkoutUseCase: SaveWorkoutUseCase
    public let generateCoachInsightsUseCase: GenerateCoachInsightsUseCase
    /// The strap's step counter. **Long-running rather than call-and-return** — see
    /// `TrackStepsUseCase` — so it is started once from `MainContainerView`'s app-level task and not
    /// from any screen's load.
    public let trackStepsUseCase: TrackStepsUseCase
    public let preferencesRepository: any AppPreferencesRepository
    public let healthKitSync: any HealthKitSyncing
    public let whoopExportImport: any WhoopExportImporting
    /// The Zero fasting tracker's history, as a fourth input. Its own slot rather than a second method
    /// on `whoopExportImport` — different file, different format, different idempotence rule, and its
    /// rows are the first ones in this app with no measurement behind them. See `FastingImporting`.
    public let fastingImport: any FastingImporting
    /// Which model the user has said each strap is. Read by the BLE layer to resolve a generation and
    /// written by the device screen.
    public let strapModelRepository: any StrapModelRepository
    /// Which generations this build can actually frame for. Presentation depends on this rather than
    /// on `Data/BLE` so the device screen can say plainly that a 5.0 has no implementation behind it.
    public let protocolCatalog: any WhoopProtocolProviding
    @MainActor public let locationTracking: any LocationTracking

    /// The lock-screen card's transport, and **a stored `let` rather than a computed property like
    /// `locationTracking` used to be**.
    ///
    /// That difference is load-bearing. A computed property builds a fresh service per read, and both
    /// of these hold state a second instance cannot reach: `LiveActivityController` holds the `Activity`
    /// handle, so a second instance would have no way to update the card the first one started — the
    /// card would be requested once and then stranded on the lock screen, counting up, until the system
    /// expired it. `CoreLocationTrackingService` holds the `CLLocationManager` it called
    /// `startUpdatingLocation` on, so a second instance's `stop()` would stop a manager that never
    /// started while the first kept the GPS awake for the life of the process. The comment that used to
    /// sit here called the computed shape harmless because "a `CLLocationManager` holds no state this app
    /// reads back" — true about *state*, wrong about *lifecycle*, which is the pair that matters for a
    /// resource that has to be released.
    @MainActor public let liveActivityController: any LiveActivityControlling

    /// The offline map, for the route card at the foot of the activity detail page.
    ///
    /// **Injected rather than built here, and this is the one service in this container where that is
    /// true.** Every other capability is constructed in `init` because the package can name its type.
    /// This one it cannot: the implementation is Mapbox, which cannot be a dependency of `Package.swift`
    /// at all — it is an iOS-only binary artifact and this manifest also declares `.macOS(.v14)` for the
    /// host executable and the test runner. So the SDK lives outside the package in `App/Map/`, and
    /// `WhoopsyApp.init` is the only place in the app that can see it. See `OfflineMapServing` for the
    /// whole of that argument.
    ///
    /// **The default is `UnavailableOfflineMaps`, and it is not a stub.** That type draws the same
    /// `MapKit` card this page drew before the feature existed, so the host build, the runner, a preview
    /// and any iOS build whose package failed to resolve all behave exactly as they did — a card that
    /// needs a network, never a blank one.
    ///
    /// Stored as a `let` for `liveActivityController`'s reason rather than `locationTracking`'s former
    /// one: a computed property would build a fresh tile-store client per read, and the instance that
    /// started a download has to be the one that can report on it.
    ///
    /// **Typed as the drawing half**, so the one instance serves both callers: `LiveSessionUseCase`
    /// takes it as `any OfflineMapServing` — the control surface, all `Domain` may see — and
    /// `ActivityDetailViewModel` takes the same object as `any OfflineMapRendering`, which is what can
    /// draw. One object, two views of it, and no second instance that could disagree about which tiles
    /// are on disk.
    ///
    /// **It is injected into the view model, not read out of the environment.** An earlier version put
    /// an `\.offlineMapService` environment value on this type as a second route to the same object;
    /// that was removed, because a page that can be reached with the value absent and the object
    /// present gives one screen two answers about whether the offline card is available.
    @MainActor public let offlineMaps: any OfflineMapRendering

    /// The live session — **the app's only recording path**, and the reason it is held here rather than
    /// by a screen.
    ///
    /// The user's requirement is that backing out of the session screen leaves it recording, so this
    /// has to outlive any view. `MainContainerView` hands the one instance to `HomeDashboardView`, which
    /// is `@MainActor` and lasts as long as the process does.
    @MainActor public let liveSessionUseCase: LiveSessionUseCase

    private let useMockBLE: Bool

    /// - Parameter offlineMaps: the offline map implementation, defaulting to the one that is honest
    ///   for a build with no map SDK behind it. `WhoopsyApp` passes the real one on the branch where
    ///   Mapbox was linked; see `offlineMaps` above for why it cannot be constructed here.
    public init(
        useMockBLE: Bool = true,
        offlineMaps: any OfflineMapRendering = UnavailableOfflineMaps()
    ) {
        self.useMockBLE = useMockBLE
        let db = LocalDatabaseManager.shared
        // Built before the BLE repository, which is handed it: the manager resolves a strap's
        // generation from these choices, so the store has to exist first.
        let strapModels = UserDefaultsStrapModelRepository()
        self.strapModelRepository = strapModels
        self.protocolCatalog = WhoopProtocolCatalog()
        self.bleRepository = WhoopBLEDeviceRepositoryImpl(
            useMock: useMockBLE, strapModelRepository: strapModels)
        self.biometricRepository = GRDBBiometricRepository(db: db)
        self.recoveryRepository = GRDBRecoveryRepository(db: db)
        self.strainRepository = GRDBStrainRepository(db: db)
        self.sleepRepository = GRDBSleepRepository(db: db)
        self.napRepository = GRDBNapRepository(db: db)
        self.userProfileRepository = GRDBUserProfileRepository(db: db)
        self.workoutRepository = GRDBWorkoutRepository(db: db)
        self.stepRepository = GRDBStepRepository(db: db)

        self.streamBiometricsUseCase = StreamBiometricsUseCase(
            bleRepository: bleRepository,
            biometricRepository: biometricRepository
        )

        self.calculateRecoveryUseCase = CalculateRecoveryUseCase(
            biometricRepository: biometricRepository,
            recoveryRepository: recoveryRepository,
            sleepRepository: sleepRepository,
            userProfileRepository: userProfileRepository
        )

        self.calculateStrainUseCase = CalculateStrainUseCase(
            biometricRepository: biometricRepository,
            strainRepository: strainRepository,
            userProfileRepository: userProfileRepository
        )

        self.analyzeSleepUseCase = AnalyzeSleepUseCase(
            biometricRepository: biometricRepository,
            sleepRepository: sleepRepository,
            // The night's Sleep Need is a function of the previous day's Strain — see `SleepNeedMath`.
            strainRepository: strainRepository,
            userProfileRepository: userProfileRepository
        )

        // Derived on read, like the other no-schema metrics: nothing here writes, so pointing it at
        // any day is safe — which is what distinguishes it from the calculate use cases.
        self.analyzeStressUseCase = AnalyzeStressUseCase(
            biometricRepository: biometricRepository
        )

        // The same no-schema bargain one line up, pointed at the window that model throws away. It
        // reads `biometric_samples` and writes nothing, so like `analyzeStressUseCase` it is safe on
        // any night — including every imported one, where it returns `nil` because the export carries
        // no R-R series at all. `SleepRepository` is deliberately absent: the page's night set is
        // handed in, so this use case cannot select a different history from the cards above it.
        self.analyzeSleepStressUseCase = AnalyzeSleepStressUseCase(
            biometricRepository: biometricRepository
        )

        self.manageBLEConnectionUseCase = ManageBLEConnectionUseCase(
            bleRepository: bleRepository
        )

        self.syncHistoricalDataUseCase = SyncHistoricalDataUseCase(
            bleRepository: bleRepository,
            biometricRepository: biometricRepository
        )

        self.exportLocalDataUseCase = ExportLocalDataUseCase(
            biometricRepository: biometricRepository,
            recoveryRepository: recoveryRepository,
            strainRepository: strainRepository,
            sleepRepository: sleepRepository
        )
        // Was `LocalWorkoutRepository()`, an in-memory array — a recorded workout did not survive the
        // launch that recorded it. Same store as everything else now, so the ACTIVITIES card can list
        // a day's sessions back.
        self.saveWorkoutUseCase = SaveWorkoutUseCase(repository: workoutRepository)
        self.generateCoachInsightsUseCase = GenerateCoachInsightsUseCase()
        self.trackStepsUseCase = TrackStepsUseCase(
            bleRepository: bleRepository,
            stepRepository: stepRepository
        )
        self.preferencesRepository = UserDefaultsAppPreferencesRepository()
        // The same repositories the strap path writes through, so an import and a strap run land in
        // one table under one day key rather than two stores that can disagree.
        self.healthKitSync = HealthKitBridge(
            store: useMockBLE
                ? HealthStoreClientFactory.makePreview() : HealthStoreClientFactory.make(),
            recoveryRepository: recoveryRepository,
            sleepRepository: sleepRepository,
            userProfileRepository: userProfileRepository)
        // The one place the two halves of the live session meet. It reads the same
        // `StreamBiometricsUseCase` `HomeViewModel` does — the BLE streams are multicast, so a second
        // consumer is an addition and not a theft, and the first one is never orphaned.
        self.liveActivityController = LiveActivityController()
        // Whatever the app target could build. Assigned here rather than at the property declaration
        // because `liveSessionUseCase` below takes it, and a session that started a download has to
        // hold the same instance the detail page later reads the region's state from.
        self.offlineMaps = offlineMaps
        // Built here rather than per read, so the instance that starts the GPS is the one that stops
        // it — see the note on `locationTracking` above.
        self.locationTracking = useMockBLE
            ? PreviewLocationTrackingService() : CoreLocationTrackingService()
        self.liveSessionUseCase = LiveSessionUseCase(
            controller: liveActivityController,
            locationTracking: locationTracking,
            streamBiometricsUseCase: streamBiometricsUseCase,
            saveWorkoutUseCase: saveWorkoutUseCase,
            userProfileRepository: userProfileRepository,
            // The session's own step reader. `TrackStepsUseCase` above is registered on the same
            // multicast `motionStream`, and both must hold it — see `LiveSessionUseCase`.
            bleRepository: bleRepository,
            // Where a running fast is kept across a relaunch. **Required rather than defaulted**, so a
            // production path cannot quietly ship without one and lose the user's fast at the next
            // launch — the failure would be a fast that silently vanished, which is worse than a
            // compile error. `UserDefaults` for the reason `UserDefaultsStrapModelRepository` records:
            // a shipped migration is frozen and a failing one `fatalError`s at launch, and one start
            // instant is not worth a schema version.
            activeFastRepository: UserDefaultsActiveFastRepository(),
            // The offline map switch on the session screen. **Required rather than defaulted**, so a
            // path that builds a session without one cannot quietly ship a switch that does nothing —
            // the same argument `activeFastRepository` above records. Passed as the control half: the
            // use case has no use for `map(route:unit:regionID:)`, which returns a `SwiftUI` view.
            offlineMaps: offlineMaps
        )
        self.whoopExportImport = WhoopExportImporter(
            recoveryRepository: recoveryRepository,
            sleepRepository: sleepRepository,
            strainRepository: strainRepository,
            napRepository: napRepository,
            workoutRepository: workoutRepository,
            userProfileRepository: userProfileRepository)
        self.fastingImport = ZeroFastingImporter(workoutRepository: workoutRepository)
    }
}