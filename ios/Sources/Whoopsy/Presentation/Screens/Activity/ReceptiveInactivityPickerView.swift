import SwiftUI

/// The name picker the receptive sheet's NAME row pushes: a flat list of `ReceptiveInactivityCatalog`.
///
/// ## A sibling of `ActivityPickerView` rather than a parameterised copy of it
///
/// The two pickers offer two different vocabularies and answer two different questions. That view is
/// built around WHOOP's own two-group split — `Strain Activities` above `Recovery Activities` — because
/// that split is WHOOP's and it is real, and it carries an **unlisted-current** branch for a name the
/// catalogue does not hold, which a stored export row can genuinely be. This list is flat and is this
/// app's own: there is no second group for a heading to name, and nothing but the sheet writes a name
/// into it, so the unlisted branch would be a row that never draws.
///
/// **Both pickers draw the same row, though**, and that is what `ActivityPickerRow` exists for — see its
/// own comment for why the extraction is free here and what restating the row would cost.
///
/// No test in the tree names `ActivityPickerView`, so a sibling costs nothing that a parameterised
/// version would have preserved.
///
/// ## It writes one value and pops
///
/// The binding is the draft's own `name` through `ReceptiveInactivityDraft.setName(_:)`, exactly as the
/// activity picker writes through `ActivityEditDraft.setName(_:)` — so this is the second writer of one
/// field rather than a second field, and the draft's own comparison decides whether the sheet counts as
/// touched.
public struct ReceptiveInactivityPickerView: View {

    /// The draft's name. Writing it goes through the draft's setter — see this type's comment.
    @Binding private var selection: String?

    @Environment(\.dismiss) private var dismiss

    public init(selection: Binding<String?>) {
        self._selection = selection
    }

    /// The picker's title. `nonisolated static` for this feature's standing reason: the runner has no
    /// renderer, so a literal written into a `body` is a literal nothing can assert.
    public nonisolated static let title = "Receptive Inactivity"

    public var body: some View {
        // One section and no heading: thirteen names are a list, not a grouping, and a header over the
        // only section would repeat the title already drawn above it.
        List {
            ForEach(ReceptiveInactivityCatalog.names, id: \.self) { name in
                row(name)
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

    /// One name. The row is `ActivityPickerRow`, shared with the activity picker so the two lists cannot
    /// draw one name two ways; what stays here is the selection test and the write.
    ///
    /// **The test is `ActivityName.matches` and not `==`**, which is the one place this picker departs
    /// from `ActivityPickerRow`'s description of it. `==` would be enough for every name this sheet
    /// wrote, but a row whose name reached the table some other way — hand-edited, or written by a build
    /// whose catalogue differed — would then draw **nothing ticked at all**, and a picker that opens
    /// with no selection reads as the app having lost the value. The tolerant comparison costs nothing
    /// and cannot tick the wrong row, because the catalogue holds no two names that differ only in case.
    private func row(_ name: String) -> some View {
        ActivityPickerRow(name: name, isSelected: ActivityName.matches(name, selection)) {
            selection = name
            dismiss()
        }
    }
}
