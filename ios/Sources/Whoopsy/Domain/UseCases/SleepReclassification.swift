import Foundation

/// When a stored night has to be classified again, as a rule a test can assert rather than a
/// condition buried in a screen.
///
/// **The question this answers is a watermark question**, the same one `RefreshStrainUseCase` asks of
/// a day: has input arrived that the stored result did not include? The sleep page used to skip the
/// question entirely and re-run the classifier on every open, which is both slow and — over a night
/// whose drain had not finished — destructive, because an inconclusive run over a rule that had not
/// changed was treated as a verdict and the row was deleted.
///
/// The two other answers live outside this type because they are not about input: an **imported**
/// night is never reclassified (WHOOP's own figure is not this app's to re-decide), and a row whose
/// `algorithm` is not `SleepAlgorithm.current` is always reclassified (the rule that made it no
/// longer exists here). This type is only the third case — the version matches, and the question is
/// whether the night has grown.
public enum SleepReclassification {

    /// Whether the night has input the stored classification did not see.
    ///
    /// **A watermark is required to answer `false`.** `inputEdge` is what the analyzer can see now;
    /// when it is `nil` there is nothing newer than any row, so nothing is owed. When the row has no
    /// watermark the caller should not be here at all — a current-version row always records one — but
    /// the answer is conservative: `true`, because a row that cannot say what it saw is a row this
    /// app cannot vouch for.
    /// How far past a night's end new input can still belong to that night.
    ///
    /// **Ten minutes, and it is the classifier's own onset threshold** — a night is a sustained
    /// ten-minute quiet run, so data within that much of the end is data the night may still be
    /// growing into. Anything later is wake time.
    public static let extensionGraceSeconds: TimeInterval = 600

    /// `nightEnd` is the stored night's own end, and it is what stops the morning churn.
    ///
    /// **Measured 2026-10-27.** The edge was the newest sample anywhere in the 21:00 → 10:00 read
    /// window, so every sample after waking made the stored night "owed": it was re-classified and
    /// re-saved on every foreground and every open of the sleep page, each time folding tens of
    /// thousands of samples to produce the same night, and each save redrew Home's ring. None of that
    /// input can change the night — a night ends when the wrist starts moving — so the test is now
    /// *could this input still belong to the night*, and input more than `extensionGraceSeconds` past
    /// the stored end is wake time.
    ///
    /// **A phone that has not classified the night yet is unaffected**: with no `nightEnd` the rule is
    /// the original one, which is what every caller sees before a row exists.
    public static func isOwed(
        watermark: Date?,
        inputEdge: Date?,
        nightEnd: Date? = nil,
        endedAtDataEdge: Bool? = nil
    ) -> Bool {
        guard let watermark else { return true }
        guard let inputEdge else { return false }
        guard inputEdge > watermark else { return false }
        guard let nightEnd else { return true }
        // **The night's own record of how it ended decides, and nothing has to be inferred.**
        switch endedAtDataEdge {
        case .some(true):
            // Cut at the data edge: everything after it is still the same night, however much later
            // it arrives. Measured 2026-10-28, a 54-minute night that seven hours of later records
            // could not reopen.
            return true
        case .some(false):
            // Trimmed at a wake, so only input inside the grace after it can still belong to the night.
            return inputEdge <= nightEnd.addingTimeInterval(extensionGraceSeconds)
        case .none:
            // No verdict recorded — every row written before `v40`. One re-classification stamps it,
            // and the row it writes takes one of the two branches above, so this fires at most once
            // per such row rather than on every foreground.
            return true
        }
    }
}
