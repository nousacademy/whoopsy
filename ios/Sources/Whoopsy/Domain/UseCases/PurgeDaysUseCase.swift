import Foundation

/// Removes a span of days the app got wrong — here, and in the database when the sync API is the
/// destination.
///
/// **The server is called first, and that order is the whole design.** `docs/GOTCHAS.md` records the
/// measurement this exists to answer: a local delete while the destination is the API is *a cache
/// eviction*, because the next read is a local miss and the decorator reaches the database — measured
/// 2026-10-20, a repaired step row came straight back on the launch that cleared it. So:
///
/// 1. if the destination is `WHOOPSY SYNC API`, every resource's range is deleted **first**, and a
///    throw aborts the whole operation with nothing local touched;
/// 2. only then does the phone forget the days.
///
/// **Refusing rather than degrading, and that is the one place this app does.** Every other cloud call
/// degrades to the local copy on `.unreachable`, because a missing figure is acceptable and a wrong one
/// is not. A delete has no local copy to degrade *to*: reporting success for a removal that did not
/// happen leaves the day on the server, draws it as gone on this phone, and puts it back on the next
/// launch. Failing loudly is the only answer that stays true.
///
/// **It validates its own range** rather than trusting the screen, with the same two rules the Worker
/// enforces — `from <= to`, and at most `Self.maximumDays` — so a caller that could not reach the
/// server still cannot ask for something the server would refuse. The bound is 31 because the control
/// is a pair of hand-picked dates and a delete has no undo.
public actor PurgeDaysUseCase {

    /// The widest span one run may remove, in calendar days, inclusive at both ends.
    ///
    /// Deliberately the Worker's own `MAX_DELETE_DAYS`. It is written down twice — once per half of a
    /// two-repository contract — because each half must refuse on its own: the client may be asked to
    /// purge with no server configured, and the server must not depend on a client that behaves.
    public static let maximumDays = 31

    /// What a run removed.
    public struct Report: Equatable, Sendable {
        /// How many calendar days the range covered, inclusive at both ends.
        public let days: Int
        /// What the phone removed.
        public let local: DayPurgeTally
        /// What the database removed, or `nil` when the destination is `DEVICE STORAGE` and the server
        /// was never asked.
        public let remote: PurgeTally?

        public init(days: Int, local: DayPurgeTally, remote: PurgeTally?) {
            self.days = days
            self.local = local
            self.remote = remote
        }

        /// The sentence the status line prints.
        ///
        /// **It names what went rather than reporting a total**, because the number that matters is
        /// not the same on both sides — a day holds tens of thousands of samples and one recovery —
        /// and a reader who pressed delete on three days wants to see that the samples went with them.
        public var message: String {
            let dayWord = days == 1 ? "day" : "days"

            guard local.total > 0 else {
                return "Nothing stored for those \(days) \(dayWord) — the range held no measurements."
            }

            var parts: [String] = []
            func add(_ count: Int, _ singular: String, _ plural: String) {
                guard count > 0 else { return }
                parts.append("\(count.formatted(.number.grouping(.automatic))) \(count == 1 ? singular : plural)")
            }
            add(local.recoveries, "recovery", "recoveries")
            add(local.sleeps, "night", "nights")
            add(local.strains, "strain day", "strain days")
            add(local.stepCounts, "step day", "step days")
            add(local.naps, "nap", "naps")
            add(local.motionEpochs, "motion window", "motion windows")
            add(local.samples, "sample", "samples")

            var sentence = "Deleted \(days) \(dayWord) here: " + Self.list(parts) + "."

            if let remote {
                sentence += remote.total > 0
                    ? " The sync API removed \(remote.total.formatted(.number.grouping(.automatic))) "
                        + "\(remote.total == 1 ? "row" : "rows")."
                    : " The sync API had nothing stored for them."
            }
            return sentence
        }

        /// `a, b and c` — one joining rule, so the two sentences above read the same way.
        private static func list(_ parts: [String]) -> String {
            guard parts.count > 1 else { return parts.first ?? "" }
            return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    /// Why a run did not happen.
    ///
    /// `cloudFailed` is the one that deletes nothing and must be visible: it means the phone still holds
    /// the days exactly as it did, because the copy that would put them back could not be reached.
    public enum Refusal: Error, LocalizedError, Equatable {
        case reversedRange(from: Date, to: Date)
        case tooWide(days: Int)
        case cloudFailed(message: String)

        public var errorDescription: String? {
            switch self {
            case .reversedRange:
                return "The first day must not be later than the last. Nothing was deleted."
            case let .tooWide(days):
                return "That range spans \(days) days; at most \(PurgeDaysUseCase.maximumDays) can be "
                    + "deleted at once. Nothing was deleted."
            case let .cloudFailed(message):
                return "Could not reach the sync API, so nothing was deleted here either — the days "
                    + "would have come back on the next read. \(message)"
            }
        }
    }

    private let cloud: any CloudSync
    private let store: any DayPurgeStore
    private let settingsStore: any SyncSettingsRepository
    private let calendar: Calendar

    public init(
        cloud: any CloudSync,
        store: any DayPurgeStore,
        settingsStore: any SyncSettingsRepository,
        calendar: Calendar = .current
    ) {
        self.cloud = cloud
        self.store = store
        self.settingsStore = settingsStore
        self.calendar = calendar
    }

    /// Remove `from…to`, inclusive at both ends, and answer with what went.
    ///
    /// Throws `Refusal` for a range this will not accept, or the cloud's own error wrapped as
    /// `.cloudFailed` — in which case **nothing has been deleted anywhere**.
    public func run(from: Date, to: Date) async throws -> Report {
        let first = from.startOfDay
        let last = to.startOfDay

        guard first <= last else {
            throw Refusal.reversedRange(from: first, to: last)
        }
        let days = (calendar.dateComponents([.day], from: first, to: last).day ?? 0) + 1
        guard days <= Self.maximumDays else {
            throw Refusal.tooWide(days: days)
        }

        // **The database first.** A throw here is the end of the operation, not a degradation: see the
        // type's comment for why a local delete without it is a cache eviction rather than a delete.
        var remote: PurgeTally?
        if await settingsStore.load().destination == .cloud {
            do {
                remote = try await cloud.purge(from: first, to: last)
            } catch {
                throw Refusal.cloudFailed(message: error.localizedDescription)
            }
        }

        let local = try await store.purgeMeasuredDays(from: first, to: last)
        return Report(days: days, local: local, remote: remote)
    }
}
