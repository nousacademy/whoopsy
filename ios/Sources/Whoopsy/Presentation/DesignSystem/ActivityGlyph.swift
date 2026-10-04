import Foundation

/// The glyph an activity's own name draws in the `ACTIVITIES` card's leading chip, named so it can be
/// asserted.
///
/// It lives here rather than inline in `HomeDashboardView`'s body for `DayBarRules`' reason: the test
/// runner has no renderer, and **a wrong SF Symbol name is not an error** — it draws an empty chip, so
/// a typo in this table is invisible to the compiler, invisible in a screenshot of a different row, and
/// only caught by an assertion over the names the file actually holds. §17 drives every one.
///
/// **The input is a name, not a workout.** `WorkoutSession` is a Domain type and Domain imports only
/// `Foundation`, so it cannot know an SF Symbol; the mapping from a producer's string to a drawing is
/// the presentation layer's, exactly as `SleepStageType.color` and `RecoveryState.color` are.
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

    /// The fallback's symbol, and the one the card drew for **every** workout before this table
    /// existed. That is the point of choosing it: a name this table does not hold renders exactly as it
    /// did, so an unrecognised activity is a missing nicety rather than a regression.
    public static let fallback = "figure.run"

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

    /// What an activity's name draws: one SF Symbol, or **two, in order**.
    ///
    /// ## Why a name needs more than one symbol
    ///
    /// `Fast` is the case. No SF Symbol combines a food mark with a time mark — `figure.fasting` is
    /// absent from `name_availability.plist` entirely, no symbol name contains `fast`, and a sweep for a
    /// name carrying a food token *and* a time token returns only `applewatch*` false positives (the
    /// "apple" token) and `thermometer.variable.badge.clock`. `fork.knife` and `timer` both exist and
    /// both clear the iOS 17.0 target, so the requested mark is drawn as the pair rather than found as
    /// one name. **The order is the specification** — `.pair` preserves it, and `fork.knife` leads
    /// because the label under it reads `FAST`, so the pair reads as *fasting, for a duration*.
    ///
    /// ## Why `primary` + `secondary` and not `symbols: [String]`
    ///
    /// An array would make `Drawing(symbols: [])` representable — a mark that draws nothing, which is
    /// the empty chip this type exists to prevent — and would make `primary` a subscript that traps. It
    /// would also let a `pair` of one symbol be written twice, giving the drawing `ForEach` duplicate
    /// ids. With this shape an empty mark is unrepresentable and a duplicate is impossible, which is the
    /// same move as `StrainScore.hasMeasurement` being a required initialiser parameter.
    ///
    /// **It is `Drawing` and not `Mark`**: this repo already uses "mark" for the typical-range band
    /// (`BandMarkGlyph`, `Theme.bandMarkFill`, `TypicalRangeBar.markDash`), so `ActivityGlyph.Mark`
    /// would read as that band's mark for an activity.
    public struct Drawing: Equatable, Sendable {
        public let primary: String
        public let secondary: String?

        public var symbols: [String] { secondary.map { [primary, $0] } ?? [primary] }
        public var isComposite: Bool { secondary != nil }

        public static func single(_ symbol: String) -> Drawing {
            Drawing(primary: symbol, secondary: nil)
        }

        public static func pair(_ primary: String, _ secondary: String) -> Drawing {
            Drawing(primary: primary, secondary: secondary)
        }
    }

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

    /// The name → drawing table, keyed by the lowercased and trimmed name.
    ///
    /// ## Two producers, one table
    ///
    /// It was written for `workouts.csv`'s own distinct `Activity name` values — 21 of them, measured,
    /// 673 of 673 rows non-empty. **It now also serves `WhoopActivityCatalog`**, whose rows the edit
    /// sheet's picker draws a chip for, and the two vocabularies are not the same set: the catalogue
    /// carries names no row in the file uses (`Racquetball`, `Curling`, `F45 Training`), while the file
    /// carries names the catalogue omits (`American Football` — the one key below that is not a
    /// catalogue name; the catalogue lists `Football`). Neither is a superset, so keys from both live
    /// here and a name only one of them produces still resolves.
    ///
    /// ## One entry is a pair
    ///
    /// `Fast` draws `fork.knife` then `timer` — see `Drawing`. It is the only composite, and the four
    /// draw sites give every drawing a frame of a fixed size, which is why the geometry constants above
    /// exist and why §19 asserts the pair fits each of them rather than leaving it to a screenshot.
    ///
    /// ## The two words that are deliberately absent
    ///
    /// `Activity` (197 of the file's 673 rows) and `Other` (11) are **not** here and take the fallback:
    /// WHOOP's two words for an activity it did not categorise are not activities, and giving them a
    /// glyph of their own would claim a distinction the file does not make. `Activity` is *in the
    /// catalogue* — the picker has to offer it or those 197 rows open on an unticked list — so the
    /// catalogue having a name is not on its own a reason for this table to hold it, and this is the
    /// pair where the two rules would otherwise look like they disagreed.
    ///
    /// ## What is still unmapped, and why that is the ordinary case
    ///
    /// Most of the catalogue has no entry: a sauna, a massage, `Bartending`, `Poker`, `Cooking` and
    /// `Public Speaking` are sessions rather than sports, and SF Symbols has no figure for them at all
    /// (`figure.cooking`, `figure.darts` and `figure.billiards` do not exist as symbol names). Those
    /// draw the fallback — a running figure, which is a **wrong drawing rather than a missing one** —
    /// and it is the same mark this card drew for every workout before this table existed.
    ///
    /// Three near-neighbours are deliberate and are named as such rather than left to look like
    /// mistakes: `Ballet` and `Breakdancing` take `figure.dance`, `Triathlon` and `Duathlon` take
    /// `figure.mixed.cardio`, and `Jiu Jitsu`, `Judo` and `Muay Thai` share `figure.martial.arts` —
    /// the same bargain `Trampoline` already makes below.
    private static let marks: [String: Drawing] = [
        "walking": .single("figure.walk"),
        "yoga": .single("figure.yoga"),
        "dance": .single("figure.dance"),
        "basketball": .single("figure.basketball"),
        "manual labor": .single("hammer.fill"),
        "hiking": .single("figure.hiking"),
        "american football": .single("figure.american.football"),
        "road biking": .single("figure.outdoor.cycle"),
        "mountain biking": .single("figure.outdoor.cycle"),
        "running": .single("figure.run"),
        // SF Symbols has no trampoline; gymnastics is the nearest named movement, and it is a
        // nearest-neighbour rather than the sport.
        "trampoline": .single("figure.gymnastics"),
        "martial arts": .single("figure.martial.arts"),
        "tennis": .single("figure.tennis"),
        "soccer": .single("figure.soccer"),
        "swimming": .single("figure.pool.swim"),
        "boxing": .single("figure.boxing"),
        "volleyball": .single("figure.volleyball"),
        // `figure.ice.skating` is iOS 18 and the target is 17.0 — see the type comment.
        "ice skating": .single("figure.skating"),
        "yard work/gardening": .single("leaf.fill"),

        // MARK: The catalogue's sports

        // WHOOP's own typo for Archery, kept as published — the key is the name the producer writes, and
        // "correcting" it would leave the row a file actually carries unmatched.
        "archercy": .single("figure.archery"),
        "assault bike": .single("figure.indoor.cycle"),
        "australian rules football": .single("figure.australian.football"),
        "badminton": .single("figure.badminton"),
        "ballet": .single("figure.dance"),
        "baseball": .single("figure.baseball"),
        "bodybuilding": .single("figure.strengthtraining.traditional"),
        "bouldering": .single("figure.climbing"),
        "bowling": .single("figure.bowling"),
        "box fitness": .single("figure.boxing"),
        "breakdancing": .single("figure.dance"),
        "climber": .single("figure.climbing"),
        "cricket": .single("figure.cricket"),
        "cross country skiing": .single("figure.skiing.crosscountry"),
        "curling": .single("figure.curling"),
        "disc golf": .single("figure.disc.sports"),
        "duathlon": .single("figure.mixed.cardio"),
        "elliptical": .single("figure.elliptical"),
        "f45 training": .single("figure.highintensity.intervaltraining"),
        "fencing": .single("figure.fencing"),
        "fishing": .single("figure.fishing"),
        // The catalogue lists `Football` and no `American Football`; the CSV lists the opposite. Both
        // keys are here for that reason — see this table's comment.
        "football": .single("figure.soccer"),
        "functional fitness": .single("figure.strengthtraining.functional"),
        "gaming": .single("gamecontroller.fill"),
        "golf": .single("figure.golf"),
        "gymnastics": .single("figure.gymnastics"),
        "handball": .single("figure.handball"),
        "hiit": .single("figure.highintensity.intervaltraining"),
        "horseback riding": .single("figure.equestrian.sports"),
        "hot yoga": .single("figure.yoga"),
        "ice hockey": .single("figure.hockey"),
        "inline skating": .single("figure.skating"),
        "jiu jitsu": .single("figure.martial.arts"),
        "judo": .single("figure.martial.arts"),
        "jumping rope": .single("figure.jumprope"),
        "kickboxing": .single("figure.kickboxing"),
        "lacrosse": .single("figure.lacrosse"),
        "mountaineering": .single("figure.hiking"),
        "muay thai": .single("figure.martial.arts"),
        "nordic walking": .single("figure.walk"),
        "obstacle course racing": .single("figure.run"),
        "paddle tennis": .single("figure.tennis"),
        "padel": .single("figure.tennis"),
        "pickleball": .single("figure.pickleball"),
        "pilates": .single("figure.pilates"),
        "powerlifting": .single("figure.strengthtraining.traditional"),
        "race walking": .single("figure.walk"),
        "racquetball": .single("figure.racquetball"),
        "reformer pilates": .single("figure.pilates"),
        "rock climbing": .single("figure.climbing"),
        // `figure.indoor.rowing` and `figure.outdoor.rowing` are both iOS 18; `figure.rower` is iOS 16
        // and is the same stroke.
        "rowing": .single("figure.rower"),
        "rugby": .single("figure.rugby"),
        "sailing": .single("figure.sailing"),
        "sculpt yoga": .single("figure.yoga"),
        "ski touring": .single("figure.skiing.crosscountry"),
        "skiing": .single("figure.skiing.downhill"),
        // `figure.skateboarding` is iOS 18 — see the type comment.
        "snowboarding": .single("figure.snowboarding"),
        "softball": .single("figure.softball"),
        "spin": .single("figure.indoor.cycle"),
        "sport fishing": .single("figure.fishing"),
        "sprint training": .single("figure.run"),
        "squash": .single("figure.squash"),
        "stadium steps": .single("figure.stair.stepper"),
        "stairmaster": .single("figure.stair.stepper"),
        "surfing": .single("figure.surfing"),
        "table tennis/ping pong": .single("figure.table.tennis"),
        "track & field": .single("figure.track.and.field"),
        "trail running": .single("figure.run"),
        "triathlon": .single("figure.mixed.cardio"),
        "ultimate": .single("figure.disc.sports"),
        "water polo": .single("figure.waterpolo"),
        "weightlifting": .single("figure.strengthtraining.traditional"),
        "wrestling": .single("figure.wrestling"),

        // MARK: The catalogue's recovery activities

        "breathwork": .single("figure.mind.and.body"),
        "guided breathing - increase alertness": .single("figure.mind.and.body"),
        "guided breathing - increase relaxation": .single("figure.mind.and.body"),
        "meditation": .single("figure.mind.and.body"),
        "qigong": .single("figure.mind.and.body"),
        "restorative yoga": .single("figure.yoga"),

        // The user's own addition, and the app's only composite mark. `fork.knife` then `timer`, in
        // that order — the order is the specification and `.pair` preserves it. The food mark leads
        // because the label under it reads `FAST`, so the pair reads as *fasting, for a duration*.
        "fast": .pair("fork.knife", "timer"),
        "stretching": .single("figure.flexibility"),
        "tai chi": .single("figure.mind.and.body"),

        // MARK: The receptive catalogue
        //
        // `ReceptiveInactivityCatalog`'s own names, keyed normalised like every entry above. **Three of its
        // thirteen names are absent here on purpose** — `Meditation`, `QiGong` and `Breathwork` are the
        // catalogue's spelling of the three recovery activities already in the block above, so they
        // resolve to those entries and a second copy would be a second place for one phenomenon's mark to
        // be changed. `ReceptiveInactivityCatalogTests` sweeps the whole list through `mark(for:)`, which is
        // what notices a name added to that list without an entry here.
        //
        // **Every symbol is a deliberate choice rather than a nearest available figure, which is the
        // opposite of the sports block's rule above** — a receptive inactivity is a state rather than a
        // movement, so there is no `figure.*` to borrow for most of these and the symbol is picked for what
        // it depicts: sleep for the sleep-adjacent states, sound for the ones that are a thing heard, and a
        // place or an element for the ones that are a place the body is put.
        "dream": .single("moon.stars.fill"),
        "lucid dream": .single("sparkles"),
        // Deliberately **not** `zzz`. This is the one name in the catalogue that states what it is not —
        // the practice is deep rest taken *awake*, which is the whole of what the abbreviation spells —
        // and a sleep mark beside the word `Non-sleep` would draw the opposite of the row it labels,
        // which is the failure `ReceptiveInactivityCatalogTests`' fallback sweep exists to catch. It joins
        // the mental-rest family above instead, so it draws what `Meditation` and `QiGong` draw.
        "non-sleep, deep rest": .single("figure.mind.and.body"),
        // `figure.yoga` and not `figure.mind.and.body`: the practice is the one WHOOP files under
        // `Recovery Activities` as a yoga, and the two marks must not differ from `Yoga`'s above.
        "yoga nidra": .single("figure.yoga"),
        // A scan is done standing still — `figure.stand` is a body upright and still, which is the state
        // rather than the practice.
        "body scan": .single("figure.stand"),
        "stillness": .single("circle.dotted"),
        "sound bath": .single("waveform"),
        "float": .single("water.waves"),
        // `heat.waves` is iOS 17.0 — the deployment target exactly. A `sauna` symbol does not exist, and
        // the nearest alternatives (`flame.fill`, `thermometer.sun`) depict a fire or a reading rather
        // than the room.
        "sauna": .single("heat.waves"),
        "prayer": .single("hands.sparkles"),
    ]

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
        guard let key = ActivityName.normalised(name) else { return .single(fallback) }
        return marks[key] ?? .single(fallback)
    }
}
