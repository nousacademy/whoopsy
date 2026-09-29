import SwiftUI

/// The sheet the `•••` menu's `Edit` row opens: the session's activity type, its window trimmed by hand,
/// and a `SAVE`.
///
/// ## It is a system `.sheet`, and this repo's own convention says otherwise
///
/// Home's calendar and this page's `•••` menu are both hand-built overlays rather than sheets, and the
/// reason recorded for the calendar is that a `.sheet` is a full-height card the system centres over a
/// dark slab with the page invisible behind it. **The user chose a real sheet here anyway**, and the
/// screenshots say why the two decisions do not conflict: the reference's `EDIT ACTIVITY` *is* a system
/// sheet — a grabber, a rounded top, the page dimmed and still legible behind it — and the calendar's
/// argument was that the grid wanted the page visible around it, which this sheet's frame does not.
/// An editing surface is a place the user goes and comes back from, which is what a sheet is for; a
/// calendar is something the user reads *against* the day behind it.
///
/// **The consequence is that it inherits nothing.** A sheet draws on the system's own background, so
/// this one states `Theme.backgroundDark` and `.preferredColorScheme(.dark)` itself — without either,
/// the sheet is a light card in front of a dark app on a phone set to light mode.
///
/// ## It owns a `NavigationStack`, which a pushed page here may not
///
/// The standing rule is that a *pushed* page takes its chrome from the screen that pushed it and owns no
/// stack of its own — a second stack would give the page a second back button and a second title. This
/// is not a pushed page: it is a presented sheet, and the stack is here so the activity row's chevron can
/// be a `NavigationLink` into the picker. The mockup asks for a second level, and a sheet with no stack
/// has nowhere to push one to.
///
/// ## Two controls write the same two instants
///
/// The trim chart's handles and the two `DatePicker`s below them both read and write `draft`, which is
/// the whole reason `ActivityEditDraft` is one value rather than two `@State` dates on this view. Neither
/// surface holds a copy: a handle moved by hand moves the picker's time, and a minute chosen in the
/// picker moves the handle. Two surfaces holding their own value would let the screen show a handle at
/// one time and a picker at another, with nothing on screen to say which of the two is the edit.
///
/// ## What `SAVE` does, in order
///
/// An untouched sheet dismisses and writes nothing — `hasChanges` is the test, and it is exact-instant,
/// so a session stored with seconds is not moved by a `SAVE` that changed only its name. A touched sheet
/// asks the view model to write, **and a failed write does not dismiss**, which is the same shape
/// `Delete` takes: a sheet that closed over a write that did not happen would leave the page printing
/// the old times as though the save had landed.
///
/// ## The date is printed and is not editable
///
/// `Start Time` reads the day, the time, and the picker. The day is a `Text` rather than a second
/// component of the `DatePicker` because `ActivityEditDraft` clamps a start to its own day — see that
/// type's `latestStart` — so a date wheel here could only ever snap back to the day it started on. That
/// is a control with no reachable destination, which is the thing this repo does not draw.
public struct ActivityEditSheet: View {

    /// The edit in progress. Owned by the page that presents this sheet, so a dismissal and a re-open
    /// start from the stored session again rather than from a half-finished edit.
    @Binding private var draft: ActivityEditDraft

    /// The session's readings, or `nil` when it has none. **`nil` on every session this machine can
    /// show** — see `ActivityTimeTrimChartView`'s comment — which is why the trim control is written to
    /// be complete without a trace rather than to degrade gracefully into one.
    private let series: ActivityHeartRateSeries?

    /// Whether a write is in flight, so `SAVE` cannot be pressed twice over one edit.
    private let isSaving: Bool

    /// Runs the save. The sheet does not dismiss itself on success — the page does, once the write has
    /// reported back — so that a failed write leaves the sheet up with the user's edit still in it.
    private let onSave: () -> Void

    public init(
        draft: Binding<ActivityEditDraft>,
        series: ActivityHeartRateSeries?,
        isSaving: Bool,
        onSave: @escaping () -> Void
    ) {
        self._draft = draft
        self.series = series
        self.isSaving = isSaving
        self.onSave = onSave
    }

    /// Drives the push into the picker. `@State` rather than a `NavigationLink` because the row is a
    /// plain button — the whole row is the target, not a chevron inside it.
    @State private var isChoosingActivity = false

    /// The sheet's own gutter, matching the page's.
    private static let gutter: CGFloat = 16

    /// The sheet's title. `nonisolated static` for the reason every string in this feature is: the runner
    /// has no renderer, so a literal written into a `body` is a literal nothing can assert.
    public nonisolated static let title = "EDIT ACTIVITY"

    /// The section heading over the chart and the two time rows.
    public nonisolated static let timeSectionTitle = "Time"

    /// The two time rows' labels, and the strings the accessibility labels are built from.
    public nonisolated static let startTimeLabel = "Start Time"
    public nonisolated static let endTimeLabel = "End Time"

    /// The button's title.
    public nonisolated static let saveTitle = "SAVE"

    /// What the picker's unlisted-current section is called. See `ActivityPickerView`.
    public nonisolated static let currentSectionTitle = "Current"

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    activityRow
                    timeSection
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
            // `.inlineNavigationTitle()` and not the modifier, on `DeviceDetailView`'s rule: the
            // modifier is unavailable on macOS and this file is compiled into the host build too.
            .inlineNavigationTitle()
            // **`.cancellationAction` and not `.topBarLeading`.** They draw in the same place on iOS,
            // and only the first exists on macOS — so this toolbar needs no `#if os(iOS)` guard at all,
            // and it says something truer: a `✕` that closes a sheet *is* the cancellation action. The
            // title is `.principal` because the mockup centres it, which is what principal means.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { closeButton }
                ToolbarItem(placement: .principal) { titleLabel }
            }
            .navigationDestination(isPresented: $isChoosingActivity) {
                ActivityPickerView(selection: nameBinding)
            }
            // Pinned rather than the last element of the stack, so it stays reachable however tall the
            // chart and the two rows make the content on a short screen. `safeAreaInset` also insets the
            // scroll view's own content, so a row cannot come to rest underneath it.
            .safeAreaInset(edge: .bottom) { saveButton }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Chrome

    /// The `✕`. A glyph rather than the word `Cancel`, which is the sheet's own vocabulary and the menu's
    /// other one — the menu's `Cancel` row dismisses a menu and this closes a sheet, and the two are not
    /// the same act.
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

    /// What the `✕` is called. A bare glyph has no words of its own.
    public nonisolated static let closeAccessibilityLabel = "Close"

    private var titleLabel: some View {
        Text(Self.title)
            .font(.system(size: 14, weight: .bold))
            .tracking(1.1)
            .foregroundStyle(Theme.textPrimary)
    }

    // MARK: - The activity row

    /// The session's activity type, with the chevron the mockup draws. Tapping it pushes the picker.
    private var activityRow: some View {
        Button {
            isChoosingActivity = true
        } label: {
            HStack(spacing: 12) {
                ActivityGlyphLabel(ActivityGlyph.mark(for: draft.activityName), size: 18, weight: .medium)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: ActivityGlyph.listGutter)

                Text(activityDisplayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
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
        .accessibilityLabel(Self.activityAccessibilityLabel)
    }

    /// What the row reads, in caps as the mockup draws it.
    ///
    /// `WhoopActivityCatalog.abstentionName` rather than a second literal: the fallback is WHOOP's own
    /// word for a session its classifier declined to name, and the page's header prints the same one. A
    /// local `"ACTIVITY"` here would be a second spelling of a value the catalogue already owns.
    private var activityDisplayName: String {
        (draft.activityName ?? WhoopActivityCatalog.abstentionName).uppercased()
    }

    /// The row is the activity type *and* the way to change it, so its label says both.
    public nonisolated static let activityAccessibilityLabel = "Activity type"

    // MARK: - The time section

    /// `TIME`, its rule, the trim chart and the two rows.
    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(Self.timeSectionTitle)

            Divider()
                .overlay(Theme.cardBorder)

            ActivityTimeTrimChartView(series: series, draft: $draft)

            timeRow(label: Self.startTimeLabel, instant: draft.start, selection: startBinding)

            Divider()
                .overlay(Theme.cardBorder)

            timeRow(label: Self.endTimeLabel, instant: draft.end, selection: endBinding)
        }
    }

    /// One `Start Time` / `End Time` row: the label, the day it is on, and the time as a compact picker.
    ///
    /// **The day is static text and the picker is time-only.** See this type's comment: a start cannot
    /// leave its own day, so a date component here would be a wheel whose every value snaps back.
    private func timeRow(label: String, instant: Date, selection: Binding<Date>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            Text(instant.formattedShortDate())
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)

            DatePicker("", selection: selection, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
                .tint(Theme.actionTint)
                .accessibilityLabel(label)
        }
        .frame(minHeight: 32)
    }

    /// The picker's read of the start, and its write back through the draft's own setter.
    ///
    /// **The write goes through `setStart(_:)` and not into a stored property**, so the clamp and the
    /// minute-write guard are the same code path the handles take. A `Binding` straight onto a `Date`
    /// field would be a second writer with its own opinions about what a legal window is.
    private var startBinding: Binding<Date> {
        Binding(
            get: { draft.start },
            set: { draft.setStart($0) })
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { draft.end },
            set: { draft.setEnd($0) })
    }

    /// The picker's read of the name, and its write back through `setName(_:)` for the same reason.
    private var nameBinding: Binding<String?> {
        Binding(
            get: { draft.activityName },
            set: { draft.setName($0) })
    }

    // MARK: - SAVE

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
        .disabled(isSaving)
        // Held at a steady opacity rather than hidden while a write is in flight: the button is the
        // sheet's last element and a view that vanished under the finger would move the two rows above it.
        .opacity(isSaving ? 0.5 : 1)
        .padding(.horizontal, Self.gutter)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.backgroundDark)
    }

    @Environment(\.dismiss) private var dismiss
}
