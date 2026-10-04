import SwiftUI

/// One name in a picker list: the glyph in its leading gutter, the word beside it, and a checkmark when
/// it is the selected one.
///
/// ## Why it is a component rather than a helper on each picker
///
/// There are two activity pickers now — `ActivityPickerView` for WHOOP's published vocabulary and
/// `ReceptiveInactivityPickerView` for this app's own — and they offer different lists, draw different
/// section structures and select from different catalogues. What they must not differ in is the *row*:
/// the same 16 pt glyph in the same `ActivityGlyph.listGutter` column, the same 15 pt label, the same
/// `Theme.actionTint` checkmark.
///
/// **Two copies of that would not stay identical, and nothing in this repo could see the drift.** The
/// runner has no renderer, so a row's spacing is invisible to every assertion in the suite, and a picker
/// whose rows sat a few points off would read as a styling choice rather than as a bug — the shape
/// `SleepStressShareBar`'s three restated constants already record as a cost. Here the extraction is
/// free: no existing assertion reads the row, so moving it takes nothing with it.
///
/// ## The selection test and the write stay at the call site
///
/// This type is told `isSelected` and given an `onSelect`; it does not know what a selection *is*. That
/// split is deliberate even though **both pickers happen to answer the question the same way** —
/// `ActivityName.matches`, so a stored `"basketball"` ticks the catalogue's `Basketball` — because the
/// two arrive there for different reasons and only one of them can lean on the list it draws.
/// `ActivityPickerView` offers WHOOP's published vocabulary and has a stored name it may not hold;
/// `ReceptiveInactivityPickerView`'s list is app-owned and exhaustive, so exact equality would be enough
/// for every name its own sheet ever wrote, and the tolerant test is there for a row that reached the
/// table some other way. Putting the comparison here would make the row's contract "compare these two
/// names" and hand it a rule about names it has no business holding — the same reason the *write* stays
/// at the call site, which is where the draft's setter lives.
///
/// The whole row is the target, so there is no chevron and no disclosure control to misread as the
/// thing that selects.
public struct ActivityPickerRow: View {

    private let name: String
    private let isSelected: Bool
    private let onSelect: () -> Void

    public init(name: String, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.name = name
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ActivityGlyphLabel(ActivityGlyph.mark(for: name), size: 16, weight: .medium)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: ActivityGlyph.listGutter)

                Text(name)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.actionTint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
