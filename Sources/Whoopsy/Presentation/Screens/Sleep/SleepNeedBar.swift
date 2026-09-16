import SwiftUI

/// Where the need card's bars sit inside their track, as fractions of the track's width.
///
/// **A value rather than arithmetic in a `body`, for the reason `TypicalRangeBarLayout` is one**: this
/// repo's suite has no renderer, so a rule written into a `View` is a rule nothing can assert. Three
/// of the rules below are the kind that fail silently on screen — a segment that overlaps its
/// neighbour by a rounding error, a bar that overflows its track, a split whose boundary does not land
/// where the two printed figures say it does — and each is asserted in the runner instead.
///
/// **Both bars share one origin and one scale, and that is structural rather than convenient.** The
/// scale's maximum is `max(asleep, need)`, so the need bar spans the track exactly and the sleep bar
/// spans `asleep / need` of it — which is the same ratio the card prints as its headline percentage,
/// so the picture and the figure above it cannot disagree. A fixed scale was the alternative and is
/// rejected: WHOOP publishes no maximum, and the export's own need spans 321–650 min while its asleep
/// totals reach 940, so any constant large enough to hold them all shrinks the pair to illegibility —
/// and any constant small enough to read clips fifteen real nights.
///
/// **The over-sleep case is drawn rather than clamped.** Fifteen of the export's nights carry more
/// stage time than need; on those, `asleepFraction` is `1` and the *need* bar is the short one, which
/// is the honest picture of a night that overshot its target. Clamping the other way would draw the
/// two bars equal and say the night exactly met its need.
public struct SleepNeedBarLayout: Equatable, Sendable {

    /// One component's span of the need bar, in the track's own fraction space.
    public struct Segment: Equatable, Sendable, Identifiable {
        public let component: SleepNeedBreakdown.Component
        public let startFraction: Double
        public let endFraction: Double

        public var id: String { component.rawValue }

        public var widthFraction: Double { max(0, endFraction - startFraction) }
    }

    /// The sleep bar's width, as a fraction of the track.
    public let asleepFraction: Double

    /// The need bar's width, as a fraction of the track. `1` unless the night overslept its need.
    public let needFraction: Double

    /// The need bar's parts, in `Component.allCases` order, contiguous from `0` and ending at
    /// `needFraction`. **Empty is an ordinary answer** — see `parts` on the initialiser.
    public let segments: [Segment]

    /// - Parameters:
    ///   - asleepSeconds: The night's hours of sleep.
    ///   - needSeconds: The night's need — the whole the parts are of.
    ///   - parts: `SleepNeedBreakdown.Breakdown.parts`, trusted to sum to `needSeconds`. That is the
    ///     breakdown's own guarantee and is not re-checked here; what is checked is everything this
    ///     type would otherwise divide by or draw outside its track. An **empty** array is the night
    ///     whose stored row supports no split, and it is what makes the layout still answerable: the
    ///     sleep bar is drawn against the need whether or not the need's composition is known, and a
    ///     caller that also wants the segments draws them only when there are some.
    /// - Returns: `nil` when there is no track to draw on — a non-positive scale or a non-positive
    ///   need. Both are corrupt rows rather than ordinary absences, and a caller with no layout draws
    ///   no card rather than an empty one.
    public init?(
        asleepSeconds: TimeInterval,
        needSeconds: TimeInterval,
        parts: [SleepNeedBreakdown.Part] = []
    ) {
        let scale = max(asleepSeconds, needSeconds)
        guard scale > 0, needSeconds > 0,
              parts.allSatisfy({ $0.seconds.isFinite && $0.seconds >= 0 })
        else { return nil }

        let asleepFraction = asleepSeconds / scale
        let needFraction = needSeconds / scale

        var cursor: TimeInterval = 0
        var segments: [Segment] = []
        for (index, part) in parts.enumerated() {
            let start = cursor / needSeconds * needFraction
            cursor += part.seconds
            // The last segment is closed at `needFraction` rather than at its own accumulated sum, so
            // a rounding error in the parts cannot leave a hairline of track showing at the bar's end.
            let end = index == parts.count - 1
                ? needFraction
                : cursor / needSeconds * needFraction
            segments.append(
                Segment(component: part.component, startFraction: start, endFraction: max(start, end)))
        }

        self.asleepFraction = asleepFraction
        self.needFraction = needFraction
        self.segments = segments
    }
}

/// One bar of a need card: a filled span on the card, with no track drawn behind it.
///
/// **No track, and that is a reading rather than a styling choice.** `TypicalRangeBar` draws one
/// because the part of *that* bar a stage did not reach is a share of the night with a meaning of its
/// own; here the space to the right of the sleep bar is simply the part of the need that was not met,
/// and drawing it in `ringTrack` would put the app's "nothing was measured" grey under a figure that
/// was. The mockup draws neither bar to the full width, and the gap is the shortfall.
struct SleepNeedBar: View {
    let fraction: Double
    let color: Color

    static let height: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: Self.height / 2, style: .continuous)
                .fill(color)
                .frame(width: proxy.size.width * max(0, min(1, fraction)))
        }
        .frame(height: Self.height)
    }
}

/// The need bar: the same track as `SleepNeedBar`, split into the parts of the need.
///
/// A separate view from `SleepNeedBar` rather than a mode of it, because the two draw different
/// things — one span in one colour, or several abutting spans — and a flag would let a caller pass
/// segments to the plain bar and silently drop all but a fraction of the need.
struct SleepNeedStackedBar: View {
    let layout: SleepNeedBarLayout

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                ForEach(layout.segments) { segment in
                    segment.component.color
                        .frame(width: proxy.size.width * segment.widthFraction)
                        .offset(x: proxy.size.width * segment.startFraction)
                }
            }
            .frame(width: proxy.size.width, alignment: .leading)
            .clipShape(
                RoundedRectangle(cornerRadius: SleepNeedBar.height / 2, style: .continuous))
        }
        .frame(height: SleepNeedBar.height)
    }
}
