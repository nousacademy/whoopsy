import Foundation

/// A diagnostic reading of the 5.0/MG record's **candidate** blood-oxygen byte.
///
/// **This is not an SpO2 measurement and must never become one.** The byte is noop's
/// `spo2_candidate_82` (issue #709): a decompile-sourced reading of the official app's `spo2_pct`
/// field at frame byte 82 — payload `[71]` here, because the 5.0 envelope puts the payload origin at
/// frame 11. The official app appears to read it as a **strap-computed percentage**, populated only
/// while the strap believes the wearer is asleep.
///
/// **Why it is a candidate rather than a field this app reads.** On one strap an eight-night
/// validation tracked the official app at a correlation of +0.99 and only byte 82 won a 74–92 offset
/// scan; on the strap of origin two nights moved the opposite way to the app. noop's rule is that
/// nothing may back a shipped metric until that cross-device contradiction is resolved, and this
/// app's own rule is stricter: a byte whose identity is contested is instrumentation, and
/// `BiometricSample.spO2Percentage` is not written from it.
///
/// **The tri-mode gate is noop's, and it is what makes the byte legible rather than plausible.**
/// 70–100 is a reading; a value with bit 7 set (`0x80`, `0xA0`, …) is a saturation sentinel; another
/// sub-70 nonzero value is a diagnostic code. 0 is the normal awake/idle state. 101–127 has never
/// been observed and is deliberately left unclassified rather than folded into a neighbour.
///
/// Offsets are frame-absolute in the reference and payload-relative here:
///
/// | field | frame | payload |
/// | :--- | :--- | :--- |
/// | unix seconds | 15 | 4 |
/// | sleep-state byte | 81 | 70 |
/// | candidate | 82 | 71 |
/// | neighbour bytes for the specificity scan | 74–92 | 63–81 |
public enum Spo2CandidateProbe {
    /// The record's own unix stamp, shared with the heart-rate walk.
    public static let unixPayloadOffset = 4
    /// The byte R18 uses for its on-wrist/motion/rest bitfield; the high nibble's bits 4–5 carry the
    /// band's own sleep state, where `2` is the reference's asleep label.
    public static let sleepStatePayloadOffset = 70
    /// noop's `@82`.
    public static let candidatePayloadOffset = 71
    /// Frame 74–92, the window noop scans to prove byte 82 is not a neighbouring field correlated by
    /// coincidence. Nineteen bytes, logged raw so the scan can be repeated offline.
    public static let neighboursPayloadRange = 63...81

    /// Decodes the candidate out of an R18 record, or returns `nil` for anything else.
    ///
    /// The generation gate is not decoration: the two generations share packet type 47, and a 4.0
    /// record with a stray selector of 18 must not be read as if its payload were this layout. Only
    /// the 5.0 and 5.0 MG emit this one.
    public static func decode(frame: WhoopRawFrame) -> Spo2CandidateObservation? {
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

        let payload = frame.payload
        let base = payload.startIndex
        var unix: UInt32 = 0
        for index in 0..<4 {
            unix |= UInt32(payload[base + unixPayloadOffset + index]) << (8 * UInt32(index))
        }
        let neighbours = neighboursPayloadRange.map { payload[base + $0] }

        return Spo2CandidateObservation(
            unix: unix,
            value: payload[base + candidatePayloadOffset],
            sleepState: payload[base + sleepStatePayloadOffset],
            neighbours: neighbours)
    }
}

/// One decoded candidate byte, with the context needed to read it later.
public struct Spo2CandidateObservation: Equatable, Sendable {
    /// What the byte's value says it is, using noop's tri-mode split.
    public enum Band: String, Equatable, Sendable {
        case inBand = "in-band"
        case sentinel
        case diagnostic
        case absent
        case unclassified
    }

    public let unix: UInt32
    public let value: UInt8
    public let sleepState: UInt8
    public let neighbours: [UInt8]

    public init(unix: UInt32, value: UInt8, sleepState: UInt8, neighbours: [UInt8]) {
        self.unix = unix
        self.value = value
        self.sleepState = sleepState
        self.neighbours = neighbours
    }

    /// The reference's band state is `(byte >> 4) & 3 == 2`; the other bits of the byte are a raw
    /// quality/packing field this app does not interpret.
    public var isAsleep: Bool {
        (sleepState >> 4) & 0x03 == 2
    }

    public var band: Band {
        if value == 0 { return .absent }
        if (70...100).contains(Int(value)) { return .inBand }
        if value & 0x80 != 0 { return .sentinel }
        if value < 70 { return .diagnostic }
        return .unclassified
    }

    /// One line, shaped for a capture file: the raw byte is the evidence and every field that
    /// identified it is on the line beside it.
    public var captureLine: String {
        let stamp = Date(timeIntervalSince1970: TimeInterval(unix)).ISO8601Format()
        let neighboursHex = neighbours.map { String(format: "%02x", $0) }.joined(separator: " ")
        let sleep = String(format: "0x%02x", sleepState)
        return """
            spo2probe v=18 unix=\(unix) at=\(stamp) value=\(value) band=\(band.rawValue) \
            sleep=\(sleep) asleep=\(isAsleep) neighbours=[\(neighboursHex)]
            """
    }
}

/// Accumulates a drain's candidate bytes and emits **one summary per drain**.
///
/// The per-record accounting is deliberately cheap: a drain carries tens of thousands of R18
/// records, and only the raw-line dump is capped. The summary is the figure a validation study
/// needs — an in-band mean for the night, its range, how many samples backed it and when they
/// occurred — and it is a statistic over raw bytes, not a health reading and not a stored value.
public struct Spo2CandidateAccumulator: Sendable {
    /// Noop's dump budget: enough records to run the offset-specificity scan, few enough to keep a
    /// night's file readable. The counters still cover every record.
    public static let maximumRawLines = 3

    private var examined = 0
    private var inBand = 0
    private var asleepInBand = 0
    private var sentinels = 0
    private var diagnostics = 0
    private var absent = 0
    private var unclassified = 0
    private var sumInBand = 0
    private var minimumInBand: UInt8?
    private var maximumInBand: UInt8?
    private var firstInBandUnix: UInt32?
    private var lastInBandUnix: UInt32?
    private var rawLines: [String] = []

    public init() {}

    public var hasObservations: Bool { examined > 0 }

    /// Records one observation and returns a capture line when the dump budget allows one.
    public mutating func observe(_ observation: Spo2CandidateObservation) -> String? {
        examined += 1

        switch observation.band {
        case .inBand:
            inBand += 1
            if observation.isAsleep { asleepInBand += 1 }
            sumInBand += Int(observation.value)
            minimumInBand = min(minimumInBand ?? observation.value, observation.value)
            maximumInBand = max(maximumInBand ?? observation.value, observation.value)
            if firstInBandUnix == nil { firstInBandUnix = observation.unix }
            lastInBandUnix = observation.unix
        case .sentinel:
            sentinels += 1
        case .diagnostic:
            diagnostics += 1
        case .absent:
            absent += 1
        case .unclassified:
            unclassified += 1
        }

        // Only in-band readings carry the evidence the offset scan needs; a dump of zeros would
        // spend the budget proving nothing.
        guard observation.band == .inBand, rawLines.count < Self.maximumRawLines else { return nil }
        let line = observation.captureLine
        rawLines.append(line)
        return line
    }

    /// The drain's single summary line, or `nil` when no R18 record was seen.
    ///
    /// **`mean` is a mean of raw candidate bytes, not a percentage this app believes in.** It is
    /// printed here so a capture can be correlated against an imported night's own value; nothing
    /// writes it to a row, a sample or a screen.
    public func summary() -> String? {
        guard examined > 0 else { return nil }
        let mean = inBand > 0
            ? String(format: "%.1f", Double(sumInBand) / Double(inBand))
            : "none"
        let minimum = minimumInBand.map(String.init) ?? "none"
        let maximum = maximumInBand.map(String.init) ?? "none"
        let first = firstInBandUnix.map { Date(timeIntervalSince1970: TimeInterval($0)).ISO8601Format() } ?? "none"
        let last = lastInBandUnix.map { Date(timeIntervalSince1970: TimeInterval($0)).ISO8601Format() } ?? "none"
        return """
            spo2probe summary r18=\(examined) in-band=\(inBand) mean=\(mean) min=\(minimum) \
            max=\(maximum) asleep=\(asleepInBand) sentinels=\(sentinels) \
            diagnostic=\(diagnostics) absent=\(absent) unclassified=\(unclassified) \
            first=\(first) last=\(last)
            """
    }

    public mutating func reset() {
        self = Spo2CandidateAccumulator()
    }
}
