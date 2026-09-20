import Foundation

/// High-frequency composite biometric telemetry sample decoded from WHOOP BLE packets.
public struct BiometricSample: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let heartRate: Int

    /// The beat-to-beat intervals carried by **one** notification, in wire order, in milliseconds.
    ///
    /// A series rather than a single figure, because that is what the standard Heart Rate
    /// characteristic (0x2A37) actually sends: one notification may carry several R-R values, and
    /// within a notification they are **adjacent beats by definition**. The decoder appends them in
    /// the order they appear, so the ordering is exact rather than inferred — which is the whole
    /// reason this is a list and not one sample per interval with a timestamp walked backwards from
    /// the arrival instant.
    ///
    /// `nil` means the notification carried no intervals (the characteristic's R-R bit was unset, or
    /// the strap does not populate the field). An empty array is deliberately collapsed to `nil` at
    /// the BLE layer: "no intervals" and "an interval list of length zero" are the same absence, and
    /// having two spellings of it would mean two branches everywhere downstream.
    public let rrIntervalsMs: [Double]?

    /// The first interval of ``rrIntervalsMs``, or `nil` when there is none.
    ///
    /// Derived, not stored. It was the stored field, and the BLE layer kept only `rrs.first`,
    /// discarding every other interval in the notification. Keeping it as a computed property means
    /// the ~4 readers that want "an R-R value" (RMSSD, the stress model, the exporter) compile and
    /// behave exactly as before, while the invariant `rrIntervalMs == rrIntervalsMs?.first` becomes
    /// structural instead of something a writer has to remember.
    ///
    /// **It is not a substitute for the series, and the two RMSSD consumers currently treat it as
    /// one** — `CalculateRecoveryUseCase` and `AnalyzeStressUseCase` each flatten one interval per
    /// notification, so they difference beats that were never adjacent. That defect predates this
    /// field and is not fixed here; see the note in `ALGORITHMS.md` §1.
    public var rrIntervalMs: Double? { rrIntervalsMs?.first }

    /// The strap's three accelerometer axes in Gs, or `nil` when the notification carried no motion.
    ///
    /// **All three are present together or none is.** The strap sends the triplet as one record, so a
    /// partial triplet is not a state any producer can be in — which is why
    /// ``accelerationMagnitude`` returns `nil` unless all three are there rather than summing
    /// whichever arrived.
    ///
    /// The scale is `1/4096` g/LSB over a signed `int16`, and **that pair is a ±8 g full scale**
    /// (32767 / 4096 = 7.9998 g). The range is worth stating beside the sensitivity because the two
    /// are inseparable: ±4 g would be 8192 LSB/g, exactly half, and would leave the top bit of every
    /// sample unused. The gyro's `2000/32768` deg/s/LSB is the same pairing at ±2000 dps.
    ///
    /// **`0.0` is not the absent value, and the difference is not cosmetic.** Gravity is inside the
    /// magnitude, so a motionless worn strap reads ≈1.0 G; `0.0` is free fall, which is unreachable
    /// on a body. Worse, it lands on the *still* side of every movement threshold in this app — so a
    /// fabricated zero does not read as "no motion was measured", it reads as "measured, and
    /// perfectly still". A confidently wrong reading of the strap's stillness is the one answer the
    /// sleep classifier and the stress model must never be handed.
    public let accelerometerX: Double?
    public let accelerometerY: Double?
    public let accelerometerZ: Double?
    public let skinTemperatureCelsius: Double?
    public let spO2Percentage: Double?
    public let isOnBody: Bool
    public let isCharging: Bool
    public let rawSequenceNumber: UInt32?

    /// - Parameter rrIntervalsMs: the notification's full interval series. Canonical.
    /// - Parameter rrIntervalMs: a single interval, folded into `rrIntervalsMs` as a one-element
    ///   series. It exists for the paths that genuinely have exactly one interval — the proprietary
    ///   `0x01` live payload reads one from `payload[5..6]`, and the fixtures that predate the
    ///   series. **When both are given the series wins**, because a caller that supplied a series
    ///   supplied the more complete answer.
    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        heartRate: Int,
        rrIntervalsMs: [Double]? = nil,
        rrIntervalMs: Double? = nil,
        accelerometerX: Double? = nil,
        accelerometerY: Double? = nil,
        accelerometerZ: Double? = nil,
        skinTemperatureCelsius: Double? = nil,
        spO2Percentage: Double? = nil,
        isOnBody: Bool = true,
        isCharging: Bool = false,
        rawSequenceNumber: UInt32? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.rrIntervalsMs = rrIntervalsMs ?? rrIntervalMs.map { [$0] }
        self.accelerometerX = accelerometerX
        self.accelerometerY = accelerometerY
        self.accelerometerZ = accelerometerZ
        self.skinTemperatureCelsius = skinTemperatureCelsius
        self.spO2Percentage = spO2Percentage
        self.isOnBody = isOnBody
        self.isCharging = isCharging
        self.rawSequenceNumber = rawSequenceNumber
    }

    /// Accelerometer magnitude vector |a| = sqrt(x² + y² + z²) in Gs, or `nil` when the sample
    /// carries no motion.
    ///
    /// At rest this reads ≈1.0 G rather than 0, because gravity is inside it — see the axis fields
    /// above for why that makes a substituted zero a reading of stillness rather than an absence.
    ///
    /// `nil` unless **all three** axes are present. A magnitude summed over a partial triplet would
    /// be arithmetic on a sensor reading that does not exist, and there is no producer that can
    /// create one: the strap's motion record carries the three axes together.
    public var accelerationMagnitude: Double? {
        guard let x = accelerometerX, let y = accelerometerY, let z = accelerometerZ else {
            return nil
        }
        return sqrt(pow(x, 2) + pow(y, 2) + pow(z, 2))
    }
}
