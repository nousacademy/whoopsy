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
    public let receptiveInactivityRepository: any ReceptiveInactivityRepository
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
    /// The owner's own notes, as a fifth input. Its own slot again, and this one is separated by the
    /// *table* rather than by the file: it is the only import in the app that writes
    /// `receptive_inactivities`, whose rows have no span, no strain and no measurement of any kind.
    /// See `InactivityImporting`.
    public let inactivityImport: any InactivityImporting
    /// Which model the user has said each strap is. Read by the BLE layer to resolve a generation and
    /// written by the device screen.
    public let strapModelRepository: any StrapModelRepository
    /// Which generations this build can actually frame for. Presentation depends on this rather than
    /// on `Data/BLE` so the device screen can say plainly that a 5.0 has no implementation behind it.
    public let protocolCatalog: any WhoopProtocolProviding

    /// The three objects the `STORAGE` pane is built from, held here rather than constructed by the
    /// pane's view model.
    ///
    /// **They are stored rather than local to `init` because the pane is not the only reader.** The
    /// settings store is what the routing decorator asks on every read and what the engine both reads
    /// and writes, the key store is what every request reads its header from, and the status log is the
    /// record behind the one line a screen draws when a read degraded — so a second instance anywhere
    /// would be a second answer to a question the app has already answered. `syncStatus` is an actor and
    /// `syncKeyStore` is one, which is the other half of the reason: an actor built per read would hold
    /// a set that is always empty and a Keychain read that is always the first, and the key's
    /// single-flight guard lives *inside* the actor precisely so two first-reads cannot mint two keys.
    public let syncSettings: any SyncSettingsRepository
    public let syncKeyStore: any SyncKeyStore
    public let syncStatus: any SyncStatus

    /// What the `STORAGE` pane does when the user presses the button.
    ///
    /// **One object for all seven resources, where this container used to hold three use cases.** The
    /// three were near-copies of one walk — read a range, filter, chunk, post, sum — differing only in
    /// which table they walked and which wire mapper they used, and the settings that justified keeping
    /// them apart are gone: there is one destination and one span for the install, so three copies of
    /// them would be three things to keep in step for no reader. `SyncResources.all(...)` names the
    /// differences instead, one descriptor per resource, and `SyncEngine` walks whichever list it is
    /// handed. `SyncEngine`'s own doc comment carries the whole of that argument.
    ///
    /// **Built unconditionally, unlike the routing decorator below, and the asymmetry is the point.**
    /// The decorator is a hop in the read path, so a build with no database behind it should not pay an
    /// `await` for a settings store that can never route a read anywhere. This is not a hop — nothing
    /// calls it unless a user opens `STORAGE` and presses a button — and the pane needs an object to
    /// ask even when there is no database, because *there is no database behind this build* is a
    /// sentence it draws from `isCloudConfigured`. A `nil` here would be a second spelling of that same
    /// fact, free to disagree with the first.
    ///
    /// The cloud half is `UnconfiguredCloudSync` when there is no base URL: every method throws
    /// `.unreachable` with the reason, which is the one error a caller may degrade over, so the failure
    /// surfaces as the pane's own sentence rather than as a crash or a silent no-op.
    ///
    /// **Every store is the same `db` object.** `LocalDatabaseManager` conforms to all seven
    /// `*SyncStore` protocols as bare extensions, and handing the one instance to each is what keeps a
    /// read of `sleeps` and a read of `recoveries` behind one SQLite connection. It is also why the
    /// stores are `LocalDatabaseManager` rather than the repositories: a sync moves *records*, the shape
    /// that carries every stored column and round-trips — `RecoveryMetric` has read-time derivations
    /// with no column, so a push built on the entity would invent them.
    public let syncEngine: SyncEngine

    /// Whether this build has a database behind it at all.
    ///
    /// `false` for a clone that has never set `WHOOPSYAPIBaseURL`, for the host test runner, and for
    /// every SwiftUI preview — `preview` is `shared`'s own initialiser with `useMockBLE: true`, so it
    /// reads the same `Info.plist` and finds the same absent key. The `STORAGE` pane uses this to say
    /// so in words rather than to offer a control that could only fail.
    public let isCloudConfigured: Bool

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
        // Built here rather than at its own assignment below, because the export is handed it: the
        // `Whoopsy` export is the one reader that takes the app's *settings* as well as its tables —
        // `AppPreferences` is `UserDefaults`-backed and is not a row in any table — so the local has
        // to exist before the use case is constructed. Same shape as `strapModels` above.
        let preferences = UserDefaultsAppPreferencesRepository()
        self.preferencesRepository = preferences
        // The sync's one set of settings, read and written by the engine the pane presses and read on
        // every call by the routing decorator below. Stored on the container as well, because the pane
        // and the decorator are two readers of the same two answers — same shape as `strapModels` and
        // `preferences` above.
        let syncSettings = UserDefaultsSyncSettingsRepository()
        self.syncSettings = syncSettings
        // Built here and not by the pane, for `liveActivityController`'s reason one screen over: this
        // actor's whole job is to make read-or-mint single-flight, and a second instance would be a
        // second read of a Keychain entry that may not exist yet.
        let syncKeyStore = KeychainSyncKeyStore()
        self.syncKeyStore = syncKeyStore
        self.syncStatus = SyncStatusLog()
        // Read once and stored: the pane that reports this and the wiring immediately below that acts
        // on it must not be able to disagree about whether this build has a database behind it.
        let apiBaseURL = WhoopsyAPIClient.configuredBaseURL()
        self.isCloudConfigured = apiBaseURL != nil
        self.protocolCatalog = WhoopProtocolCatalog()
        self.bleRepository = WhoopBLEDeviceRepositoryImpl(
            useMock: useMockBLE, strapModelRepository: strapModels)
        self.biometricRepository = GRDBBiometricRepository(db: db)
        // **The routing decorator, or the plain repository — and the branch is the feature rather than
        // a convenience.** `CloudRecoveryRepository` answers a day from SQLite first and, only when the
        // phone has none *and* the destination is the API, asks the database once — which is the whole
        // of "local to DB is seamless": no screen learns a second read path, because the port's four
        // methods are the same four either way.
        //
        // The `else` is not a degraded mode. A build with no `WHOOPSYAPIBaseURL` has no database to
        // route to, so a decorator there would be a hop that can only add a failure — every call would
        // consult a destination that can never send it anywhere, and take an `await` to do it. That is
        // the host runner, every SwiftUI preview (`preview` is this initialiser with `useMockBLE:
        // true`), and every fresh clone, so the unconfigured branch is the one most builds take and it
        // is byte-identical to the app before this feature existed.
        //
        // Built **before** `whoopExportImport` below, and that ordering is load-bearing: the importer
        // holds whatever it is handed for the life of the process, so a plain repository here would
        // leave the one writer that can reach a historical day writing around the decorator — a day
        // imported under `.cloud` would sit on the phone and never be pushed, with nothing saying so.
        // It is the same class of bug as the fasts/export day skip, one table over.
        //
        // **The cloud is a local rather than an inline expression, because it has two readers.** It was
        // written into the decorator's argument when the decorator was the only thing that needed one;
        // `syncEngine` below is the second, and `HTTPCloudSync` is a value type over a value-type
        // client, so handing the same value to both costs nothing and — the point — leaves one instance
        // of the key store and one base URL behind every request the app makes. Two constructions would
        // be two `WhoopsyAPIClient`s reading the same Keychain.
        let cloud: any CloudSync
        if let apiBaseURL {
            let http = HTTPCloudSync(
                client: WhoopsyAPIClient(baseURL: apiBaseURL, keyStore: syncKeyStore))
            cloud = http
            self.recoveryRepository = CloudRecoveryRepository(
                local: GRDBRecoveryRepository(db: db),
                cloud: http,
                settingsStore: syncSettings,
                status: syncStatus)
        } else {
            cloud = UnconfiguredCloudSync()
            self.recoveryRepository = GRDBRecoveryRepository(db: db)
        }
        // One engine, seven descriptors, and every store the same database object. The `db` is handed
        // over rather than a repository because the sync moves *records*: `RecoveryRecord` is the only
        // shape carrying all nine stored fields, while `RecoveryMetric` has three read-time derivations
        // with no column, so a push built on the entity would invent them. `LocalDatabaseManager`
        // conforms to all seven `*SyncStore` protocols as bare extensions — see `SyncResources.all`.
        self.syncEngine = SyncEngine(
            resources: SyncResources.all(
                cloud: cloud,
                profileStore: db,
                inactivityStore: db,
                recoveryStore: db,
                sleepStore: db,
                stepCountStore: db,
                strainStore: db,
                workoutStore: db),
            settingsStore: syncSettings)
        self.strainRepository = GRDBStrainRepository(db: db)
        self.sleepRepository = GRDBSleepRepository(db: db)
        self.napRepository = GRDBNapRepository(db: db)
        self.userProfileRepository = GRDBUserProfileRepository(db: db)
        self.workoutRepository = GRDBWorkoutRepository(db: db)
        self.receptiveInactivityRepository = GRDBReceptiveInactivityRepository(db: db)
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

        // **The database, not the repositories.** It reads through `LocalDatabaseSnapshotting`, which
        // walks `sqlite_master`, so the export cannot drift from the schema the way a hand-written
        // per-table read would — a migration that adds a table is exported with no edit here. The
        // biometric repository is still handed in for the CSV alone, which is a rendering of one table
        // the JSON already carries in full. See `ExportLocalDataUseCase`.
        self.exportLocalDataUseCase = ExportLocalDataUseCase(
            biometricRepository: biometricRepository,
            snapshotter: db,
            preferencesRepository: preferences
        )
        // Was `LocalWorkoutRepository()`, an in-memory array — a recorded workout did not survive the
        // launch that recorded it. Same store as everything else now, so the ACTIVITIES card can list
        // a day's sessions back.
        self.saveWorkoutUseCase = SaveWorkoutUseCase(repository: workoutRepository)
        self.trackStepsUseCase = TrackStepsUseCase(
            bleRepository: bleRepository,
            stepRepository: stepRepository
        )
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
        self.inactivityImport = InactivityImporter(receptiveRepository: receptiveInactivityRepository)
    }
}