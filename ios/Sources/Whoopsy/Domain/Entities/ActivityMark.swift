import Foundation

/// What an activity's name draws: one SF Symbol, or **two, in order**.
///
/// ## Why this is not in `Presentation`
///
/// It was, as `ActivityGlyph.Drawing` and `ActivityGlyph`'s private table, and the rule that a name is
/// the presentation layer's to translate is still right for every screen. The **Live Activity** is the
/// exception that forces the move: the lock screen card draws the running session's mark, and the
/// widget extension cannot import `Whoopsy` — so the symbols have to be resolved in the app and pushed
/// through `LiveSessionActivityState`, which is `Domain`. A table living in `Presentation` could not be
/// read there without the use case reaching upward, which is the one direction this codebase forbids.
///
/// So the mapping moved down one layer, and `ActivityGlyph` forwards to it. **The table is unmoved** —
/// every key and every symbol below is the one the app has drawn since `v15`, and §17's sweep still
/// drives it, now through the forwarder.
public struct ActivityMark: Equatable, Sendable {
    public let primary: String
    public let secondary: String?

    public var symbols: [String] { secondary.map { [primary, $0] } ?? [primary] }
    public var isComposite: Bool { secondary != nil }

    public static func single(_ symbol: String) -> ActivityMark {
        ActivityMark(primary: symbol, secondary: nil)
    }

    public static func pair(_ primary: String, _ secondary: String) -> ActivityMark {
        ActivityMark(primary: primary, secondary: secondary)
    }
}

/// The one name → mark table.
public enum ActivityMarkCatalog {

    /// The fallback's symbol, and the one the card drew for **every** workout before the table existed.
    /// A name this table does not hold renders exactly as it did, so an unrecognised activity is a
    /// missing nicety rather than a regression.
    public static let fallback = "figure.run"

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
    private static let marks: [String: ActivityMark] = [
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
        // fourteen names are absent here on purpose** — `Meditation`, `QiGong` and `Breathwork` are the
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
        // `leaf` because there is no `cannabis` symbol: the row names a plant, and the outline leaf is
        // the object itself rather than a state — the one entry in this block that depicts a thing.
        // Available long before the 17.0 floor, so unlike `heat.waves` it carries no availability note.
        "cannabis": .single("leaf"),
    ]

    /// What `name` draws, or the fallback mark when the table has no entry for it.
    ///
    /// Matched through `ActivityName.normalised`, which is why this type sits beside that one rather
    /// than in `Core`: the normalisation is a rule, not a copy, and the activity detail page groups a
    /// session with its own history by the same one.
    public static func mark(for name: String?) -> ActivityMark {
        guard let key = ActivityName.normalised(name) else { return .single(fallback) }
        return marks[key] ?? .single(fallback)
    }
}
