import Foundation

/// What a HealthKit import actually did.
///
/// The counts are the point. HealthKit cannot report whether read access was granted, so the only
/// honest signal that an import worked is whether it found data — a user who tapped "Don't Allow"
/// and a user with an empty history produce the same authorization result, and this summary is what
/// tells them apart.
public struct HealthImportSummary: Sendable, Equatable {
    /// Days the caller asked for.
    public let daysRequested: Int
    /// Days that produced a stored recovery row.
    public let daysImported: Int
    /// Days inside the window that had no usable reading and were skipped.
    public let daysWithoutData: Int
    /// Days skipped because a recovery row already existed locally.
    ///
    /// Counted separately from `daysWithoutData` because the two mean opposite things: one is
    /// "HealthKit had nothing", the other is "this app already had a measurement". Folding them
    /// together would report a healthy strap-recorded history as a failed import.
    public let daysAlreadyRecorded: Int
    /// Which HRV metric was imported.
    public let metric: HRVMetric

    public init(
        daysRequested: Int, daysImported: Int, daysWithoutData: Int, daysAlreadyRecorded: Int,
        metric: HRVMetric
    ) {
        self.daysRequested = daysRequested
        self.daysImported = daysImported
        self.daysWithoutData = daysWithoutData
        self.daysAlreadyRecorded = daysAlreadyRecorded
        self.metric = metric
    }

    public static func empty(daysRequested: Int, metric: HRVMetric = .sdnn) -> HealthImportSummary {
        HealthImportSummary(
            daysRequested: daysRequested, daysImported: 0, daysWithoutData: 0,
            daysAlreadyRecorded: 0, metric: metric)
    }

    /// Written for the person reading it, who needs to distinguish "granted nothing" from
    /// "granted, and there was nothing to bring over".
    public var message: String {
        let day = daysRequested == 1 ? "day" : "days"
        guard daysImported > 0 else {
            if daysAlreadyRecorded > 0 {
                return "No new HealthKit data for the last \(daysRequested) \(day) — "
                    + "\(daysAlreadyRecorded) already recorded by your strap."
            }
            if daysWithoutData > 0 {
                return "No HealthKit \(metric.displayName) data found for the last "
                    + "\(daysRequested) \(day). Check that Health access is allowed in "
                    + "Settings › Privacy › Health."
            }
            return "No HealthKit data found for the last \(daysRequested) \(day)."
        }

        var text = "Imported \(daysImported) \(day) of \(metric.displayName) data."
        if daysAlreadyRecorded > 0 { text += " \(daysAlreadyRecorded) already recorded." }
        if daysWithoutData > 0 { text += " \(daysWithoutData) had no reading." }
        return text
    }
}
