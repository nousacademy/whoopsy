import SwiftUI

/// The sheet the `+` menu's `ADD RECEPTIVE INACTIVITY` row opens, and the one a receptive row opens:
/// a name, an optional time of day, and a `SAVE`.
///
/// ## It is a system `.sheet`, on `ActivityEditSheet`'s argument and not a new one
///
/// Home's calendar and the `•••` menu are hand-built overlays because they are read *against* the page
/// behind them; an editing surface is a place the user goes and comes back from. This is the second, so
/// it is a sheet — and **it inherits nothing**, which is why it states `Theme.backgroundDark` and
/// `.preferredColorScheme(.dark)` itself. Without either, the sheet is a light card in front of a dark
/// app on a phone set to light mode.
///
/// ## It owns a `NavigationStack`, which a pushed page here may not
///
/// The standing rule is that a *pushed* page takes its chrome from the screen that pushed it; this is a
/// presented sheet, and the stack is here so the NAME row can push `ReceptiveInactivityPickerView`. A
/// sheet with no stack has nowhere to push a second level to.
///
/// ## The day is the sheet's, and the time is a time *on* it
///
/// `day` is the day Home was showing when this sheet was opened, and `ReceptiveInactivityDraft` owns the
/// rule that the picked hour and minute are rebuilt onto that day's own midnight. **This view never does
/// that arithmetic itself** — it hands the draft's `instant(of:on:)` to the picker's binding, which is
/// the third of the three call sites that function has. A `DatePicker` with `.hourAndMinute` hands back
/// a whole instant carrying *today's* date whatever day the user is looking at, so a sheet that filed
/// that instant directly would put a 2024 day's meditation on today.
///
/// The day is **static text and not a second picker component**, for `ActivityEditSheet.timeRow`'s
/// reason: a time-only picker plus a date wheel would be two controls on one value, and the wheel's
/// every value snaps back to the day the sheet was opened on.
///
/// ## The NOTE field holds its own text, and the draft holds the canonical one
///
/// The field's characters live in `noteText` and **not** in a binding straight onto
/// `ReceptiveInactivityDraft.setNote(_:)`, and this is the one place on this sheet where a second copy
/// of a value is right. That setter trims trailing whitespace on every write and drops a write that
/// changes nothing — the rule that keeps a whitespace-only note out of the column as `nil` — so a field
/// bound through it cannot be typed into: pressing space calls `setNote("hello ")`, the setter trims it
/// back to `"hello"`, the binding re-reads `"hello"`, and the space is erased before the next character
/// arrives. Multi-word prose is the whole of what this field is for, so the raw text is held here and
/// the draft is handed the trimmed value beside it. `ProfileFormSnapshot` is the same arrangement one
/// screen over and for the same reason: a form holds what the user typed, and the model holds what
/// would be written.
///
/// Holding it in `@State` is safe because the sheet has no single identity — Home presents it from
/// `.sheet(item: $presentedReceptive)`, which rebuilds the content view per presentation — so opening a
/// row seeds the field from that row and dismissing throws the text away.
///
/// ## The TIME row has three states, and a compact `DatePicker` is why
///
/// A compact picker has no "no value" state, and the user's rule is *"time is optional"* — so the row
/// copies `ProfileDashboardView`'s `birthdayRow` idiom rather than `ActivityEditSheet`'s `timeRow`,
/// whose start is non-optional and has no absence to draw:
///
/// 1. **no time** draws the app's own `—` as a button; tapping it seeds `startedDraft` and opens the
///    picker **on a draft that writes nothing**;
/// 2. **a draft** draws the picker, and the first move commits it — the picker's opening position is a
///    control's position, like a slider's, and it does not become the entry's time until it is moved;
/// 3. **a time** draws the picker with a trailing clear control, so the field can be put back to *no
///    time* and not only set.
///
/// **The rebuild is `instant(of:on:)` and never `.startOfDay`**, which is where this departs from the
/// birthday it otherwise copies: a birthday is a whole day and snapping it is right, while this row
/// exists to capture an hour — snapping here would erase the very value and leave `SAVE` permanently
/// live over an edit the user never made.
///
/// ## `Delete` is edit-mode only, and it does not confirm
///
/// A row you cannot remove is a row you are stuck with, which is why the control exists; and it takes
/// no confirmation, mirroring the `•••` menu's `Delete`, which is this app's only other destructive
/// control. **A receptive entry carries nothing**, so the blast radius is one row — there is no child
/// table filed under it the way `workout_route_points` is filed under a session.
public struct ReceptiveInactivitySheet: View {

    /// The entry in progress. Owned by the page that presents this sheet, so a dismissal and a re-open
    /// start from the stored row again rather than from a half-finished edit.
    @Binding private var draft: ReceptiveInactivityDraft

    /// The day this entry is being filed on — see this type's comment.
    private let day: Date

    /// Whether a write is in flight, so `SAVE` cannot be pressed twice over one edit.
    private let isSaving: Bool

    /// Runs the save. The sheet does not dismiss itself on success — the page does, once the write has
    /// reported back — so that a failed write leaves the sheet up with the user's edit still in it.
    private let onSave: () -> Void

    /// Runs the delete. Drawn only in edit mode.
    private let onDelete: () -> Void

    public init(
        draft: Binding<ReceptiveInactivityDraft>,
        day: Date,
        isSaving: Bool,
        onSave: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self._draft = draft
        self.day = day
        self.isSaving = isSaving
        self.onSave = onSave
        self.onDelete = onDelete

        // Seeded from the row the sheet was opened on, and **only on the first render of this
        // identity** — which is the whole of what makes it correct here. See this type's comment.
        self._noteText = State(initialValue: draft.wrappedValue.note ?? "")
    }

    /// Drives the push into the picker. `@State` rather than a `NavigationLink` because the row is a
    /// plain button — the whole row is the target, not a chevron inside it.
    @State private var isChoosingName = false

    /// The birthday idiom's middle state: a picker's opening position, held here and **written into no
    /// draft until it is moved**. `nil` means the row is in state 1 or 3.
    @State private var startedDraft: Date?

    /// The NOTE field's characters, verbatim and untrimmed. Deliberately a second copy of what the
    /// draft holds — see this type's comment for the space that cannot be typed without it.
    @State private var noteText: String

    /// The sheet's own gutter, matching the page's and the activity sheet's.
    private static let gutter: CGFloat = 16

    /// The two titles. `nonisolated static` for the reason every string in this feature is: the runner
    /// has no renderer, so a literal written into a `body` is a literal nothing can assert. Which of the
    /// two is drawn is `draft.isEditing`, and §14 asserts both strings rather than the branch.
    public nonisolated static let addTitle = "ADD RECEPTIVE INACTIVITY"
    public nonisolated static let editTitle = "EDIT RECEPTIVE INACTIVITY"

    /// The two section headings, over the note field and the time row.
    public nonisolated static let noteSectionTitle = "Note"
    public nonisolated static let timeSectionTitle = "Time"

    /// The time row's label, and the string its accessibility labels are built from.
    public nonisolated static let startTimeLabel = "Start Time"

    /// The two controls' titles.
    public nonisolated static let saveTitle = "SAVE"
    public nonisolated static let deleteTitle = "DELETE"

    /// What the NAME row is called. It draws a glyph and a word and no visible label, so this is the
    /// only place the row says what it is.
    public nonisolated static let nameAccessibilityLabel = "Receptive inactivity"

    /// What the NOTE field is called. It carries no visible label, so this and its section heading are
    /// the only two places the field says what it is — and the heading is drawn, where this is spoken.
    public nonisolated static let noteAccessibilityLabel = "Note"

    /// What the `✕` is called. A bare glyph has no words of its own.
    public nonisolated static let closeAccessibilityLabel = "Close"

    /// The clear control's label, and the unset row's — two acts on one field, so two words.
    public nonisolated static let clearTimeAccessibilityLabel = "Clear time"
    public nonisolated static let addTimeAccessibilityLabel = "Add a time"

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    nameRow
                    noteSection
                    timeSection

                    // Edit mode alone. An add draft has no row behind it, so a `DELETE` there would be a
                    // control whose only outcome is dismissing the sheet it is drawn on.
                    if draft.isEditing {
                        deleteButton
                    }
                }
                .padding(.horizontal, Self.gutter)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The scroll view is the sheet's whole surface, so its background is the sheet's background:
            // the content is a `VStack` of fixed-height blocks with nothing flexible in it, and without
            // this its frame would be the content's width and the colour would paint a centred column.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.backgroundDark)
            // `.inlineNavigationTitle()` and not the modifier, on the rule that helper's own file
            // states: the modifier is unavailable on macOS and this file is compiled into the host
            // build too.
            .inlineNavigationTitle()
            // `.cancellationAction` and not `.topBarLeading`: they draw in the same place on iOS, and
            // only the first exists on macOS — so this toolbar needs no `#if os(iOS)` guard at all.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { closeButton }
                ToolbarItem(placement: .principal) { titleLabel }
            }
            .navigationDestination(isPresented: $isChoosingName) {
                ReceptiveInactivityPickerView(selection: nameBinding)
            }
            // Pinned rather than the last element of the stack, so it stays reachable however tall the
            // rows make the content on a short screen. `safeAreaInset` also insets the scroll view's own
            // content, so a row cannot come to rest underneath it.
            .safeAreaInset(edge: .bottom) { saveButton }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    /// The `✕`. A glyph rather than the word `Cancel`, which is the sheet's own vocabulary and the
    /// menu's other one — the menu's `Cancel` row dismisses a menu and this closes a sheet.
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
        Text(draft.isEditing ? Self.editTitle : Self.addTitle)
            .font(.system(size: 14, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(Theme.textPrimary)
    }

    // MARK: - The name row

    /// The entry's name, with the chevron the activity sheet's own row draws. Tapping it pushes the
    /// picker.
    ///
    /// **The word is drawn exactly as the catalogue spells it and is not uppercased**, which is the one
    /// place this row departs from `ActivityEditSheet.activityRow`. That row uppercases because a WHOOP
    /// activity's name is a producer's string the card prints in caps anyway; this list is this app's own
    /// and its names are mixed case (`Non-sleep, deep rest`), so uppercasing here would draw one name two
    /// ways on two screens a tap apart.
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

    /// What the row leads with: the name's own mark once there is one, and the feature's otherwise.
    ///
    /// **The unset branch is not `mark(for: nil)`**, which would draw `figure.run` — the right answer for
    /// an activity this app has no glyph for and a false one on a sheet about a dream. See
    /// `ActivityGlyph.receptiveMark`.
    private var nameMark: ActivityGlyph.Drawing {
        guard let name = draft.name, !name.isEmpty else {
            return .single(ActivityGlyph.receptiveMark)
        }
        return ActivityGlyph.mark(for: name)
    }

    /// What the row reads. An empty string is *no name* for the same reason `nil` is, on the draft's own
    /// rule — and it is the case that would otherwise draw a blank where the dash belongs.
    private var nameDisplay: String {
        guard let name = draft.name, !name.isEmpty else { return ActivityFigure.dash }
        return name
    }

    // MARK: - The note section

    /// `NOTE`, its rule, and the field.
    ///
    /// **The field is multi-line and grows with the text**, which is what a journal entry needs: an
    /// imported dream's note runs to several lines, and a single-line box would draw the first clause
    /// and hide the rest behind a horizontal scroll nobody would think to try. `lineLimit(3...10)` is a
    /// range rather than a number for that reason — the floor is what makes it a prose field at rest,
    /// and the ceiling is what keeps one long entry from pushing `SAVE` off the bottom of the sheet,
    /// which is pinned to the safe area rather than laid after the content.
    ///
    /// The surface is the name row's own `glassCard` rather than the bordered box
    /// `ProfileDashboardView.field` draws, because the two sit one row apart on this sheet and a second
    /// box style here would read as a different kind of field.
    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(Self.noteSectionTitle)

            Divider()
                .overlay(Theme.cardBorder)

            TextField(ActivityFigure.dash, text: noteBinding, axis: .vertical)
                .lineLimit(3...10)
                .sentenceCapitalisation()
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.actionTint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(cornerRadius: 12, padding: 14)
                .accessibilityLabel(Self.noteAccessibilityLabel)
        }
    }

    /// The field's read of the text, and its write into the local copy **and** the draft.
    ///
    /// **Two writes rather than one, and the order matters**: the local copy takes the characters
    /// verbatim, so the field can render a trailing space the draft has already trimmed away. See this
    /// type's comment for why the draft cannot be the field's only store.
    ///
    /// It is a `Binding<String>` and not a `Binding<String?>`, which is the one place this departs from
    /// `nameBinding`: a `TextField` writes `""` when the last character is deleted, and `setNote(_:)`
    /// is the function that turns that `""` into the column's own word for nothing. Making the field's
    /// own type optional would move that decision to a second place.
    private var noteBinding: Binding<String> {
        Binding(
            get: { noteText },
            set: { newValue in
                noteText = newValue
                draft.setNote(newValue)
            })
    }

    // MARK: - The time section

    /// `TIME`, its rule, and the three-state row.
    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(Self.timeSectionTitle)

            Divider()
                .overlay(Theme.cardBorder)

            timeRow
        }
    }

    /// The one time row. See this type's comment for the three states and what each is for.
    @ViewBuilder
    private var timeRow: some View {
        if draft.startedAt != nil {
            HStack(spacing: 8) {
                timeLabel

                Spacer(minLength: 8)

                dayText

                picker(selection: startBinding)

                Button {
                    draft.setStart(nil)
                    // The middle state's draft goes with the value it was seeding: leaving it set would
                    // put the row straight back into state 2 on the next render, drawing a picker over a
                    // field the user has just cleared.
                    startedDraft = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.clearTimeAccessibilityLabel)
            }
            .frame(minHeight: 32)
        } else if startedDraft != nil {
            HStack(spacing: 8) {
                timeLabel

                Spacer(minLength: 8)

                dayText

                picker(selection: draftStartBinding)
            }
            .frame(minHeight: 32)
        } else {
            Button {
                startedDraft = Date()
            } label: {
                HStack(spacing: 8) {
                    timeLabel

                    Spacer(minLength: 8)

                    Text(ActivityFigure.dash)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textMuted)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.addTimeAccessibilityLabel)
        }
    }

    private var timeLabel: some View {
        Text(Self.startTimeLabel)
            .font(.system(size: 15))
            .foregroundStyle(Theme.textPrimary)
    }

    /// The day the time is on, as static text — see this type's comment for why it is not a second
    /// picker component.
    private var dayText: some View {
        Text(day.formattedShortDate())
            .font(.system(size: 15))
            .foregroundStyle(Theme.textSecondary)
    }

    private func picker(selection: Binding<Date>) -> some View {
        DatePicker("", selection: selection, displayedComponents: .hourAndMinute)
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(Theme.actionTint)
            .accessibilityLabel(Self.startTimeLabel)
    }

    /// The picker's read of a time the draft already holds, and its write back through the draft's own
    /// setter.
    ///
    /// **The read is `instant(of:on:)` and not the raw `startedAt`.** That function is the one definition
    /// of the day-rebuild, and this is the third of its call sites — a raw instant here would display the
    /// hour and minute of a date on a different day, which is the same time on the clock and therefore
    /// looks correct until the write happens.
    private var startBinding: Binding<Date> {
        Binding(
            get: { ReceptiveInactivityDraft.instant(of: draft.startedAt ?? Date(), on: day) },
            set: { draft.setStart($0) })
    }

    /// The middle state's binding: the picker's opening position held locally, **written into the draft
    /// only once it is moved**. See this type's comment for why the middle state exists at all.
    private var draftStartBinding: Binding<Date> {
        Binding(
            get: { startedDraft ?? Date() },
            set: { newValue in
                startedDraft = newValue
                draft.setStart(newValue)
            })
    }

    /// The picker's read of the name, and its write back through `setName(_:)` — so the sheet is not
    /// marked dirty by a pick that differs only in case or surrounding space.
    private var nameBinding: Binding<String?> {
        Binding(
            get: { draft.name },
            set: { draft.setName($0) })
    }

    // MARK: - SAVE and DELETE

    /// `SAVE`, full width, on the card surface until there is something to write.
    ///
    /// **One value drives both the gate and the colours**, which is `ProfileDashboardView`'s rule and a
    /// necessity rather than a preference: `.buttonStyle(.plain)` with a custom background does not grey
    /// itself when disabled, so a button whose colour came from a second condition would look live while
    /// being dead. `hasChanges(on:)` is that value, and it answers the question for **both** modes — an
    /// add draft has nothing to save until it has a name, and an edit draft nothing until it differs from
    /// the row it came from — so neither mode has a branch of its own here.
    ///
    /// A write in flight therefore greys the button, which is the honest reading of a control that cannot
    /// be pressed; it is momentary, and the sheet is dismissed by the page rather than by itself.
    private var saveButton: some View {
        let isLive = draft.hasChanges(on: day) && !isSaving
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

    /// `DELETE`, drawn in edit mode alone. See this type's comment for why it confirms nothing.
    private var deleteButton: some View {
        Button {
            onDelete()
        } label: {
            Text(Self.deleteTitle)
                .font(.system(size: 15, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Theme.recoveryRed)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(Theme.homeCard, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
    }

    @Environment(\.dismiss) private var dismiss
}

// MARK: - Platform

extension View {
    /// Capitalises the first letter of a sentence, on the platforms that have the concept.
    ///
    /// `textInputAutocapitalization` is declared in SwiftUI's **iOS-only** interface — the iPhoneOS SDK
    /// carries it at `SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface:4517`, under
    /// `@available(iOS 15.0, tvOS 15.0, watchOS 8.0, *)` and `@available(macOS, unavailable)` — and it
    /// is absent from the macOS SDK altogether, in both `SwiftUI` and `SwiftUICore`. This sheet is
    /// compiled for both: the host `swift build` is this repo's edit/compile loop and the test runner
    /// links its objects, so an unguarded modifier breaks the fast path while the simulator build stays
    /// green. It is the fifth member of the family `HomeDashboardView.hidingTabBar(_:)` documents.
    ///
    /// It rides on the *box* rather than on the value — the decision `.sentences` makes is about a
    /// keyboard, and a note is prose, so every sentence the user starts is capitalised. Nothing here
    /// applies `.autocorrectionDisabled()` beside it: correcting a dream's words into dictionary words
    /// is the failure mode this app has no reason to trade for.
    @ViewBuilder
    func sentenceCapitalisation() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.sentences)
        #else
        self
        #endif
    }
}
