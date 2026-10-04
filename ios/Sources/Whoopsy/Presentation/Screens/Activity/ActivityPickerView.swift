import SwiftUI

/// The activity-type picker, pushed from the `EDIT ACTIVITY` sheet's activity row.
///
/// ## WHOOP's own vocabulary, in WHOOP's own two groups
///
/// The list is `WhoopActivityCatalog` — WHOOP's published activity names, **curated** — offered
/// as **two sections**, Strain Activities and Recovery Activities, because that is the split WHOOP
/// publishes and the split is real: a sauna and a massage have no meaningful cardiovascular load, and
/// the strain figure this app stores does not describe them. The two lists are kept apart in the
/// catalogue for that reason rather than merged into one alphabetical run, and this view draws them
/// apart for the same one.
///
/// **Three names here are not on WHOOP's page, and their presence is deliberate** — see the
/// catalogue's own comment. Two of them are prepended to their sections rather than sorted in:
/// `Activity` at the head of the strain list and `Fast` at the head of the recovery one, so each
/// is a decision this app makes rather than a consequence of the letter it starts with. `Fast` is
/// the only name whose row draws **two** symbols.
///
/// ## The stored name is offered even when it is not on the list
///
/// The file is **not** a subset of the published list. `Activity` — WHOOP's own abstention word, on 197
/// of the bundled export's 673 rows — is not published at all, and it is in the catalogue for that
/// reason. But the picker cannot assume the catalogue is exhaustive of what is *stored*: a name could
/// have come from a future export, a hand-edited row, or a build whose catalogue differed. So a
/// selection the catalogue does not hold is drawn as a section of its own, marked selected, and any
/// other pick is what replaces it. The alternative — opening on a list with nothing ticked — reads as
/// the app having lost the value.
///
/// **It asks `WhoopActivityCatalog.contains(_:)` rather than comparing strings itself**, so the
/// membership test is the same case- and whitespace-tolerant one the selection ticks with: a stored
/// `"basketball"` is the catalogue's `Basketball`, and a raw comparison would draw an extra *Current*
/// row for a name that is also in the section below it, ticked twice on one screen.
///
/// ## It writes one value and pops
///
/// The binding is the draft's own `activityName` through `ActivityEditDraft.setName(_:)`, which is what
/// keeps this the second writer of the same field rather than a second field. `dismiss()` pops back to
/// the sheet, which is what a picker that has just been answered does.
public struct ActivityPickerView: View {

    /// The draft's activity name. Writing it goes through the draft's setter — see this type's comment.
    @Binding private var selection: String?

    @Environment(\.dismiss) private var dismiss

    public init(selection: Binding<String?>) {
        self._selection = selection
    }

    /// The picker's title, and the two section headings. `nonisolated static` for this feature's standing
    /// reason: the runner has no renderer, so a literal inside a `body` is one nothing can assert.
    public nonisolated static let title = "Activity"
    public nonisolated static let strainSectionTitle = "Strain Activities"
    public nonisolated static let recoverySectionTitle = "Recovery Activities"

    /// What the section holding a stored name the catalogue does not offer is called.
    public nonisolated static let currentSectionTitle = ActivityEditSheet.currentSectionTitle

    public var body: some View {
        List {
            if let current = unlistedSelection {
                Section(Self.currentSectionTitle) {
                    row(current)
                }
            }

            Section(Self.strainSectionTitle) {
                ForEach(WhoopActivityCatalog.strainActivities, id: \.self) { name in
                    row(name)
                }
            }

            Section(Self.recoverySectionTitle) {
                ForEach(WhoopActivityCatalog.recoveryActivities, id: \.self) { name in
                    row(name)
                }
            }
        }
        // A grouped `List` draws its own background, which would put a light slab inside a dark sheet.
        // Hiding it leaves the sheet's own colour showing between the rows.
        .scrollContentBackground(.hidden)
        .background(Theme.backgroundDark)
        .navigationTitle(Self.title)
        .inlineNavigationTitle()
        .preferredColorScheme(.dark)
    }

    /// The stored name, when the catalogue does not hold it. See this type's comment.
    private var unlistedSelection: String? {
        guard let selection, !selection.isEmpty else { return nil }
        return WhoopActivityCatalog.contains(selection) ? nil : selection
    }

    /// One name. The row itself is `ActivityPickerRow`, shared with the receptive picker so the two
    /// lists cannot draw one name two ways; what stays here is the two things that are *this* picker's —
    /// the case- and whitespace-tolerant selection test, and writing the draft's field on a pick.
    private func row(_ name: String) -> some View {
        ActivityPickerRow(name: name, isSelected: ActivityName.matches(name, selection)) {
            selection = name
            dismiss()
        }
    }
}
