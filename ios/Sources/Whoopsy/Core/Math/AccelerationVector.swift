import Foundation

/// The strap's mean acceleration for one second, as `R18` body 24 carries it.
///
/// **Three axes, not a magnitude.** A wrist turning over can keep |a| at 1 g while changing direction,
/// so a consumer that only kept the magnitude would see no movement in exactly the case a pedometer
/// miscounts. `magnitude` exists for the plausibility gate and for readers whose question really is
/// "how much", but the stillness and step gates difference the axes.
public struct AccelerationVector: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    /// `|a|` — ≈1 g for a wrist at rest, because gravity is inside it.
    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }

    /// The change since another vector, `|Δa|` — 0 when still, rising when the wrist moves.
    public func delta(from other: AccelerationVector) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        let dz = z - other.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}
