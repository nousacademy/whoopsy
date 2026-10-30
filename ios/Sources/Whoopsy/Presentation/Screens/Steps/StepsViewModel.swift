import Foundation
import SwiftUI

/// The steps trend page: one window's daily counts, their mean, and the period the reader chose.
///
/// **It reads and never computes a step count.** Every number on the page comes from `stepCounts`
/// through `StepCount.measuredStepCount`, the same gate Home's tile and the strain page's row use; the
/// only arithmetic is `StepsTrend`'s, which is a value the runner can assert. There is no goal on this
/// page because the app has no goal to read — see the page's own note.
@MainActor @Observable public final class StepsViewModel {

    public private(set) var period: StepsTrend.Period = .week

    /// The last day of the window on screen. The page opens on today and the chevrons move it.
    public private(set) var anchor: Date

    public private(set) var trend: StepsTrend?
    public private(set) var isLoading = false
    public var errorMessage: String?

    private let repository: any StepRepository
    private let calendar: Calendar

    public init(repository: any StepRepository, calendar: Calendar = .current) {
        self.repository = repository
        self.calendar = calendar
        self.anchor = calendar.startOfDay(for: Date())
    }

    /// Whether the window can move forward — a future week has nothing to show, and a control that
    /// moved there would draw a page of gaps under a future date.
    public var canMoveForward: Bool {
        calendar.startOfDay(for: anchor) < calendar.startOfDay(for: Date())
    }

    /// The range the page heads itself with, from the trend's own bounds.
    public var rangeTitle: String {
        guard let trend else { return "" }
        let start = trend.windowStart.formatted(.dateTime.month(.abbreviated).day())
        let end = trend.windowEnd.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(start) – \(end)"
    }

    public func select(_ period: StepsTrend.Period) async {
        guard period != self.period else { return }
        self.period = period
        // A shorter period ending on the same day keeps the reader's place; the window is recomputed
        // from that day, not from "today", so switching periods does not jump the page.
        await load()
    }

    /// Moves the window one period forward (`+1`) or back (`-1`).
    ///
    /// The step is one whole window, which is what the chevrons mean: a week back is the previous
    /// week, a month back the previous thirty days. Forward stops at today.
    public func move(by windows: Int) async {
        guard windows != 0 else { return }
        if windows > 0, !canMoveForward { return }
        let days = period.dayCount * windows
        guard let moved = calendar.date(byAdding: .day, value: days, to: anchor) else { return }
        let today = calendar.startOfDay(for: Date())
        anchor = min(calendar.startOfDay(for: moved), today)
        await load()
    }

    /// Reads the window and builds the trend.
    ///
    /// The read is one day wider than the window at the start — a weekly bucket is aligned to its own
    /// week and can begin before the window's first day — and `StepsTrend` counts only the days inside
    /// the window, so the extra days cannot leak into the average.
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await repository.getStepCountHistory(
                days: period.dayCount + 7, endingOn: anchor)
            trend = StepsTrend.make(
                rows: rows, anchor: anchor, period: period, calendar: calendar)
            errorMessage = nil
            CaptureLog.shared.append(
                "STEPS page period=\(period.rawValue) anchor=\(anchor.ISO8601Format()) "
                    + "points=\(trend?.points.count ?? 0) measured=\(trend?.measuredSlots ?? 0) "
                    + "average=\(trend?.average.map(String.init) ?? "-")")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
