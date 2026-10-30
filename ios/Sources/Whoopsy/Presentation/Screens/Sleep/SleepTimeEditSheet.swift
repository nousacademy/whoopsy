import SwiftUI

/// The sheet the sleep page's pencil opens: the night's **two bounds, and nothing else**.
///
/// The user's instruction was *"add ability to edit like other activities in upper right corner, only
/// time"*, so this is `ActivityEditSheet`'s shape with the parts it cannot have removed. The activity
/// sheet edits a name, a window and an effort rating; a night has no name to change and no rating, and
/// its stage totals are what the strap or the export measured — a correction to *when* the night ran is
/// a different act from a claim about how it went. So the sheet draws two clock pickers and no third
/// row, and `SleepSession.withEditedTimes` carries every other field through untouched.
///
/// **It is a system `.sheet`**, for `ActivityEditSheet`'s reason: an editing surface is somewhere the
/// user goes and comes back from, and it draws on its own background — so it states
/// `Theme.backgroundDark` and `.preferredColorScheme(.dark)` itself or it is a light card in front of a
/// dark app.
///
/// **The day is printed and is not editable.** Both pickers are `.hourAndMinute`, so the row's day key
/// cannot move: `sleeps` is keyed by date, and a save that changed the key would leave the old row
/// behind under a day nothing reads. See `SleepTimeEditDraft.maximumSpanSeconds` for the span rule the
/// `SAVE` button enforces.
public struct SleepTimeEditSheet: View {

    @Binding private var draft: SleepTimeEditDraft

    /// Whether a write is in flight, so `SAVE` cannot be pressed twice over one edit.
    private let isSaving: Bool

    private let onSave: () -> Void

    /// The gutter every scrollable sheet here uses.
    private static let gutter: CGFloat = 16

    public nonisolated static let title = "EDIT SLEEP"
    public nonisolated static let saveTitle = "SAVE"
    public nonisolated static let startLabel = "BEDTIME"
    public nonisolated static let endLabel = "WAKE"
    public nonisolated static let invalidCaption =
        "The night has to end after it starts, and within a day."

    public init(
        draft: Binding<SleepTimeEditDraft>,
        isSaving: Bool,
        onSave: @escaping () -> Void
    ) {
        _draft = draft
        self.isSaving = isSaving
        self.onSave = onSave
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    timeRow(
                        title: Self.startLabel,
                        selection: Binding(
                            get: { draft.start },
                            set: { draft.start = $0 }),
                        identifier: "sleep.edit.start")

                    timeRow(
                        title: Self.endLabel,
                        selection: Binding(
                            get: { draft.end },
                            set: { draft.end = $0 }),
                        identifier: "sleep.edit.end")

                    if !draft.isValid {
                        Text(Self.invalidCaption)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.recoveryRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Self.gutter)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The scroll view is the sheet's whole surface, so its background is the sheet's
            // background: without this its frame is the content's width and the colour paints a column.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.backgroundDark)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { closeButton }
                ToolbarItem(placement: .principal) { titleLabel }
            }
            .safeAreaInset(edge: .bottom) { saveButton }
        }
        .preferredColorScheme(.dark)
    }

    private func timeRow(title: String, selection: Binding<Date>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title)

            HStack {
                DatePicker(
                    title,
                    selection: selection,
                    displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .accessibilityIdentifier(identifier)

                Spacer(minLength: 8)
            }
        }
    }

    private var titleLabel: some View {
        Text(Self.title)
            .font(.system(size: 14, weight: .bold))
            .tracking(1.0)
            .foregroundStyle(Theme.textPrimary)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityLabel("Cancel")
    }

    private var saveButton: some View {
        Button {
            onSave()
        } label: {
            Text(Self.saveTitle)
                .font(.system(size: 15, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.backgroundDark)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Theme.textPrimary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        // Both gates: nothing changed, or what changed to is not a night.
        .disabled(!draft.canSave || isSaving)
        // Held at a steady opacity rather than hidden while a write is in flight: the button is the
        // sheet's last element and a view that vanished under the finger would move the rows above it.
        .opacity((draft.canSave && !isSaving) ? 1 : 0.5)
        .padding(.horizontal, Self.gutter)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.backgroundDark)
    }

    @Environment(\.dismiss) private var dismiss
}
