import Foundation

/// One of the five heart-rate zone rows under the session's chart: the band's edges, the time the
/// session spent inside it, and — when there is history — the time a typical session of the same
/// activity spends there.
///
/// ## Why this is a value and not five lines in a `body`
///
/// `DayBarRules`' reason, which applies to every rule this page draws that a person would otherwise
/// write inline: the runner that tests this app has no renderer, so a derivation written into a `View`
/// is a derivation nothing can assert. Three things here are worth asserting and none of them is
/// visible in a screenshot — the pairing of a row's time with its bar, the ordering of the five rows,
/// and the difference between an absent measurement and a measured zero.
///
/// ## A row's time comes from exactly one producer
///
/// Two producers can name a session's time in a band, and a row uses one of them, never a mean of the
/// two:
///
/// - **`.measured`** — this app's own `ZoneTimeMath.totals` folded from the session's heart-rate
///   samples. Every session this app recorded has this, and it is the path that made the page's five
///   dashes into figures.
/// - **`.imported`** — WHOOP's own `HR Zone n %` block scaled by the session's length, through
///   `WorkoutSession.zoneSeconds(_:)`. A session the app did not record has only this.
///
/// **Measured wins when both are present**, because it is this session's actual readings rather than
/// a percentage WHOOP rounded to a whole number. A row averaging the two would be a figure from
/// neither producer — the defect `RecoveryScoring` avoids by never mixing a computed need with an
/// imported one.
///
/// ## The absences are different, and only one of them is a dash
///
/// `seconds` is `nil` only when the session has neither samples nor a valid block — then all five
/// rows draw a dash. **A stored zero is a measurement**: the bundled export has rows reading `0` in
/// every band (workouts that never reached zone 1), and `.measured` produces a real zero whenever the
/// session's readings all sat below zone 1. Those print `0:00:00`, never a dash.
///
/// ## The five times need not sum to the session
///
/// Time below zone 1 is measured time that belongs to no band, so the five band times sum to at most
/// the measured span — the same shortfall `WorkoutSession`'s own doc records, and the reason
/// `WholePercentMath.wholePercents(ofSeconds:)` must not be used to derive a share of a session.
///
/// ## The bar scale is the block's, not the row's
///
/// Every bar in the block is a fraction of `scaleSeconds` — the largest time anywhere in the block,
/// session or average. A per-row scale would draw zone 2 as long as zone 5; a session-length scale
/// would draw every bar as a sliver. One scale also makes the grey average mark comparable with the
/// session's own bar on the same track, which is the whole point of drawing the two together.
public struct ActivityZoneRow: Equatable, Sendable {

    /// Which producer a row's `seconds` came from. `nil` exactly when `seconds` is.
    public enum Source: Equatable, Sendable {
        /// This app's own `ZoneTimeMath` fold over the session's heart-rate samples.
        case measured
        /// WHOOP's `HR Zone n %` block, scaled by the session's length.
        case imported
    }

    public let index: HeartRateZoneIndex

    /// The band's own edges, out of the profile's zone table. `upperBpm` is `maxHR` for zone 5 and is
    /// drawn as an open end rather than a ceiling — see `bpmRangeText`.
    public let lowerBpm: Int
    public let upperBpm: Int

    /// This session's time in the band, or `nil` when it has neither samples nor a valid block.
    public let seconds: Double?

    /// Which producer `seconds` came from; `nil` with it.
    public let source: Source?

    /// Mean time in the band over the prior sessions of this activity that carried samples, or `nil`
    /// below `ActivityZoneBaseline`'s floor — and `nil` on every row of a session that has no time of
    /// its own, because a marker beside a dash is a comparison with one side missing.
    public let averageSeconds: Double?

    /// How many prior sessions the mean was taken over; `nil` with `averageSeconds`.
    public let averageSessionCount: Int?

    /// Seconds at full track width. One value for every row in the block.
    public let scaleSeconds: Double

    /// `seconds / scaleSeconds`, clamped to `0…1`. `0` when `seconds` is nil.
    public let barFraction: Double

    /// `averageSeconds / scaleSeconds`, or `nil` with it.
    public let averageFraction: Double?

    private init(
        index: HeartRateZoneIndex,
        lowerBpm: Int,
        upperBpm: Int,
        seconds: Double?,
        source: Source?,
        averageSeconds: Double?,
        averageSessionCount: Int?,
        scaleSeconds: Double,
        barFraction: Double,
        averageFraction: Double?
    ) {
        self.index = index
        self.lowerBpm = lowerBpm
        self.upperBpm = upperBpm
        self.seconds = seconds
        self.source = source
        self.averageSeconds = averageSeconds
        self.averageSessionCount = averageSessionCount
        self.scaleSeconds = scaleSeconds
        self.barFraction = barFraction
        self.averageFraction = averageFraction
    }

    /// The five rows for a session, **highest band first**.
    ///
    /// The order is the reference's and it is decided here rather than by a `reversed()` in the page's
    /// `body`, because an ordering is a rule: the runner can assert this array's first element and
    /// cannot see a `ForEach` that happens to walk it backwards.
    ///
    /// `zones` is the profile's table — `StrainAccumulatorMath.computeZones(maxHR:restHR:)` — and a
    /// table that is not five bands long answers **no rows at all** rather than a partial list. A page
    /// drawing three of five zones would be reporting a session's time as if the two hardest bands did
    /// not exist, which is worse than drawing nothing; and the table cannot in fact be short, since
    /// `computeZones` zips `HeartRateZoneIndex.allCases` against a fixed five-element array.
    ///
    /// - Parameters:
    ///   - measured: the session's own heart-rate fold, or `nil` when it has no samples.
    ///   - priorAverage: the same-activity mean, or `nil` below its floor. Applied only to rows that
    ///     have a time of their own.
    ///
    /// **A whole percent is required and a fraction is refused** on the imported path. The bundled
    /// export's 3,365 `HR Zone n %` cells are all whole numbers — measured, zero fractional values —
    /// so a fractional percent would be a value from some other producer, and `seconds` is a share of
    /// the session computed from it. Refusing rather than rounding is the conservative direction: this
    /// app has no case that produces one and rounding would silently invent a reading if it ever did.
    public static func rows(
        for session: WorkoutSession,
        zones: [HeartRateZone],
        measured: ZoneTimeMath.Totals?,
        priorAverage: ActivityZoneBaseline?
    ) -> [ActivityZoneRow] {
        guard zones.count == HeartRateZoneIndex.allCases.count else { return [] }
        let percents = wholePercents(of: session)

        // Resolved before the rows so one scale can be taken across both marks in the block.
        let resolved: [(zone: HeartRateZone, seconds: Double?, source: Source?)] = zones.map { zone in
            if let measured, measured.zoneSeconds.count == HeartRateZoneIndex.allCases.count {
                return (zone, measured.seconds(in: zone.index), .measured)
            }
            guard let percents else { return (zone, nil, nil) }
            // `wholePercents` has already checked finiteness and count, so `zoneSeconds` answers a
            // number for the same reason the block was accepted.
            let seconds = percents[zone.index.rawValue - 1].isFinite
                ? session.zoneSeconds(zone.index)
                : nil
            return (zone, seconds, seconds == nil ? nil : .imported)
        }

        let scale = resolved
            .compactMap(\.seconds)
            .reduce(0, max)
        let averageScale = resolved
            .compactMap { row in
                row.seconds == nil ? nil : priorAverage?.seconds(in: row.zone.index)
            }
            .reduce(0, max)
        let scaleSeconds = max(scale, averageScale)

        return resolved.reversed().map { row in
            let average = row.seconds == nil
                ? nil
                : priorAverage?.seconds(in: row.zone.index)
            return ActivityZoneRow(
                index: row.zone.index,
                lowerBpm: row.zone.lowerBpm,
                upperBpm: row.zone.upperBpm,
                seconds: row.seconds,
                source: row.seconds == nil ? nil : row.source,
                averageSeconds: average,
                averageSessionCount: average == nil ? nil : priorAverage?.sessionCount,
                scaleSeconds: scaleSeconds,
                barFraction: fraction(row.seconds, of: scaleSeconds),
                averageFraction: average.map { fraction($0, of: scaleSeconds) })
        }
    }

    /// The session's block, or `nil` when it has none or holds anything but five whole percentages.
    private static func wholePercents(of session: WorkoutSession) -> [Double]? {
        guard let percents = session.hrZonePercents,
              percents.count == HeartRateZoneIndex.allCases.count,
              percents.allSatisfy({ $0.isFinite && $0 == $0.rounded() })
        else { return nil }
        return percents
    }

    /// A mark's position on the track, clamped so a malformed input cannot draw past the end.
    private static func fraction(_ value: Double?, of scale: Double) -> Double {
        guard let value, scale > 0, value.isFinite else { return 0 }
        return min(1, max(0, value / scale))
    }

    /// The band as the row prints it: `106-125`, and `178+` for the top band.
    ///
    /// The open end is the reference's own and it is not decoration. Zone 5's ceiling is `maxHR`, which
    /// is a *nominal* maximum rather than a measured one — a strap reports a rate above it the moment a
    /// session is harder than the profile assumes, and `StrainAccumulatorMath.loadDelta` scores that
    /// rate as zone 5 anyway. Printing `178-190` would name a ceiling the scoring does not honour.
    ///
    /// **Bands are half-open and this is not an inconsistency**: zone 4 ends where zone 5 begins, and
    /// `computeZones` rounds each edge once so the two agree on the shared number rather than counting
    /// it in both.
    public var bpmRangeText: String {
        index == .zone5 ? "\(lowerBpm)+" : "\(lowerBpm)-\(upperBpm)"
    }

    /// The time as the row prints it — `0:00:12` — or the dash an absent measurement draws.
    ///
    /// A dash and not `0:00:00`: the first is the absence of a measurement and the second is a
    /// measurement of none, and the two are the same pixels only if someone collapses them.
    public var secondsText: String {
        guard let seconds else { return "—" }
        return seconds.formattedClockDuration()
    }

    /// A clock duration split into its two halves for drawing — `0:00:12` becomes `("0:00", ":12")`.
    ///
    /// **This is a drawing rule and it lives here for `DayBarRules`' reason**: the runner has no
    /// renderer, so a split written into a `body` is a split nothing can assert. The reference draws
    /// the hours-and-minutes half dim and the seconds half bright, which is a reading a person takes in
    /// at a glance — the seconds are the digit that moves while the minutes hold still, so the figure
    /// that changes is the one at full strength.
    ///
    /// **The split is at the last colon, and that is what keeps the two halves one duration.** The
    /// trailing half keeps its colon, so `0:15` + `:58` still reads as `0:15:58` if the two colours are
    /// ignored, and the two pieces are never a pair of unrelated numbers. Splitting at the *first*
    /// colon would put the minutes on the trailing side and leave `0` alone on the leading one.
    ///
    /// **A string with no colon comes back whole with an empty tail**, which is the dash an absent
    /// measurement draws (`—`): the dash is not a duration and has no halves, so it is drawn undivided
    /// rather than padded into a shape it does not have.
    public nonisolated static func durationParts(
        _ text: String
    ) -> (leading: String, trailing: String) {
        guard let colon = text.lastIndex(of: ":") else { return (text, "") }
        return (String(text[text.startIndex..<colon]), String(text[colon...]))
    }

    /// The row in one sentence, for VoiceOver.
    ///
    /// `nonisolated static` rather than text composed inside the `body`, on the rule this page's other
    /// strings follow: the runner has no renderer, so a sentence written into a `body` is a sentence
    /// nothing can assert. It is asserted against the absences and against the average's basis rather
    /// than against a screenshot.
    public nonisolated static func spoken(_ row: ActivityZoneRow) -> String {
        let band = "Zone \(row.index.rawValue), \(row.bpmRangeText) bpm"
        guard let seconds = row.seconds else {
            return "\(band). Not recorded for this session."
        }
        let time = "\(band). \(seconds.formattedClockDuration())."
        guard let average = row.averageSeconds, let count = row.averageSessionCount else {
            return time
        }
        return time
            + " Average over your last \(count) sessions of this activity: "
            + average.formattedClockDuration() + "."
    }
}
