import SwiftUI

/// The sheet the `+` menu's `ADD ACTIVITY` row opens: an activity name and the window it happened in,
/// on the day Home was showing.
///
/// ## What it is for, and what it refuses to invent
///
/// A session this app records itself has a strap behind it; an imported one has WHOOP's file behind it.
/// This is the third case — the walk that happened before the app, the class the phone was in a locker
/// for — so the sheet writes a row with a **name and a window and no measurement at all**.
/// `AddActivityDraft.applying()` states that absence as `nil` strain, `nil` heart rates and empty
/// route and splits, which is the same shape the fasting producer writes and the reason both draw
/// dashes rather than a measured `0`.
///
/// ## It is a system `.sheet`, on `ActivityEditSheet`'s argument
///
/// An editing surface is a place the user goes and comes back from, unlike the calendar and the `+`
/// menu, which are read *against* the page behind them and are hand-built overlays. It is the third
/// sheet in the app, and it inherits nothing — hence `Theme.backgroundDark` and
/// `.preferredColorScheme(.dark)` stated here. Without either, the sheet is a light card in front of a
/// dark app on a phone set to light mode.
///
/// ## It owns a `NavigationStack`, which a pushed page here may not
///
/// A pushed page takes its chrome from the screen that pushed it; this is a presented sheet, and the
/// stack is here so the name row can push `ActivityPickerView`. A sheet with no stack has nowhere to
/// push a second level to.
///
/// ## The two times are required, and the draft is the only thing that clamps them
///
/// A `WorkoutSession` has two instants and no way to say *one of them is missing*, so unlike the
/// receptive sheet's optional time this sheet draws two compact pickers at once. **Both write through
/// `AddActivityDraft`**, which rebuilds the picked clock onto the sheet's day and keeps the window
/// inside it — so the day cannot move under the row, and the end cannot precede the start. The
/// `DatePicker`'s `in:` range is the visible half of that same rule; the draft's clamp is the half
/// that holds for a write no picker made.
///
/// The date is drawn once beside the section heading rather than beside each picker: both times are on
/// the same day, and a second `formattedShortDate()` under the first would say one thing twice.
public struct AddActivitySheet: View {

    /// The session in progress. Owned by the page that presents this sheet, so a dismissal and a
    /// re-open start from a fresh draft rather than from a half-finished one.
    @Binding private var draft: AddActivityDraft

    /// Whether a write is in flight, so `SAVE` cannot be pressed twice over one session.
    private let isSaving: Bool

    /// Runs the save. The sheet does not dismiss itself on success — the page does, once the write has
    /// reported back — so a failed write leaves the sheet up with the user's entry still in it.
    private let onSave: () -> Void

    public init(
        draft: Binding<AddActivityDraft>,
        isSaving: Bool,
        onSave: @escaping () -> Void
    ) {
        self._draft = draft
        self.isSaving = isSaving
        self.onSave = onSave
    }

    /// Drives the push into the picker. `@State` rather than a `NavigationLink` because the row is a
    /// plain button — the whole row is the target, not a chevron inside it.
    @State private var isChoosingName = false

    /// The sheet's own gutter, matching the page's and the other two sheets'.
    private static let gutter: CGFloat = 16

    /// The sheet's title, and the section heading over the two time rows.
    ///
    /// `nonisolated static` for this feature's standing reason: the runner has no renderer, so a
    /// literal written into a `body` is a literal nothing can assert.
    public nonisolated static let title = "ADD ACTIVITY"
    public nonisolated static let timeSectionTitle = "Time"

    /// The two rows' labels, and what their accessibility labels are built from.
    public nonisolated static let startTimeLabel = "Start Time"
    public nonisolated static let endTimeLabel = "End Time"

    /// The control's title, and the chrome's two spoken names.
    public nonisolated static let saveTitle = "SAVE"
    public nonisolated static let nameAccessibilityLabel = "Activity"
    public nonisolated static let closeAccessibilityLabel = "Close"

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    nameRow
                    timeSection
                }
                .padding(.horizontal, Self.gutter)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The scroll view is the sheet's whole surface, so its background is the sheet's
            // background: the content is a `VStack` of fixed-height blocks with nothing flexible in
            // it, and without this its frame would be the content's width and the colour would paint
            // a centred column.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.backgroundDark)
            // `.inlineNavigationTitle()` and not the modifier, on the rule that helper's own file
            // states: the modifier is unavailable on macOS and this file is compiled into the host
            // build too.
            .inlineNavigationTitle()
            // `.cancellationAction` and not `.topBarLeading`: the two draw in the same place on iOS,
            // and only the first exists on macOS — so this toolbar needs no `#if os(iOS)` guard.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { closeButton }
                ToolbarItem(placement: .principal) { titleLabel }
            }
            .navigationDestination(isPresented: $isChoosingName) {
                ActivityPickerView(selection: nameBinding)
            }
            // Pinned rather than the last element of the stack, so it stays reachable however tall
            // the rows make the content on a short screen. `safeAreaInset` also insets the scroll
            // view's own content, so a row cannot come to rest underneath it.
            .safeAreaInset(edge: .bottom) { saveButton }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    /// The `✕`. A glyph rather than the word `Cancel`, matching the receptive sheet: the menu's
    /// `Cancel` row dismisses a menu, and a glyph closes a sheet.
    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
        }
        .accessibilityLabel(Self.closeAccessibilityLabel)
    }

    private var titleLabel: some View {
        Text(Self.title)
            .font(.system(size: 14, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(Theme.textPrimary)
    }

    // MARK: - The name row

    /// The session's name, with the chevron the activity sheet's own row draws. Tapping it pushes the
    /// picker.
    ///
    /// **The row draws the catalogue's spelling, not an uppercased one**, which is
    /// `ReceptiveInactivitySheet.nameRow`'s rule rather than `ActivityEditSheet.activityRow`'s: the
    /// card will uppercase whatever row lands here, but this row is a picker's answer and should read
    /// as the user chose it.
    private var nameRow: some View {
        Button {
            isChoosingName = true
        } label: {
            HStack(spacing: 12) {
                ActivityGlyphLabel(nameMark, size: 18, weight: .medium)
                    .foregroundStyle(draft.name == nil ? Theme.textSecondary : Theme.textPrimary)
                    .frame(width: ActivityGlyph.listGutter)

                Text(nameDisplay)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(draft.name == nil ? Theme.textMuted : Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(cornerRadius: 12, padding: 14)
        .accessibilityLabel(Self.nameAccessibilityLabel)
    }

    /// The name's own mark, or the plain-activity fallback before one is chosen — `mark(for: nil)` is
    /// `figure.run`, which is the right answer on a sheet about a workout and the wrong one on the
    /// receptive sheet, where that feature has a mark of its own.
    private var nameMark: ActivityGlyph.Drawing {
        ActivityGlyph.mark(for: draft.name)
    }

    /// What the row reads. An empty string is *no name* for the same reason `nil` is, on the draft's
    /// own rule.
    private var nameDisplay: String {
        guard let name = draft.name, !name.isEmpty else { return ActivityFigure.dash }
        return name
    }

    // MARK: - The time section

    /// `TIME`, the day both times are on, its rule, and the two picker rows.
    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(Self.timeSectionTitle)
                Spacer(minLength: 8)
                Text(draft.day.formattedShortDate())
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
            }

            Divider()
                .overlay(Theme.cardBorder)

            VStack(spacing: 12) {
                timeRow(
                    label: Self.startTimeLabel,
                    selection: startBinding,
                    range: draft.earliestStart...draft.latestStart)
                timeRow(
                    label: Self.endTimeLabel,
                    selection: endBinding,
                    range: draft.earliestEnd...draft.latestEnd)
            }
            .glassCard(cornerRadius: 12, padding: 14)
        }
    }

    /// One label-and-picker row. The card is the section's, so the two rows read as one block.
    private func timeRow(
        label: String,
        selection: Binding<Date>,
        range: ClosedRange<Date>
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            DatePicker("", selection: selection, in: range, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(Theme.actionTint)
                .accessibilityLabel(label)
        }
        .frame(minHeight: 32)
    }

    /// The start picker's read and write, both through the draft.
    ///
    /// The read is `draft.start` directly because the draft stores an instant **already rebuilt onto
    /// its own day** — the rebuild happens in `setStart(_:)`, which is the only writer. A raw pick is
    /// never stored, so there is no second form to display.
    private var startBinding: Binding<Date> {
        Binding(
            get: { draft.start },
            set: { draft.setStart($0) })
    }

    /// The end picker's read and write — `startBinding` for the other end.
    private var endBinding: Binding<Date> {
        Binding(
            get: { draft.end },
            set: { draft.setEnd($0) })
    }

    /// The picker's read of the name, and its write back through `setName(_:)` — so the sheet is not
    /// marked dirty by a pick that differs only in case or surrounding space.
    private var nameBinding: Binding<String?> {
        Binding(
            get: { draft.name },
            set: { draft.setName($0) })
    }

    // MARK: - SAVE

    /// `SAVE`, full width, on the card surface until the draft has a name.
    ///
    /// **One value drives both the gate and the colours**, which is `ProfileDashboardView`'s rule and
    /// a necessity rather than a preference: `.buttonStyle(.plain)` with a custom background does not
    /// grey itself when disabled, so a button whose colour came from a second condition would look
    /// live while being dead. `isComplete` is that value — a name chosen, which is the only thing this
    /// sheet's invariants leave open — and a write in flight greys it too, which is the honest reading
    /// of a control that cannot be pressed.
    private var saveButton: some View {
        let isLive = draft.isComplete && !isSaving
        return Button {
            onSave()
        } label: {
            Text(Self.saveTitle)
                .font(.system(size: 15, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(isLive ? Theme.backgroundDark : Theme.textMuted)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(
                    isLive ? Theme.textPrimary : Theme.homeCard,
                    in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!isLive)
        .padding(.horizontal, Self.gutter)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.backgroundDark)
    }

    @Environment(\.dismiss) private var dismiss
}
