import Foundation

/// What a fast's own recovery figure is read *as* — the band the score falls in, and the sentence that
/// band prints under the chart.
///
/// ## The bands are not `RecoveryState`'s, and that is a decision rather than a drift
///
/// `RecoveryState` bands a score 67 / 34, and it is the one definition of the recovery tiers — Home's
/// ring, the Recovery tab's gauge and the score above this sentence all read it. **This type bands the
/// same figure 67 / 50**, so a score of 45 is *yellow* above and a stop signal below. That divergence
/// is deliberate and it is the user's own call: a fast is itself a stressor, so the reading that means
/// "an ordinary day, maintain" does not mean that on day four of not eating.
///
/// The cost is stated rather than hidden: **the sentence is not drawn in the band's colour.** The
/// figure above it keeps `RecoveryState`'s colour, because a score that is green on one screen and
/// yellow on another would be a worse fault than this one — so the band is carried by the words
/// (*Recovery holding* / *Recovery slipping* / *Stop signal*) and the paragraph is plain prose. Two
/// colour scales for one number, on one screen, is the thing this arrangement exists to avoid.
///
/// ## There is no published threshold to borrow
///
/// `docs/PATENTS.md` holds no fasting section at all — WHOOP ships no fasting feature — so unlike the
/// recovery tiers there is no disclosed shape to substitute against and no constant to fit. The two
/// numbers here are authored guidance, and `docs/ALGORITHMS.md` §9 records them as this app's own.
public enum FastingRecoveryGuidance {

    /// Which reading a fast's mean Recovery score is.
    ///
    /// Three cases and no fourth: the middle one is the whole reason the type exists, since a two-state
    /// *stop / carry on* would have to file a 60% fast under one of them and be wrong either way.
    public enum Band: String, Sendable, CaseIterable {
        case steady = "Steady"
        case caution = "Caution"
        case stop = "Stop"

        /// The two boundaries, and **the only place either is written down**.
        ///
        /// Deliberately not `Range` literals in `RecoveryState`'s shape. That type spells its tiers as
        /// half-open ranges because a **view prints them** — the month legend reads `<34%` and
        /// `34% - 66%` off them — and the cost of that form is a hole above the top bound, which only
        /// escapes notice because the scoring formula clamps to `1...99`. Nothing prints these two as a
        /// range, so they are written as the ceilings they are and `init(score:)` is total over every
        /// `Int` rather than only over the ones the formula can produce.
        public static let stopCeiling = 50
        public static let cautionCeiling = 66

        /// **Total, and the severe band is the fallback.** A score below the floor, or any value that
        /// is not a score at all, lands on `.stop` — the same shape `RecoveryState.init(score:)` takes
        /// when it sends an out-of-band value to `.red`. The alternative, testing each band positively
        /// and letting the last one be whatever is left, is how a scoring change turns an unexpected
        /// number into a confident *nothing to see here*.
        public init(score: Int) {
            if score > Self.cautionCeiling {
                self = .steady
            } else if score > Self.stopCeiling {
                self = .caution
            } else {
                self = .stop
            }
        }

        /// The two-word lead-in the sentence opens with — **the band's own name, in the reader's
        /// words** rather than this enum's.
        ///
        /// It is what carries the band on the screen, since the paragraph is drawn in one colour. So
        /// each one has to be readable on its own, above a figure it does not repeat: `Steady` is a
        /// verdict about the fast and `Green` would be a second name for the colour of the number above.
        public var leadIn: String {
            switch self {
            case .steady: return "Recovery holding."
            case .caution: return "Recovery slipping."
            case .stop: return "Stop signal."
            }
        }
    }

    /// The sentence under the chart, in two halves — the band's lead-in and the body that names the
    /// figure.
    ///
    /// Returned as a pair rather than as one string because the view draws the lead-in bold, exactly as
    /// it draws `Normalized Trends (z-score basis):` above it, and **concatenating them with `+` here
    /// would take the `StringProtocol` overload of `Text`, which parses no Markdown** — the trap that
    /// puts literal asterisks on the screen. Two `Text`s, joined at the call site.
    ///
    /// ## The fast's own state decides the tense, and the whole feature turns on it
    ///
    /// **A fast that has already ended cannot be stopped**, and this app's page is drawn almost
    /// entirely for fasts that have: all 170 bundled ones have ended, and a fast only ever arrives from
    /// a Zero export. So the live arm — *This is the signal to end the fast* — is reachable only from a
    /// fixture here, and the retrospective arm is what a reader actually sees. A single sentence that
    /// instructed the user to stop, printed under a fast that finished three days ago, would be advice
    /// they cannot take.
    ///
    /// `isInProgress` is handed in rather than read from a `Date()` for `DayBarRules`' reason: an
    /// assertion about *running now* must not say something different tomorrow. `ActivityFigure
    /// .isInProgress(_:now:)` is where the test itself lives.
    ///
    /// ## It states the figure and never claims a mechanism
    ///
    /// *Your recovery averaged 28%* is a statement about the user's own nights. Nothing here says the
    /// fast *caused* the reading — this app has no glucose and no ketone sensor, so a causal verb would
    /// be the same fabrication the z-score sentence above is forbidden, and `ActivityFigure.fastingZone`
    /// is forbidden for the same reason. The named action is a response to a measurement, not a
    /// diagnosis of one.
    public static func sentence(
        band: Band,
        score: Int,
        nightCount: Int,
        isInProgress: Bool
    ) -> String {
        let nights = nightPhrase(nightCount: nightCount, isInProgress: isInProgress)
        let figure = "\(score)%"

        switch (band, isInProgress) {
        case (.steady, true):
            return "Your recovery is at \(figure) over \(nights). Nothing here says to stop."
        case (.steady, false):
            return "Your recovery held at \(figure) across \(nights)."

        case (.caution, true):
            return "Your recovery has averaged \(figure) over \(nights) — worth watching if you "
                + "carry on."
        case (.caution, false):
            return "Your recovery averaged \(figure) across \(nights) — worth watching if you fast "
                + "this long again."

        case (.stop, true):
            return "Your recovery has averaged \(figure) over \(nights). This is the signal to end "
                + "the fast."
        case (.stop, false):
            // The live arm's instruction has no present tense to live in here, so it is turned to the
            // next fast rather than dropped: a reader whose fast already ended is the reader this page
            // is built for, and "end the fast" told to someone who cannot is worse than silence.
            return "Your recovery averaged \(figure) across \(nights) — a fast that runs it this low "
                + "is one to end earlier."
        }
    }

    /// The band and the body together — what the page actually draws, picked in one place.
    ///
    /// A pair rather than a joined `String` because the two halves are drawn in two weights: the lead-in
    /// bold, the body plain, exactly as the z-score sentence above them is drawn. Joining them here
    /// would make that impossible without splitting on a delimiter, and **a `Text` built from a
    /// concatenated `String` takes the `StringProtocol` overload, which parses no Markdown** — so the
    /// emphasis cannot be smuggled in with `**…**` either. Two `Text`s at the call site is the only
    /// arrangement that survives both.
    ///
    /// Keeping the `Band` rather than only its words means a caller cannot hold half a statement: there
    /// is no way to draw the body without the band it came from, and so no way for the two to disagree.
    public struct Statement: Equatable, Sendable {
        public let band: Band
        public let body: String

        /// The bold half — forwarded rather than copied, so the words live on `Band` alone.
        public var leadIn: String { band.leadIn }

        public init(band: Band, body: String) {
            self.band = band
            self.body = body
        }
    }

    /// The statement for a fast's own figure — **the one entry point a caller needs.**
    ///
    /// Separated from `sentence(band:…)` so that the builder stays drivable band by band from a fixture,
    /// while a caller with a score and a state gets the band chosen for it. Nothing here re-derives the
    /// band: `Band(score:)` is the only place the two ceilings are compared.
    public static func statement(score: Int, nightCount: Int, isInProgress: Bool) -> Statement {
        let band = Band(score: score)
        return Statement(
            band: band,
            body: sentence(
                band: band,
                score: score,
                nightCount: nightCount,
                isInProgress: isInProgress
            )
        )
    }

    /// The noun phrase the sentence counts its nights with.
    ///
    /// `1 nights` is the reason it is a function rather than interpolation at the call site, and the two
    /// arms differ by more than the numeral: a running fast says *the night so far* because it may have
    /// more, and a finished one says *this night* because it will not.
    public static func nightPhrase(nightCount: Int, isInProgress: Bool) -> String {
        guard nightCount != 1 else {
            return isInProgress ? "the night so far" : "this night"
        }
        return isInProgress ? "the \(nightCount) nights so far" : "these \(nightCount) nights"
    }
}
