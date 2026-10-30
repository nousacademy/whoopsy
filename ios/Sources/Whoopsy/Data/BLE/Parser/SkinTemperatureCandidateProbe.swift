import Foundation

/// A diagnostic reading of the 5.0/MG `R18` record's **skin-temperature candidates**.
///
/// **This is instrumentation, and it writes no health value.** The community reference's sensor
/// document names a skin-temperature field in the 5.0 record family — `u16` little-endian, encoded as
/// raw ÷ 100 °C, plausible 5–45 °C — but the document and this codebase disagree about which byte
/// origin a "byte 73" is counted from, and **both conventions are already in use here**:
///
/// - the accelerometer is documented as *body 24* and read at payload 34, so `body N → payload 10 + N`;
/// - the oxygen candidate is documented as *frame byte 82* and read at payload 71, so
///   `frame N → payload N − 11`.
///
/// Under the first, byte 73 is payload **83**; under the second it is payload **62**. Choosing wrong
/// yields a number that still reads as a temperature — the plausible-value failure this repo's
/// absence rules exist to prevent — so the probe reads **both** and logs them beside the record's own
/// stamp. One drained night on a strap whose temperature is known from the official app settles which
/// offset is real, and then the field is one line in `HeartRatePayloadDecoder`.
///
/// The gate is the reference's own plausible range: a candidate outside 5–45 °C is reported as `out`
/// rather than clamped, because an impossible value is evidence about the offset, not a bad reading.
public enum SkinTemperatureCandidateProbe {

    /// The record's unix stamp, shared with the heart-rate and oxygen walks.
    public static let unixPayloadOffset = 4

    /// Byte 73 counted in the **body** coordinate — see the type's comment.
    public static let bodyPayloadOffset = 83

    /// Byte 73 counted in the **envelope frame** coordinate. See the type's comment.
    public static let framePayloadOffset = 62

    /// The reference's plausible range for a wrist thermistor, in °C.
    public static let plausibleCelsius: ClosedRange<Double> = 5...45

    /// Decodes the two candidates out of an R18 record, or returns `nil` for anything else.
    public static func decode(frame: WhoopRawFrame) -> SkinTemperatureObservation? {
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
    public static func decode(payload: Data) -> SkinTemperatureObservation? {
        guard payload.count > max(bodyPayloadOffset, framePayloadOffset) + 1 else { return nil }
        let base = payload.startIndex

        var unix: UInt32 = 0
        for index in 0..<4 {
            unix |= UInt32(payload[base + unixPayloadOffset + index]) << (8 * UInt32(index))
        }
        guard unix > 0 else { return nil }

        func raw(at offset: Int) -> UInt16 {
            UInt16(payload[base + offset]) | (UInt16(payload[base + offset + 1]) << 8)
        }

        return SkinTemperatureObservation(unix: unix, bodyRaw: raw(at: bodyPayloadOffset),
                                          frameRaw: raw(at: framePayloadOffset))
    }
}

/// One decoded pair of candidates, with the record's stamp.
public struct SkinTemperatureObservation: Equatable, Sendable {
    public let unix: UInt32
    public let bodyRaw: UInt16
    public let frameRaw: UInt16

    public init(unix: UInt32, bodyRaw: UInt16, frameRaw: UInt16) {
        self.unix = unix
        self.bodyRaw = bodyRaw
        self.frameRaw = frameRaw
    }

    /// `body N → payload 10 + N`'s candidate, in °C.
    public var bodyCelsius: Double { Double(bodyRaw) / 100.0 }

    /// `frame N → payload N − 11`'s candidate, in °C.
    public var frameCelsius: Double { Double(frameRaw) / 100.0 }

    public var bodyIsPlausible: Bool {
        SkinTemperatureCandidateProbe.plausibleCelsius.contains(bodyCelsius)
    }

    public var frameIsPlausible: Bool {
        SkinTemperatureCandidateProbe.plausibleCelsius.contains(frameCelsius)
    }

    /// One line, shaped for a capture file: both candidates, their raw halves and their verdicts.
    public var captureLine: String {
        let stamp = Date(timeIntervalSince1970: TimeInterval(unix)).ISO8601Format()
        return """
            skintempprobe v=18 unix=\(unix) at=\(stamp) \
            body=\(String(format: "%.2f", bodyCelsius))(\(bodyIsPlausible ? "in" : "out")) \
            frame=\(String(format: "%.2f", frameCelsius))(\(frameIsPlausible ? "in" : "out"))
            """
    }
}

/// Accumulates a drain's candidates and emits **one summary per drain** for each offset.
///
/// The summary is what a validation study needs and the raw lines cannot give: how many records backed
/// each candidate, over what span, and what the values ranged over. A candidate that is in range on
/// every record of every drain is a field; one that is in range on a third of them is not.
public struct SkinTemperatureAccumulator: Sendable {
    /// The same dump budget the oxygen probe uses.
    public static let maximumRawLines = 3

    private var examined = 0
    private var bodyIn = 0
    private var bodySum = 0.0
    private var bodyLow = Double.greatestFiniteMagnitude
    private var bodyHigh = -Double.greatestFiniteMagnitude
    private var frameIn = 0
    private var frameSum = 0.0
    private var frameLow = Double.greatestFiniteMagnitude
    private var frameHigh = -Double.greatestFiniteMagnitude
    private var rawLines = 0
    private var firstUnix: UInt32?
    private var lastUnix: UInt32?

    public init() {}

    /// Clears the drain's counters. Called under the drain lock, with `Spo2CandidateAccumulator.reset`.
    public mutating func reset() {
        self = SkinTemperatureAccumulator()
    }

    /// Records one observation, returning a raw line for the first few.
    public mutating func observe(_ observation: SkinTemperatureObservation) -> String? {
        examined += 1
        firstUnix = firstUnix ?? observation.unix
        lastUnix = observation.unix

        if observation.bodyIsPlausible {
            bodyIn += 1
            bodySum += observation.bodyCelsius
            bodyLow = min(bodyLow, observation.bodyCelsius)
            bodyHigh = max(bodyHigh, observation.bodyCelsius)
        }
        if observation.frameIsPlausible {
            frameIn += 1
            frameSum += observation.frameCelsius
            frameLow = min(frameLow, observation.frameCelsius)
            frameHigh = max(frameHigh, observation.frameCelsius)
        }

        guard rawLines < Self.maximumRawLines else { return nil }
        rawLines += 1
        return observation.captureLine
    }

    /// The drain's summary, or `nil` when it carried no R18 record.
    public func summary() -> String? {
        guard examined > 0 else { return nil }
        let span = "\(firstUnix.map { Date(timeIntervalSince1970: TimeInterval($0)).ISO8601Format() } ?? "-")"
            + "..\(lastUnix.map { Date(timeIntervalSince1970: TimeInterval($0)).ISO8601Format() } ?? "-")"

        func describe(_ count: Int, _ sum: Double, _ low: Double, _ high: Double) -> String {
            guard count > 0 else { return "in=0" }
            return "in=\(count) mean=\(String(format: "%.2f", sum / Double(count)))"
                + " range=\(String(format: "%.2f", low))..\(String(format: "%.2f", high))"
        }

        return """
            skintempprobe summary records=\(examined) \(span) \
            body[\(describe(bodyIn, bodySum, bodyLow, bodyHigh))] \
            frame[\(describe(frameIn, frameSum, frameLow, frameHigh))]
            """
    }
}
