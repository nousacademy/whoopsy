import Foundation

/// What the sleep page's editor is holding: the night's two bounds, and what they were.
///
/// **It is the draft and not the session**, so the sheet can be opened, touched and cancelled without
/// anything being written — the same shape `ActivityEditDraft` uses on the activity page. `hasChanges`
/// is what disables `SAVE` on a sheet nobody touched, and `isValid` is the one rule the sheet enforces:
/// a night has to end after it starts, or the row describes a negative span and the chart's axis is a
/// division by zero.
///
/// Both live here rather than inside the sheet's `body` for this repo's standing reason: the runner has
/// no renderer, so a rule written into a view is a rule nothing can assert.
public struct SleepTimeEditDraft: Equatable, Identifiable {

    /// The day the row belongs to, and the sheet's identity — `SleepDetailView` presents on it, so a
    /// second night cannot reuse the first one's draft.
    public let id: Date

    /// The bounds as they are being edited.
    public var start: Date
    public var end: Date

    /// The bounds as they were when the sheet opened, for `hasChanges`.
    public let originalStart: Date
    public let originalEnd: Date

    public init(session: SleepSession) {
        self.id = session.date
        self.start = session.startTime
        self.end = session.endTime
        self.originalStart = session.startTime
        self.originalEnd = session.endTime
    }

    /// The longest span the editor will accept. A night, not a day: anything longer is a mistyped date
    /// rather than a long sleep, and the row's day key would no longer describe it.
    public static let maximumSpanSeconds: TimeInterval = 24 * 3600

    /// Whether the draft describes a night at all. `SAVE` is disabled while it does not.
    public var isValid: Bool {
        let span = end.timeIntervalSince(start)
        return span > 0 && span <= Self.maximumSpanSeconds
    }

    /// Whether the user changed anything — the gate on `SAVE` being enabled at all.
    public var hasChanges: Bool {
        start != originalStart || end != originalEnd
    }

    /// Whether the draft can be written: something changed **and** what it changed to is a night.
    public var canSave: Bool { hasChanges && isValid }
}
