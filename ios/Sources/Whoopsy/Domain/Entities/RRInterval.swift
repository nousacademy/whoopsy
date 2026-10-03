import Foundation

/// Represents a beat-to-beat (R-R) interval in milliseconds.
public struct RRInterval: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let milliseconds: Double
    public let isValid: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        milliseconds: Double,
        isValid: Bool = true
    ) {
        self.id = id
        self.timestamp = timestamp
        self.milliseconds = milliseconds
        self.isValid = isValid
    }
}
