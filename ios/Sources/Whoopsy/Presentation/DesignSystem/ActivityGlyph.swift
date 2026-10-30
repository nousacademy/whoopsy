import Foundation

/// The glyph an activity's own name draws in the `ACTIVITIES` card's leading chip, named so it can be
/// asserted.
///
/// It lives here rather than inline in `HomeDashboardView`'s body for `DayBarRules`' reason: the test
/// runner has no renderer, and **a wrong SF Symbol name is not an error** — it draws an empty chip, so
/// a typo in this table is invisible to the compiler, invisible in a screenshot of a different row, and
/// only caught by an assertion over the names the file actually holds. §17 drives every one.
///
/// **The input is a name, not a workout**, and the table itself now lives one layer down as
/// `ActivityMarkCatalog`: the Live Activity draws the same mark and its widget cannot import this
/// module, so the mapping had to be reachable from `Domain`, from where the session pushes the two
/// symbol names through its state. This type still owns the geometry the four draw sites use, and
/// forwards the lookup; §17's sweep drives it through the forwarder.
///
/// **Every symbol below is iOS 13–16, and that is a constraint rather than an accident.** The
/// deployment target is 17.0, and SF Symbols has since added `figure.ice.skating`, `figure.indoor.rowing`
/// and `figure.indoor.soccer` — all iOS 18, all of which would draw nothing on this build. `Ice Skating`
/// therefore takes `figure.skating`, which has meant the same thing since iOS 16.
///
/// **One entry draws two symbols.** `Fast` is `fork.knife` then `timer`, because no single SF Symbol
/// carries both a food mark and a time mark — see `Drawing` for the sweep that established it. That is
/// why this type answers with a `Drawing` rather than a `String`, and why the geometry constants beside
/// `Drawing` exist: the four draw sites frame a drawing to a fixed size, and a pair is wider.
public enum ActivityGlyph {

    /// Forwarded from `ActivityMarkCatalog`, which is where the mapping now lives — see `ActivityMark`'s
    /// note on why it moved down a layer.
    public static let fallback = ActivityMarkCatalog.fallback

    /// The mark the receptive-inactivity feature draws where there is **no name yet**, and the symbol the
    /// `+` menu's `ADD RECEPTIVE INACTIVITY` row leads with.
    ///
    /// **It exists because the fallback would be a false drawing rather than a missing one, which is a
    /// distinction this table's own comment makes about unrecognised activities.** `mark(for: nil)`
    /// answers `figure.run` — the right answer for a session whose name this app has no glyph for, and an
    /// absurd one on a sheet whose subject is a dream: a receptive sheet opened fresh would draw a
    /// running figure beside the app's word for *no value*, which reads as a chosen mark rather than as an
    /// absence. So the receptive sheet's NAME row asks for this instead of `mark(for:)` while the draft
    /// has no name, and stops doing so the moment one is picked.
    ///
    /// **It is one value rather than two literals** — the same string is the menu row's `symbol` — so the
    /// glyph beside `ADD RECEPTIVE INACTIVITY` and the glyph on the sheet it opens cannot come apart. iOS
    /// 15, well inside the 17.0 target; a wrong name draws an empty chip, which is why `ActivityMenu`'s
    /// non-empty sweep and this comment are the only things that can see a typo here.
    ///
    /// It is deliberately **not** an entry in the `marks` table: that table is keyed by a name and this is
    /// the answer where there is none. A `"receptive inactivity"` key would also be a row no producer writes.
    public static let receptiveMark = "brain.head.profile"

    /// The drawing type, aliased so the four draw sites keep their spelling after the move.
    public typealias Drawing = ActivityMark

    // MARK: - Geometry
    //
    // The four draw sites give a drawing a frame of a fixed size, and a composite is wider than a
    // single symbol — so whether it fits is arithmetic rather than something a screenshot can settle.
    // The runner has no renderer, so these live here as named values and `drawnWidth` states the rule.

    /// A composite's symbols are drawn at this fraction of the size a single one gets, so a pair reads
    /// as one mark rather than as two.
    public static let compositeScale: CGFloat = 0.8

    /// The gap between a pair's two symbols, as a fraction of the single-symbol size — **a ratio and not
    /// a fixed 2pt**, which is airy at 12pt and cramped at 30pt.
    public static let compositeSpacingRatio: CGFloat = 0.15

    /// The width `drawnWidth` assumes one symbol occupies, as a multiple of its point size.
    ///
    /// **Measured, and measured narrowly on purpose: it is a bound for the symbols this app *pairs*,
    /// not for SF Symbols at large.** Read off the host's own glyph metrics at the sizes the four sites
    /// draw — the picker's 16pt medium, the edit sheet's 18pt medium and the detail header's 38pt
    /// regular — the pair's two symbols measure `timer` **1.267** and `fork.knife` **1.000**, so 1.3
    /// covers both with room.
    ///
    /// It is emphatically **not** a universal upper bound, and a future composite has to re-measure it:
    /// `figure.outdoor.cycle` measures **1.474–1.600** depending on size and weight, and would overflow
    /// every frame below. That symbol is only ever drawn *alone*, where this ratio is not what decides
    /// the fit.
    public static let assumedSymbolWidthRatio: CGFloat = 1.3

    /// Home's `ACTIVITIES` chip, unchanged. The frame is the drawing there — the chip is tinted and
    /// clipped — so the fit that matters is that a drawing does not exceed it.
    public static let chipDiameter: CGFloat = 38

    /// The detail header's gutter, which is a floor rather than a width so a composite can take more.
    /// A single symbol is unaffected at 48: the widest one this app draws a *title* beside measures 45pt
    /// at the header's 38pt regular.
    public static let activityHeaderMinWidth: CGFloat = 48

    /// The picker's and the edit sheet's glyph column, **widened from 26**.
    ///
    /// A fixed width rather than a floor, because it is the column all 191 catalogue rows align against
    /// and a per-row width would put `Fast`'s name at a different x from its neighbours, which reads
    /// as a broken list. 26 was enough for a single symbol; a pair at the widest size the two sites draw
    /// (18pt medium) needs 40.14 under `assumedSymbolWidthRatio`, so 42 is the smallest round number
    /// with headroom. The intended cost is that **every activity name in the picker and the sheet moves
    /// right by 16pt**.
    public static let listGutter: CGFloat = 42

    /// How wide `drawing` is drawn at `pointSize`.
    ///
    /// **This is a documented upper bound and not a measurement of a rendered view.** The runner has no
    /// renderer and cannot ask an `Image` for its width, so it multiplies by
    /// `assumedSymbolWidthRatio` — which is honest for the composite it exists to check and conservative
    /// for a single symbol. An assertion using it therefore proves *the arithmetic leaves room*, not
    /// that a particular glyph on a particular OS lands inside a particular frame.
    public static func drawnWidth(of drawing: Drawing, atPointSize size: CGFloat) -> CGFloat {
        let symbolWidth = size * assumedSymbolWidthRatio
        guard drawing.isComposite else { return symbolWidth }
        let partWidth = size * compositeScale * assumedSymbolWidthRatio
        return partWidth * 2 + size * compositeSpacingRatio
    }

    /// What `name` draws, or the fallback mark when the table has no entry for it.
    ///
    /// `nil` is the ordinary case rather than an error path: it is every session this app recorded
    /// itself and every row written before `v15`. `Paintball` is the one name in the bundled file with
    /// no entry, and it takes the fallback like any other.
    ///
    /// Matched lowercased and trimmed so a future export that changes the casing of a name — or pads a
    /// cell — still lands, which is the one normalisation this table can make without guessing.
    ///
    /// **The normalisation is `ActivityName.normalised`, not a copy of it.** The activity detail page
    /// groups a session with its own history by that same rule, so a fold written twice here would let
    /// the page decide two sessions were different activities while this table drew them the same
    /// glyph — or the reverse. The forwarding direction is Presentation → Domain, which is the one this
    /// app's dependency rule allows.
    ///
    /// **There is deliberately no accessor that hands back a single symbol.** A `symbol(for:) -> String`
    /// would answer `"fork.knife"` for `Fast` — a non-empty string that satisfies a non-empty sweep while
    /// drawing a plausible, complete and *wrong* mark, which is precisely the failure this type's own
    /// comment says it exists to catch. With only this accessor, `Image(systemName: ActivityGlyph.mark(for: x))`
    /// does not compile, so a composite cannot be truncated to its first symbol by accident.
    public static func mark(for name: String?) -> Drawing {
        ActivityMarkCatalog.mark(for: name)
    }
}
