import Foundation

/// Represents a single heart rate reading from the WHOOP strap.
public struct HeartRateReading: Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let bpm: Int
    public let confidence: Double // 0.0 to 1.0

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        bpm: Int,
        confidence: Double = 1.0
    ) {
        self.id = id
        self.timestamp = timestamp
        self.bpm = max(30, min(240, bpm))
        self.confidence = max(0.0, min(1.0, confidence))
    }
}
