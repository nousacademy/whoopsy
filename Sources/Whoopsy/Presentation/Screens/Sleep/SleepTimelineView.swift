import SwiftUI

/// Where the night's two timeline lanes are filled, as fractions of the night's own sleep period.
///
/// **It exists because a rule written into a `View` is a rule nothing here can assert**, which is
/// `TypicalRangeBarLayout`'s reason for being a type of its own and applies here for the same reason:
/// the runner that tests this app has no renderer, so a mapping from epoch timestamps to bar
/// positions written inside a `GeometryReader` is arithmetic nothing can check. Resolving the
/// fractions here means the thing the card's picture is made of — including segments that fall
/// outside the period they are drawn in — is asserted as a value.
///
/// **The two lanes are complements of one another and are both drawn**, which is the reference's
/// shape rather than this app's invention: the upper lane is where the night was asleep, the lower is
/// where it was awake, and each fills its own track for the same span of clock. A reader can therefore
/// see at a glance that the lower lane's marks are exactly the upper lane's gaps, which is what makes
/// the pair read as one night rather than as two recordings.
///
/// **`nil` is the whole absence rule, and it is deliberately not an empty instance.** No segments and
/// a non-positive period both mean there is no timeline to draw, and the card answers both by falling
/// back to its note. An instance with two empty lanes would be a *drawn* timeline of a night that had
/// neither sleep nor wakefulness in it — the fabrication every absence rule in this app exists to
/// prevent, in the shape of a picture. So the gate is on `make` returning nothing rather than on a
/// lane being empty.
public struct SleepTimelineLanes: Equatable, Sendable {

    /// One filled run along a lane, as fractions of the sleep period's width. Always within `0...1`,
    /// and always ordered `start <= end`.
    public struct Span: Equatable, Sendable {
        public let start: Double
        public let end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    /// Where the night was in any of the three sleep stages, merged into contiguous runs.
    public let asleep: [Span]

    /// Where it was awake, merged the same way.
    public let awake: [Span]

    /// The night's two lanes, or `nil` when it has no timeline.
    ///
    /// - Parameters:
    ///   - segments: one per 30-second epoch, in the order they occurred. Empty is the ordinary case
    ///     on an imported night and on any row written before `v12`.
    ///   - start: the sleep period's start — `SleepSession.startTime`, the in-bed bound.
    ///   - end: its end. The period is `end - start`, and it is the scale both lanes are drawn on, so
    ///     a lane's marks are a position *within the night* and not within the day.
    public static func make(
        segments: [SleepStageSegment],
        start: Date,
        end: Date
    ) -> SleepTimelineLanes? {
        let period = end.timeIntervalSince(start)
        // A night with no duration has no scale to draw on. `SleepSession` guards its own zero
        // denominator, so this is unreachable through the entity — it is here so a hand-built
        // session cannot divide by zero into two `NaN` lanes, which would be a mark that takes the
        // whole bar rather than one drawn in the wrong place.
        guard period > 0, !segments.isEmpty else { return nil }

        var asleep: [Span] = []
        var awake: [Span] = []

        for segment in segments {
            let from = segment.startTime.timeIntervalSince(start) / period
            let to = segment.endTime.timeIntervalSince(start) / period

            // Clamped rather than trusted. The epochs are cut from the same window the bounds come
            // from, so in practice every segment lands inside it — but a span outside the scale is
            // worse than a span in the wrong place, because it reads as a different scale rather
            // than as a wrong reading. `TypicalRangeBarLayout.fraction` makes the same argument.
            let start = Self.fraction(min(from, to))
            let end = Self.fraction(max(from, to))
            guard end > start else { continue }

            if segment.stage == .awake {
                awake.append(Span(start: start, end: end))
            } else {
                asleep.append(Span(start: start, end: end))
            }
        }

        // **Merging is load-bearing and not an optimisation.** A night is ~960 epochs, so an
        // unmerged asleep lane is hundreds of adjacent rectangles; anti-aliasing draws a hairline of
        // track between each pair, and an eight-hour stretch of sleep comes out looking striped —
        // a picture of a fragmented night, made by the drawing rather than by the data. Merging is
        // also what makes the spans mean "a run of this state" rather than "an epoch", which is what
        // a reader takes from a continuous fill.
        return SleepTimelineLanes(
            asleep: Self.merge(asleep),
            awake: Self.merge(awake))
    }

    /// Joins runs that touch, and orders them, so a caller draws one rectangle per uninterrupted
    /// stretch. The epsilon is for floating-point drift in the division above rather than for a real
    /// gap: two epochs that abut should not be separated by `1e-16` of the bar.
    private static func merge(_ spans: [Span]) -> [Span] {
        let sorted = spans.sorted { $0.start < $1.start }
        var merged: [Span] = []

        for span in sorted {
            if let last = merged.last, span.start <= last.end + 1e-9 {
                merged[merged.count - 1] = Span(start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    /// A fraction clamped into the lane. Non-finite collapses to zero rather than propagating, on
    /// `TypicalRangeBarLayout.fraction`'s rule: a `NaN` is not a mark drawn at the wrong place, it is
    /// a mark that takes the whole lane with it, since every comparison against a `NaN` is false.
    private static func fraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

/// The night's two-lane timeline: where it slept, over where it was awake.
///
/// **It is the middle of the sleep-efficiency card, and it is drawn only when a night really has a
/// timeline.** `SleepEfficiencyCard` holds the gate — it passes `nil` lanes and gets its note instead
/// — so this view has no empty state and no opinion about one. That is deliberate: a view that could
/// draw nothing would be a view that can be asked to draw an absent recording, and the note is the
/// card's answer to that question rather than this view's.
///
/// **The lanes are complements, and drawing both is the point.** The upper lane fills
/// `Theme.sleepPerformance` where the night was in any sleep stage; the lower fills hatched where it
/// was awake. Each lane's track is `Theme.ringTrack` — the part of *this lane's* scale the night did
/// not spend in that state — which is the same reading of that token `TypicalRangeBar` makes. It is
/// the honest use of it: a drawn lane really is a proportion of a night, unlike the card's note slot,
/// which is why the note is `Theme.sleepTimelineSlot` and not this.
public struct SleepTimelineView: View {

    public let lanes: SleepTimelineLanes

    /// One lane's thickness, and the gap between them. Parameters because the card tunes them against
    /// the two measure rows they sit between, and this view has no opinion about that — but the
    /// defaults are the card's own, so a caller that passes nothing draws what the reference draws.
    public var laneHeight: CGFloat
    public var spacing: CGFloat

    public init(
        lanes: SleepTimelineLanes,
        laneHeight: CGFloat = 15,
        spacing: CGFloat = 10
    ) {
        self.lanes = lanes
        self.laneHeight = laneHeight
        self.spacing = spacing
    }

    public var body: some View {
        VStack(spacing: spacing) {
            lane(spans: lanes.asleep, style: .filled)
            lane(spans: lanes.awake, style: .hatched)
        }
        // Decoration, on `TypicalRangeBar`'s rule: the card is announced as one element and speaks
        // its own sentence, so a listener has already been told the two durations this picture
        // divides. A second reading of the same figures in a shape with no words would be noise.
        .accessibilityHidden(true)
    }

    private enum LaneStyle { case filled, hatched }

    /// One lane: the scale, the gaps, and the runs of this state over them.
    ///
    /// The marks are drawn as an `overlay` on a fixed-height track rather than as siblings in a
    /// `ZStack`, which is `TypicalRangeBar.track`'s arrangement and its reason: a stack sizes itself
    /// to its tallest child, so anything in it without a height of its own would stretch.
    ///
    /// **The marks go inside an explicit `ZStack(alignment: .leading)` with an explicit full-width
    /// frame, and both halves of that are load-bearing.** A bare `ForEach` in this position is laid out
    /// as an implicit group sized to its *widest* mark and centred inside it, so every narrower mark
    /// starts `(widest − thisOne) / 2` to the right of where its own offset puts it. That is not a
    /// subtle drift: measured on the simulator, a night whose asleep runs are 101, 50.5 and 50.5 pt put
    /// its two narrow runs `+25` pt right — into the gaps between them — and an awake lane of 457 and
    /// 355 pt put its second run `+51` pt right, past the end of the asleep run it should sit under.
    /// The lanes then interleave wrongly while each lane's *widths* stay correct, which is what makes it
    /// read as a plausible picture rather than as a bug. A lane whose runs all happen to be the same
    /// width draws correctly, so an equal-band fixture cannot see this. `SleepNeedStackedBar` is the
    /// same arrangement done right, and this is its shape.
    private func lane(spans: [SleepTimelineLanes.Span], style: LaneStyle) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            Self.trackShape
                .fill(Theme.ringTrack)
                .overlay(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        marks(spans: spans, style: style, width: width)
                    }
                    .frame(width: width, alignment: .leading)
                }
        }
        .frame(height: laneHeight)
    }

    /// The runs of one state, as one rectangle each.
    ///
    /// **A rectangle per merged span and not a mask**, which is where this parts company with
    /// `TypicalRangeBar`'s hatch: that bar draws one texture over the whole track and masks it to the
    /// remainder, so four rows share one stripe phase. Here the hatched lane's marks are *disjoint
    /// intervals*, and a single mask cannot express a set of them — so the hatch is drawn per span.
    /// The cost is that stripes start afresh in each run, which is invisible at this scale and is the
    /// right trade against a texture that would otherwise have to be built as one path.
    ///
    /// The minimum width is a legibility floor and not a rule: a single 30-second epoch is a third of
    /// a point on a 390 pt card, so without it a one-epoch waking would be drawn and then not be
    /// visible — a reading present in the data and absent from the picture. It moves no edge by more
    /// than a point and it is the same bargain `TypicalRangeBar.markMinimumWidth` makes.
    private func marks(spans: [SleepTimelineLanes.Span], style: LaneStyle, width: CGFloat) -> some View {
        ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
            let startX = min(max(0, width * span.start), width)
            let endX = min(max(0, width * span.end), width)

            Group {
                switch style {
                case .filled:
                    Rectangle().fill(Theme.sleepPerformance)
                case .hatched:
                    Rectangle()
                        .fill(Theme.ringTrack)
                        .overlay {
                            HatchShape(spacing: Self.stripeSpacing)
                                .stroke(Theme.hatchStripe, lineWidth: Self.stripeWidth)
                        }
                        .clipShape(Rectangle())
                }
            }
            .frame(width: max(Self.minimumMarkWidth, endX - startX))
            .offset(x: min(startX, max(0, width - max(Self.minimumMarkWidth, endX - startX))))
        }
    }

    /// The track's shape, shared by both lanes so they read as one pair.
    ///
    /// The radius is `TypicalRangeBar.trackCornerRadius`'s — solved for off the reference rather than
    /// read off, and the number this app's other bar in this card already draws with. Reused by value
    /// rather than by reference because that constant is `private` to the other type; what keeps them
    /// equal is that both are stated against the same measurement.
    private static var trackShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
    }

    /// The hatch's period and stripe width, matching `TypicalRangeBar`'s pair exactly — the two
    /// textures are the same mark on the same page and a reader comparing them should find one hatch.
    private static let stripeSpacing: CGFloat = 10.9
    private static let stripeWidth: CGFloat = 3.85
    private static let minimumMarkWidth: CGFloat = 1.5
}
