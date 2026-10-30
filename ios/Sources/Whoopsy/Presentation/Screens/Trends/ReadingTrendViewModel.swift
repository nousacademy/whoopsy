import Foundation
import SwiftUI

/// One reading's trend page — HRV or resting heart rate — over a window: the average above the line,
/// the comparison with the window before, and a band showing what those priors called typical.
///
/// **Every figure comes from stored rows**, through `ReadingTrend`; the page computes nothing else.
/// The two readings share this type because they share the arithmetic — see `ReadingTrend.Kind` for
/// what actually differs between them (a unit, a direction of "better", one extraction).
@MainActor @Observable public final class ReadingTrendViewModel {

    public private(set) var kind: ReadingTrend.Kind

    public private(set) var period: ReadingTrend.Period = .month
    public private(set) var anchor: Date
    public private(set) var trend: ReadingTrend?
    public private(set) var isLoading = false
    public var errorMessage: String?

    private let repository: any RecoveryRepository
    /// The VO₂ estimate's only non-daily input. Optional so the two reading pages need not carry a
    /// dependency they never use; `nil` simply means the estimate has no anchor and draws nothing.
    private let userProfileRepository: (any UserProfileRepository)?
    private let calendar: Calendar

    public init(
        kind: ReadingTrend.Kind,
        repository: any RecoveryRepository,
        userProfileRepository: (any UserProfileRepository)? = nil,
        calendar: Calendar = .current
    ) {
        self.kind = kind
        self.repository = repository
        self.userProfileRepository = userProfileRepository
        self.calendar = calendar
        self.anchor = calendar.startOfDay(for: Date())
    }

    /// Whether the window can move forward — a future month has nothing to show.
    public var canMoveForward: Bool {
        calendar.startOfDay(for: anchor) < calendar.startOfDay(for: Date())
    }

    /// The range the page heads itself with, from the trend's own bounds.
    public var rangeTitle: String {
        guard let trend else { return "" }
        let start = trend.windowStart.formatted(.dateTime.month(.abbreviated).day())
        let end = trend.windowEnd.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))
        return "\(start) - \(end)"
    }

    public func select(_ period: ReadingTrend.Period) async {
        guard period != self.period else { return }
        self.period = period
        await load()
    }

    /// Moves the window one period at a time; forward stops at today.
    public func move(by windows: Int) async {
        guard windows != 0 else { return }
        if windows > 0, !canMoveForward { return }
        guard let moved = calendar.date(
            byAdding: .day, value: period.dayCount * windows, to: anchor)
        else { return }
        let today = calendar.startOfDay(for: Date())
        anchor = min(calendar.startOfDay(for: moved), today)
        await load()
    }

    /// Reads the window **and the one before it** — the comparison and the band both come from the
    /// prior days, so the read is twice the period wide plus a week of slack for the month edges.
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await repository.getRecoveryHistory(
                days: period.dayCount * 2 + 7, endingOn: anchor)
            // Read only for the estimate: the other kinds have no non-daily input, and a profile
            // this app cannot read leaves the VO₂ page empty rather than anchored to an invented
            // maximum.
            let maxHeartRate = try? await userProfileRepository?.getUserProfile().maxHeartRate
            trend = ReadingTrend.make(
                rows: rows, anchor: anchor, period: period, kind: kind,
                maxHeartRate: maxHeartRate ?? nil, calendar: calendar)
            errorMessage = nil
            CaptureLog.shared.append(
                "TREND page kind=\(kind.rawValue) period=\(period.rawValue) anchor=\(anchor.ISO8601Format()) "
                    + "metric=\(trend?.hrvMetric?.rawValue ?? "-") measured=\(trend?.measuredDays ?? 0) "
                    + "average=\(trend?.average.map { String(format: "%.1f", $0) } ?? "-")")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
