import SwiftUI

/// Premium dark-mode-first aesthetic theme and color definitions.
public enum Theme {
    // Backgrounds
    public static let backgroundDark = Color(red: 0.05, green: 0.06, blue: 0.08)
    public static let cardBackground = Color(red: 0.10, green: 0.11, blue: 0.14).opacity(0.85)
    public static let cardBorder = Color.white.opacity(0.12)

    // Recovery Colors
    public static let recoveryGreen = Color(red: 0.0, green: 0.90, blue: 0.46) // #00E676
    public static let recoveryYellow = Color(red: 1.0, green: 0.84, blue: 0.0) // #FFD600
    public static let recoveryRed = Color(red: 1.0, green: 0.09, blue: 0.27) // #FF1744

    // Strain Colors
    public static let strainPrimary = Color(red: 1.0, green: 0.33, blue: 0.10)
    public static let strainGradientStart = Color(red: 1.0, green: 0.67, blue: 0.05)
    public static let strainGradientEnd = Color(red: 1.0, green: 0.12, blue: 0.16)

    // Sleep Colors
    //
    // The four stage colours, measured off the reference screenshot rather than picked.
    //
    // **They were re-derived from the image, and the arithmetic is worth recording** because a future
    // reader will otherwise assume they are eyeballed. The reference is a screenshot taken on a P3
    // display — its PNG carries a `cICP` chunk of `0c 0d 00 01`, primaries 12 with the sRGB transfer
    // curve — so its pixel values are P3-encoded and copying them into a `Color(red:green:blue:)`
    // (which is extended sRGB) would render every stage slightly wrong. Each was converted P3 → XYZ →
    // sRGB through the standard matrices before being written down; the largest move is SWS, whose
    // blue channel goes 247 → 253 and whose red clips at the gamut edge.
    //
    // The four are read through `SleepStageType.color`, this app's single stage-to-colour mapping, so
    // the hypnogram and the sleep detail screen's typical-range card move together — which is the
    // intent, since they are the same four stages.
    public static let sleepIndigo = Color(red: 0.48, green: 0.30, blue: 1.0)

    /// SWS, which WHOOP labels `SWS (DEEP)`: a light magenta.
    public static let sleepDeep = Color(red: 1.0, green: 0.563858, blue: 0.990785)

    /// Light sleep: a periwinkle blue.
    public static let sleepLight = Color(red: 0.639170, green: 0.639222, blue: 0.947854)

    /// REM: a violet.
    public static let sleepRem = Color(red: 0.714780, green: 0.331181, blue: 0.961380)

    /// Awake: a neutral light grey, **not a colour**.
    ///
    /// The one of the four that is not a hue, and deliberately so — awake is the absence of sleep
    /// rather than a fourth kind of it, and on the hypnogram it is the band a reader should be able to
    /// ignore. It was a red, which made every waking moment on the chart the loudest thing on it.
    public static let sleepAwake = Color(red: 0.778558, green: 0.788571, blue: 0.779855)

    // Home
    //
    // These four were literals inside `HomeDashboardView`, which is why `DayNavigationBar` carried a
    // private copy of the card grey with a comment apologising for the duplication: one screen's
    // palette was a private convention that a shared component had to guess at. Promoted rather than
    // re-picked, so the values on screen do not move.
    public static let homeBackground = Color(red: 0.11, green: 0.13, blue: 0.15)
    public static let homeCard = Color(red: 0.16, green: 0.18, blue: 0.21)

    /// The unfilled part of a Home ring, **and of a sleep stage's bar on the sleep detail screen**.
    ///
    /// Its own token rather than the ring colour at low opacity, which is what `GaugeRingView` uses.
    /// The two read differently at a low fill: a faded tint of the ring colour disappears into the
    /// card, while a neutral track keeps the circle legible as one shape with a gap in it.
    ///
    /// The second reader is `TypicalRangeBar`, and it is the same job: the part of the scale a figure
    /// did not reach, drawn in a colour that is nobody's reading. It takes `hatchStripe` over it rather
    /// than a second token, because the two are one another's complement and a bar whose track was a
    /// different grey from a ring's would read as a different component.
    public static let ringTrack = Color(red: 0.22, green: 0.24, blue: 0.27)

    /// The two parts of a typical-range band mark: the region, and the two dashed rules that bound it.
    ///
    /// **A band is drawn as a filled region with dashed sides, not as an outlined box**, and the two
    /// halves are one mark rather than a fill and a border — the fill says *this span of the bar is the
    /// range*, and the dashes say *at these two points*, which is why neither alone is enough. Neither
    /// has a horizontal edge: a top and bottom stroke would close the region into a shape that reads as
    /// a second bar drawn on top of the first.
    ///
    /// Both are white at an opacity rather than opaque greys, and here the white is load-bearing: the
    /// mark is drawn **over** whatever is beneath it — the stage colour inside the bar, the card's own
    /// background above and below it — and an opaque grey would read as two different colours on one
    /// mark. The alphas are the reference's, measured off it rather than
    /// picked: `0.11` for the region (which lifts the card's `(38,42,46)` to `(61,65,70)` and a stage
    /// fill by a comparable step) and `0.48` for the rules.
    ///
    /// **`bandMarkEdge` has a second reader, and it is the same mark turned ninety degrees.** The
    /// sleep-consistency chart draws its two average rules with this colour and
    /// `TypicalRangeBar.markDash`, because those rules are a dashed line saying *at this value* laid
    /// across a chart instead of down a bar — the identical claim, on the identical surface, and two
    /// dash styles for it would be two marks a reader has to learn. `bandMarkFill` has no second
    /// reader: a region bounded by two rules is a *span*, and the consistency chart's two rules are
    /// two independent values with nothing between them to fill.
    public static let bandMarkFill = Color.white.opacity(0.11)
    public static let bandMarkEdge = Color.white.opacity(0.48)

    /// The diagonal stripes that fill the **remainder** of a sleep stage's typical-range bar.
    ///
    /// **It is a texture and not a colour, and that is what it is for.** The bar already carries a
    /// reading in the stage's own colour; the region beyond tonight's share has to be visibly *not*
    /// that reading without being a second reading. A token of its own rather than `ringTrack` at an
    /// opacity, for `ringTrack`'s own reason: an opacity written at the call site is a value nothing
    /// else in the app can see, and the two bars that draw this would be free to pick differently.
    ///
    /// **It is darker than the track it is drawn on, and this token had that backwards.** The
    /// reference's hatched remainder is a *light* ground — the track — carrying *dark* stripes, and the
    /// measurement is unambiguous: its track reads `(60, 64, 68)` and its stripes `(39, 43, 47)`, on a
    /// 1:1 duty cycle, so the hatch is a dark texture and not a light one seen against a dark card.
    /// Drawn in white over the track it gives the same coverage and the opposite figure — a shimmering
    /// dark band where the reference has a quiet light one — which is exactly what a reader comparing
    /// the two screens reports as the bars not matching.
    ///
    /// Black at `0.30` over `ringTrack` is `(39, 43, 48)`: the reference's own stripe, to within a
    /// unit, and with the reference's own internal contrast of about 21. It is an opacity over the
    /// *track* rather than an opaque colour because the track is what the stripes are painted on —
    /// the same reason the band mark above is an alpha.
    ///
    /// The reference's stripes do read as its card background to within a unit, which would make the
    /// honest rule "let the card through"; that is not what is written here because the card is a
    /// shared surface this bar has no business re-picking, and because this app's card is some 15
    /// points darker than the reference's, so the card-under-track form would lay a heavier hatch than
    /// the reference draws. What is matched is the stripe's measured tone, which is what a comparison
    /// against the reference is comparing.
    public static let hatchStripe = Color.black.opacity(0.30)

    /// The slot the sleep efficiency card draws where the night's timeline would go, on a night no
    /// strap recorded.
    ///
    /// **It is a faint fill and not `ringTrack`, because it is not a scale.** `ringTrack` is the part
    /// of a *scale* a reading did not reach, and every bar in this app that draws it is drawing a
    /// fraction of something — the efficiency slot is not a fraction of anything, it is where a
    /// recording would be and there is none. Drawing it in the track's colour would say the night
    /// measured zero, which is the claim this app's whole absence discipline exists to avoid; a fill
    /// barely above the card says only that something is missing here. It is a token rather than an
    /// opacity at the call site for `hatchStripe`'s own reason: an opacity written in a view is a
    /// value nothing else can see.
    public static let sleepTimelineSlot = Color.white.opacity(0.06)

    /// The Sleep and Strain ring fills.
    ///
    /// Distinct from `sleepIndigo`/`strainPrimary` on purpose: those belong to the detail screens'
    /// gradient palette, and Home's mockup is flat. Recovery needs no token here — its ring is drawn
    /// in whichever of the three `recovery*` tiers the day scored, via `RecoveryState.color`.
    public static let sleepPerformance = Color(red: 0.42, green: 0.60, blue: 0.73)
    public static let strainRing = Color(red: 0.00, green: 0.68, blue: 1.00)

    /// The sleep need's own line, its points and its value labels on the week chart that draws it
    /// against the night's hours asleep.
    ///
    /// **A green of its own, and neither of the app's two existing greens will do.** `recoveryGreen`
    /// is the recovery tier scale and `bandOptimal` is the sleep *band* scale, and both of them mean a
    /// verdict — a figure that cleared a threshold. Sleep need carries no verdict: it is a requirement,
    /// and on this chart it is one of two readings of the same unit rather than a grade of either. The
    /// comment on `bandPoor` below already states the rule this would otherwise break — "two greens
    /// that mean different things is the drift".
    ///
    /// The other lane is `sleepPerformance` and deliberately not a token of its own: that is the
    /// colour this page's ring, its need card's sleep bar and its performance bars are already drawn
    /// in, and the line is the same quantity a week at a time.
    ///
    /// Picked from the reference rather than sampled off it, like the need card's three tokens: this
    /// mockup is not a file on disk, so there is nothing here to measure against. What it encodes is
    /// the reference's *ordering* — the need reads brighter and warmer than the sleep it is measured
    /// against — which is the part a reader can actually see.
    public static let sleepNeedLine = Color(red: 0.16, green: 0.84, blue: 0.51)

    /// The Recovery detail page's three week line charts — heart-rate variability, resting heart
    /// rate and respiratory rate — for their lines, points and value labels.
    ///
    /// A token of its own rather than one of the four blues above, because every one of them already
    /// means something else: `sleepLight`/`sleepIndigo`/`sleepDeep` are sleep *stages* on the
    /// hypnogram, `sleepRem` its wakefulness, `sleepPerformance` Home's sleep ring and `strainRing`
    /// Home's strain ring. Neither of these quantities has a ring, a stage or a tier, so borrowing any
    /// of them would invite a reader to compare two things this app has decided not to put on one axis.
    ///
    /// **Both charts share it, and here the colour is deliberately not carrying quantity identity.**
    /// On the bars above them it does — the bar's colour *is* the recovery tier — but on these two the
    /// card's own label says which quantity is plotted and each has its own axis, so colouring them
    /// apart would imply a relationship between a millisecond count and a beat rate that does not
    /// exist. One token also keeps them from drifting into two nearly-the-same blues.
    public static let weekLine = Color(red: 0.55, green: 0.66, blue: 0.92)

    /// The need card's two components, and the recessed box its breakdown is listed in.
    ///
    /// **These three are picked rather than measured, and they are the only tokens in this file that
    /// are.** Every other colour here was sampled off a reference screenshot with the P3 → sRGB
    /// conversion written down beside it — the four sleep stages' arithmetic is above, and the band
    /// mark's alphas are quoted against the card's own tone. The screenshot the need card was built
    /// from arrived as a pasted image rather than a file on disk, so there is no pixel to sample and no
    /// conversion to write down. What the two swatches encode is the reference's *ordering* — the base
    /// term is drawn darker than the debt — which is the half of the choice a reader can see; the exact
    /// tones are free to move, and moving them is not a regression the way re-picking a stage colour
    /// would be.
    ///
    /// `sleepNeedWell` is the box the two rows sit in. It is **darker than the card**, because the
    /// reference's box reads as a recess rather than as a second card stacked on the first, and this
    /// app's `cardBackground` is already `.opacity(0.85)` over the page — a well drawn lighter than the
    /// surface it sits on would read as raised.
    public static let sleepNeedBaseline = Color(white: 0.34)
    public static let sleepNeedDebt = Color(white: 0.72)
    public static let sleepNeedWell = Color(red: 0.07, green: 0.08, blue: 0.10)

    /// The sleep-consistency chart's two bar colours: the night the card is about, and the four it was
    /// read against.
    ///
    /// **A pair of its own rather than `sleepPerformance`, which is what the ring and the need card's
    /// sleep bar are drawn in.** Those two encode *how much* was slept; this chart encodes *when*, and
    /// a reader who saw the page's sleep colour on a bar in this card would reasonably expect the bar's
    /// length to mean what it means two cards up. The anchor is a lighter tone of the same hue rather
    /// than a different one, so the card still reads as belonging to this page while the bar's meaning
    /// is its own — the same reasoning that gave the Recovery page's three line charts `weekLine`
    /// instead of a sleep blue.
    ///
    /// The four priors take a neutral grey and **not `ringTrack`**, which is the app's "nothing was
    /// measured" grey: these are four measured nights and the colour must not carry the opposite claim.
    /// It is also not a second tint of the accent, because the four are the comparison and the anchor is
    /// the reading, and a family of blues would say the five columns are five of one thing.
    ///
    /// Picked rather than measured, like the three above it: the reference screenshot arrived as a
    /// pasted image with no pixel to sample.
    ///
    /// **The time-in-bed week chart reads this token too**, and on the same argument rather than a
    /// borrowed one: its bars are also *when* a night happened rather than how much of it there was, so
    /// the two charts on that page that place a night on a clock are one colour and the ones that
    /// measure a quantity are the other. **`sleepConsistencyPriorBar` is not shared with it** — that
    /// grey separates an anchor from the four nights it was *scored against*, and the week chart draws
    /// no such comparison; its anchor is marked by the frame's own tinted column.
    public static let sleepConsistencyBar = Color(red: 0.50, green: 0.70, blue: 0.86)
    public static let sleepConsistencyPriorBar = Color(white: 0.30)

    /// The sleep-performance screen's three bands — Poor, Sufficient, Optimal.
    ///
    /// **Not the recovery tiers, and the difference is deliberate.** Orange/grey/green is the
    /// reference's own key, and its middle colour is a neutral rather than a warning: a night this app
    /// calls *Sufficient* is not a caution, so drawing it in `recoveryYellow` — the token that means
    /// "you are sliding" everywhere else in the app — would put a judgement on the screen that the
    /// band does not carry. The optimal green is a token of its own for the same reason: this scale is
    /// not the recovery tier scale, and two greens that mean different things is the drift
    /// `StressBand+Extensions` avoids by borrowing and this file avoids by not.
    ///
    /// They are read only through `SleepBand.color`, which is the app's single band-to-token mapping.
    public static let bandPoor = Color(red: 1.00, green: 0.60, blue: 0.16)
    public static let bandSufficient = Color(white: 0.62)
    public static let bandOptimal = Color(red: 0.24, green: 0.84, blue: 0.48)

    /// A comparison that carries no verdict — the activity detail page's two delta badges.
    ///
    /// **A token of its own, and the alternative was to borrow one.** The three verdict colours above
    /// say *better*, *unchanged* and *worse*, and an activity's strain rising against its own history
    /// is none of the three: it is neither good news nor bad news, and it is certainly not the
    /// yellow `same` — a badge reading `▲ 2.5` in `recoveryYellow` would be calling a harder session a
    /// warning. `textSecondary` and `bandSufficient` were the two candidates for borrowing and neither
    /// means a verdict either: the first is body copy, the second is a sleep band, and a token whose
    /// name says one thing while a screen uses it to mean another is exactly the drift
    /// `SleepBand.color` and this file exist to prevent. So the neutral gets a name.
    ///
    /// **It is deliberately not one of the three, and it is read only through `ActivityDelta.color`.**
    /// That type is `MetricChange`'s sibling and holds no `Verdict` at all — see its own comment for
    /// why a fourth case could not be added to that enum instead.
    public static let neutralDelta = Color(white: 0.62)

    // Telemetry Pulse
    public static let livePulseCyan = Color(red: 0.0, green: 0.95, blue: 1.0)
    public static let textPrimary = Color.white
    public static let textSecondary = Color(white: 0.70)
    public static let textMuted = Color(white: 0.45)
}
