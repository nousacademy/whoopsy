import Foundation

/// The receptive entry a sheet is in the middle of writing: a name, an optional text, and an optional
/// time of day on the day being viewed.
///
/// ## It is a value, and the runner is why
///
/// The runner has no renderer, so a rule written into a `body` is a rule nothing can check — this
/// repo's standing reason for pulling `DayBarRules`, `MonthGrid`, `ActivityMenu` and
/// `ActivityEditDraft` out of the views that use them. Two of this feature's rules are the kind that
/// would otherwise live in the sheet: **the day-rebuild** below, and **whether an untouched sheet has
/// anything to save**. Both are here, and both are assertable.
///
/// ## The invariant it owns: the start time is a time-of-day on the day being viewed
///
/// A `DatePicker` with `displayedComponents: .hourAndMinute` hands back a whole instant carrying
/// *today's* year, month and day, whatever day the user is actually looking at. Filing that instant
/// directly would put a 2024 day's meditation on today, and the row would then be read back on a day
/// the user never opened.
///
/// So the picked hour and minute are rebuilt onto the target day's own midnight in `applying(to:)`,
/// which is the single place a `ReceptiveInactivity` is constructed from a draft:
///
///     date == startOfDay(startedAt)   whenever a time is given
///
/// There is nothing left to reconcile, and no reconciliation to get wrong. It also means the `+` row
/// is offered on **every** day rather than today alone — filing yesterday's dream onto yesterday is
/// the whole point of the feature.
///
/// ## The text has two rules, and both are the name's applied to a second field
///
/// **An empty field is *no* text.** `setNote(_:)` trims what it is handed and writes `nil` for a value
/// that is blank or whitespace-only, so the sheet cannot store `""` where the column's honest word for
/// nothing is NULL — the same rule that already makes `""` not a name. It also **drops a write that
/// changes nothing**, on `setName(_:)`'s guard, so opening a row and closing it again does not leave the
/// sheet marked dirty.
///
/// Unlike the name's, the comparison is exact rather than case-insensitive: `ActivityName.matches` is
/// right for a value chosen off a catalogue and wrong for prose, where a change of case or of spacing
/// *is* an edit the user made. The trim is the only normalisation, and it is there so that blank and
/// whitespace-only collapse to one answer rather than two.
///
/// ## `hasChanges` compares the text, and a missing clause is invisible to the compiler
///
/// The third clause below is not decoration. Without it a user can open a row, edit only its text, and
/// find `SAVE` still dark — a button that is live for every other kind of edit and dead for this one.
///
/// ## The rebuild is elapsed seconds, not `date(bySettingHour:)`
///
/// `Calendar.date(bySettingHour:minute:second:of:)` returns **`nil`** for a wall time that does not
/// exist, which is what 02:30 is on a spring-forward day — and the only fallback available there is a
/// fabricated midnight, a value the user never picked. Adding the picked offset to the day's own
/// midnight is total instead, and it keeps the invariant on both DST days: in the gap it lands on the
/// clock time that follows (03:30), and in the fold it lands on the earlier of the two occurrences.
/// Neither instant leaves its day, which is the property everything downstream reads.
///
/// ## A missing time is a missing time, and never a stand-in
///
/// `startedAt` is optional because the user's own rule is *"time is optional"*. `nil` means the entry
/// has no time — not midnight, not the moment the sheet was opened. `applying(to:)` writes the `nil`
/// straight through to the row and the card draws a name with no clock beside it, which is the
/// absence rule this app applies everywhere else.
///
/// ## `hasChanges` is the SAVE gate for both modes, and it is one gate rather than two
///
/// An **add** draft has nothing to save until it has a name, and an **edit** draft has nothing to save
/// until it differs from the row it came from. Both fall out of one comparison:
/// `applying(to:)` returns `nil` for a nameless draft, so an add draft with no name is *unchanged* and
/// the button stays dark; and an add draft that has been named differs from `original`'s `nil`, so it
/// is changed. The sheet asks one question, and neither mode has a branch of its own.
///
/// **The comparison is made on the rebuilt pair**, both sides of it, which is `MetricChange`'s rule
/// applied to a form: a `DatePicker` re-fires its setter with a freshly-built instant on a render the
/// user did not touch, so an untouched sheet must compare **equal** to its own row rather than
/// differing by the seconds between two reads of the clock. Normalising both sides is what makes a
/// re-opened `8:00 AM` read back as the stored 8:00 AM.
public struct ReceptiveInactivityDraft: Equatable, Identifiable, Sendable {

    /// The row this draft was opened over, or `nil` for a new entry.
    ///
    /// It is kept whole rather than picked apart into a name and a time, because it is also the
    /// **identity** below and the answer to "is this an edit" — and a draft that could not tell the two
    /// modes apart would offer `Delete` on a row that does not exist yet.
    public let original: ReceptiveInactivity?

    /// The chosen name, or `nil` while none has been picked.
    ///
    /// Optional rather than an empty string on the entity's own rule: `""` is not a name, and a
    /// published property holding one would be a value the sheet has to remember to test for.
    public private(set) var name: String?

    /// The entry's text, or `nil` — which is what the field holds for every meditation and every entry
    /// nobody has typed into. Declared between `name` and `startedAt`, mirroring the entity.
    ///
    /// The sheet owns it through `setNote(_:)`, so the two rules in this type's comment hold however
    /// the field is edited: blank is `nil`, and an unchanged value is not a change.
    public private(set) var note: String?

    /// The picked start instant, as the `DatePicker` handed it over — **not yet rebuilt onto the day**.
    ///
    /// Storing it raw is deliberate: the rebuild happens in exactly one place, `applying(to:)`, and a
    /// draft that also rebuilt on write would be two owners of the invariant (see this type's comment).
    /// The only thing reading this value directly is the sheet's binding, which goes through
    /// `instant(of:on:)` for the same reason.
    public private(set) var startedAt: Date?

    /// The identity of a draft that has no row behind it yet.
    ///
    /// A fresh `UUID` per draft is right here, unlike a static list's `Entry.id`: the sheet is
    /// presented by `.sheet(item:)`, and the item it holds for the whole presentation is the draft the
    /// page constructed. Neither the sheet nor the page mutates that value — the sheet edits its own
    /// copy — so the identity does not move under a live presentation.
    private let draftID: UUID

    /// What `.sheet(item:)` keys on, and what an edited entry keeps so its row survives the write.
    public var id: UUID { original?.id ?? draftID }

    /// Whether this is an edit, and therefore whether `Delete` has anything to delete.
    public var isEditing: Bool { original != nil }

    /// A draft for a new entry: no name, no text, no time.
    public init() {
        self.original = nil
        self.name = nil
        self.note = nil
        self.startedAt = nil
        self.draftID = UUID()
    }

    /// A draft over an existing row.
    ///
    /// The name, the text and the time are taken **verbatim**, on `ActivityEditDraft`'s rule: a draft
    /// that adjusted what it was handed on open would report a change the user never made, and `SAVE`
    /// would be live over a sheet nobody had touched. The verbatim carry is what makes an imported
    /// dream's prose appear in the field unaltered — and it is the first edit that trims it.
    public init(_ activity: ReceptiveInactivity) {
        self.original = activity
        self.name = activity.name
        self.note = activity.note
        self.startedAt = activity.startedAt
        self.draftID = activity.id
    }

    // MARK: - The three writers

    /// Sets the name, **dropping a write that changes nothing**.
    ///
    /// The guard is `ActivityEditDraft.setName(_:)`'s, and it is `ActivityName.matches` rather than
    /// `==` so the sheet is not marked dirty by a pick that differs only in case or surrounding space.
    /// Both the picker's row and this guard compare names the same tolerant way, which is what keeps
    /// the tick on the right row and the button dark on an untouched sheet.
    public mutating func setName(_ name: String?) {
        guard !ActivityName.matches(name, self.name) else { return }
        self.name = name
    }

    /// Sets the text, or clears it — **trimming, and dropping a write that changes nothing**.
    ///
    /// A blank or whitespace-only value becomes `nil` rather than `""`, which is the whole reason this
    /// goes through a setter instead of writing the property from the sheet's binding: the column's word
    /// for *no text* is NULL, and an empty string stored beside it would be a second one that reads back
    /// as text the user supplied. The guard is `setName(_:)`'s, and the comparison is exact — see this
    /// type's comment for why prose is not compared the way a catalogue name is.
    public mutating func setNote(_ note: String?) {
        let text = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = (text?.isEmpty ?? true) ? nil : text
        guard trimmed != self.note else { return }
        self.note = trimmed
    }

    /// Sets the start, or clears it.
    ///
    /// **There is no guard here, deliberately.** The value is stored exactly as the picker handed it
    /// over, and every question asked of it — is it changed, what instants does it become — is answered
    /// against the rebuilt form in `applying(to:)` and `hasChanges(on:)`. A guard comparing two raw
    /// instants would be comparing two different days' worth of clock time and would drop writes it
    /// should keep.
    public mutating func setStart(_ instant: Date?) {
        self.startedAt = instant
    }

    // MARK: - The day-rebuild

    /// The entry this draft describes, filed on `day` — or `nil` when there is no name to file.
    ///
    /// The optional is not a convenience: **a receptive inactivity with no name is not an entry**, and
    /// making that unrepresentable is what lets the sheet's `SAVE` gate be a test on this return value
    /// rather than a second rule about empty strings.
    ///
    /// `day` is the day the sheet was opened over, and the picked time is a time *on that day* — see
    /// this type's comment for the invariant and for why the rebuild is elapsed seconds.
    public func applying(to day: Date) -> ReceptiveInactivity? {
        guard let name, !name.isEmpty else { return nil }
        return ReceptiveInactivity(
            id: original?.id ?? draftID,
            date: day,
            name: name,
            note: note,
            startedAt: startedAt.map { Self.instant(of: $0, on: day) }
        )
    }

    /// Whether `SAVE` has anything to write. See this type's comment for why one question covers both
    /// modes.
    public func hasChanges(on day: Date) -> Bool {
        guard let candidate = applying(to: day) else { return false }
        guard let original else { return true }
        // The stored instant is rebuilt onto the same day before it is compared, so a row written by an
        // older build — or by hand, with seconds on it — is not read as an edit the user never made.
        let stored = original.startedAt.map { Self.instant(of: $0, on: day) }
        // The third clause is the text, and without it an edit to the text alone leaves `SAVE` dark —
        // see this type's comment. Nothing has to be normalised on either side: `setNote(_:)` is the
        // only writer and it has already trimmed, so a stored note and a drafted one are compared in
        // the same form.
        return candidate.name != original.name
            || candidate.note != original.note
            || candidate.startedAt != stored
    }

    /// `time`'s hour and minute, rebuilt onto `day`'s own midnight.
    ///
    /// The one definition of the invariant, called from the three places that need it: `applying(to:)`
    /// when it writes, `hasChanges(on:)` when it compares, and the sheet when it hands the picker the
    /// instant to display. A second copy of this arithmetic is how one of the three drifts — the shape
    /// `SleepConsistencyMath.clockMinutes(fromNightClock:)` records against a bridge that must not be
    /// inlined.
    public static func instant(of time: Date, on day: Date) -> Date {
        let clock = Calendar.current.dateComponents([.hour, .minute], from: time)
        let offset = (clock.hour ?? 0) * 3600 + (clock.minute ?? 0) * 60
        return day.startOfDay.addingTimeInterval(TimeInterval(offset))
    }
}
