import Foundation

/// User physiological profile for baseline calibration.
///
/// **The fields split into three kinds, and only the first kind is a measurement.**
///
/// | Kind | Fields | Why they may be here |
/// | :--- | :--- | :--- |
/// | Measured or modelled | `maxHeartRate`, `restingHeartRate` | The Karvonen zone table cannot be built without them, so an absence is not a dash a screen can draw — it is a table that does not exist |
/// | Stored measurement | `weightKg` | Divides into `StrainAccumulatorMath.estimateCalories`; `nil` withholds the figure |
/// | **Declared** | `name`, `gender`, `heightCm` | Facts the user types about themselves. **None has a reader in `Sources/`** |
/// | **Declared, now read** | `birthDate` | Feeds `age` (never a defaulted age), which is population context for `SleepNeedBaselineMath`'s learned baseline — its cold-start value and floor — and supplies `CircadianAgeMath`'s timing prior only when a night has no consistency |
///
/// **A declared fact is not a fabricated measurement, and that distinction is the whole reason these
/// fields are allowed on the entity at all.** The rule this app holds — written out in
/// `ui-data-provenance` and enforced everywhere from `RecoveryMetric.hasMeasurement` to
/// `StepCount.hasMeasurement` — is that *the app must not invent a number and report it back as the
/// user's*. A height the user typed is the opposite of that: the user is the sensor. What the app must
/// never do is supply a plausible default for one, which is what `178.0 cm`, `"Athlete"` and a
/// `-28`-year birth date were, and `v20` deleted all three.
///
/// **The honest cost, stated rather than buried: the three unread fields feed no model.** They are
/// saved and read back onto the form, and nothing else consumes them. `birthDate` is the exception
/// since the sleep score gained an age prior, and `targetSleepHours` lost its last reader when the
/// need baseline moved to `SleepNeedBaselineMath`; the field is kept for a future user-set target, not
/// because a model still reads it.
public struct UserProfile: Identifiable, Equatable, Sendable {

    /// The vocabulary of `GENDER`, nested because it is this entity's and nothing else's.
    ///
    /// **No reader anywhere in this app consults a gender**, so there is no consumer to derive the list
    /// from and its four cases are a judgement rather than a measurement. They are `CaseIterable` and
    /// carry a `title` so the picker's rows and the assertion over them are built from one list, the
    /// shape `DeviceSettingsView.Tab` and `ActivityMenu.Entry` already take.
    public enum Gender: String, CaseIterable, Identifiable, Sendable {
        case man
        case woman
        case nonBinary
        case preferNotToSay

        public var id: String { rawValue }

        /// The word the `GENDER` row's picker shows for this case.
        public var title: String {
            switch self {
            case .man: "Man"
            case .woman: "Woman"
            case .nonBinary: "Non-binary"
            case .preferNotToSay: "Prefer not to say"
            }
        }
    }

    public let id: UUID

    /// The user's first name, or `nil` when they have not supplied one.
    ///
    /// Optional since `v20`; the `"Athlete"` default it replaced was a name this app wrote down and
    /// then drew back in a field labelled `FIRST NAME`.
    public let name: String?

    /// The user's date of birth, or `nil`.
    ///
    /// Optional since `v20`. The default it replaced was *28 years before `Date()`* — **unstable**,
    /// being relative to the moment of construction, so a defaulted value would have moved at every
    /// launch. `age` follows it into optionality.
    public let birthDate: Date?

    public let maxHeartRate: Int
    public let restingHeartRate: Int
    public let baselineHrvRmssd: Double
    public let baselineRhr: Double
    public let targetSleepHours: Double

    /// The body weight the calorie estimate needs, or `nil` when the user has not supplied one.
    ///
    /// **Optional because it is the one profile field this app drew a figure from.** The others are
    /// either consumed by a model that has a defined answer without them (the heart rates are the
    /// inputs a Karvonen zone table cannot be built without) or read by nothing at all (`heightCm`,
    /// `name`, `gender`, `targetSleepHours`, the two `baseline*` fields). Weight was neither:
    /// `CalculateStrainUseCase` passed it to
    /// `StrainAccumulatorMath.estimateCalories`, so a default here became a calorie count on a screen.
    ///
    /// A defaulted `75.0` is therefore not a neutral starting point — it is a measurement this app
    /// would be inventing about the user's body and then reporting back to them. `nil` is the honest
    /// value, and it propagates: `estimateCalories` returns `nil`, and the session screen draws a dash
    /// where the figure would go. Supplied by the profile page, persisted in `user_profiles.weightKg`
    /// since `v16`.
    public let weightKg: Double?

    /// The user's height in centimetres, or `nil` when they have not supplied one.
    ///
    /// Optional since `v20`; the `178.0` default it replaced is the exact analogue of the `75.0`
    /// weight above. **Nothing reads it** — see the type's doc comment — so this is a declared fact
    /// held rather than a figure drawn from.
    public let heightCm: Double?

    /// The user's gender, or `nil` when they have not supplied one.
    ///
    /// New in `v20`: the table had no vocabulary for it before, so this is the first of the four
    /// declared fields with no default to argue with.
    public let gender: Gender?

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        birthDate: Date? = nil,
        maxHeartRate: Int = 195,
        restingHeartRate: Int = 54,
        baselineHrvRmssd: Double = 65.0,
        baselineRhr: Double = 54.0,
        targetSleepHours: Double = 8.0,
        weightKg: Double? = nil,
        heightCm: Double? = nil,
        gender: Gender? = nil
    ) {
        self.id = id
        self.name = name
        self.birthDate = birthDate
        self.maxHeartRate = maxHeartRate
        self.restingHeartRate = restingHeartRate
        self.baselineHrvRmssd = baselineHrvRmssd
        self.baselineRhr = baselineRhr
        self.targetSleepHours = targetSleepHours
        self.weightKg = weightKg
        self.heightCm = heightCm
        self.gender = gender
    }

    /// The user's age in whole years, or `nil` when no birth date has been supplied.
    ///
    /// **The sleep score's only age reader, and population context rather than a verdict.**
    /// `AnalyzeSleepUseCase` passes it to `SleepNeedBaselineMath`, which uses it for the learned
    /// baseline's cold-start value and floor, not as the baseline itself; `SleepScoreScoring` passes
    /// it to `CircadianAgeMath` only when a night has no consistency to score its timing against. It
    /// is still optional, and an absent birth date must produce no age rather than a
    /// twenty-eight-year-old: the need's cold-start value falls back to the adult midpoint through
    /// `SleepNeedBaselineMath`, and the timing prior is simply unavailable.
    public var age: Int? {
        guard let birthDate else { return nil }
        let years = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year
        return years.map { max(14, $0) }
    }

    /// Default calculated Max HR if uncalibrated (Gellish formula: 207 - 0.7 * age)
    public static func estimatedMaxHeartRate(age: Int) -> Int {
        Int((207.0 - (0.7 * Double(age))).rounded())
    }

    public static let `default` = UserProfile()
}
