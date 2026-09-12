import Foundation

public final class AnalyzeSleepUseCase: Sendable {
    private let biometricRepository: any BiometricRepository
    private let sleepRepository: any SleepRepository
    private let strainRepository: any StrainRepository
    private let userProfileRepository: any UserProfileRepository

    public init(
        biometricRepository: any BiometricRepository,
        sleepRepository: any SleepRepository,
        strainRepository: any StrainRepository,
        userProfileRepository: any UserProfileRepository
    ) {
        self.biometricRepository = biometricRepository
        self.sleepRepository = sleepRepository
        self.strainRepository = strainRepository
        self.userProfileRepository = userProfileRepository
    }

    /// Samples needed before a night is classified at all: one full 30-second epoch. Below this
    /// there is nothing to average, so the night is reported as absent rather than guessed at.
    static let minimumEpochSamples = 30

    /// A night with too few samples is `nil` — no session is invented and **nothing is written**.
    ///
    /// The previous behaviour built an eight-hour night out of literals and saved it, so a strap
    /// that never came off the charger produced a plausible-looking, permanently stored 8h session
    /// that every later reader (sleep debt, sleep performance, the importer's precedence check)
    /// treated as a measurement. An absent night has to stay absent.
    public func execute(for morningDate: Date = Date()) async throws -> SleepSession? {
        let profile = try await userProfileRepository.getUserProfile()

        // Window: 9:00 PM previous evening to 10:00 AM current day
        let calendar = Calendar.current
        let prevEvening = calendar.date(byAdding: .hour, value: -11, to: morningDate.startOfDay) ?? morningDate
        let morningEnd = calendar.date(byAdding: .hour, value: 10, to: morningDate.startOfDay) ?? morningDate

        let samples = try await biometricRepository.getSamples(from: prevEvening, to: morningEnd)

        guard samples.count >= Self.minimumEpochSamples else { return nil }

        var lightSec: TimeInterval = 0
        var deepSec: TimeInterval = 0
        var remSec: TimeInterval = 0
        var awakeSec: TimeInterval = 0
        var disturbances = 0
        var stages: [SleepStageSegment] = []

        // Classify 30-second epochs
        let epochDuration: TimeInterval = 30.0
        let strideSize = 30
        let restHR = Double(profile.restingHeartRate)

        for i in stride(from: 0, to: samples.count, by: strideSize) {
            let epochSamples = Array(samples[i..<min(i + strideSize, samples.count)])
            guard let firstEpochSample = epochSamples.first,
                  let lastEpochSample = epochSamples.last else { continue }

            let avgEpochHR = Double(epochSamples.map { $0.heartRate }.reduce(0, +)) / Double(epochSamples.count)
            let avgAccel = Double(epochSamples.map { $0.accelerationMagnitude }.reduce(0, +)) / Double(epochSamples.count)

            let startTime = firstEpochSample.timestamp
            let endTime = lastEpochSample.timestamp

            let stage: SleepStageType
            if avgAccel > 1.25 || avgEpochHR > restHR * 1.25 {
                stage = .awake
                awakeSec += epochDuration
                disturbances += 1
            } else if avgEpochHR < restHR * 0.92 && avgAccel < 1.05 {
                stage = .deep
                deepSec += epochDuration
            } else if avgEpochHR > restHR * 1.05 && avgAccel < 1.05 {
                stage = .rem
                remSec += epochDuration
            } else {
                stage = .light
                lightSec += epochDuration
            }

            stages.append(SleepStageSegment(startTime: startTime, endTime: endTime, stage: stage))
        }

        guard let firstSample = samples.first, let lastSample = samples.last else { return nil }

        // The cycle that ran into this night. `strains` is keyed on `startOfDay(wakeOnset)`, and the
        // cycle ending on morning D is keyed D — so a night keyed D+1 follows the strain row keyed D.
        // That is WHOOP's "previous day's Strain", and the export agrees it is the right lag: on the
        // 909 nights that carry one, previous-day strain fits at R²=0.366 against same-day's 0.161.
        //
        // `.startOfDay` is explicit rather than assumed: `execute(for:)` defaults to a raw `Date()`,
        // and `SleepViewModel` passes exactly that on a first load, so the subtraction would land
        // mid-day and miss the row the keyed lookup needs.
        let previousDay = calendar.date(byAdding: .day, value: -1, to: morningDate.startOfDay) ?? morningDate
        let previousStrain = try await strainRepository.getStrain(for: previousDay)

        let session = SleepSession(
            date: morningDate,
            startTime: firstSample.timestamp,
            endTime: lastSample.timestamp,
            // A flat `targetSleepHours` stood here, which reported every night against the same
            // denominator while WHOOP's own need for the same nights ranged 321–650 min. See
            // `SleepNeedMath` for the fit and for what is deliberately left out.
            targetSleepNeedSeconds: SleepNeedMath.sleepNeedSeconds(
                baselineSeconds: profile.targetSleepHours * 3600,
                previousDayStrain: previousStrain?.score),
            lightSleepSeconds: lightSec,
            deepSleepSeconds: deepSec,
            remSleepSeconds: remSec,
            awakeSeconds: awakeSec,
            // Both derived from the epochs above: a disturbance is a counted awake epoch.
            disturbanceCount: disturbances,
            // No respiratory sensor on this path. The literal 14.4 that stood here reached the
            // Recovery screen as a measured "14.4 rpm"; absent is the honest answer, and Recovery
            // already renders a nil respiratory rate as a dash.
            respiratoryRate: nil,
            sleepStages: stages
        )

        try await sleepRepository.saveSleepSession(session)
        return session
    }
}
