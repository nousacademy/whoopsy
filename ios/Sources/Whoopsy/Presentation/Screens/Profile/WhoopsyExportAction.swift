import Foundation

/// The profile page's `Whoopsy` section: the row that writes this app's own record out, what it is
/// called and what it promises.
///
/// **A plain value rather than a button written into the view**, on `WhoopImportAction`'s rule and for
/// its reason: the runner has no renderer, so a title or a caption typed into a `body` is a string
/// nothing can assert. It is the `FastingImportAction` shape rather than the
/// `WhoopImportAction` one, because there is one row here and no file to enumerate — the subject is the
/// whole store.
///
/// **The section is named for who produced the file, like the three above it.** `Apple Health`,
/// `Whoop` and `Zero Fasting` each name the app the data came *from*, and that is the line this section
/// sits on the other side of: those three bring another app's history in, and this one takes Whoopsy's
/// own history out. Naming it `Whoopsy` is the same sentence the other three headers are making, which is
/// why the section title is a constant here rather than a literal at the call site — the runner asserts
/// it, and a header typed into the view is a header nothing can read.
///
/// **It replaced a section called `Local backup`, and the two words that changed are both corrections.**
/// `Local` was a claim about where the data lives, and it is not true of this export any more: the file
/// holds everything stored *wherever* it is stored — the SQLite database and the `UserDefaults` beside
/// it — which is the user's own scope decision, *"everything from wherever user stores their data, local
/// or a database"*. `Backup` was the more consequential of the two, because it promises a restore this
/// app does not have: nothing in `Sources/` reads an exported file back, so the honest word is
/// `export`, and the caption says so on its face rather than leaving a reader to find out.
///
/// **The title is stored in the case it is drawn in** — capitals, tracked — rather than being
/// lower-cased here and uppercased with a `.textCase` in the view: this app's button idiom is bold
/// tracked capitals (`SAVE`, `END`), and a `.textCase` would put half of what the reader sees in a
/// `body` where nothing can assert it. **The caption carries no Markdown** — it is a `String` built with
/// `+`, which takes `Text`'s `StringProtocol` overload rather than `LocalizedStringKey`, so a phrase in
/// asterisks or a filename in backticks would render literally, characters and all.
public struct WhoopsyExportAction: Sendable, Equatable {

    /// The section header, in the case it is drawn in — which is `Form`'s, so it is plain here.
    ///
    /// It matches the four headers above it, all of which name the app a file came from.
    public static let sectionTitle = "Whoopsy"

    /// The button's own words, in the case they are drawn in.
    public let title: String

    /// The sentence drawn under it.
    ///
    /// **It names the two stores, because that is the part a reader cannot see.** The four tables a
    /// screen draws from are the visible half; the unit choice and the three toggles — including the
    /// anonymous-diagnostics switch that is the entire contents of the Settings page — live in
    /// `UserDefaults` and appear on no screen beside it, so a caption that described only the database
    /// would describe a file smaller than the one the button writes.
    ///
    /// **It says there is no time limit**, which is the difference from what this button did before: the
    /// window it used to read was thirty days, so a reader who has seen the old file may reasonably
    /// expect a recent slice, and the caption is where that expectation is corrected.
    ///
    /// **It says the file is not read back**, which is the claim the word `backup` used to make and the
    /// one this app cannot keep. The two figures a fast has behind it and the four the imports skip are
    /// stated on the captions above for the same reason — a behaviour that is not visible from the button
    /// belongs in the sentence under it.
    public let caption: String

    /// The section's one row.
    ///
    /// **It is one row and not a `[WhoopsyExportAction]`**, unlike the `Whoop` section, because there is
    /// nothing to enumerate: one button writes the whole record, and a second button beside it would be
    /// a second definition of what the record is. The `CSV` is not a second row for that same reason —
    /// it is written by the same press, and it is a rendering of one table the JSON already carries in
    /// full rather than a separate export.
    public static let export = WhoopsyExportAction(
        title: "EXPORT WHOOPSY DATA",
        caption: "Writes everything Whoopsy has stored into one JSON file: every row of every table "
            + "in the local database, and the settings kept outside it such as your unit choice and "
            + "the diagnostics toggle. There is no time limit on it, so your whole record goes rather "
            + "than a recent window. Heart rate is also written as a CSV, the one series here a "
            + "spreadsheet can chart. Nothing in the app reads this file back.")
}
