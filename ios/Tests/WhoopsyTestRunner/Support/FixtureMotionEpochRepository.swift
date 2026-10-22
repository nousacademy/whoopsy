import Foundation
import Whoopsy

/// Motion epochs for the sleep tests, without a database or a strap.
///
/// **The default is quiet**, because most sleep fixtures are about the heart-rate bands and the span;
/// a quiet window keeps the onset decision on the same footing those fixtures were written against
/// (`|a| ≈ 1.0` is a motionless strap, gravity included). A test about the motion gate itself passes
/// a different `magnitude`, or `epochs: []` for a window the recorder never filled.
struct FixtureMotionEpochRepository: MotionEpochRepository {
    /// When set, these exact epochs are returned (filtered to the requested range) instead of a
    /// generated grid. An empty array is the "no motion was recorded" case.
    var epochs: [MotionEpoch]? = nil

    /// The mean magnitude of each generated 30-second window. 1.0 is still; 1.5 is movement.
    var magnitude: Double = 1.0

    func saveMotionEpoch(_ epoch: MotionEpoch) async throws {}

    func getMotionEpochs(from: Date, to: Date) async throws -> [MotionEpoch] {
        if let epochs {
            return epochs.filter { $0.start >= from && $0.start < to }
        }
        var result: [MotionEpoch] = []
        var start = from
        while start < to {
            result.append(
                MotionEpoch(
                    start: start,
                    end: start.addingTimeInterval(30),
                    meanMagnitudeG: magnitude,
                    maxMagnitudeG: magnitude + 0.1,
                    sampleCount: 3_000))
            start = start.addingTimeInterval(30)
        }
        return result
    }
}
