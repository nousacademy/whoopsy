import SwiftUI

/// The coloured capsule Home's `ACTIVITIES` card draws in place of a fast's duration — the zone the
/// fast reached, named, on the fill that zone owns.
///
/// ## Why the name alone and not the hours
///
/// The zone's range is a definition rather than a reading, and the row it sits on already prints the
/// session's own span as a time range on the trailing edge. A pill reading `FAT BURNING 16-24H` would
/// state a rule beside a figure that obeys it. So the pill carries `zone.label` alone, which is what
/// the row is *for*: a reader asking "what kind of fast was this" gets the answer in one word.
///
/// ## Where it draws, and why nothing else moved
///
/// It is drawn in the slot `ActivityFigure.headlineText` would have filled, inside
/// `HomeDashboardView.activityRow`'s shared `VStack`. Every other row on the card — the `SLEEP` row
/// above it and every measured activity — still draws its figure as a `Text` exactly as before, and
/// the two are mutually exclusive by construction: `ActivityFigure.fastingZone(for:)` returns `nil`
/// for any session the headline prints a strain for.
///
/// The vertical padding is chosen so the pill is no taller than the 19 pt figure it replaces, which
/// keeps the row's height decided by its 38 pt chip rather than by which branch was taken — so a fast's
/// row and its neighbours stay the same height and the card does not jitter as the day changes.
///
/// ## The geometry is here rather than in the `body`
///
/// `drawnWidth` follows `ActivityGlyph.drawnWidth`, and for the same reason: the runner has no
/// renderer, so the only way an assertion can reach "the widest label fits the row" is for the
/// arithmetic to be a function on this type. Its caveat is that type's caveat verbatim — it is a
/// **bound from nominal character metrics and not a measurement of a rendered view**, so an assertion
/// using it proves the arithmetic leaves room, not that a particular label on a particular OS lands
/// inside the row.
public struct FastingZonePill: View {

    /// The zone whose name and colour this pill draws.
    public let zone: FastingZone

    public init(zone: FastingZone) {
        self.zone = zone
    }

    // MARK: - Geometry

    // `nonisolated` on all five, and that is this repo's standing rule for a value a test has to reach
    // rather than a tidiness: `View` is `@MainActor`-isolated, so a plain `static` here would be
    // reachable only from the main actor — and the runner is a `main.swift` whose assertions run
    // outside it. Swift 6 accepts that today as a warning and refuses it in the language mode, so the
    // alternative is not "leave it" but "the whole fit block stops compiling". `MonthGrid.make`,
    // `WorkoutRoutePoint.isPlausible` and `SleepTimelineLanes.make` are `nonisolated` for the same
    // reason: these are arithmetic, and arithmetic that only a `body` can reach is arithmetic nothing
    // can assert.

    /// The capsule's horizontal inset around its label. Declared here rather than taken from
    /// `ActivityDeltaBadge`'s `8` — the two are different components with different contents, and a
    /// shared constant between them would move one when the other was tuned.
    public nonisolated static let horizontalPadding: CGFloat = 8

    /// The capsule's vertical inset, sized so the pill stays inside the height of the 19 pt figure it
    /// replaces — see the type comment.
    public nonisolated static let verticalPadding: CGFloat = 3

    /// The label's point size. Below the row's 19 pt figure deliberately: the pill is a **word** where
    /// the figure was a **number**, and the two longest labels here carry twelve characters where
    /// `24:59` carries five.
    public nonisolated static let fontSize: CGFloat = 11

    /// The width `drawnWidth` assumes one character occupies, as a multiple of the point size.
    ///
    /// **A bound and not a measurement, and a different quantity from `assumedSymbolWidthRatio`** —
    /// that one covers SF Symbols, where this one covers text. It is the upper end of what a bold
    /// 11 pt system face spends per character across the labels this type draws: `DEEP KETOSIS` is the
    /// widest at twelve characters including a space, and a ratio of 0.62 bounds it with room.
    /// A future label longer than that has to re-measure this, exactly as a new composite has to
    /// re-measure that type's ratio.
    public nonisolated static let assumedCharacterWidthRatio: CGFloat = 0.62

    /// How wide the pill for `zone` is drawn at `size`.
    ///
    /// Its caveat is `ActivityGlyph.drawnWidth`'s: a documented upper bound from nominal metrics, not
    /// an observation of a rendered view.
    public nonisolated static func drawnWidth(of zone: FastingZone, atPointSize size: CGFloat) -> CGFloat {
        CGFloat(zone.label.count) * size * assumedCharacterWidthRatio
            + horizontalPadding * 2
    }

    /// The zone whose pill is widest — the one any fit assertion has to be made against.
    ///
    /// A computed property rather than a hardcoded `.deepKetosis`, so a label added or lengthened
    /// later moves the assertion with it instead of leaving it checking a zone that is no longer the
    /// widest.
    public nonisolated static var widest: FastingZone {
        FastingZone.allCases.max {
            drawnWidth(of: $0, atPointSize: fontSize) < drawnWidth(of: $1, atPointSize: fontSize)
        } ?? .deepKetosis
    }

    public var body: some View {
        Text(zone.label)
            .font(.system(size: Self.fontSize, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(zone.inkColor)
            .lineLimit(1)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .background(zone.color, in: Capsule())
    }
}
