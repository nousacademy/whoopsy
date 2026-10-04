import Foundation

/// The names a receptive inactivity can be recorded under — the vocabulary the sheet's picker offers.
///
/// ## Why this is a second catalogue rather than an addition to `WhoopActivityCatalog`
///
/// `WhoopActivityCatalog` is WHOOP's published activity list, curated: its split into strain and
/// recovery activities is *their* split, its names are typed onto a workout session, and every entry
/// answers a question about load — either a strain figure describes it or it was deliberately placed
/// in the list where none does. This is the opposite set. A receptive inactivity is a state the user was
/// **in** rather than a thing the body did, so folding these names into that type would put them under
/// a header (`Strain Activities` / `Recovery Activities`) that describes neither one, and would make
/// the edit sheet's picker offer a dream to a run.
///
/// It lives in `Domain/Entities/` beside `ActivityName` and `WhoopActivityCatalog`, for that type's
/// own reason: this is a fact about a vocabulary, `Domain` is where vocabularies live, and a
/// presentation type could not hold it — the picker is one reader and a future one (a default, a
/// validator) would not be a screen.
///
/// ## Four names are shared, and they are spelled the way the other catalogue spells them
///
/// `Meditation`, `Non-sleep, deep rest`, `QiGong` and `Breathwork` are already in
/// `WhoopActivityCatalog.recoveryActivities`, and this list carries each of them **verbatim** —
/// including the comma in `Non-sleep, deep rest` and the capital `G` in `QiGong`, both of which are
/// WHOOP's own strings and are kept there for that type's recorded reason (*"a 'fixed' name is a name
/// that no longer matches what a future export writes"*).
///
/// **One phenomenon gets one spelling.** `ActivityGlyph.mark(for:)` resolves a name through
/// `ActivityName.normalised`, so a meditation recorded either way already reaches one mark and draws
/// one chip; the risk this rule covers is the *name*, not the drawing — two spellings of one
/// phenomenon are two entries in two pickers that a reader would reasonably read as two different
/// practices. `ReceptiveInactivityCatalogTests` asserts the agreement against `WhoopActivityCatalog`
/// rather than leaving it to whoever edits either list next.
///
/// ## Every name here needs a mark, and the fallback is not available
///
/// `ActivityGlyph.mark(for:)` answers `figure.run` for a name its table does not hold. That is the
/// right answer for the many WHOOP activities this app has no glyph for, and it is the wrong answer
/// for every name below: a running figure beside `Dream` is not a missing drawing, it is a false one.
/// So every name in this list has an entry in `ActivityGlyph.marks`, and the test file sweeps the list
/// so that a name added without one fails there rather than on a screen — a wrong or absent SF Symbol
/// name draws an empty chip rather than raising anything, which makes it invisible to the compiler and
/// to any screenshot of a different row.
///
/// ## What is *not* here
///
/// Nothing WHOOP's own list already covers under the same name: `Body Scan` is an app-owned name
/// where `Guided Breathing - …` and `Restorative Yoga` are WHOOP's and stay in their catalogue, so a
/// reader who wants a restorative yoga session finds it in the activity picker where WHOOP put it
/// rather than finding a second spelling here.
public enum ReceptiveInactivityCatalog {

    /// The names the picker offers, in the order it draws them.
    ///
    /// Ordered as a reader would move through them rather than alphabetically: the sleep-adjacent
    /// states first, then the seated practices, then the ones that are a place the body is put. The
    /// order is a decision this type makes, so it is stated here instead of falling out of the first
    /// letter of each name — `WhoopActivityCatalog`'s `abstentionName` and `fastingName` are prepended
    /// for the same reason.
    public static let names: [String] = [
        "Dream",
        "Lucid dream",
        "Meditation",
        "Non-sleep, deep rest",
        "Yoga nidra",
        "QiGong",
        "Breathwork",
        "Body scan",
        "Stillness",
        "Sound bath",
        "Float",
        "Sauna",
        "Prayer",
    ]

    /// The app's spelling of a producer's own word for what was received.
    ///
    /// `dreams.json` writes `"type": "dream"` — the file's vocabulary, minted by a generator that knows
    /// nothing about this app — and the card must draw `Dream`, the word the picker offers, rather than
    /// an unlisted string that happens to look nearly the same. This is the one mapping between the two,
    /// and it is a **resolver rather than a validator**: an unmatched type is answered, not refused.
    ///
    /// **A type absent from ``names`` is capitalised and returned.** Throwing would make a producer's
    /// addition — a future file of `"type": "sound bath"`, or one carrying a practice this list has
    /// never heard of — a build-time problem for a row that is perfectly readable, and refusing it would
    /// lose the entry rather than the vocabulary. The capitalisation is cosmetic; the point is that the
    /// value survives.
    ///
    /// **The match is `ActivityName.normalised`'s**, so `"dream"`, `"Dream"` and `" DREAM "` are one
    /// type, and a future file's stray casing cannot mint a second `Dream` entry on the same day. That
    /// is the same rule `ActivityGlyph.mark(for:)` keys its table by, which is what keeps the name this
    /// returns and the chip it draws from being resolved two different ways — the second half of why the
    /// catalogue's own spellings are carried verbatim.
    ///
    /// It returns the **catalogue's** spelling and not the file's: `"dream"` resolves to `"Dream"`, so
    /// the sheet's picker shows its own row as the selected one when the user opens an imported entry,
    /// and `ActivityGlyph` needs no second key beside the `"dream"` it already holds.
    public static func name(for type: String) -> String {
        let key = ActivityName.normalised(type)
        if let match = names.first(where: { ActivityName.normalised($0) == key }) { return match }
        return type.capitalized
    }
}
