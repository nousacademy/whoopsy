import Foundation

/// A session the user is adding by hand: a name and a window on the day Home was showing.
///
/// ## Why it is a value
///
/// The runner has no renderer, so a rule written into a `body` is a rule nothing can check — the
/// standing reason `ReceptiveInactivityDraft`, `ActivityEditDraft`, `DayBarRules` and `ActivityMenu`
/// are named types rather than expressions in a view. This draft owns four rules that would otherwise
/// live in `AddActivitySheet`'s body: **the day-rebuild** of both pickers, **the window's clamps**,
/// **the identity** `.sheet(item:)` keys on, and **what `SAVE` writes** — including the three
/// measured fields, which are `nil` here because nothing measured them.
///
/// ## It is a fourth producer of `workouts` rows, and it says so
///
/// A session added this way carries `WorkoutSession.manualSourceLabel`, not `nil`. `nil` is the label
/// `LiveSessionUseCase.end()` writes for a session this app recorded live, and a hand-entered row is
/// not that: no clock ran, no sample arrived and no strain was computed. The label is also read — by
/// `WhoopExportImporter.recordedWorkoutDays()`, whose day skip must not read a day holding only a
/// hand-added row as a day the app already recorded. See `WorkoutSession.measurementFreeSourceValues`.
///
/// ## The day is the sheet's, and both instants stay on it
///
/// A `DatePicker` with `displayedComponents: .hourAndMinute` hands back a whole instant carrying
/// *today's* year, month and day, whatever day the user is looking at — so both writers rebuild the
/// picked clock time onto the draft's own day through `Date.clockTime(on:)`. Filing the raw instant
/// would put a 2024 day's walk on today, and — worse here than on the receptive sheet, because a
/// workout's `date` column is snapped from `startedAt` — would file it under a day the user never
/// opened.
///
/// **Both ends are clamped inside the day, and the window is never allowed to invert.** Moving the
/// start past the end carries the end along to `start + minimumDuration` rather than letting the two
/// cross, and moving the end before the start clamps it back up. The invariant is what lets
/// `applying()` fail for one reason only — a missing name — instead of carrying a second validity
/// rule the sheet would also have to draw around.
///
/// ## It adds and never edits
///
/// There is no `original`: a stored session is edited by `ActivityEditDraft` from its detail page,
/// where the body and profile are on screen. This draft exists for the row that has no page yet, which
/// is why it constructs a fresh identity and why its window may be placed anywhere in the day rather
/// than narrowed within a recorded one.
public struct AddActivityDraft: Equatable, Identifiable, Sendable {

    /// The day this session is filed on — Home's `selectedDate` snapped to midnight.
    ///
    /// Held rather than passed to each method so the sheet, both pickers and `applying()` cannot be
    /// given different days, and so the clamps below are facts about one day rather than an argument.
    public let day: Date

    /// The chosen name, or `nil` while none has been picked.
    ///
    /// Optional rather than an empty string on the entity's own rule: `""` is not a name, and a
    /// published property holding one would be a value `applying()` has to remember to test for.
    public private(set) var name: String?

    /// The window's two ends, always on `day` and always at least a minute apart.
    public private(set) var start: Date
    public private(set) var end: Date

    /// The identity `.sheet(item:)` keys on, and the id the saved row carries.
    ///
    /// A fresh one per draft, unlike `ActivityEditDraft`'s session id: each presentation of the sheet
    /// is a *new* session, so two drafts opened one after the other are two rows rather than two edits
    /// of one. It is stable across every write below, so the presentation does not tear down when the
    /// user types or moves a picker.
    private let draftID: UUID
    public var id: UUID { draftID }

    /// The shortest window this draft can hold.
    ///
    /// One minute, the same floor `ActivityEditDraft` clamps to — a row with a zero-length span would
    /// draw a `0:00` duration on its detail page, which is an absence the app cannot tell from a
    /// measured zero.
    public static let minimumDuration: TimeInterval = 60

    /// The window a fresh draft proposes: noon to one, on the day being viewed.
    ///
    /// **An arbitrary seed rather than "now"**, deliberately. A draft opened on yesterday with today's
    /// clock time would quietly propose an instant the user did not choose and did not ask to see
    /// today's time in, while a fixed noon is one predictable starting point they then adjust — and
    /// both pickers are on screen, so the adjustment is the first thing the sheet invites. The seed is
    /// built by elapsed seconds from the day's midnight, like every other instant in this feature, so
    /// it is always a real instant inside the day.
    public static let defaultStartHour = 12
    public static let defaultDuration: TimeInterval = 3600

    /// The first instant either end may take.
    public var earliestStart: Date { day.startOfDay }

    /// The last instant the start may take, leaving the minimum window inside the day.
    public var latestStart: Date {
        day.startOfNextDay.addingTimeInterval(-Self.minimumDuration)
    }

    /// The first instant the end may take, given the start.
    public var earliestEnd: Date { start.addingTimeInterval(Self.minimumDuration) }

    /// The day's exclusive upper bound — the first instant *after* the day being viewed.
    ///
    /// `startOfNextDay` and not `endOfDay`, on that property's own rule: the end is a half-open upper
    /// bound, and the one-second difference is invisible and load-bearing. An end at exactly midnight
    /// still covers the day (`WorkoutSession.covers(_:)` is half-open at both ends) and still files
    /// under the start's day.
    public var latestEnd: Date { day.startOfNextDay }

    /// A draft for a new session on `day`, with no name and the noon-to-one seed.
    public init(on day: Date) {
        let dayKey = day.startOfDay
        self.day = dayKey
        self.draftID = UUID()
        self.name = nil
        let seed = dayKey.addingTimeInterval(TimeInterval(Self.defaultStartHour * 3600))
        self.start = seed
        self.end = seed.addingTimeInterval(Self.defaultDuration)
    }

    // MARK: - The three writers

    /// Sets the name, **dropping a write that changes nothing**.
    ///
    /// `ActivityEditDraft.setName(_:)`'s guard, and `ActivityName.matches` rather than `==` for its
    /// reason: the picker draws its tick through the same tolerant comparison, so a re-render that
    /// hands back the same activity in different case must not mark the draft dirty.
    public mutating func setName(_ name: String?) {
        guard !ActivityName.matches(name, self.name) else { return }
        self.name = name
    }

    /// Moves the start to a picked instant, rebuilt onto this draft's day and carried inside the day.
    ///
    /// **A write that changes nothing is dropped**, which is the `DatePicker` rule
    /// `ActivityEditDraft.setStart(_:)` records: an untouched compact picker can re-fire its setter
    /// with a freshly built instant, and a draft that accepted it would report a change nobody made.
    /// The rebuild makes that comparison meaningful — two reads of `8:00 AM` become one instant.
    public mutating func setStart(_ picked: Date) {
        let candidate = Self.clamped(
            picked.clockTime(on: day), low: earliestStart, high: latestStart)
        guard candidate != start else { return }
        start = candidate
        // The end follows rather than inverting the window. It is clamped to the day as well, which
        // can only bind when the start is at `latestStart` and the window is then exactly the floor.
        if end < earliestEnd {
            end = min(earliestEnd, latestEnd)
        }
    }

    /// Moves the end to a picked instant, rebuilt onto this draft's day and kept after the start.
    ///
    /// A write that changes nothing is dropped for `setStart(_:)`'s reason. The lower clamp is
    /// `start + minimumDuration`, so the window can never invert however the picker is dragged.
    public mutating func setEnd(_ picked: Date) {
        let candidate = Self.clamped(
            picked.clockTime(on: day), low: earliestEnd, high: latestEnd)
        guard candidate != end else { return }
        end = candidate
    }

    // MARK: - What `SAVE` writes

    /// The session this draft describes, or `nil` while it has no name.
    ///
    /// **`nil` is the whole SAVE gate**, because the window cannot be invalid by construction: both
    /// clamps keep it inside the day and at least `minimumDuration` long. So there is one thing the
    /// sheet must ask, and it is this return value rather than a second rule about empty strings.
    ///
    /// **The three measured fields are `nil`, and that is the row's honest shape.** Nothing ran, so
    /// there is no strain, average heart rate or maximum heart rate to report; `0.0` would claim a
    /// session measured at rest. The route and splits are empty lists rather than absent, matching the
    /// fast producer: a hand-added walk was not walked by this app and has no laps. `hrZonePercents`
    /// and `steps` take their defaults, also `nil`, so the detail page draws dashes rather than a
    /// measured zero.
    public func applying() -> WorkoutSession? {
        guard let name,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return WorkoutSession(
            id: draftID,
            startedAt: start,
            endedAt: end,
            strain: nil,
            averageHeartRate: nil,
            maxHeartRate: nil,
            route: [],
            splits: [],
            source: WorkoutSession.manualSourceLabel,
            activityName: name)
    }

    /// Whether `SAVE` has anything to write — the sheet's one gate for the button's state and colour.
    public var isComplete: Bool { applying() != nil }

    // MARK: - Arithmetic

    /// `value`, held inside `low...high`.
    ///
    /// `max(low, high)` on the upper bound is `ActivityEditDraft.clamped`'s rule: an inside-out pair
    /// resolves to `low` rather than to an answer that depends on the arguments' order.
    private static func clamped(_ value: Date, low: Date, high: Date) -> Date {
        min(max(value, low), max(low, high))
    }
}
