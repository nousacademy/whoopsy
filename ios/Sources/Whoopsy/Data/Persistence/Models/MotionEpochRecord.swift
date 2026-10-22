import Foundation
import GRDB

/// The `motionEpochs` row.
///
/// **No `CodingKeys`, so the property names are the column names** — `StepCountRecord`'s convention.
/// The `v32` migration declares the columns in exactly this spelling, because a record that declares
/// `meanMagnitudeG` against a migration writing `mean_magnitude_g` fails at launch with `no such
/// column`, and a failing migration `fatalError`s.
///
/// `start` is the primary key: one row per 30-second window, and a window is saved more than once as
/// its batches arrive, so the write is an upsert on that key.
public struct MotionEpochRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "motionEpochs"

    public var start: Date
    public var date: Date
    public var end: Date
    public var meanMagnitudeG: Double
    public var maxMagnitudeG: Double
    public var sampleCount: Int

    public init(
        start: Date,
        date: Date,
        end: Date,
        meanMagnitudeG: Double,
        maxMagnitudeG: Double,
        sampleCount: Int
    ) {
        self.start = start
        self.date = date
        self.end = end
        self.meanMagnitudeG = meanMagnitudeG
        self.maxMagnitudeG = maxMagnitudeG
        self.sampleCount = sampleCount
    }
}
