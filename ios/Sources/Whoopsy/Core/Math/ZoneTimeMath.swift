import Foundation

/// How a stream of heart-rate samples becomes time in each zone — **the one definition of the rule**.
///
/// **The rule.** Each accepted sample is credited with the interval since the previous accepted
/// sample, and that interval belongs to the *current* sample's zone: a reading of 160 bpm is a claim
/// that the last few seconds were spent at 160. The first sample has no predecessor and is credited
/// `firstSampleSeconds`; an interval longer than `maximumIntervalSeconds` is credited as that cap,
/// because a strap that stopped notifying was not measuring the gap.
///
/// **It was written twice before this type existed** — `LiveSessionAccumulator.accept` and
/// `StrainDayMath.compute` each carried a copy — and the two agreed by inspection rather than by
/// construction. They now both call `delta(_:)`, and `totals(_:)` is the completed-stream fold the
/// activity page uses. A third copy is what `ZoneTimeMathTests` is written to catch: it asserts this
/// fold against the live accumulator's own snapshot over a stream with a gap and a zero reading.
///
/// **Time below zone 1 is measured and belongs to no band.** It adds to `measuredSeconds` and its
/// load is the low-intensity band's, but no zone is credited, so the five band times sum to at most
/// the measured span. That shortfall is the whole reason a share of a *session* is not a share of
/// the measured time, and the reason `WholePercentMath` must not be used to derive one.
public enum ZoneTimeMath {

    /// What the first sample of a stream is credited with.
    ///
    /// One second rather than zero: a single reading is still a measurement of that instant, and a
    /// stream of readings a second apart is what the strap normally produces.
    public static let firstSampleSeconds: TimeInterval = 1.0

    /// The longest interval one sample can be credited with.
    ///
    /// A strap that stopped notifying for a minute did not measure that minute at the rate it last
    /// reported, so the gap is capped rather than spread over the reading that follows it.
    public static let maximumIntervalSeconds: TimeInterval = 5.0

    /// A completed stream's zone time, and the span it was taken over.
    ///
    /// `zoneSeconds` is always five entries in `HeartRateZoneIndex` order, so a caller can read a
    /// band by index without re-deriving the order.
    public struct Totals: Equatable, Sendable {
        public let zoneSeconds: [Double]

        /// Every credited interval, **including time below zone 1** — which is why the five band
        /// times sum to at most this and not to it.
        public let measuredSeconds: Double

        /// How many readings contributed. `0` never happens: `totals` returns `nil` instead.
        public let sampleCount: Int

        public init(zoneSeconds: [Double], measuredSeconds: Double, sampleCount: Int) {
            self.zoneSeconds = zoneSeconds
            self.measuredSeconds = measuredSeconds
            self.sampleCount = sampleCount
        }

        /// Time in one band, by index rather than by array position.
        public func seconds(in zone: HeartRateZoneIndex) -> Double {
            let index = zone.rawValue - 1
            guard zoneSeconds.indices.contains(index) else { return 0 }
            return zoneSeconds[index]
        }
    }

    /// The interval a sample is credited with, before any zone is decided.
    ///
    /// No `max(0, …)`: every repository read returns samples in ascending order (`StrainDayMath`
    /// documents the contract), and clamping here would hide an unsorted stream rather than show it.
    public static func intervalSeconds(
        previousTimestamp: Date?, timestamp: Date
    ) -> TimeInterval {
        guard let previousTimestamp else { return firstSampleSeconds }
        return min(maximumIntervalSeconds, timestamp.timeIntervalSince(previousTimestamp))
    }

    /// One sample's contribution: which band it fell in, how long it is credited with, and its load.
    ///
    /// **No zero filtering here.** The live accumulator refuses a `0` bpm reading before calling
    /// this, and the day model counts it as a zero-load sample — both are callers' rules, and the
    /// shared unit is the arithmetic they agree on rather than the admissibility rule they do not.
    public static func delta(
        heartRate: Int,
        previousTimestamp: Date?,
        timestamp: Date,
        zones: [HeartRateZone],
        restingHeartRate: Int
    ) -> (zone: HeartRateZoneIndex?, durationSeconds: TimeInterval, load: Double) {
        let duration = intervalSeconds(
            previousTimestamp: previousTimestamp, timestamp: timestamp)
        let (zone, load) = StrainAccumulatorMath.loadDelta(
            for: heartRate,
            zones: zones,
            restingHeartRate: restingHeartRate,
            durationSeconds: duration)
        return (zone, duration, load)
    }

    /// Folds a completed, ascending sample stream into its zone times.
    ///
    /// **A reading of `0` is refused**, on the live accumulator's rule: no worn strap reports a zero
    /// heart rate, so it is a decode artefact, and admitting it would credit time to a reading no
    /// sensor produced. Refusing it leaves the previous timestamp where it was, so the next real
    /// reading spans the interval that the artefact sat inside.
    ///
    /// `nil` for a stream with no usable reading — an absence, not a measured zero — and for a zone
    /// table that is not five bands long, which cannot name the five it would be folded into.
    public static func totals(
        samples: [BiometricSample],
        zones: [HeartRateZone],
        restingHeartRate: Int
    ) -> Totals? {
        guard zones.count == HeartRateZoneIndex.allCases.count else { return nil }

        var zoneDurations: [HeartRateZoneIndex: Double] = [:]
        var measuredSeconds: Double = 0
        var sampleCount: Int = 0
        var previousTimestamp: Date?

        for sample in samples where sample.heartRate > 0 {
            let delta = delta(
                heartRate: sample.heartRate,
                previousTimestamp: previousTimestamp,
                timestamp: sample.timestamp,
                zones: zones,
                restingHeartRate: restingHeartRate)

            if let zone = delta.zone {
                zoneDurations[zone, default: 0] += delta.durationSeconds
            }
            measuredSeconds += delta.durationSeconds
            sampleCount += 1
            previousTimestamp = sample.timestamp
        }

        guard sampleCount > 0 else { return nil }

        return Totals(
            zoneSeconds: HeartRateZoneIndex.allCases.map { zoneDurations[$0] ?? 0 },
            measuredSeconds: measuredSeconds,
            sampleCount: sampleCount)
    }
}
