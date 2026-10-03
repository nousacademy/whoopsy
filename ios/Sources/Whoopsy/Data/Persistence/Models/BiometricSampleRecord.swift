import Foundation
import GRDB

/// Storage row for `BiometricSample`. Every channel the strap reports is persisted: dropping any of
/// them here silently disables a downstream calculation, because the repositories rebuild the
/// domain entity purely from this row.
public struct BiometricSampleRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "biometric_samples"

    public var id: Int?
    public var timestamp: Date
    public var heartRate: Int
    /// Beats-to-beats interval. `CalculateRecoveryUseCase` derives RMSSD from these and nothing else.
    ///
    /// One interval per notification, and the only shape the schema knew before `v8`. It is now the
    /// **lossy** field: a notification carrying several intervals kept only its first here. It is
    /// still written, because every existing reader reads it and because it is the whole content of
    /// a row written before the series column existed.
    public var rrIntervalMs: Double?
    /// Every interval the notification carried, in wire order, as a JSON-encoded array.
    ///
    /// Declared `[Double]?` on a `Codable` record with **no `CodingKeys`**, which is what makes GRDB
    /// store it: the property name *is* the column name (`rrIntervalsMs`, camelCase — see the `v8`
    /// migration), and GRDB's `Codable` support JSON-encodes the array to a String. GRDB does **not**
    /// conform `Array` to `DatabaseValueConvertible`, so this can only ever be a record property and
    /// must never be used as a query binding — use ``rrSeries`` for anything that needs to be a
    /// value.
    ///
    /// `nil` means the row predates the column **or** the notification carried no intervals. Those
    /// are the same absence to every reader, which is why `v8` does not backfill from the scalar.
    public var rrIntervalsMs: [Double]?

    /// The intervals this row holds, from whichever column has them, with the scalar as the fallback.
    ///
    /// The one place the two columns are reconciled. `computed`, so `Codable` synthesis skips it and
    /// it adds no column; a `[Double]` returned from a computed property is an ordinary Swift value,
    /// safe to pass anywhere a query binding would not be.
    ///
    /// The fallback is not a backfill dressed up as one: a pre-`v8` row's `[882.0]` is exactly what
    /// was captured — one interval out of a notification that may have carried more — and returning
    /// it as a one-element series claims nothing further.
    public var rrSeries: [Double] { rrIntervalsMs ?? rrIntervalMs.map { [$0] } ?? [] }

    public var accelX: Double?
    public var accelY: Double?
    public var accelZ: Double?
    public var skinTemp: Double?
    public var spo2Percentage: Double?
    public var isOnBody: Bool?
    public var isCharging: Bool?
    public var rawSequenceNumber: UInt32?

    public init(
        id: Int? = nil,
        timestamp: Date,
        heartRate: Int,
        rrIntervalsMs: [Double]? = nil,
        rrIntervalMs: Double? = nil,
        accelX: Double? = nil,
        accelY: Double? = nil,
        accelZ: Double? = nil,
        skinTemp: Double? = nil,
        spo2Percentage: Double? = nil,
        isOnBody: Bool? = nil,
        isCharging: Bool? = nil,
        rawSequenceNumber: UInt32? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.heartRate = heartRate
        self.rrIntervalsMs = rrIntervalsMs
        self.rrIntervalMs = rrIntervalMs
        self.accelX = accelX
        self.accelY = accelY
        self.accelZ = accelZ
        self.skinTemp = skinTemp
        self.spo2Percentage = spo2Percentage
        self.isOnBody = isOnBody
        self.isCharging = isCharging
        self.rawSequenceNumber = rawSequenceNumber
    }
}
