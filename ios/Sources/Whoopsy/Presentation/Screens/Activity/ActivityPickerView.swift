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
/// **The two sections are a segmented switch rather than one list with the second below the first.**
/// The one-list form put Recovery Activities under ~150 strain rows, so a reader looking for
/// `Meditation` or `Sauna` had to scroll the whole catalogue to discover it exists — the user's own
/// report was that recovery activities should show up in the list for adding an activity. The control
/// is pinned above the list, both groups are visible before the list is read, and it opens on the
/// group the current selection belongs to.
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

    /// Which of the catalogue's two lists the sheet is drawing.
    ///
    /// **The two groups are a control rather than 150 rows followed by 33**, which is what the
    /// one-list form made the recovery names: reachable only by scrolling past every strain activity,
    /// so an activity like `Meditation` read as absent from a list that has always contained it. The
    /// switch is the affordance that makes the second half visible.
    ///
    /// It starts on the group the current selection belongs to — a stored `Meditation` opens on
    /// Recovery with its tick in view, and a fresh add opens on Strain — through
    /// `SectionGroup.containing(_:)`.
    @State private var group: SectionGroup

    @Environment(\.dismiss) private var dismiss

    public init(selection: Binding<String?>) {
        self._selection = selection
        self._group = State(initialValue: SectionGroup.containing(selection.wrappedValue))
    }

    /// The picker's title, and the two section headings. `nonisolated static` for this feature's standing
    /// reason: the runner has no renderer, so a literal inside a `body` is one nothing can assert.
    public nonisolated static let title = "Activity"
    public nonisolated static let strainSectionTitle = "Strain Activities"
    public nonisolated static let recoverySectionTitle = "Recovery Activities"

    /// What the section holding a stored name the catalogue does not offer is called.
    public nonisolated static let currentSectionTitle = ActivityEditSheet.currentSectionTitle

    /// The segmented control's two short tabs, and its spoken name.
    ///
    /// **The short words are the tabs and the long ones the section headings**, deliberately: a
    /// segmented control splits its width in two, so `Strain Activities`/`Recovery Activities` would
    /// truncate on a narrow phone, while the heading above the list has the full width to say which
    /// list is on screen.
    public nonisolated static let strainGroupTitle = "Strain"
    public nonisolated static let recoveryGroupTitle = "Recovery"
    public nonisolated static let groupPickerLabel = "Activity group"

    /// One of the catalogue's two lists, and the names it offers.
    ///
    /// A value rather than two branches in `body` for this app's standing reason — the runner has no
    /// renderer — and because the control, the heading and the rows must all read the same answer.
    public enum SectionGroup: String, CaseIterable, Identifiable, Sendable {
        case strain
        case recovery

        public var id: String { rawValue }

        /// The tab's word.
        public var tabTitle: String {
            switch self {
            case .strain: return ActivityPickerView.strainGroupTitle
            case .recovery: return ActivityPickerView.recoveryGroupTitle
            }
        }

        /// The heading over the list, which keeps WHOOP's own two names.
        public var sectionTitle: String {
            switch self {
            case .strain: return ActivityPickerView.strainSectionTitle
            case .recovery: return ActivityPickerView.recoverySectionTitle
            }
        }

        /// The names, read from the catalogue rather than copied — `allNames` is the concatenation
        /// of these two in this order, so the switch and a caller walking everything cannot disagree.
        public var names: [String] {
            switch self {
            case .strain: return WhoopActivityCatalog.strainActivities
            case .recovery: return WhoopActivityCatalog.recoveryActivities
            }
        }

        /// The group a selection belongs to, for the control's opening position.
        ///
        /// The test is `ActivityName.matches`, the same case- and whitespace-tolerant comparison the
        /// rows tick with: a stored `"meditation"` is the catalogue's `Meditation` and should open on
        /// Recovery rather than on a list that cannot show it. An unlisted or absent name opens on
        /// Strain, which is where a fresh add begins.
        public static func containing(_ name: String?) -> SectionGroup {
            guard let name else { return .strain }
            return WhoopActivityCatalog.recoveryActivities.contains { ActivityName.matches($0, name) }
                ? .recovery : .strain
        }
    }

    public var body: some View {
        List {
            if let current = unlistedSelection {
                Section(Self.currentSectionTitle) {
                    row(current)
                }
            }

            Section(group.sectionTitle) {
                ForEach(group.names, id: \.self) { name in
                    row(name)
                }
            }
        }
        // Pinned above the list rather than made its first row: a control that chooses what the list
        // contains has to stay reachable after the list is scrolled, and a row would scroll away.
        .safeAreaInset(edge: .top) { groupControl }
        // A grouped `List` draws its own background, which would put a light slab inside a dark sheet.
        // Hiding it leaves the sheet's own colour showing between the rows.
        .scrollContentBackground(.hidden)
        .background(Theme.backgroundDark)
        .navigationTitle(Self.title)
        .inlineNavigationTitle()
        .preferredColorScheme(.dark)
    }

    /// The `Strain` / `Recovery` switch.
    ///
    /// `.segmented` and not a menu: both groups should be visible before the list is read, which is
    /// the whole point of the control — a menu would hide the fact that the second list exists behind
    /// another tap.
    private var groupControl: some View {
        Picker(Self.groupPickerLabel, selection: $group) {
            ForEach(SectionGroup.allCases) { group in
                Text(group.tabTitle).tag(group)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Theme.backgroundDark)
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
