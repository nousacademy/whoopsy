import SwiftUI

/// One recorded activity, opened from the `ACTIVITIES` card on Home.
///
/// ## The page, top to bottom
///
/// A full-bleed header naming the session and when it was; its strain and its steps side by side, each
/// read against the same activity's own recent history; its heart-rate trace, drawn edge to edge; its
/// length against what is typical for that activity, as a plain section header; and its five
/// heart-rate zone rows, one card each.
///
/// ## Why the header and the chart are not cards
///
/// The header and the chart are deliberately not `.glassCard()`s, and they are not the page's only bare
/// blocks — **the zone rows are the one thing here that is carded**, each its own
/// `.glassCard(cornerRadius: 12, padding: 12)`, and the stat row and the range row sit on the page's own
/// background beside the two full-bleed blocks. The header needs the bare treatment because it is the
/// page's masthead: a card around the name would put a border between the reader and the thing they just
/// tapped. The chart needs it because its whole reading is its *shape across the session* — a window
/// drawn inside a margin is a shorter window. The zone rows take a card each because they are five
/// independent readings rather than one figure, which is the same reason the reference draws them
/// separately.
///
/// ## A fast draws a different page
///
/// `ActivityFigure.isFast(_:)` is the gate, and **a fast's page ends earlier**. What it replaces: the
/// stat row and the heart-rate trace — a fast has neither a strain nor a step count, so both columns
/// would read `—`, and its trace is `No Data` for the same reason — and in their place it draws a
/// duration, a recovery figure over the nights the fast covered, a chart of those nights and a sentence
/// under it. What it **drops**: the `TYPICAL RANGE` header with its `DURATION` cell, and the five
/// `HEART RATE ZONES` cards. Both are absent rather than dashed, on the user's own instruction — a fast
/// draws a shorter page, not a page of five `—` cards under a range it has no reading to compare
/// against. Its duration is not lost with the range header: `TOTAL DURATION` in the row above carries
/// it. The gate is the same call `ActivityDetailViewModel` makes before it reads anything, so the
/// layout and the figures behind it cannot disagree about which sessions are fasts, and an ordinary
/// session's page is unchanged.
///
/// ## What it is not
///
/// **No `AUTO-DETECTED` badge.** The reference draws one and the user's instruction was to take it out:
/// every session on this page came from a file or from a session the user started by hand, and this app
/// has no activity classifier at all — so a badge claiming the session was detected would be the app
/// describing a capability it does not have. That is the absence rule applied to a capability, on the
/// same terms as the `RECORD ROUTE` toggle's refused-permission sentence.
///
/// **No splits.** `workout_splits` still has no producer — there is no lap model — so that half of this
/// page's original scope is still unbuilt.
///
/// **The `•••` opens a menu of full-width rows pinned to the bottom of the screen, and it is the app's
/// first destructive control.** `Edit`, `Delete` and `Cancel` over a dimmed page, the last of them in a
/// card of its own a small space below the other two — the rows, their grouping and the space are
/// `ActivityOverflowMenu`'s, `Delete` removes the session and returns to Home, and `Edit` opens
/// `ActivityEditSheet` over this page.
///
/// **Nothing on this page is inert, and that is a change.** `Edit` was drawn and reached nothing for as
/// long as the user's *"edit we will wire later"* stood; that instruction is now discharged, so the
/// repo's no-control-without-a-destination rule — which `CLAUDE.md`'s `## Pages` carried an exception
/// for — holds here without qualification. A control added to this page with no destination is the bug
/// the rule describes, not a repeat of a precedent.
///
/// **It is hand-built and not `confirmationDialog`, and the user is the reason.** The system's action
/// sheet insets its rows in a centred card with a detached `Cancel` card below them; the instruction was
/// that the three rows sit at the bottom of the screen and run its full width, which is a layout that
/// sheet does not produce. So the scrim, the cards and their rows are drawn here — the price being the
/// three things the system gave for free and this page now owns: the dimming is a colour that has to
/// follow the OS's own contrast, and each row needs its own label and its own minimum tap height.
///
/// **A later instruction separated `Cancel`, and it did not move anything else.** It sits a small space
/// below the two rows above it and is the same height and the same full width as they are, so the menu
/// keeps the bottom-anchored, full-width shape the earlier instruction asked for and borrows exactly one
/// thing from the sheet this page replaced — that the way out of a menu is its own card. The space is
/// `ActivityOverflowMenu.groupSpacing` and the split that produces it is `ActivityOverflowMenu.groups`.
///
/// **A fourth instruction then removed the `Cancel` card's bottom, and "the same size as the buttons
/// above it" is what it meant.** Matching the rows' height and width was not enough while the card's
/// fill also ran to the screen's bottom edge: that card measured **88 pt** against the rows' 54, so the
/// button read as half again the size of the two it was supposed to match. The fill no longer extends
/// past the safe area — see `overflowCard` — so the card ends where its row ends, and the dimmed page
/// shows below it exactly as it shows through the gap above it. Nothing else moved: the split, the
/// space, the width and the three row heights are all as the previous instruction left them.
///
/// **A fifth rounded the `Delete` row's bottom corners**, which the arrangement above had left square:
/// rounding only the menu's two outer ends puts the first card's bottom edge in the middle of the
/// stack, so `Delete` sat on a hard rectangle while `Cancel` sat on a rounded one. Every corner of both
/// cards is now `ActivityOverflowMenu.cardCornerRadius`.
///
/// ## It tells Home what it removed, rather than asking Home to re-read
///
/// `onDeleted` is a closure the pushing screen supplies, and it is called with the removed session's id
/// **after** the dismiss. The alternative — popping and letting Home's `.task` re-fire — is undocumented
/// behaviour that varies by OS version, so nothing here depends on it; and re-running `load(for:)` is a
/// nine-read, non-reentrant call that would run concurrently with whatever else is loading. A local
/// removal from `HomeViewModel.workouts` is exact, because no other figure on Home is built from a
/// workout: the rings, the week chart and the calendar all come from the three day-keyed histories.
///
/// ## Why it owns no `NavigationStack`
///
/// The pushed-page shape `RecoveryDetailView`, `SleepDetailView` and `StrainDetailView` all take: the
/// pushing screen — Home — supplies the chrome, and this page supplies the content. A `NavigationStack`
/// here would nest one inside Home's and draw a second navigation bar.
public struct ActivityDetailView: View {

    /// The page's state. A `@State` holding a `@MainActor @Observable` class, on the shape every other
    /// screen here uses: the pushing screen builds it and hands it over, and re-renders of Home behind
    /// the push cannot re-point it at another session because the session is a `let` on the view model.
    @State private var viewModel: ActivityDetailViewModel

    /// Whether the overflow menu is up.
    ///
    /// A plain `@State` on this view rather than a property on the view model: the menu's presentation
    /// is the page's own, it survives no navigation, and a view model that could be re-pointed would
    /// make it a fact about the session rather than about the screen showing it.
    ///
    /// **It is also the flag the tab bar is hidden on, one screen up.** `.hidingTabBar(_:)` is
    /// documented in this repo as working only from a tab's *root* view and doing nothing at all on a
    /// pushed destination — silently, with no error, no warning and no compiler diagnostic. This page is
    /// a pushed destination, so the call that hides the bar lives on `HomeDashboardView`'s root and is
    /// gated on `presentedActivity`, the same flag that pushes this page; nothing here can hide it.
    @State private var isPresentingOverflowMenu = false

    /// Pops this page. `LiveSessionView` is the repo's precedent for the environment dismiss in a
    /// pushed destination.
    @Environment(\.dismiss) private var dismiss

    /// Called with the removed session's id **after** this page has dismissed itself, so the pushing
    /// screen can drop the row from the list it is drawing. See this type's comment for why the removal
    /// is local rather than a reload.
    ///
    /// A required parameter rather than a defaulted one: a call site that forgot it would leave Home
    /// drawing a session the user just deleted until the next load, which is a silent wrong rather than
    /// a compile error. `WhoopsyPreviews` is the second call site and passes a no-op.
    private let onDeleted: (UUID) -> Void

    /// Called with the session **as saved** after this page has written an edit and dismissed its sheet,
    /// so the pushing screen can replace the row it is drawing.
    ///
    /// Required for `onDeleted`'s own reason, and not defaulted: a call site that forgot it would leave
    /// Home drawing the activity's old name and old times until the next load, which is a silent wrong
    /// rather than a compile error. The pushed page is a snapshot — its view model took the session once
    /// — so nothing behind it moves unless this is handed back.
    ///
    /// **It is handed the whole session and not just its id**, unlike `onDeleted`. A deletion removes a
    /// row and an id is enough to name it; an edit moves fields *inside* a row that stays where it is,
    /// and Home re-sorts its rows by start instant — so a callback carrying only an id would leave the
    /// list holding the pre-edit times, in the pre-edit order, with no way to tell that it was stale.
    private let onSaved: (WorkoutSession) -> Void

    /// Ends the running fast this page is showing, and is called **after** the page has dismissed
    /// itself.
    ///
    /// Required for `onDeleted`'s own reason, and the stakes are higher here: a call site that forgot it
    /// would leave `END FAST` dismissing the page and doing nothing else, so the user would watch the
    /// fast's page go away and believe it had ended while the bar went on counting behind it. A
    /// no-op is a silent wrong rather than a compile error, so this is not defaulted.
    ///
    /// **It is `async` and returns nothing**, unlike its two siblings, because there is nothing to hand
    /// back: an ended fast is a `workouts` row whose day Home may or may not be showing, and
    /// `HomeViewModel.updateWorkout(_:on:)` already decides that from the covering rule — so the
    /// insertion is Home's, driven from `activeFast` going `nil`, and not a value pushed across this
    /// boundary. A `Summary?` would invite this page to decide something the pushing screen owns.
    ///
    /// It is unreachable from a stored session's page by construction: the row that calls it exists only
    /// in `ActivityOverflowMenu.groups(isLive: true)`, and that shape is drawn only while
    /// `viewModel.isLiveFast`.
    private let onEndFast: () async -> Void

    public init(
        viewModel: ActivityDetailViewModel,
        onDeleted: @escaping (UUID) -> Void,
        onSaved: @escaping (WorkoutSession) -> Void,
        onEndFast: @escaping () async -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onDeleted = onDeleted
        self.onSaved = onSaved
        self.onEndFast = onEndFast
    }

    /// The edit the sheet is open over, or `nil` when no sheet is up.
    ///
    /// **Seeded from `viewModel.session` at the moment `Edit` is tapped**, and not from anything the
    /// pushing screen holds. Home's `presentedActivity` is the session *as it was before* this page
    /// wrote anything, so re-opening the sheet from it after a save would seed the stale times back —
    /// which is the one way an edit could come undone without the user asking.
    ///
    /// `.sheet(item:)` keys on `ActivityEditDraft.id`, which is the session's own id — so a write to the
    /// draft is not a new identity and does not re-present the sheet under the user's finger.
    @State private var editDraft: ActivityEditDraft?

    /// Whether a save is in flight, so `SAVE` cannot be pressed twice over one edit.
    @State private var isSavingEdit = false

    /// The page's own gutter. Applied per block rather than to the stack, because the chart is drawn
    /// full-bleed and a stack-wide `padding()` would inset it.
    private static let gutter: CGFloat = 16

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                    .padding(.horizontal, Self.gutter)

                // **Two layouts, one gate.** A fast has neither a strain nor a step count — a Zero fast
                // measures none of the three, which §20 asserts on the stored row — so its two stat
                // columns would both read `—`. It gets its own pair instead, and its own chart in place
                // of the heart-rate trace, which on a fast is `No Data` for the same reason.
                //
                // The gate is `ActivityFigure.isFast`, the same call `loadFastingRecovery()` reads
                // nothing until it passes, so the layout and the read behind it cannot disagree.
                if viewModel.isFast {
                    fastingStatsRow
                        .padding(.horizontal, Self.gutter)

                    fastingChartSection
                } else {
                    statsRow
                        .padding(.horizontal, Self.gutter)

                    heartRateSection

                    typicalRangeHeader
                        .padding(.horizontal, Self.gutter)

                    zoneSection
                        .padding(.horizontal, Self.gutter)
                }

                // **Below both layouts, and that placement is the user's own instruction** — *"on
                // activity detail page, and location was enabled i want this map to be displayed below
                // HR panels at bottom of page"* — so it is a sibling of the `if`/`else` rather than a
                // member of either arm. A fast could in principle record one too, and nothing here
                // would have to change if it did.
                routeSection
                    .padding(.horizontal, Self.gutter)
            }
            .padding(.vertical, 10)
        }
        // Not optional: a `ScrollView` whose content holds nothing flexible lays out at its content's
        // width, and this page's narrowest block is a row of text — see `StrainDetailView`'s gotcha for
        // the pure-black column that draws down both sides when this is left off.
        .frame(maxWidth: .infinity)
        .background(Theme.backgroundDark)
        .task { await viewModel.load() }
        // The `•••`'s menu. An overlay rather than a `.sheet`, on Home's calendar's and menu's rule: a
        // sheet is a full-height card the system centres in a dark slab, while this is a row of actions
        // whose whole reading is that it belongs to the page behind it.
        .overlay {
            if isPresentingOverflowMenu { overflowMenuOverlay }
        }
        // The `Edit` sheet. A `.sheet` and not an overlay, which is the one place on this page where the
        // two disagree — the menu above states its own reason, and `ActivityEditSheet` states this one:
        // the reference's `EDIT ACTIVITY` is a real sheet, and the user chose it.
        //
        // **The binding reads back through `editDraft` rather than through the closure's argument.** The
        // closure is handed the draft as it was when the sheet was presented, and the sheet writes into
        // that value on every handle drag and every minute picked — so a `Binding` built on the captured
        // copy would hand the sheet its own opening state on the next render and freeze the handles.
        .sheet(item: $editDraft) { presented in
            ActivityEditSheet(
                draft: Binding(
                    get: { editDraft ?? presented },
                    set: { editDraft = $0 }),
                series: viewModel.heartRateSeries,
                isSaving: isSavingEdit,
                onSave: { saveEdit() })
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    /// The session's name, when it was, the glyph Home drew for it, and the overflow control.
    ///
    /// **The glyph comes from `ActivityGlyph.mark(for:)`**, the app's one name-to-mark mapping, so the
    /// mark here and the row on Home cannot come to draw one activity two ways. `nil` and an unmapped
    /// name both fall back inside that type rather than here.
    ///
    /// **The gutter is a `minWidth` and not the fixed `width` it was.** A single symbol is unaffected —
    /// the widest one this app draws a title beside measures 45 pt at this 38 pt regular — so the four
    /// names that were drawn here before sit exactly where they sat. A composite is not: `Fast`'s
    /// pair is ~70 pt at this size, which a fixed 48 pt frame would let bleed into the title. The honest
    /// cost is that the **four names whose symbol is wider than 48 pt** now grow the frame instead of
    /// overhanging it, so their titles move right by about 8 pt: `Road Biking` and `Mountain Biking`
    /// draw `figure.outdoor.cycle` at ~56 pt, and `Spin` and `Assault Bike` draw its indoor sibling.
    /// Under `width:` the overhang was absorbed by the 12 pt spacing and looked deliberate; it is not
    /// something to preserve at the price of a pair drawn over the name.
    ///
    /// **It is drawn bare and in `textPrimary`**, at the page's own weight rather than in a tinted chip:
    /// the shape is what identifies the activity, and a coloured badge behind it would make the glyph a
    /// decoration on a coloured square rather than the mark. The strain figure below is the page's one
    /// blue element.
    ///
    /// **The name is WHOOP's own word and the fallback is WHOOP's own word too.** `activityName` is
    /// `nil` on every session this app recorded itself, and the reference's own label for an activity
    /// its classifier could not name is `ACTIVITY` — the literal string on 197 of the export's 673
    /// rows. So the fallback is not a placeholder this page invented; it is the same word WHOOP writes.
    /// It is drawn as a **label and not a dash**, because a name was never a measurement.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ActivityGlyphLabel(ActivityGlyph.mark(for: viewModel.session.activityName), size: 38)
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: ActivityGlyph.activityHeaderMinWidth, minHeight: 48, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .textCase(.uppercase)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(Self.subtitle(startedAt: viewModel.session.startedAt, endedAt: viewModel.session.endedAt))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            overflowControl
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// The control in the top-right corner: the word `END FAST` while a fast is running, the `•••`
    /// otherwise. **Both open the same menu**, and the word only says which of its two shapes is behind
    /// it.
    ///
    /// **It is a label change and not a second control, which is the decision worth stating.** Making
    /// `END FAST` end the fast on the spot would leave `ActivityOverflowMenu.groups(isLive:)` — and the
    /// `Cancel` row that is the only way out of the menu — unreachable on the one page that has a live
    /// menu, which would make the live shape dead code that §19 asserts the shape of. It would also put
    /// the app's second irreversible action behind a single tap with no row to read first, where
    /// `Delete` — the first — is reached through exactly this menu. The menu confirms; the control
    /// announces.
    ///
    /// **It has a destination**, which is why it is no longer the control the repo's
    /// *no-control-without-a-destination* rule had to make an exception for. The exception moved to the
    /// menu's `Edit` row, and has now been retired there too — see `perform(_:)`.
    private var overflowControl: some View {
        Button {
            presentOverflowMenu()
        } label: {
            Group {
                if viewModel.isLiveFast {
                    Text(Self.endFastTitle)
                        .font(.system(size: 15, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.recoveryRed)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .frame(height: 40, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.isLiveFast ? Text(Self.endFastTitle) : Text("More options"))
    }

    /// The live control's word. A constant rather than a literal at the drawing for
    /// `ActivityOverflowMenu`'s reason — it is a UI literal with no second consumer, so the value is the
    /// whole answer — and because the row behind it reads `End Fast` in sentence case, which is not the
    /// same string.
    private nonisolated static let endFastTitle = "END FAST"

    // MARK: - The overflow menu

    /// The menu: full-width rows at the bottom of the screen over a dimmed page.
    ///
    /// **Anchored to the bottom because that is what was asked for**, and the rows run the screen's whole
    /// width for the same reason — `ActivityOverflowMenu`'s three entries, drawn top to bottom in the
    /// reference's own order.
    ///
    /// **The scrim takes the tap**, which is what makes dismissing a matter of touching anywhere outside
    /// the rows; only the scrim ignores the safe area, and it does so in both directions so the dimming
    /// reaches behind the status bar and the home indicator. It also stops the page scrolling underneath
    /// — a hit test lands on the scrim rather than on the `ScrollView` below it, so a drag while the menu
    /// is up moves nothing. Home's calendar and its `+` menu are the same arrangement.
    private var overflowMenuOverlay: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(ActivityOverflowMenu.scrimOpacity)
                .ignoresSafeArea()
                .onTapGesture { dismissOverflowMenu() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text("Dismisses the activity options"))
                .transition(.opacity)

            overflowMenu
                .transition(.move(edge: .bottom))
        }
    }

    /// The menu itself: one card per group of `ActivityOverflowMenu`, a small gap between them.
    ///
    /// **Two cards and not one, because the last row is not an action on the session.** `Edit` and
    /// `Delete` do something to the activity and sit together under a hairline; `Cancel` is the way out
    /// of the menu and sits in a card of its own, held `groupSpacing` clear of them — so the dimmed page
    /// shows through that gap and the last row reads as apart rather than as a third action. Both cards
    /// are full width, both rows are `rowHeight`, and neither card is taller than its rows — so the
    /// separation and the address of one card rather than the other are the whole of the difference.
    ///
    /// **The grouping is `ActivityOverflowMenu.groups` and not a condition here.** Splitting on
    /// `entry.action == .cancel` inside this `body` would be a rule the runner has no way to see, which
    /// is why the split lives on the value and §19 asserts its shape.
    ///
    /// **A running fast draws a different first card from `groups(isLive:)`, and the shape of the menu
    /// is unchanged.** One acting row above, `Cancel` alone below, the same gap and the same radius —
    /// so the live menu reads as this menu rather than as a second one. The `isLive` argument is the
    /// whole of the fork; nothing in this drawing branches on it, which is what keeps `groupSpacing`'s
    /// one job — setting `Cancel` apart — true of both shapes.
    ///
    /// **Each card is rounded on all four of its own corners, and this `VStack` draws nothing itself.**
    /// The alternative the menu first had — round the stack's two outer ends and leave the inner edges
    /// square — put a square corner on the `Delete` row, which is the last row of the *first* card and
    /// therefore a free end rather than an edge meeting anything. Matching a card's ends to each other
    /// is a property of the card, so it is `overflowCard`'s background that carries the radius and there
    /// is no clip here at all.
    private var overflowMenu: some View {
        VStack(spacing: ActivityOverflowMenu.groupSpacing) {
            ForEach(
                Array(ActivityOverflowMenu.groups(isLive: viewModel.isLiveFast).enumerated()),
                id: \.offset
            ) { _, group in
                overflowCard(group)
            }
        }
    }

    /// One card: a group's rows, hairline-separated, rounded on all four corners.
    ///
    /// **The fill is the card's own bounds and nothing more, so the safe area bounds the drawing exactly
    /// as it bounds the rows.** The overlay this card hangs in is bounded by the safe area, so a
    /// bottom-aligned card's last row already clears the home indicator by construction; a background
    /// **shape** with no `.ignoresSafeArea` fills to that same line and stops, and the `Cancel` card is
    /// therefore its row and only its row. Nothing here reaches for `.safeAreaPadding` either.
    ///
    /// **It used to extend, and the measurement is why it no longer does.** With
    /// `.ignoresSafeArea(edges: .bottom)` on this background, the fill ran to the screen's edge: measured
    /// on the iPhone 17 Pro simulator at the card's centre, `Edit` and `Delete` came out 54 pt each, the
    /// gap 8.0 pt, and the `Cancel` card **88 pt** — its 54 pt row plus 34 pt of fill. The first version
    /// of that modifier was itself the fix for a *different* fault, where the fill stopped at the safe
    /// area and this page's own footnote was legible in the strip below; what it bought was a `Cancel`
    /// card half again the size of the rows above it. The instruction was to remove that bottom part, so
    /// the card ends where its row ends and the dimmed page shows below it — which is what the top card
    /// already had under it, and what the gap between the two cards already showed.
    ///
    /// **Rounded on all four corners, because a card's two ends have to be the same shape as each
    /// other.** Only the top corners were rounded while the menu's two outer ends were clipped from the
    /// stack, which left a square corner directly under `Delete` — the last row of the first card, and
    /// an end of that card rather than an edge meeting the gap. A card whose top is round and whose
    /// bottom is square reads as half a card; the instruction was to round it, so the radius is this
    /// background's and nothing else in the menu draws a corner. `cardCornerRadius` is one constant for
    /// both cards so the two cannot come out at two radii.
    private func overflowCard(_ group: [ActivityOverflowMenu.Entry]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(group.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { Divider().overlay(Theme.cardBorder) }
                overflowRow(entry)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: ActivityOverflowMenu.cardCornerRadius)
                .fill(Theme.homeCard)
        }
    }

    /// One row. The tap closes the menu, then does whatever the entry's `Action` names.
    ///
    /// **`frame(maxWidth: .infinity)` is the whole of the row's width**, and `rowHeight` is a constant on
    /// the value rather than a padding here so the three rows cannot come out at three heights.
    /// `buttonStyle(.plain)` is load-bearing, on `HomeDashboardView.activityMenuRow`'s note: the default
    /// style tints its label and adds a hit shape, which would recolour the word the entry specifies.
    private func overflowRow(_ entry: ActivityOverflowMenu.Entry) -> some View {
        Button {
            perform(entry.action)
        } label: {
            Text(entry.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(entry.tint)
                .frame(maxWidth: .infinity)
                .frame(height: ActivityOverflowMenu.rowHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Runs the row's action.
    ///
    /// **Every row closes the menu first**, including the one that does nothing: closing is what a menu
    /// row does, and it is also what the system's action sheet did before this menu was hand-built.
    ///
    /// **The `switch` is exhaustive over `ActivityOverflowMenu.Entry.Action`**, on `HomeDashboardView`'s
    /// rule for `ActivityMenu.Entry.Action`: a case added there stops this compiling until it is handled
    /// here, which is the property a stored closure in the entry would not have had.
    ///
    /// **`Edit` has a destination now, and the repo's *no-control-without-a-destination* rule therefore
    /// has no exception anywhere.** The user's instruction was *"edit we will wire later"*, and this is
    /// that later: the row opens `ActivityEditSheet` over this page. The exception used to belong to the
    /// `•••` itself, moved here when that control was wired, and is now retired — the rule stands
    /// unqualified, and anything added to a screen with no destination is the bug it describes.
    private func perform(_ action: ActivityOverflowMenu.Entry.Action) {
        dismissOverflowMenu()
        switch action {
        case .edit:
            presentEdit()
        case .delete:
            deleteActivity()
        case .endFast:
            endFast()
        case .cancel:
            break
        }
    }

    /// Ends the running fast, and only then leaves the page.
    ///
    /// **Dismiss first, then end it** — `deleteActivity()`'s documented order, and its reason applies
    /// here word for word: `onEndFast` writes a `workouts` row and moves `activeFast` to `nil`, which is
    /// what Home's bar is drawn from, so this page must not be on screen while the screen behind it
    /// changes shape.
    ///
    /// **There is no `guard` on the result, and that is not the same as ignoring one.** `endFast()` on
    /// the use case returns `nil` for a fast that had already ended or that has not run for a whole
    /// second, and both are states this page cannot be in: the page is only drawn from a live
    /// `activeFast`, and it takes a tapped row to get here. `deleteActivity` needs its guard because a
    /// delete can genuinely fail against storage — this cannot, because nothing here reads the database,
    /// and a dismissal is the honest response to a write that the use case declined.
    ///
    /// **Nothing is handed back to Home, deliberately.** The row the fast becomes is a `workouts` row
    /// whose day the pushing screen may or may not be showing, and `HomeViewModel.updateWorkout(_:on:)`
    /// already settles that from its covering rule — so the insertion is Home's, made once
    /// `liveSessionUseCase.activeFast` reads `nil`. See `onEndFast`.
    private func endFast() {
        Task {
            dismiss()
            await onEndFast()
        }
    }

    // MARK: - Editing

    /// Opens the sheet over the session as it is **stored right now**. See `editDraft`.
    private func presentEdit() {
        editDraft = ActivityEditDraft(viewModel.session)
    }

    /// Writes the open draft, then dismisses and reports it back.
    ///
    /// **Three ways out, and only one of them writes.** No draft at all is a dismissal already in flight
    /// and is ignored. An untouched draft dismisses and writes nothing — the user opened the sheet and
    /// changed their mind, and `WorkoutSession`'s two instants are exact while the pickers are not, so
    /// writing an untouched draft would move a session stored with seconds. Only a draft that says
    /// something different reaches the repository.
    ///
    /// **A failed write does not dismiss.** Same shape as `deleteActivity()`: the sheet stays up with the
    /// edit still in it, because closing over a write that did not land would leave the page printing the
    /// old times as though it had. The failure is silent on screen — `errorMessage` is written by five
    /// view models and drawn by none — so the honest half is at least not to claim success.
    private func saveEdit() {
        guard let draft = editDraft else { return }
        guard draft.hasChanges else {
            editDraft = nil
            return
        }
        isSavingEdit = true
        Task {
            let saved = await viewModel.save(draft)
            isSavingEdit = false
            guard saved else { return }
            // Read back off the view model rather than off the draft: `save` re-derives the zone rows
            // and the heart-rate series from the session it wrote, and the session it holds is the row
            // that was actually persisted.
            let updated = viewModel.session
            editDraft = nil
            onSaved(updated)
        }
    }

    private func presentOverflowMenu() {
        withAnimation(.snappy(duration: 0.3)) { isPresentingOverflowMenu = true }
    }

    private func dismissOverflowMenu() {
        withAnimation(.snappy(duration: 0.26)) { isPresentingOverflowMenu = false }
    }

    /// Removes the session, and only then leaves the page.
    ///
    /// **Dismiss first, then tell Home** — in that order, because `onDeleted` mutates the list the
    /// pushing screen is drawing and this page must not be on screen while that happens.
    ///
    /// The page does not dismiss when nothing was removed: `viewModel.delete()` returns `false` for a row
    /// that was already gone and for a failed write alike, and staying put is the honest response to both
    /// — a dismissal would tell the user the session is gone while Home still lists it.
    private func deleteActivity() {
        Task {
            let id = viewModel.session.id
            guard await viewModel.delete() else { return }
            dismiss()
            onDeleted(id)
        }
    }

    /// The session's name, uppercased for the drawing only — `HomeDashboardView.activityRow`'s rule,
    /// and `textCase` is idempotent over the already-uppercase `ACTIVITY` fallback.
    private var displayName: String { viewModel.session.activityName ?? "ACTIVITY" }

    /// When the session was, in one line.
    ///
    /// `nonisolated static` rather than composed in the `body`, on the rule this page's other strings
    /// follow: the runner has no renderer, so a sentence written into a `body` is a sentence nothing can
    /// assert. The date is the app's existing short form (`Sun, Aug 10`) and the two ends are its
    /// existing clock form, so this page introduces no fourth date format.
    public nonisolated static func subtitle(startedAt: Date, endedAt: Date) -> String {
        "\(startedAt.formattedShortDate()) \(startedAt.formattedHourMinute()) to \(endedAt.formattedHourMinute())"
    }

    // MARK: - Strain and steps

    /// The session's two headline figures side by side, each with its comparison against this activity's
    /// history.
    ///
    /// **The figure is above the label, not below it.** Every other row in this app puts its label first
    /// — `metricRow` on the Recovery page, the zone rows below — and this page's reference does the
    /// opposite. The reason it reads: these two are *figures*, not readings in a table, so the thing the
    /// eye lands on is the number and the words are its caption. It is `ActivityDetailView`'s own layout
    /// and nothing else in the app takes it.
    ///
    /// **Both badges are neutral and neither carries a verdict** — see `ActivityDelta`. Strain rising
    /// against the last ten basketball sessions is neither good news nor bad, and there is no token on
    /// this page that would let a reader think otherwise.
    ///
    /// **The basis is named on the card**, which is what the user asked for: the mean each figure is
    /// compared against is written under it, and the caption says how many sessions it was taken
    /// over. Without that, `vs 3.8` is a comparison against a number with no stated provenance. The
    /// reference has no such line; it is kept deliberately, and the caption is the reason.
    private var statsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                statColumn(
                    title: "ACTIVITY STRAIN",
                    value: viewModel.strainText,
                    delta: viewModel.strainDelta,
                    valueColor: Theme.strainRing)

                statColumn(
                    title: "ACTIVITY STEPS",
                    value: viewModel.stepsText,
                    delta: viewModel.stepsDelta,
                    valueColor: Theme.textPrimary)
            }

            Text(Self.comparisonBasis(sessionCount: viewModel.comparisonSessionCount))
                .font(.system(size: 10))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One figure, its badge and its caption.
    ///
    /// **The badge is drawn only when there is a delta**, so a session with no history shows the figure
    /// and nothing beside it rather than an empty badge or a `vs —` — and on this page that is also what
    /// withholds the steps badge on every imported session, since a step count and its mean are absent
    /// together.
    ///
    /// **The two columns are equal by construction**: each ends in
    /// `frame(maxWidth: .infinity, alignment: .leading)`, so a wide figure on one side cannot push the
    /// other narrower. `minimumScaleFactor` is the guard for the widest case — a five-digit step count
    /// with a pill beside it in a half-width column — and it shrinks rather than truncating, because a
    /// figure with an ellipsis in it is no longer a reading.
    private func statColumn(
        title: String, value: String, delta: ActivityDelta?, valueColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(value)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                ActivityDeltaBadge(delta: delta, showsMean: false)

                Spacer(minLength: 0)
            }

            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The sentence naming what the two badges were taken over.
    ///
    /// **It says so plainly when there was nothing to compare against**, rather than leaving the card
    /// bare: a reader who sees no badge should be told why, and *"not enough history yet"* and *"this is
    /// the first time"* are the same sentence here because both are true of the same state.
    public nonisolated static func comparisonBasis(sessionCount: Int) -> String {
        guard sessionCount > 0 else {
            return "No comparison: not enough previous sessions of this activity yet."
        }
        let sessions = sessionCount == 1 ? "session" : "sessions"
        return "Compared with your last \(sessionCount) \(sessions) of this activity."
    }

    // MARK: - A fast's two figures

    /// A fast's own headline pair: how long it ran, and the mean Recovery score over the nights it
    /// covered.
    ///
    /// **It replaces `statsRow` rather than sitting beside it.** `ACTIVITY STRAIN` and `ACTIVITY STEPS`
    /// are both `—` on a fast, and two dashes with two captions under them is a card that says nothing
    /// twice; the reference has two figures on its fast screen and neither of them is either of those.
    ///
    /// **There is no comparison line under it**, deliberately. `comparisonBasis` names the window the
    /// two stat columns were compared against, and neither figure here is a comparison: the duration is
    /// the session's own span and the score is an average over its own nights. The basis that *does*
    /// need stating is the badge under the score, and it states it there.
    /// **A live fast's duration is recomputed from its anchor once a minute, and that is the one figure
    /// on this page that moves.** `viewModel.totalDurationText(at:)` takes the instant for exactly this
    /// reason: the stored form is `durationSeconds`, a subtraction of two frozen instants, so wrapping
    /// *that* in a `TimelineView` would re-render a constant sixty times an hour and call it a clock.
    /// The live form is `now − liveFast.startedAt`, formatted through the same formatter, so the page and
    /// the row it becomes on Home cannot print one fast's length two ways.
    ///
    /// **The `TimelineView` wraps the one column and not the row.** The score beside it is a mean over
    /// nights and is minute-insensitive, so a row-wide timeline would re-evaluate the whole pair — and
    /// the badge, and its colour — to move one string. It is not the `LiveSessionBar` split, which is
    /// about *where an Observation dependency is registered*; this page holds no observable use case, so
    /// the timeline is only ever a re-render.
    ///
    /// The non-live branch passes `Date()` and the value ignores it: `totalDurationText(at:)` takes the
    /// stored form whenever `liveFast` is `nil`, which is every stored session including an ended fast.
    private var fastingStatsRow: some View {
        HStack(alignment: .top, spacing: 12) {
            if viewModel.isLiveFast {
                TimelineView(.everyMinute) { context in
                    totalDurationColumn(at: context.date)
                }
            } else {
                totalDurationColumn(at: Date())
            }

            fastingScoreColumn
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The `TOTAL DURATION` column, for a fast somewhere on the running-or-ended axis. See
    /// `fastingStatsRow` for why `now` is asked for here rather than left to the view model.
    private func totalDurationColumn(at now: Date) -> some View {
        statColumn(
            title: Self.totalDurationTitle,
            value: viewModel.totalDurationText(at: now),
            delta: nil,
            valueColor: Theme.textPrimary)
    }

    /// The score column: the figure, its caption, and the basis **under** both.
    ///
    /// **The badge is below the label rather than beside the figure**, which is the one structural
    /// difference from `statColumn` and the reason this is a column of its own. A recovery score has no
    /// comparison to make — `vs 3.8` is the shape a delta implies and there is no mean for one — so
    /// what sits beside it in the reference is a raised badge, and `ActivityDeltaBadge` draws a
    /// movement this figure does not have.
    ///
    /// The badge's surface is `Theme.deltaPillFill`, the token that exists for exactly this: a badge on
    /// the activity page's bare background rather than inside a card. It is not a new token, and it is
    /// not `cardBackground` — see that token's own comment for why drawing a card surface here would
    /// draw a card.
    private var fastingScoreColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(viewModel.fastingScoreText)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(viewModel.fastingScoreColor)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(Self.fastingScoreTitle)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let badge = viewModel.fastingBadgeText {
                Text(badge)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.deltaPillFill, in: Capsule())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private nonisolated static let totalDurationTitle = "TOTAL DURATION"

    /// `FAST RECOVERY SCORE`, and **it is the app's ordinary Recovery score** — the reference's own
    /// caption, kept because it names the figure honestly enough: what the reader is looking at is a
    /// recovery score computed over the fast's nights. It is not a fasting score, and `docs/ALGORITHMS.md`
    /// §9 says so where the substitution is recorded.
    private nonisolated static let fastingScoreTitle = "FAST RECOVERY SCORE"

    // MARK: - The fasting chart

    /// The nights the fast covered, or the one line that says why there are none.
    ///
    /// **Both absence states live in this slot rather than on the page**, and they are different
    /// sentences on purpose. `fastingRecovery == nil` means the fast enclosed no measured night — the
    /// common case on the bundled files, where 152 of 170 fasts predate the recovery record entirely.
    /// A summary that exists but yields no series means the opposite: the fast covered nights and the
    /// baseline window behind them was too thin to measure them against. Telling a user with four real
    /// readings that they had none would be a lie about their own data, so the two do not share a string.
    ///
    /// **The chart always has a frame when it is drawn** — `FastingRecoveryChartView` is handed a
    /// non-optional series, because the branch that has no chart is this one.
    private var fastingChartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(Self.fastingMetricsTitle)
                .padding(.horizontal, Self.gutter)

            if let series = viewModel.fastingChartSeries {
                Text(Self.fastingMetricsCaption)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.gutter)

                FastingRecoveryChartView(series: series)
                    .padding(.horizontal, Self.gutter)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(series.spokenSentence)

                // The reference's bold lead-in and its sentence. **Concatenated as two `Text`s and
                // never as one string with Markdown asterisks** — `Text` parses Markdown only for a
                // literal, so a `**bold**` inside a built `String` would render its asterisks on the
                // screen, which is the trap `CLAUDE.md` records and nothing in this repo can catch.
                (Text(Self.fastingTrendLeadIn).fontWeight(.bold) + Text(" " + series.sentence))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.gutter)
            } else {
                Text(viewModel.fastingRecovery == nil
                    ? Self.noFastingReadingsNote
                    : Self.thinFastingBaselineNote)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.gutter)
            }

            // The page's conclusion, and **deliberately outside the two branches above**: the sentence
            // reads the score, and the score is a mean of stored recovery scores that needs no baseline
            // to exist. So a fast whose history was too thin to *plot* still gets its band statement —
            // the bars are withheld, the figure is not, and a reader told the comparison is unavailable
            // is still owed the answer to "should I stop".
            //
            // It draws one step brighter than the trend sentence above it (`textSecondary` against
            // `textMuted`, 11 pt against 10) because it is a verdict rather than another reading — and
            // **in no band colour at all**, which is the one thing here that is a decision rather than
            // styling: the figure above is tiered by `RecoveryState` (67/34) while this bands the same
            // number 67/**50**, so between 34 and 50 the two disagree on purpose. Two colour scales
            // under one figure is the fault that arrangement exists to avoid; the band is carried by
            // the words (`Recovery holding.` / `Recovery slipping.` / `Stop signal.`) instead.
            //
            // Two `Text`s and never one with Markdown asterisks, for the reason the trend sentence
            // above states in full.
            if let guidance = viewModel.fastingGuidance {
                (Text(guidance.leadIn).fontWeight(.bold) + Text(" " + guidance.body))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.gutter)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The section's title, and the fixture's own heading rearranged: the reference writes
    /// `Physiological Recovery Metrics (normalized)`, and this app names the scale in the caption
    /// instead — because *normalized* does not say normalised against **what**, and that is the whole
    /// question a reader of this chart has.
    private nonisolated static let fastingMetricsTitle = "Physiological Recovery Metrics"

    /// **`block`, not `bar`** — the columns are merged, so what a reader reads is a segment inside one
    /// column rather than a bar of its own, and the sentence has to name the thing they can point at.
    /// The scale is still σ, and it is still against the window that preceded the fast rather than a
    /// rolling one, which is the question the title cannot answer.
    ///
    /// **The second half is the one the picture cannot teach on its own.** Nothing on the drawing says
    /// that a zero-height block means *fell* rather than *was not measured* — the legend keys the
    /// colours, not the absences — and a reader who took an empty column for missing data would read a
    /// night of three falls as a night with no readings, which is the opposite of what it is. So the
    /// caption says it once, plainly, in the same breath as the scale.
    private nonisolated static let fastingMetricsCaption =
        "Each block is a z-score against your 30-day baseline (σ); a night's three stack into one "
        + "column, and a reading that fell shows less of it rather than a block below the line."

    private nonisolated static let fastingTrendLeadIn = "Normalized Trends (z-score basis):"

    /// The fast covered no night this app has a reading for.
    private nonisolated static let noFastingReadingsNote =
        "No physiological readings inside this fast."

    /// The fast covered nights, and there is not enough history behind them to compare against.
    private nonisolated static let thinFastingBaselineNote =
        "Not enough history yet to compare these nights against your baseline."

    // MARK: - Heart rate

    /// The session's heart-rate trace, drawn across the page's full width.
    ///
    /// **The chart is handed the series as an optional and always draws a frame**, so the two branches
    /// are one picture with a different middle rather than a chart and an empty state side by side. A
    /// session with no samples gets the session's own two bounds, its two clock labels and its empty y
    /// gutter, with `ActivityHeartRateChartView.absenceNote` centred in the plot — never a flat line.
    ///
    /// **The caption below is the why, not the what**, and it is drawn only in the absent branch: the
    /// chart's own sentence already says nothing was recorded, so a second sentence repeating it would
    /// be noise. What a reader cannot work out from the picture is the reason, and the reason is narrow
    /// — this app records heart rate only while it is connected to a strap. It deliberately does not say
    /// "sync your strap": this build's drain has no heart-rate record walk, so that would promise a fix
    /// that does not exist. `SleepDetailView.noSleepingData`'s wording, for its reason.
    private var heartRateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ActivityHeartRateChartView(
                series: viewModel.heartRateSeries,
                start: viewModel.session.startedAt,
                end: viewModel.session.endedAt)

            if viewModel.heartRateSeries == nil {
                Text(Self.noHeartRateNote)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.gutter)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Why the chart above is empty, on the sessions where it is.
    private nonisolated static let noHeartRateNote =
        "This app records heart rate only while it is connected to a strap."

    // MARK: - Typical range

    /// This session's length, as the reference's plain section header: the band mark and its label on
    /// the left, `DURATION` and the figure on the right.
    ///
    /// **The row is always drawn and the band is not.** The session's own length is a fact the page has
    /// whether or not there is any history to read it against, so a session with fewer than
    /// `minimumBaselineDays` priors shows its duration with no range — the figure is a reading and the
    /// range is a comparison, and only the comparison needs a baseline.
    ///
    /// **The range is spoken and not drawn.** The user's instruction was *"exactly the mockup — header
    /// only"*, which takes the duration bar and its `Typical: 27-41 min` caption off the page. The model
    /// behind them still computes and is still asserted; what moved is where the range reaches a reader,
    /// which is now this row's accessibility label alone. `ActivityDurationBar` and its layout type are
    /// kept unrendered rather than deleted — see `CLAUDE.md` `## Pages` for why.
    @ViewBuilder
    private var typicalRangeHeader: some View {
        if let typical = viewModel.baseline.typicalDuration {
            typicalRangeRow
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    Self.spokenDuration(
                        durationText: viewModel.durationText, low: typical.low, high: typical.high))
        } else {
            typicalRangeRow
                .accessibilityElement(children: .combine)
        }
    }

    /// The row itself. `SectionLabel` carries `frame(maxWidth: .infinity, alignment: .leading)` of its
    /// own, which is what pushes the `DURATION` pair to the right and holds the two ends of the row
    /// apart without a `Spacer`.
    private var typicalRangeRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            BandMarkGlyph()

            SectionLabel("Typical range")

            Text("DURATION")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textMuted)

            Text(viewModel.durationText)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The band as a caption, in minutes — `Typical: 9-26 min`.
    ///
    /// **Minutes and not `m:ss`**, because this is a *range* rather than a reading: two clock-shaped
    /// durations side by side invite the eye to compare digits, and the band is a span of the scale.
    ///
    /// **No longer drawn** — the header row above speaks it instead and `spokenDuration` is what carries
    /// it. It is kept, with its assertion, as the model's own sentence; see `CLAUDE.md` `## Pages`.
    public nonisolated static func typicalDurationCaption(low: Double, high: Double) -> String {
        "Typical: \(minutes(low))-\(minutes(high)) min"
    }

    /// The header row in one sentence: what the session lasted, and what is typical where there is a
    /// band to say it with.
    public nonisolated static func spokenDuration(
        durationText: String, low: Double, high: Double
    ) -> String {
        "Duration \(durationText). Typical for this activity is \(minutes(low)) to \(minutes(high)) minutes."
    }

    /// Whole minutes, rounded — the unit the caption prints.
    private nonisolated static func minutes(_ seconds: Double) -> Int {
        Int((seconds / 60).rounded())
    }

    // MARK: - Heart rate zones

    /// The five bands, hardest first, each its own card with its BPM range, its share and its time.
    ///
    /// **This block is what the user asked to sit below the chart** — *"heart zones, zone 1, 2, 3, 4,
    /// and 5 and time duration within those zones for that workout"* — and it is drawn whether or not
    /// the chart above it has a trace, because the two answer different questions: the chart is a
    /// recording this app makes, the rows are WHOOP's own published block. A session with no trace can
    /// still have five real rows.
    ///
    /// **A session with no block draws five dashes**, not a `0%` and not an absent card. See
    /// `ActivityZoneRow` for why those are different answers and which one this is.
    ///
    /// **There is no `HEART RATE ZONES` heading.** The reference has none — the five rows name
    /// themselves — and the `TYPICAL RANGE` row directly above them now serves as the section's label.
    @ViewBuilder
    private var zoneSection: some View {
        if !viewModel.zoneRows.isEmpty {
            VStack(spacing: 8) {
                ForEach(viewModel.zoneRows, id: \.index) { row in
                    zoneCard(row)
                }

                Text(Self.zoneFootnote)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
    }

    /// One zone, as its own card.
    ///
    /// **The percent is drawn in the zone's own colour**, through
    /// `HeartRateZoneIndex.color` — the app's one zone-to-colour mapping, so this row and the strain
    /// page's bar cannot come to name one band two colours. It is the figure that belongs to the band,
    /// and the tint says which band without a second label.
    ///
    /// **The time is split into a dim minutes half and a bright seconds half**, through
    /// `ActivityZoneRow.durationParts`: the seconds are the digit that moves, so the moving part is the
    /// one at full strength. Both halves keep their monospaced digits, so the column does not shift as
    /// the numbers change width.
    ///
    /// **The dashes an absent block draws are not split.** `durationParts` hands a string with no colon
    /// back whole, so the single em dash is drawn once in the dim colour rather than being padded into a
    /// two-part shape it does not have.
    private func zoneCard(_ row: ActivityZoneRow) -> some View {
        let parts = ActivityZoneRow.durationParts(row.secondsText)
        return HStack(spacing: 8) {
            Text("ZONE \(row.index.rawValue)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 54, alignment: .leading)

            Text("\(row.bpmRangeText) BPM")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 68, alignment: .leading)

            Text(row.percentText)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(row.index.color)
                .frame(width: 42, alignment: .leading)

            Spacer(minLength: 4)

            HStack(spacing: 0) {
                Text(parts.leading)
                    .foregroundStyle(Theme.textSecondary)

                Text(parts.trailing)
                    .foregroundStyle(Theme.textPrimary)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12, padding: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ActivityZoneRow.spoken(row))
    }

    /// The one thing about this block a reader cannot work out from the rows.
    ///
    /// **The five do not sum to the session**, and a reader who adds the column up and finds it short
    /// would otherwise read that as an error. The remainder is time below zone 1, which WHOOP publishes
    /// no column for — the same fact `WorkoutSession`'s own doc comment records and the reason these
    /// rows are not derived through `WholePercentMath`.
    ///
    /// **And the edges are not WHOOP's.** The shares are its own; the BPM boundaries are this app's
    /// Karvonen table off the profile's two heart rates, which on a fresh install is the cold-start
    /// `190/60` constant. Saying so on the card is the same judgement that labels Home's VO₂ figure
    /// `(EST.)` — the figure is real, its provenance is this app's. The reference has no such footnote,
    /// and it needs none: its boundaries *are* WHOOP's. Removing a provenance disclosure to match a
    /// picture is the one edit this page will not make.
    private nonisolated static let zoneFootnote =
        "Zone percentages are WHOOP's own and need not sum to 100: time below zone 1 belongs to no band. "
        + "The BPM boundaries are this app's, from your profile's heart rates."

    // MARK: - Route

    /// The session's recorded path, drawn on a map below everything else on the page.
    ///
    /// **Absent with nothing in its place, and that is the section's whole design.** `routeSection` is
    /// `zoneSection`'s sibling rather than `heartRateSection`'s: a route the session never recorded
    /// leaves the page with no block, no heading and no sentence, where the heart-rate chart draws its
    /// frame and a note explaining why the frame is empty. The two are different because their slots
    /// are: the chart's slot is *always* drawn — every session has a window to draw a trace across, and
    /// `No heart rate recorded` is a fact about one session — while this one has nothing to say on the
    /// sessions that lack it, which is currently all of them. A note here would be a permanent fixture
    /// saying *this app can record a route* rather than a response to a state, and it would have to
    /// name a toggle (`RECORD ROUTE`, on the live session screen) that a reader looking at a stored
    /// session has no way to have seen. `ActivityRoute`'s own comment carries the argument in full.
    ///
    /// **The unit is resolved here**, at the one layer that knows what device it is on, and handed to
    /// the value as an argument — which is what keeps every assertion about the two figures
    /// locale-independent. See `ActivityRoute.Unit`.
    ///
    /// **The switch is over a value the view model already decided**, not over a question asked here.
    /// `viewModel.routeRenderer` is resolved once per load, so the two halves of this `if` cannot both
    /// be reached within one page — and `RouteMapRenderer.resolve` is where the rule lives, asserted by
    /// the runner, rather than a condition written into this `body` that nothing could check.
    ///
    /// `.offline` reaches the SDK's view through the seam and is the only case that does. Every other
    /// state resolved to `.mapKit` at the view model, so a build without the SDK, a session whose
    /// download has not finished, and one whose download failed all draw the same card this page drew
    /// before the feature existed.
    @ViewBuilder
    private var routeSection: some View {
        if let route = viewModel.route {
            switch viewModel.routeRenderer {
            case .mapKit:
                ActivityRouteMapView(route: route, unit: .forLocale(.current))
            case .offline(let regionID):
                viewModel.offlineMaps.map(
                    route: route, unit: .forLocale(.current), regionID: regionID)
            }
        }
    }
}
