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
    public static func isOwed(watermark: Date?, inputEdge: Date?) -> Bool {
        guard let watermark else { return true }
        guard let inputEdge else { return false }
        return inputEdge > watermark
    }
}
