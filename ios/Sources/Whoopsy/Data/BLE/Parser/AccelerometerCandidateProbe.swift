import Foundation

/// A diagnostic reading of the `R18` record's **accelerometer triplet** — the signal the sleep
/// classifier's stillness spine reads.
///
/// **This is instrumentation, and it writes no health value.** `HeartRatePayloadDecoder` reads body 24
/// at payload 34/38/42 as three `f32` in g and refuses a magnitude outside 0.5–2 g. That decode is the
/// only producer of `SampleStillnessMath`'s input, and it is the one link in the sleep chain that has
/// never been checked against a real record: the reference says "body 24", the offsets are arithmetic
/// from body 1 at payload 11, and a wrong origin here does not raise — it produces either `nil`
/// (magnitude out of band) or a plausible vector that is not acceleration at all.
///
/// **Why it is needed rather than merely nice.** Measured 2026-10-26 and 2026-10-30, two nights whose
/// stillness windows existed only at the hours the phone was connected and not for the core of the
/// night: the classifier then reports a night that is exactly the connected window — 22:37–23:08 on the
/// 30th — and the reclassification gate freezes it, because a morning connection supplies epochs after
/// its end. The `decisions.txt` line added beside this probe prints the same night's magnitude quantiles;
/// this file prints the **per-record** values underneath them, so "no windows" can be told apart from
/// "windows that read as movement".
///
/// It gates on the same 0.5–2 g band the decoder uses and reports an out-of-band vector as `out`
/// rather than clamping it: an impossible magnitude is evidence about the offsets, not a reading.
public enum AccelerometerCandidateProbe {

    /// The record's unix stamp, shared with the heart-rate, oxygen and temperature walks.
    public static let unixPayloadOffset = 4

    /// The three `f32` offsets the decoder reads, as body 24 counted from body 1 at payload 11.
    public static let xPayloadOffset = 34
    public static let yPayloadOffset = 38
    public static let zPayloadOffset = 42

    /// The band a wrist under gravity cannot leave.
    public static let plausibleMagnitude: ClosedRange<Double> = 0.5...2

    public struct Observation: Sendable, Equatable {
        public let unix: UInt32
        public let x: Double
        public let y: Double
        public let z: Double
        public let isPlausible: Bool

        public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
    }

    /// Decodes the triplet out of an R18 record, or returns `nil` for anything else.
    public static func decode(frame: WhoopRawFrame) -> Observation? {
        switch frame.generation {
        case .whoop5, .whoop5MG:
            break
        case .whoop4, .standardBleHR, .simulator:
            return nil
        }
        guard let profile = WhoopProtocolProfile.profile(for: frame.generation),
              frame.type == profile.packetTypes.historicalData,
              frame.seq == HeartRatePayloadDecoder.historicalLayout,
              frame.payload.count == HeartRatePayloadDecoder.r18PayloadBytes
        else { return nil }
        return decode(payload: frame.payload)
    }

    /// The same decode over a bare payload, which is what the suite hands it.
    public static func decode(payload: Data) -> Observation? {
        guard payload.count >= zPayloadOffset + 4 else { return nil }
        let base = payload.startIndex

        var unix: UInt32 = 0
        for index in 0..<4 {
            unix |= UInt32(payload[base + unixPayloadOffset + index]) << (8 * UInt32(index))
        }

        func float(at offset: Int) -> Double? {
            let bits = UInt32(payload[base + offset])
                | UInt32(payload[base + offset + 1]) << 8
                | UInt32(payload[base + offset + 2]) << 16
                | UInt32(payload[base + offset + 3]) << 24
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        }

        guard let x = float(at: xPayloadOffset),
              let y = float(at: yPayloadOffset),
              let z = float(at: zPayloadOffset)
        else { return nil }

        let observation = Observation(unix: unix, x: x, y: y, z: z, isPlausible: false)
        return Observation(
            unix: unix, x: x, y: y, z: z,
            isPlausible: plausibleMagnitude.contains(observation.magnitude))
    }

    /// One line per record, the shape `SkinTemperatureCandidateProbe` uses so the two can be read
    /// side by side.
    public static func line(for observation: Observation, at date: Date) -> String {
        "accelprobe unix=\(observation.unix) at=\(date.ISO8601Format()) "
            + "x=\(String(format: "%.4f", observation.x)) "
            + "y=\(String(format: "%.4f", observation.y)) "
            + "z=\(String(format: "%.4f", observation.z)) "
            + "mag=\(String(format: "%.4f", observation.magnitude)) "
            + (observation.isPlausible ? "in" : "out")
    }

    /// The drain's closing summary: how many records were walked and how many carried a plausible
    /// vector — the number that says whether body 24 is where this code says it is.
    public static func summary(_ observations: [Observation]) -> String {
        let plausible = observations.filter(\.isPlausible)
        guard !plausible.isEmpty else {
            return "accelprobe summary records=\(observations.count) in-band=0 "
                + "mean=none min=none max=none"
        }
        let magnitudes = plausible.map(\.magnitude)
        let mean = magnitudes.reduce(0, +) / Double(magnitudes.count)
        return "accelprobe summary records=\(observations.count) in-band=\(plausible.count) "
            + "mean=\(String(format: "%.3f", mean)) "
            + "min=\(String(format: "%.3f", magnitudes.min() ?? 0)) "
            + "max=\(String(format: "%.3f", magnitudes.max() ?? 0))"
    }
}

/// The drain's running tally for the accelerometer probe, on `SkinTemperatureAccumulator`'s pattern.
public struct AccelerometerAccumulator: Sendable {

    /// The same dump budget the other two probes use — three raw lines per drain, because the summary
    /// is what is read and the lines exist only to show the shape of one record.
    public static let maximumRawLines = 3

    private var examined = 0
    private var plausible = 0
    private var sum = 0.0
    private var low = Double.greatestFiniteMagnitude
    private var high = -Double.greatestFiniteMagnitude
    private var rawLines = 0
    private var firstUnix: UInt32?
    private var lastUnix: UInt32?

    public init() {}

    /// Clears the drain's counters. Called under the drain lock, with the other two probes.
    public mutating func reset() { self = AccelerometerAccumulator() }

    /// Records one observation, returning a raw line for the first few.
    public mutating func observe(_ observation: AccelerometerCandidateProbe.Observation) -> String? {
        examined += 1
        firstUnix = firstUnix ?? observation.unix
        lastUnix = observation.unix

        if observation.isPlausible {
            plausible += 1
            sum += observation.magnitude
            low = min(low, observation.magnitude)
            high = max(high, observation.magnitude)
        }

        guard rawLines < Self.maximumRawLines else { return nil }
        rawLines += 1
        let date = Date(timeIntervalSince1970: TimeInterval(observation.unix))
        return AccelerometerCandidateProbe.line(for: observation, at: date)
    }

    /// The drain's summary, or `nil` when it carried no R18 record.
    public func summary() -> String? {
        guard examined > 0 else { return nil }
        let span = "\(firstUnix.map { Date(timeIntervalSince1970: TimeInterval($0)).ISO8601Format() } ?? "-")"
            + "..\(lastUnix.map { Date(timeIntervalSince1970: TimeInterval($0)).ISO8601Format() } ?? "-")"
        let figures = plausible == 0
            ? "in-band=0 mean=none range=none"
            : "in-band=\(plausible) mean=\(String(format: "%.3f", sum / Double(plausible)))"
                + " range=\(String(format: "%.3f", low))..\(String(format: "%.3f", high))"
        return "accelprobe summary records=\(examined) \(figures) span=\(span)"
    }
}
