import Foundation

/// One row of the profile page's `Whoop` section: which bundled file a button imports, what it is
/// called and what it promises.
///
/// **A plain value rather than three buttons written into the view**, which is this repo's standing
/// rule and has a second reason here. The runner has no renderer, so a title or a caption typed into a
/// `body` is a string nothing can assert — and the thing most worth asserting about this section is its
/// *shape*: that there are exactly three rows, that `journal_entries.csv` is not one of them, and that
/// the order is the order. A `[WhoopImportAction]` is all three of those facts at once, and
/// `ProfileDashboardView` draws it with a `ForEach` rather than listing buttons, so the count cannot
/// drift from the type.
///
/// **`all` is derived from `WhoopExportFile.allCases` and built by an exhaustive `switch`.** That is
/// what makes a fourth case a compile error here rather than a button that silently never appears: the
/// enum is `CaseIterable`, so a new case lands in `all` automatically and `make(for:)` refuses to
/// compile until it has been given a name and a sentence. The alternative — three `static let`s — would
/// compile perfectly while a fourth file shipped with no way to import it, which is the failure the
/// user's instruction is about in the first place: they named the one CSV they do *not* want, so the
/// section's job is to contain exactly the others.
///
/// **Why the titles do not repeat the section header.** The section is `Whoop`, so a row called
/// "IMPORT WHOOP NAPS" would say it twice; these name what lands, which is also the distinction that
/// matters, since the three files write five different tables between them and no two of the buttons
/// are interchangeable.
///
/// **The titles are stored in the case they are drawn in** — capitals, tracked — rather than being
/// lower-cased here and uppercased with a `.textCase` in the view. This app's button idiom is bold
/// tracked capitals (`SAVE`, `END`), and the runner has no renderer: a `.textCase` would put half of
/// what the reader sees in a `body` where nothing can assert it, so §18's title assertions would pin a
/// string that is not on the screen.
///
/// **The captions carry no Markdown.** They are `String`s built with `+`, which takes `Text`'s
/// `StringProtocol` overload rather than `LocalizedStringKey` — so a filename written between
/// backticks or a phrase wrapped in asterisks renders literally, characters and all. The filenames are
/// therefore plain words in the sentence.
public struct WhoopImportAction: Sendable, Equatable, Identifiable {

    /// The file this button imports. Also the identity — one button per file, by construction.
    public let file: WhoopExportFile

    /// The button's own words, in the case they are drawn in.
    public let title: String

    /// The sentence drawn under it. Every one of these states what the file writes and what the import
    /// will not touch, because idempotence is not visible from the button.
    public let caption: String

    public var id: WhoopExportFile { file }

    /// The three rows, in the order they are drawn — which is `WhoopExportFile.allCases`' order.
    ///
    /// Not sorted, filtered or otherwise rearranged: the declaration order of the enum is the order of
    /// the buttons, so moving a row up is moving a case up and not editing an array here.
    public static let all: [WhoopImportAction] = WhoopExportFile.allCases.map(make(for:))

    /// The one place a file becomes a row.
    ///
    /// Exhaustive on purpose — see the type's doc comment. `default:` would defeat the whole point.
    static func make(for file: WhoopExportFile) -> WhoopImportAction {
        switch file {
        case .cycles:
            return WhoopImportAction(
                file: .cycles,
                title: "IMPORT RECOVERY & SLEEP",
                caption: "Loads physiological_cycles.csv from this build: one recovery score, one "
                    + "night's sleep and one day's strain per day, so a new install shows your "
                    + "history instead of starting empty. Days already recorded on this device are "
                    + "left untouched, so edits you make are kept.")

        case .naps:
            return WhoopImportAction(
                file: .naps,
                title: "IMPORT NAPS",
                caption: "Loads the nap records out of sleeps.csv. A nap is filed on the day it was "
                    + "taken rather than the morning it ended, and it carries no performance figure — "
                    + "WHOOP scores a nap against a whole night's need, which would read a "
                    + "deliberate afternoon rest as a very poor night.")

        case .workouts:
            return WhoopImportAction(
                file: .workouts,
                title: "IMPORT WORKOUTS",
                caption: "Loads workouts.csv: every workout's window, activity name and heart-rate "
                    + "zone breakdown. This is the only producer of the zone figures on the strain "
                    + "and activity pages, so without it those rows show a dash. A day that already "
                    + "holds a workout is left untouched — but a workout you deleted will come back.")
        }
    }
}
