import Foundation

/// The sleep detail screen's heading: the words `Last Night's Sleep`, and the line beneath it naming
/// the night and the window the page's comparisons are read against.
///
/// **It is a type rather than two `Text` views for the reason every rule on this screen is.** The test
/// runner has no renderer, so a string built inside a `body` is a string nothing can assert — and the
/// date half of this one has more than one answer. `Today` on the day the user is actually having, the
/// date otherwise; that decision is `DayBarRules.isToday`, the app's single answer to "is this day
/// today", which is a **calendar-day** comparison and not an instant one. Written as `date == now` the
/// word would be true for one second of the day and the date would print for the other 86,399.
///
/// **`Today` replaces the date rather than joining it**, exactly as the shared day bar's own `TODAY`
/// does, and the reference draws both forms: its subtitle reads `Wed, Aug 5 vs. prior 30 days` on a past
/// night, because a screen opened on a day from three weeks ago has to say which one it is showing.
///
/// **The window is a parameter and never a literal `30`.** It is the same constant
/// `RecoveryScoring.baselineWindow(before:in:)` caps the window with, so a caption can never come to
/// describe a window the bands below it were not taken over. It is a default argument rather than a
/// value read at the call site, so a caller with no opinion cannot invent a second window by omission.
/// (`SleepDetailView` no longer draws a second copy of this line above its ring, so this subtitle is
/// now the only place the window is stated on that page.)
public enum SleepNightHeading {

    /// The heading. A constant, and it is true of every night this screen can draw: the night the page
    /// is about is always the one that ended this morning, whether the user opens it that day or a
    /// month later. Nothing here is a promise that the night is recent — the subtitle below says which
    /// night it is.
    public static let title = "Last Night's Sleep"

    /// `Wed, Aug 5 vs. prior 30 days`, or `Today vs. prior 30 days` when the night is today's.
    public static func subtitle(
        for date: Date,
        windowDays: Int = RecoveryScoring.baselineWindowDays,
        now: Date = Date()
    ) -> String {
        let day = DayBarRules.isToday(date, now: now) ? "Today" : date.formattedShortDate()
        return "\(day) vs. prior \(windowDays) days"
    }

    /// The heading and its subtitle as one sentence.
    ///
    /// Two `Text` views read in sequence make a listener hold the first words while the date arrives
    /// separately, so the two are announced as one sentence rather than as the two lines they are
    /// drawn as. This is now the page's only statement of which night it is.
    public static func spoken(
        for date: Date,
        windowDays: Int = RecoveryScoring.baselineWindowDays,
        now: Date = Date()
    ) -> String {
        "\(title), \(subtitle(for: date, windowDays: windowDays, now: now))"
    }
}
