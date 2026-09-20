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
    /// Which model the user has said each strap is. Read by the BLE layer to resolve a generation and
    /// written by the device screen.
    public let strapModelRepository: any StrapModelRepository
    /// Which generations this build can actually frame for. Presentation depends on this rather than
    /// on `Data/BLE` so the device screen can say plainly that a 5.0 has no implementation behind it.
    public let protocolCatalog: any WhoopProtocolProviding
    @MainActor public var locationTracking: any LocationTracking { useMockBLE ? PreviewLocationTrackingService() : CoreLocationTrackingService() }
    private let useMockBLE: Bool

    public init(useMockBLE: Bool = true) {
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
        self.whoopExportImport = WhoopExportImporter(
            recoveryRepository: recoveryRepository,
            sleepRepository: sleepRepository,
            strainRepository: strainRepository,
            napRepository: napRepository,
            workoutRepository: workoutRepository,
            userProfileRepository: userProfileRepository)
    }
}