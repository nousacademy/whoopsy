import Foundation

/// One row of the profile page's `Receptive inactivities` section: which bundled file the button
/// imports, what it is called and what it promises.
///
/// **A plain value rather than a button written into the view**, on `WhoopImportAction`'s and
/// `FastingImportAction`'s rule and for their reason: the runner has no renderer, so a title or a
/// caption typed into a `body` is a string nothing can assert, and the section's shape — one row,
/// titled thus, promising this — is exactly what is worth pinning. `ProfileDashboardView` draws from
/// `inactivities` rather than restating the words, so the button and the assertion cannot come apart.
///
/// **It is the third section on that pane and the first whose header does not name a producer app.**
/// `Apple Health`, `Whoop` and `Zero Fasting` each name the app a file came *from*, because each of
/// those files is another service's export of a record that service measured. There is no such app
/// here: the file is the owner's own notes log, so the only thing the header can honestly name is the
/// row the import produces — `Receptive inactivities`, the same words as the Home card it fills. That
/// is a deliberate deviation and it is recorded rather than smoothed over.
///
/// **Its own protocol and its own summary, not a case on either import above it.** The row type is
/// what separates it: `WhoopExportImporter` and `ZeroFastingImporter` both write `workouts`, and this
/// one writes `receptive_inactivities` — a table whose rows have no span, no strain and no measurement
/// of any kind. Folding it into either would mean an importer writing two tables and answering a
/// summary about one of them. See `InactivityImporting`.
///
/// **The title is stored in the case it is drawn in** — capitals, tracked — rather than being
/// lower-cased here and uppercased with a `.textCase` in the view, on `FastingImportAction`'s
/// argument: a `.textCase` would put half of what the reader sees in a `body` where nothing can read
/// it. **The caption carries no Markdown** — it is a `String` built with `+`, which takes `Text`'s
/// `StringProtocol` overload rather than `LocalizedStringKey`, so a filename in backticks would render
/// literally, characters and all.
public struct InactivityImportAction: Sendable, Equatable {

    /// The section header, in the case it is drawn in — which is `Form`'s, so it is plain here.
    ///
    /// **It is the one header on this pane that does not name a producer app, and the deviation is the
    /// point of holding it here.** `Apple Health`, `Whoop` and `Zero Fasting` each name the app a file
    /// came *from*, because each of those files is another service's export of a record that service
    /// measured. There is no such app here: the file is the owner's own notes log, so the only thing
    /// this header can honestly name is the row the import produces — `Receptive inactivities`, the
    /// same two words as the Home card it fills. `WhoopsyExportAction.sectionTitle`'s rule applies:
    /// held as a constant rather than typed into the `body`, so §18 can read it and the deviation is
    /// assertable rather than a claim in a comment.
    public static let sectionTitle = "Receptive inactivities"

    /// The file's name **as the reader knows it and as the screen says it** — `dreams.json`, the
    /// generator's own output beside the notes file it was drawn from.
    ///
    /// It is deliberately a separate constant from `InactivityImporter.bundledResourceName`, on the
    /// split `FastingImportAction` already carries: the name on screen and the name of the resource
    /// answer to different readers, and here they happen to agree today. A future rename of the
    /// bundled file — or of the button's copy — moves one without dragging the other, and §18 pins
    /// this one while §21 pins the resource's.
    public static let fileName = "dreams.json"

    /// The button's own words, in the case they are drawn in.
    public let title: String

    /// The sentence drawn under it. It states what lands, that no entry carries a time, and what a
    /// re-import does to an edit — none of which is visible from the button.
    public let caption: String

    /// The section's one row.
    ///
    /// **The re-import clause is the one a reader has to be told**, and it is the same asymmetry §20
    /// records for fasts: this import deliberately skips no day, because each entry's primary key is
    /// derived from its own content and is therefore disjoint from every other producer's — so a write
    /// can only ever touch a row this import put there, and a skip would protect nothing. The cost of
    /// that is that pressing the button again recomputes the same id from the unchanged file and
    /// `save`s the file's original text back over the user's, silently, since both are `Dream` rows on
    /// the same day. The export's caption restates its own version of this rather than inheriting it,
    /// on `FastingImportAction`'s rule: the two arrive at "a deleted row comes back" from opposite
    /// directions, so one caption cannot be read off the other.
    ///
    /// **The "text stays in the file rather than in the app" clause this caption once carried is
    /// gone, because the reversal made it false.** The prose is read *and stored* — `v22` adds
    /// `receptive_inactivities.note` — so the caption says "carries its text" rather than promising a
    /// reader that the app holds nothing.
    public static let inactivities = InactivityImportAction(
        title: "IMPORT RECEPTIVE INACTIVITIES",
        caption: "Loads " + fileName + " — your own notes with their dates resolved. Every entry is "
            + "filed on its day as a receptive inactivity named by its own type, and carries its text. "
            + "No entry has a time, so none draws a clock. Re-importing writes the file's text back "
            + "over any edit you have made to an entry.")
}
