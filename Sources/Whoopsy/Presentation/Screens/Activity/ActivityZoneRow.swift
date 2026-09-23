import Foundation

/// One of the five heart-rate zone rows under the session's chart: the band's edges, the share of the
/// session that fell inside it, and the time that share works out to.
///
/// ## Why this is a value and not five lines in a `body`
///
/// `DayBarRules`' reason, which applies to every rule this page draws that a person would otherwise
/// write inline: the runner that tests this app has no renderer, so a derivation written into a `View`
/// is a derivation nothing can assert. Three things here are worth asserting and none of them is
/// visible in a screenshot — the pairing of the two figures, the ordering of the five rows, and the
/// difference between an absent block and a measured zero.
///
/// ## Both figures come from one source
///
/// `percent` is WHOOP's own `HR Zone n %` for the session and `seconds` is that share of the session's
/// length — the same derivation `WorkoutSession.zoneSeconds(_:)` already performs for the strain page's
/// two summed rows, forwarded to rather than restated. **A row printing `22%` beside a time derived
/// independently of it would be two figures free to disagree**, which is the rule `MetricChange.between`
/// applies to the pair it compares and the reason that type compares formatted text.
///
/// ## The two absences are different, and only one of them is a dash
///
/// `percent` and `seconds` are `nil` together or set together — one condition produces both, so a row
/// can never print a percentage with no time beside it:
///
/// - **`nil` is an absent block.** A session this app recorded itself carries no `hrZonePercents`, and
///   neither does any row written before `v14`. All five rows draw a dash.
/// - **A stored `0` is a measurement.** 45 of the bundled export's 673 rows read `0` in every band —
///   real workouts that never reached zone 1 — and those are a measured `0%` and `0:00`, drawn as
///   such. The two must not be collapsed: a dash over a measured zero says *not measured* about a fact
///   WHOOP did measure.
///
/// ## What these rows are not
///
/// **The five percentages do not sum to the session**, so neither do the five times. The remainder is
/// time below zone 1, which WHOOP publishes no column for — the same shortfall `WorkoutSession`'s own
/// doc comment records, and the reason `WholePercentMath.wholePercents(ofSeconds:)` must not be used to
/// derive this column.
///
/// **The share is WHOOP's and the edges are this app's.** The percentages come out of `workouts.csv`
/// verbatim; the BPM boundaries come from `StrainAccumulatorMath.computeZones`, which is a pure function
/// of the profile's two heart rates and which `GRDBUserProfileRepository` answers with a cold-start
/// `190/60` when no profile row exists — indistinguishably from a user-supplied profile. So on a fresh
/// install those edges are a constant this app wrote down. The strain detail page already carries the
/// same mismatch, which is why this is a documented property of the page rather than a defect here.
public struct ActivityZoneRow: Equatable, Sendable {

    public let index: HeartRateZoneIndex

    /// The band's own edges, out of the profile's zone table. `upperBpm` is `maxHR` for zone 5 and is
    /// drawn as an open end rather than a ceiling — see `bpmRangeText`.
    public let lowerBpm: Int
    public let upperBpm: Int

    /// WHOOP's share of the session in this band, in whole percent, or `nil` when the session carries
    /// no zone block at all.
    public let percent: Double?

    /// `percent` of the session's length, in seconds, or `nil` with it.
    public let seconds: Double?

    public init(
        index: HeartRateZoneIndex,
        lowerBpm: Int,
        upperBpm: Int,
        percent: Double?,
        seconds: Double?
    ) {
        self.index = index
        self.lowerBpm = lowerBpm
        self.upperBpm = upperBpm
        self.percent = percent
        self.seconds = seconds
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
    /// **A whole percent is required and a fraction is refused.** The bundled export's 3,365
    /// `HR Zone n %` cells are all whole numbers — measured, zero fractional values — so a fractional
    /// percent would be a value from some other producer, and `seconds` is a share of the session
    /// computed from it. Refusing rather than rounding is the conservative direction: this app has no
    /// case that produces one and rounding would silently invent a reading if it ever did.
    public static func rows(
        for session: WorkoutSession, zones: [HeartRateZone]
    ) -> [ActivityZoneRow] {
        guard zones.count == HeartRateZoneIndex.allCases.count else { return [] }
        let percents = wholePercents(of: session)

        return zones.reversed().map { zone in
            let percent = percents?[zone.index.rawValue - 1]
            return ActivityZoneRow(
                index: zone.index,
                lowerBpm: zone.lowerBpm,
                upperBpm: zone.upperBpm,
                percent: percent,
                // The same condition that produced `percent`, applied through the entity's own
                // derivation so the two figures are one answer and not two.
                seconds: percent == nil ? nil : session.zoneSeconds(zone.index))
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

    /// The share as the row prints it — `0%`, `22%` — or the dash an absent block draws.
    ///
    /// A dash and not `0%`: see this type's comment. `0%` is a measurement WHOOP made and a dash is the
    /// absence of a block, and the two are the same pixels only if someone collapses them.
    public var percentText: String {
        guard let percent else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

    /// The time as the row prints it — `0:00:12` — or the same dash, from the same condition.
    public var secondsText: String {
        guard let seconds else { return "—" }
        return seconds.formattedClockDuration()
    }

    /// The row in one sentence, for VoiceOver.
    ///
    /// `nonisolated static` rather than text composed inside the `body`, on the rule this page's other
    /// strings follow: the runner has no renderer, so a sentence written into a `body` is a sentence
    /// nothing can assert. It is asserted against the two absences rather than against a screenshot.
    public nonisolated static func spoken(_ row: ActivityZoneRow) -> String {
        let band = "Zone \(row.index.rawValue), \(row.bpmRangeText) bpm"
        guard let percent = row.percent, let seconds = row.seconds else {
            return "\(band). Not recorded for this session."
        }
        return "\(band). \(Int(percent.rounded())) percent, \(seconds.formattedClockDuration())."
    }
}
