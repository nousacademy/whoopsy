import Foundation

/// Three axes of one sensor, as one record carries them.
///
/// A named triple rather than a tuple, because a tuple cannot be a stored property of an `Equatable`
/// struct and every batch below wants to be compared in a fixture. The arrays are equal length by
/// construction — the decoder refuses a record whose lanes do not fit, so nothing downstream has to
/// re-check.
public struct MotionAxes: Sendable, Equatable {
    public let x: [Double]
    public let y: [Double]
    public let z: [Double]

    public init(x: [Double], y: [Double], z: [Double]) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// One record's worth of motion: three axes at 100 Hz, and when they were measured.
///
/// **This is the seam the two generations meet at.** A 4.0's live stream and a 5.0's drained history
/// are different envelopes, different record types and different layouts, and they produce this —
/// which is what lets one pedometer, one stored row and one screen serve both.
///
/// ## Why this is a domain entity and not a wire type
///
/// It sits here, beside `BiometricSample`, for the same reason that one does: it is **a measurement
/// the strap took**, and the shape of the bytes it arrived in is not part of what it means. The
/// decoders in `Data/BLE/Parser/` construct it; the pedometer in `Core/Math/` consumes its
/// primitives; `WhoopBLEDeviceRepository` — a `Domain` protocol — can only expose it if it lives on
/// this side of the line. A wire type in `Data/` would have forced the stream protocol, the
/// accumulator's caller and the use case above it all into `Data/`, or forced a second parallel type
/// with a translation layer between them that carried no information.
///
/// Nothing here is wire-shaped: there is no length, no checksum, no offset and no `Data`.
public struct MotionBatch: Sendable, Equatable {
    public let generation: WhoopHardwareGeneration

    /// The instant of the batch's **first** sample.
    public let start: Date

    /// Whether `start` came off the strap's own clock, or is the instant the app heard the record.
    ///
    /// **This is the day-keying rule, made explicit at the call site rather than implied by the
    /// generation.** An R21 record carries the strap's unix time in its own bytes, so a drained
    /// record from last night is stamped last night. The 4.0's live record carries no timestamp this
    /// app can read, and for a live stream that is not a loss — the record arrives as it is measured,
    /// so the arrival instant *is* the measurement instant, the same convention
    /// `BiometricSample.timestamp` already documents. A caller keying a day must know which of the
    /// two it is holding, because the banked one is the one that can be wrong: a strap with a flat
    /// battery stamps every record with a wrong offset, and that files history onto a wrong day
    /// rather than onto no day.
    public let timestampIsFromStrap: Bool

    /// The spacing between consecutive samples within each axis.
    ///
    /// Carried rather than assumed to be `1/100`, so a second record family at a different rate would
    /// arrive through this type without every consumer having to be re-read. Both layouts in use are
    /// 100 Hz.
    public let sampleIntervalSeconds: Double

    public let accelerometerG: MotionAxes

    /// `nil` when the record carries no gyroscope lane.
    ///
    /// Optional because it is a second sensor and not every layout this app reads necessarily carries
    /// one — a defaulted zero triple would be a fabricated reading of exactly the kind the absence
    /// rule forbids. Nothing in the step path reads it: steps are counted from acceleration, and the
    /// gyroscope is decoded because it is in the same record and costs nothing, not because the
    /// pedometer needs it.
    public let gyroscopeDps: MotionAxes?

    public init(
        generation: WhoopHardwareGeneration,
        start: Date,
        timestampIsFromStrap: Bool,
        sampleIntervalSeconds: Double,
        accelerometerG: MotionAxes,
        gyroscopeDps: MotionAxes?
    ) {
        self.generation = generation
        self.start = start
        self.timestampIsFromStrap = timestampIsFromStrap
        self.sampleIntervalSeconds = sampleIntervalSeconds
        self.accelerometerG = accelerometerG
        self.gyroscopeDps = gyroscopeDps
    }
}
