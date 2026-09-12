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

    public let accelerometerX: Double // in Gs (±4G)
    public let accelerometerY: Double
    public let accelerometerZ: Double
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
        accelerometerX: Double = 0.0,
        accelerometerY: Double = 0.0,
        accelerometerZ: Double = 0.0,
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

    /// Accelerometer magnitude vector |a| = sqrt(x^2 + y^2 + z^2)
    public var accelerationMagnitude: Double {
        sqrt(pow(accelerometerX, 2) + pow(accelerometerY, 2) + pow(accelerometerZ, 2))
    }
}
