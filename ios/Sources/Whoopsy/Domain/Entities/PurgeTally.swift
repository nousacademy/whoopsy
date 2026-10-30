import Foundation

/// What the database removed for a range of days, one number per resource it holds a copy of.
///
/// **Keyed by `SyncedResource` rather than by table, because these are the server's rows.** The phone
/// holds more for a day than the database does — samples, motion epochs, naps — and those are the local
/// purge's business (`DayPurgeTally`). This type answers the other question: how much of *the cloud's*
/// copy went, which is the half that used to come back.
///
/// A missing key means the resource was not purged, which is why the dictionary is not pre-filled with
/// zeros: a run against a build with no API configured reports `nil` for the whole tally rather than
/// claiming four resources were emptied.
public struct PurgeTally: Equatable, Sendable {

    public let rows: [SyncedResource: Int]

    public init(rows: [SyncedResource: Int] = [:]) {
        self.rows = rows
    }

    public var total: Int { rows.values.reduce(0, +) }

    /// The count for one resource, or `0` when it was not part of the run.
    public func count(for resource: SyncedResource) -> Int { rows[resource] ?? 0 }
}
