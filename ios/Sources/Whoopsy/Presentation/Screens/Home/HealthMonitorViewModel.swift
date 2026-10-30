import Foundation
import SwiftUI

/// The Health Monitor sheet's subject: the night's `recoveries` row, the bands behind it, and the
/// night's mean heart rate.
///
/// **Three reads and no more.** The row and its history are the numbers the five cards print and the
/// bands they are read against — the same `getRecoveryHistory` a dozen other surfaces take, ending on
/// the day the sheet was opened from. The samples are the night's own, over the session's in-bed
/// window, and they are read only when a session exists: an imported night has no `biometric_samples`,
/// which is why its heart rate is absent rather than zero.
///
/// **It is a page-scoped view model built in `MainContainerView`**, like every other screen's: the
/// sheet holds it in `@State` and its `.task` calls `load(for:)`, so opening the sheet is what reads.
@MainActor @Observable public final class HealthMonitorViewModel {

    /// The night's five readings, in the monitor's order. Empty when there is no row for the night.
    public private(set) var readings: [HealthMonitorReadings.Reading] = []

    /// How many measured nights the bands were taken over — the page's footnote states it.
    public private(set) var baselineNights = 0

    /// The night's mean heart rate, or `nil` when the night holds no samples.
    public private(set) var averageHeartRate: Int?

    /// The day's mortality-risk multiplier from three published relative risks, or `nil` when the day
    /// supplies none of the three readings — see `MortalityRiskProfile`.
    public private(set) var riskProfile: MortalityRiskProfile?

    /// The multiplier turned into years by the bundled life table, or `nil` when there is no profile,
    /// no age, or no table for this region — see `LongevityEstimate`.
    public private(set) var longevity: LongevityEstimate?

    /// Fat-free mass estimated from the profile's height, weight and sex, or `nil` when it holds none
    /// of the three — the eighth of WHOOP's nine healthspan inputs. See `LeanBodyMassMath`.
    public private(set) var leanBodyMass: LeanBodyMassMath.Estimate?

    /// The day the age, the resting rate and the step count were read from, when it is **not** the day
    /// the sheet was opened from. The card prints it, so a figure taken from an older measurement never
    /// reads as today's.
    public private(set) var healthspanDay: Date?

    /// Why the dial has no age to draw, or `nil` when it has one.
    ///
    /// **A dash alone cannot say which of three different things is missing**, and they need three
    /// different answers from the reader: no measured night, no date of birth, or no life table for
    /// where they live. This is the sentence that turns the dash into an instruction.
    public private(set) var longevityAbsence: LongevityAbsence?

    public enum LongevityAbsence: Equatable, Sendable {
        /// No resting rate on any day the lookback covered — the estimate's only measured input.
        case noMeasuredNight
        /// A measured night, but the profile carries no birth date, so there is no age to compare with.
        case noBirthDate
        /// An age and a profile, but no table bundled for this region.
        case noLifeTable
    }

    /// How far back the healthspan inputs are looked for when the day on screen has no measurement.
    ///
    /// **A day with no row is the normal state of an unmeasured day** — this app stores no placeholder
    /// for one, and `Home` opens on today — so an estimate taken only from the day on screen would dash
    /// for anyone who has not slept with the strap since the last import. A year is the bound rather
    /// than "everything": past a year the profile describes someone the wearer may no longer be, and a
    /// dash says that better than a stale number.
    public static let healthspanLookbackDays = 365

    public private(set) var isLoading = false

    private let recoveryRepository: any RecoveryRepository
    private let sleepRepository: any SleepRepository
    private let biometricRepository: any BiometricRepository
    private let stepRepository: any StepRepository
    private let userProfileRepository: any UserProfileRepository
    private let lifeTableStore: LifeTableStore
    private let calendar: Calendar

    /// The region the estimate is keyed on. Read from the device's locale at init — the only signal
    /// this app has for where its owner lives — and overridable so the suite can say "the US" and "a
    /// country with no table" without touching the machine's settings.
    private let regionCode: String?

    public init(
        recoveryRepository: any RecoveryRepository,
        sleepRepository: any SleepRepository,
        biometricRepository: any BiometricRepository,
        stepRepository: any StepRepository,
        userProfileRepository: any UserProfileRepository,
        lifeTableStore: LifeTableStore = LifeTableStore(),
        regionCode: String? = Locale.current.region?.identifier,
        calendar: Calendar = .current
    ) {
        self.recoveryRepository = recoveryRepository
        self.sleepRepository = sleepRepository
        self.biometricRepository = biometricRepository
        self.stepRepository = stepRepository
        self.userProfileRepository = userProfileRepository
        self.lifeTableStore = lifeTableStore
        self.regionCode = regionCode
        self.calendar = calendar
    }

    public func load(for date: Date) async {
        isLoading = true
        defer { isLoading = false }

        let day = date.startOfDay
        let recovery = try? await recoveryRepository.getRecovery(for: day)
        // One read, one window: the same 30 days every other "typical" figure is taken over, ending on
        // the night so the night itself is never inside the band that judges it.
        let history = (try? await recoveryRepository.getRecoveryHistory(
            days: RecoveryScoring.baselineWindowLookbackDays, endingOn: day)) ?? []

        let summary = HealthMonitorReadings(recovery: recovery, prior: history, calendar: calendar)
        readings = summary.readings
        baselineNights = summary.baselineNights

        averageHeartRate = try? await averageHeartRateForNight(day)

        // **The risk profile describes the person, not the night the sheet was opened from.** A day
        // with no row is the normal state of an unmeasured day, so when this one holds no measurement
        // the most recent day that does stands in, and `healthspanDay` carries its date for the card.
        // `nil` means the readings below really are this day's.
        let measured = recovery?.hasMeasurement == true
            ? recovery
            : Self.mostRecentMeasured(
                in: (try? await recoveryRepository.getRecoveryHistory(
                    days: Self.healthspanLookbackDays, endingOn: day)) ?? [])
        healthspanDay = measured.flatMap { row in
            calendar.isDate(row.date, inSameDayAs: day) ? nil : row.date
        }

        // **The risk multiplier's three inputs are all readings this app already stores**, which is
        // what makes it buildable without a life table: fitness is the profile's max rate over the
        // day's resting rate (`Vo2MaxMath`), steps are the day's own count, and the resting rate is the
        // same row the five cards print. A reading that is absent drops its factor rather than
        // counting as average — see `MortalityRiskProfile.make`.
        let steps = (try? await stepRepository.getStepCount(for: measured?.date ?? day))?.measuredStepCount
        let profile = try? await userProfileRepository.getUserProfile()
        let vo2 = Vo2MaxMath.heartRateRatioEstimate(
            maxHeartRate: profile?.maxHeartRate,
            restingHeartRate: measured?.restingHeartRate)
        riskProfile = MortalityRiskProfile.make(
            vo2MaxMlKgMin: vo2,
            steps: steps,
            restingHeartRate: measured?.restingHeartRate)

        // The years, when all three halves line up: a multiplier, an age, and a table for where the
        // owner lives. Any of the three missing leaves `longevity` nil, and `longevityAbsence` names
        // which one so the card can ask for it rather than printing a bare dash.
        longevity = Self.longevity(
            riskProfile: riskProfile, profile: profile, regionCode: regionCode, store: lifeTableStore)
        if longevity == nil {
            if riskProfile == nil {
                longevityAbsence = .noMeasuredNight
            } else if profile?.age == nil {
                longevityAbsence = .noBirthDate
            } else {
                longevityAbsence = .noLifeTable
            }
        } else {
            longevityAbsence = nil
        }

        // **The one healthspan input the strap cannot supply, estimated rather than measured.** Only a
        // profile that says `man` or `woman` reaches it: the regressions are fitted on those two
        // categories, and answering one of the profile's other two options would be inferring an
        // anatomical category this app has no basis for.
        leanBodyMass = LeanBodyMassMath.estimate(
            weightKg: profile?.weightKg,
            heightCm: profile?.heightCm,
            sex: Self.sex(for: profile?.gender))
    }

    /// The latest row in `rows` that holds a measurement, or `nil`.
    ///
    /// `getRecoveryHistory` returns its rows oldest-first, so the last qualifying one is the most
    /// recent. The order is stated here rather than left implicit: a reversed read would silently pick
    /// the oldest night the window covers and still look plausible.
    public nonisolated static func mostRecentMeasured(in rows: [RecoveryMetric]) -> RecoveryMetric? {
        rows.last(where: { $0.hasMeasurement })
    }

    /// The profile's gender mapped onto the two categories the regressions were fitted on, or `nil`.
    static func sex(for gender: UserProfile.Gender?) -> LeanBodyMassMath.Sex? {
        switch gender {
        case .man: return .male
        case .woman: return .female
        default: return nil
        }
    }

    /// The estimate, or `nil`. Split out so the rule is one expression rather than a nest inside `load`.
    public nonisolated static func longevity(
        riskProfile: MortalityRiskProfile?,
        profile: UserProfile?,
        regionCode: String?,
        store: LifeTableStore
    ) -> LongevityEstimate? {
        guard
            let riskProfile,
            let age = profile?.age,
            let regionCode,
            let iso3 = iso3(forRegion: regionCode),
            let table = store.table(for: iso3, sex: sexKey(for: profile?.gender))
        else {
            // A capture line while this is being brought up: the four ways to come up empty here are
            // indistinguishable on the glass.
            CaptureLog.shared.append(
                "LONGEVITY absent region=\(regionCode ?? "-") age=\(profile?.age.map(String.init) ?? "-") "
                    + "risk=\(riskProfile != nil) countries=\(store.countryCodes.joined(separator: ","))")
            return nil
        }

        return LongevityEstimate.make(
            table: table,
            multiplier: riskProfile.multiplier,
            age: age,
            countryName: countryName(for: iso3),
            sexLabel: sexKey(for: profile?.gender))
    }

    /// The ISO 3166-1 alpha-3 code the life-table bundle is keyed on, from the locale's alpha-2 region.
    ///
    /// A table is added by regenerating the bundle, so this map grows with it — and a region absent
    /// here is a card that says there is no table, which is the honest answer rather than a guess.
    public nonisolated static func iso3(forRegion region: String) -> String? {
        ["US": "USA"][region.uppercased()]
    }

    public nonisolated static func countryName(for iso3: String) -> String {
        ["USA": "United States"][iso3] ?? iso3
    }

    /// The sex row the table carries.
    ///
    /// **Only `man` and `woman` take a sex-specific row.** The profile's other two answers — non-binary
    /// and prefer-not-to-say — take the `total` row, which is the table's own row for a population
    /// without a sex split; inferring an anatomical category from a gender answer would be exactly the
    /// kind of substitution this app does not make.
    public nonisolated static func sexKey(for gender: UserProfile.Gender?) -> String {
        switch gender {
        case .man: return "male"
        case .woman: return "female"
        default: return "total"
        }
    }

    /// The mean of the night's samples, or `nil` when the night has no window or no reading.
    ///
    /// A `heartRate` of `0` is dropped rather than averaged in — the app's absence rule, and the same
    /// one the sleep page's trace applies to the same rows.
    private func averageHeartRateForNight(_ day: Date) async throws -> Int? {
        guard let session = try await sleepRepository.getSleepSession(for: day) else { return nil }
        guard session.endTime > session.startTime else { return nil }

        let samples = try await biometricRepository.getSamples(
            from: session.startTime, to: session.endTime)
        let rates = samples.map(\.heartRate).filter { $0 > 0 }
        guard !rates.isEmpty else { return nil }

        return Int((Double(rates.reduce(0, +)) / Double(rates.count)).rounded())
    }
}
