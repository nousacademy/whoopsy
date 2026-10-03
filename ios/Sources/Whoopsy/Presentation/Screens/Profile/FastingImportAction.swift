import Foundation

/// One row of the profile page's `Zero Fasting` section: which bundled file the button imports, what it
/// is called and what it promises.
///
/// **A plain value rather than a button written into the view**, on `WhoopImportAction`'s rule and for
/// its reason: the runner has no renderer, so a title or a caption typed into a `body` is a string
/// nothing can assert, and the section's shape — one row, titled thus, promising this — is exactly what
/// is worth pinning. `ProfileDashboardView` draws from `fasting` rather than restating the words, so the
/// button and the assertion cannot come apart.
///
/// **It is deliberately *not* a fourth `WhoopImportAction`, and not a case on `WhoopExportFile`.** Three
/// things separate it, and each is a reason rather than a detail. The file is a different producer's —
/// a fasting tracker's history rather than WHOOP's — so a row in the `Whoop` section would put rows in
/// `workouts` that WHOOP never recorded under a header named for who produced the files. Its rows carry
/// **no measurement at all**: a fast has no strain, no heart rate and no zone block, which is the whole
/// of why `v18` relaxed those columns, and `ActivityFigure` draws a dash for each. And it is the one
/// import here that **skips no day** — a fast's primary key is Zero's own `FastID`, disjoint from every
/// other producer's, so a write can only ever touch a fast row and a day check would drop fasts on
/// precisely the days the two files overlap. `WhoopExportImporter.recordedWorkoutDays()` carries the
/// matching half of that pair by filtering fasts out of the day set it skips against.
///
/// **Which file the caption names, and why it is not the name of the resource.** The screen says
/// `biodata.json`, because that is the file Zero gives a user when they export their own data and it is
/// therefore the name a reader recognises. What actually ships inside this build is `fasts.json` — the
/// same fasts, being that export's `fast_data` array projected down to the one key the importer reads,
/// which is why the two names describe one file rather than two. They differ because `biodata.json`
/// itself is 599 KB across nineteen top-level keys, 92% of which this app does not read, and because the
/// whole `Data/Resources/ZeroFasting/` directory is gitignored as a real person's record — so shipping
/// the export itself would put that record in the app bundle. The name on screen is `fileName` below and
/// the name of the resource is `ZeroFastingImporter.bundledResourceName`; §18 and §20 pin one each, so
/// neither drifts into the other. `ZeroFastingParser.parseFasts` refuses any payload that is not
/// `{"fast_data": […]}` with `.missingFastData`, which is what makes pointing the importer at the raw
/// file — or at any of its other eighteen keys — fail loudly rather than report a successful import of
/// nothing.
///
/// **The title is stored in the case it is drawn in** — capitals, tracked — rather than being
/// lower-cased here and uppercased with a `.textCase` in the view: this app's button idiom is bold
/// tracked capitals (`SAVE`, `END`), and a `.textCase` would put half of what the reader sees in a
/// `body` where nothing can read it. **The caption carries no Markdown** — it is a `String` built with
/// `+`, which takes `Text`'s `StringProtocol` overload rather than `LocalizedStringKey`, so a filename
/// in backticks or a phrase in asterisks would render literally, characters and all.
public struct FastingImportAction: Sendable, Equatable {

    /// The file's name **as the producer writes it and as the screen says it** — `biodata.json`, the
    /// file Zero hands a user who exports their own data.
    ///
    /// It is deliberately not the name of the bundled resource (`fasts.json`, on
    /// `ZeroFastingImporter.bundledResourceName`): the two hold the same fasts, and the resource's name
    /// is a build detail while this one is what a reader recognises. The caption is built from this
    /// constant rather than repeating the word, so the sentence cannot come to name a file the app does
    /// not claim to read.
    public static let fileName = "biodata.json"

    /// The button's own words, in the case they are drawn in.
    public let title: String

    /// The sentence drawn under it. It states what lands, what a fast has behind it, and what a
    /// re-import does to a fast the user deleted — none of which is visible from the button.
    public let caption: String

    /// The section's one row.
    ///
    /// **The caveat is stated rather than inherited**, which is the same rule the three `Whoop` captions
    /// follow: the export happens to share the behaviour, but an import that skips days and one that
    /// skips none arrive at "a deleted row comes back" from opposite directions, so one caption cannot
    /// be read off the other.
    public static let fasting = FastingImportAction(
        title: "IMPORT FASTING HISTORY",
        caption: "Loads " + fileName + " — the Zero app's own fasting history — as activities filed "
            + "under the day each fast started. A fast has no heart rate or strain behind it, so those "
            + "figures stay blank. Unlike the WHOOP imports this one skips nothing, because a fast's "
            + "id is its own; re-importing is therefore safe, but a fast you deleted will come back.")
}
