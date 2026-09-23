import SwiftUI

/// How an activity's figure compares with the same activity's own recent history — **and no verdict at
/// all**, which is the whole of what separates it from `MetricChange`.
///
/// ## Why this is a sibling and not a change to `MetricChange`
///
/// `MetricChange` is shared by Home's four metric panels, its two tiles and `RecoveryDetailView`'s four
/// breakdown rows, so anything added to it moves four screens — and the thing this page needs is not an
/// addition to it. That type's `Verdict` is `better`/`same`/`worse` and `color(for:)` maps all three to
/// `recoveryGreen`/`recoveryYellow`/`recoveryRed`, so every comparison it can express is *news*. Strain
/// going up against the last ten basketball sessions is not news in that sense: it is neither good nor
/// bad, and the badge would have to be drawn in one of the three colours to say otherwise. A fourth
/// `Verdict` case would be a fourth tile colour on four screens to serve one row on one page, and the
/// screen it would restyle is the one that did not ask for it.
///
/// So this type carries the comparison and **no verdict**, and draws in `Theme.neutralDelta` — a token
/// that exists for exactly this and that no verdict reads. `MetricChange`'s three-state rule is not
/// lost, it is simply not this type's business: the reader of `ACTIVITY STRAIN 4.1 ▲ 2.5` is being told
/// which way the figure moved and by how much, and nothing on the page claims to know whether that was
/// a good session.
///
/// ## What is shared with `MetricChange` is the *comparison rule*, not the code
///
/// Three of its decisions are copied deliberately rather than extracted, because extracting them would
/// be a change to a shared component and the two types answer different questions:
///
/// - **The comparison is made on the text the caller will print, not on the raw pair.** A strain of
///   `4.1` against a mean of `4.14` is genuinely higher, but the badge would read `▲ 4.1` beside a
///   figure of `4.1` — a row contradicting itself. The digits on screen are the whole of the evidence
///   the reader has, so two figures that print alike *are* the same. This is why the comparison lives
///   in the type rather than at the call site: every caller prints `meanText` beside its own figure,
///   and the gate has to be applied by whatever produced that text.
/// - **Equal is not `nil`.** Sitting exactly on the mean is a real answer.
/// - **`nil` is reserved for a missing side** — a session with no strain history, or a window too thin
///   to produce a mean. Not for "unchanged", and not for a value that is absent for another reason.
public struct ActivityDelta: Equatable, Sendable {

    /// Which way the figure went, or `nil` when the two formatted figures print the same.
    ///
    /// Optional rather than a third case, on `MetricChange.Direction`'s argument: "same" is the absence
    /// of a direction rather than a third one, and every reader that draws an arrow handles the absence
    /// anyway.
    public enum Direction: Equatable, Sendable {
        case up
        case down
    }

    public let direction: Direction?

    /// The comparison value, already formatted — the window's mean, not the session's own figure. The
    /// page prints this beside the session's figure so the badge has something to be *about*.
    public let meanText: String

    /// The size of the move, already formatted and **never signed**: the direction is carried by
    /// `direction` and drawn as a triangle, so a `-` in the text as well would state it twice. That is
    /// the one shape difference from the reference's `▲ 2.5`, which is unsigned for the same reason.
    public let magnitudeText: String

    public init(direction: Direction?, meanText: String, magnitudeText: String) {
        self.direction = direction
        self.meanText = meanText
        self.magnitudeText = magnitudeText
    }

    /// The comparison against a mean, or `nil` when there is nothing honest to draw.
    ///
    /// `current` and `mean` are both optional because both sides genuinely can be absent: a session
    /// whose steps were never measured has no figure to compare, and a window below
    /// `RecoveryScoring.minimumBaselineDays` has no mean. Either absence returns `nil` — the caller
    /// withholds the badge — rather than a badge against a substituted number.
    ///
    /// `formatted` is handed in rather than chosen here, on `MetricChange.between`'s reasoning: a
    /// strain prints to one decimal and a step count to none, so the caller owns the format and this
    /// type owns the comparison, and the two cannot come to disagree because the comparison is made on
    /// what the caller's own formatter produced.
    public static func between(
        current: Double?,
        mean: Double?,
        formatted: (Double) -> String
    ) -> ActivityDelta? {
        guard let current, let mean else { return nil }
        let meanText = formatted(mean)
        guard formatted(current) != meanText else {
            return ActivityDelta(direction: nil, meanText: meanText, magnitudeText: formatted(0))
        }
        let direction: Direction = current > mean ? .up : .down
        return ActivityDelta(
            direction: direction,
            meanText: meanText,
            magnitudeText: formatted(abs(current - mean)))
    }

    /// The triangle this delta draws — the direction and nothing else.
    ///
    /// Here rather than at the use site so the direction and the shape cannot come apart, on
    /// `MetricChange.symbolName`'s reasoning: a caller that renders `magnitudeText` without the glyph
    /// has dropped the only thing that says which way the number went.
    public var symbolName: String {
        switch direction {
        case .up: return "arrowtriangle.up.fill"
        case .down: return "arrowtriangle.down.fill"
        case nil: return "circle.fill"
        }
    }

    /// The colour this delta draws: **the neutral, always.**
    ///
    /// A computed property rather than a `Theme` read at each call site so the page cannot come to draw
    /// a delta in a verdict colour by hand — the failure this type exists to make unreachable, since it
    /// holds no verdict to pick one from.
    public var color: Color { Theme.neutralDelta }
}

/// One activity figure read against the same activity's own recent history: the figure, the mean it is
/// read against, and the neutral badge between them.
///
/// It is a `View` rather than a fragment inlined into the page because the page draws it **twice** —
/// `ACTIVITY STRAIN` and `ACTIVITY STEPS` — and the second one is the same row with a different pair
/// of figures and a `nil`-able badge. Two copies of a badge's spacing, glyph and colour would be two
/// places to change the neutral.
public struct ActivityDeltaBadge: View {

    /// The delta, or `nil` when there is nothing to compare — in which case **no badge is drawn at
    /// all** rather than an empty one. See `ActivityDelta.between`.
    public let delta: ActivityDelta?

    /// Whether the badge sits beside a figure the reader can see. The page prints the mean under the
    /// figure either way, so the badge repeats nothing the card does not already say.
    public var showsMean: Bool

    public init(delta: ActivityDelta?, showsMean: Bool = true) {
        self.delta = delta
        self.showsMean = showsMean
    }

    public var body: some View {
        if let delta {
            HStack(spacing: 4) {
                Image(systemName: delta.symbolName)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(delta.color)

                Text(delta.magnitudeText)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(delta.color)

                if showsMean {
                    Text("vs \(delta.meanText)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            // One sentence rather than three fragments. A listener hearing "up triangle, 2 point 5, vs
            // 1 point 6" gets the arrow as punctuation; the sentence says what the comparison is.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(delta))
        }
    }

    /// The badge as a sentence, and it names the window because the card does: "compared with your last
    /// ten" is the fact that decides whether the comparison means anything.
    ///
    /// `nonisolated static` rather than text built in the `body`, on the rule this page's other strings
    /// follow — the runner has no renderer, so a sentence written into a `body` is a sentence nothing
    /// can assert.
    public nonisolated static func spoken(_ delta: ActivityDelta) -> String {
        let movement: String
        switch delta.direction {
        case .up: movement = "up \(delta.magnitudeText)"
        case .down: movement = "down \(delta.magnitudeText)"
        case nil: movement = "unchanged"
        }
        return "\(movement), against an average of \(delta.meanText) over your last ten"
    }
}
