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

    /// The `ActivityDeltaBadge` capsule's fill.
    ///
    /// **A token of its own for the same reason `neutralDelta` is one.** The badge is drawn on the
    /// activity page's bare background rather than inside a card, so it needs a surface of its own to
    /// read as a badge rather than as a word with a triangle beside it — and every existing candidate
    /// means something else: `cardBackground` is the card surface itself (drawing it on the page
    /// background would draw a card), `ringTrack` is an unfilled gauge arc and the charts' gridline,
    /// and `cardBorder` is a hairline. A white wash reads as a chip on any dark surface it is placed
    /// on without naming a meaning it does not have.
    public static let deltaPillFill = Color.white.opacity(0.14)

    /// The tint of a menu row that is neither destructive nor a refusal — the activity page's `Edit`
    /// and `Cancel` rows.
    ///
    /// **A token of its own rather than a borrowed blue.** The two blues already in this file are
    /// `strainRing` and `livePulseCyan`, and both mean a quantity: `strainRing` is the strain figure's
    /// colour, drawn on this very page, and a second appearance of it three inches below would make
    /// one colour say two things — the drift `neutralDelta`'s and `deltaPillFill`'s comments describe.
    /// This one names a *role* rather than a measurement, and the destructive row beside it keeps
    /// `recoveryRed`, the app's only *verdict* red — `fastingZoneAnabolic` below is the one other red
    /// in this file and carries no judgement, which is why it is a second token rather than a reuse.
    public static let actionTint = Color(red: 0.04, green: 0.52, blue: 1.00)

    // MARK: Fasting zones

    /// The five fills of the Zero fasting scale, and the two inks their letters take.
    ///
    /// **New tokens rather than borrowed ones**, on the rule `bandPoor`/`bandSufficient`/`bandOptimal`
    /// above states: `recoveryRed`/`recoveryYellow`/`recoveryGreen` are the recovery *tier* scale and
    /// each means a verdict — better, unchanged, worse — while a fasting zone is a category with no
    /// judgement in it at all. Painting `CATABOLIC` in `recoveryYellow` would put a caution colour on
    /// a metabolic phase that is not a caution, and `bandPoor`'s orange is a sleep band. Red is the
    /// one place the two scales meet, so the two reds are different hues (#FF1744 crimson against
    /// #FF3B30) and the pill is never drawn beside a recovery ring.
    ///
    /// **The ink is two tokens and not five**, because the rule is one rule: a fill dark enough to
    /// carry white letters takes `zonePillInkOnDeep`, and the two pale fills take `zonePillInkOnPale`.
    /// `FastingZone.inkDepth` is what decides which, and §20 pins that decision — the colour mapping
    /// cannot state it in a form an assertion can reach, because asserting `inkColor == Theme.token`
    /// would only prove the extension returns the token it returns.
    ///
    /// The five fills are the user's own specification (red, orange, yellow, white, blue/violet) and
    /// are **not** legibility-driven, so their contrast against the ink is a property to record rather
    /// than to tune. Computed with the WCAG 2.x relative-luminance formula against the ink each zone
    /// actually takes: red **3.5:1**, orange **2.2:1**, yellow **12.2:1**, white **18.4:1**,
    /// blue/violet **5.1:1**. Blue/violet is the only one that clears the 4.5:1 bar for small text on
    /// white ink; orange is the one that does not, and it is deliberately left as specified —
    /// deepening it to #E8730C would reach 3.1:1 and putting near-black on it would reach 8.6:1.
    public static let fastingZoneAnabolic = Color(red: 1.00, green: 0.23, blue: 0.19)
    public static let fastingZoneCatabolic = Color(red: 1.00, green: 0.58, blue: 0.00)
    public static let fastingZoneFatBurning = Color(red: 1.00, green: 0.80, blue: 0.00)
    public static let fastingZoneKetosis = Color.white
    public static let fastingZoneDeepKetosis = Color(red: 0.37, green: 0.36, blue: 0.90)

    /// The letters on a fill dark enough to carry them — red, orange and blue/violet.
    public static let zonePillInkOnDeep = Color.white

    /// The letters on the two pale fills — yellow and white, where white ink would be invisible.
    ///
    /// The app's own near-black rather than pure black, so it reads as ink on a card rather than as a
    /// hole punched in the pill. `sleepNeedWell` happens to hold the same value and is **not** the
    /// token to reach for: its name says a sleep figure's colour, and a borrowed token whose name
    /// means one thing while a screen uses it to mean another is the drift this file exists to stop.
    public static let zonePillInkOnPale = Color(red: 0.07, green: 0.08, blue: 0.10)

    // The fasting detail page's three chart segments.
    //
    // **Three shades of one hue, which is the user's own instruction** — *"make the bars 3 shades of
    // blue"*. It is the third palette this drawing has had, and the two it replaces were both rejected
    // for the same underlying reason. The first was the reference screen's own swatches, a mint and a
    // tan and a near-white, borrowed from another app's screen and related to nothing here. The second
    // was this app's three verdict accents, `recoveryGreen`/`Yellow`/`Red` by reference, which put the
    // recovery ring's scale on a chart whose subject is not a verdict: a z-score is a distance from the
    // user's own mean, and an HRV that fell is not a red night.
    //
    // A ramp of one hue claims exactly one thing — *these are three quantities on one scale* — which is
    // what a stacked column is. **The ramp runs light at the top of the stack to deep at its foot**,
    // which is the order the legend lists them in (HRV, then RHR, then respiratory rate) and the order
    // the segments stack, so a reader who has the legend has the key to the column as well. All three
    // are pale enough to read against `homeBackground`; the deepest is a solid mid blue rather than a
    // navy, because a segment is a filled area on a near-black ground and a shade that only separates
    // from its two neighbours is a shade that vanishes into the page.
    //
    // They are tokens rather than a direct use of `Color(red:…)` at the chart so that
    // `FastingMetric+Extensions.swift` stays the app's **one** metric-to-`Color` mapping. Nothing in
    // that file picks a hue; if the ramp is ever re-measured, this is the one place it moves.
    public static let fastingChartHRV = Color(red: 0.64, green: 0.87, blue: 1.00) // #A3DEFF
    public static let fastingChartRestingHeartRate = Color(red: 0.29, green: 0.67, blue: 0.98) // #4AABFA
    public static let fastingChartRespiratoryRate = Color(red: 0.11, green: 0.42, blue: 0.80) // #1C6BCC

    // MARK: The route map

    /// The line a recorded route is drawn with, and the fill of the dot marking where it began.
    ///
    /// **New tokens rather than borrowed ones, and every existing candidate names something else.**
    /// `strainRing` is the strain figure's own blue and is drawn a few inches above this map on the same
    /// page, so reusing it would make one colour say two things — the drift `neutralDelta` and
    /// `actionTint` above are tokens to prevent. `sleepPerformance`, `weekLine` and `sleepConsistencyBar`
    /// are all sleep quantities on other screens, and `livePulseCyan` means a live telemetry pulse,
    /// which a stored path is not. The map's own blue is a *drawing* colour rather than a measurement,
    /// which is the same distinction `actionTint` records for the menu rows.
    ///
    /// **It holds the same value as `actionTint`, and that is a coincidence rather than a reuse.** The
    /// two are equal because both are the system's own route/link blue (#0A84FF) — the colour Apple Maps
    /// draws a route in, which is what the reference the user supplied shows — and this file already
    /// carries two tokens with one value (`neutralDelta` and `bandSufficient`) on the rule that a
    /// token's *name* is what has to match its meaning, not its hex. Changing the menu rows' tint must
    /// not move a route on a map.
    public static let routeLine = Color(red: 0.04, green: 0.52, blue: 1.00) // #0A84FF

    /// The ink every mark *on* the map is drawn in — the ring around the start dot, and the finish flag.
    ///
    /// **A token of its own although it is white**, which `textPrimary` and `zonePillInkOnDeep` also
    /// are, for the reason `zonePillInkOnPale` records about `sleepNeedWell`: a name that says *text* or
    /// *ink on a pill* while a map draws a marker with it is the drift this file exists to stop, and the
    /// next person to change `textPrimary` would move a pin on a map. It is one token for both marks
    /// because they answer one question — what separates a mark from the map beneath it — and the
    /// checkered flag is drawn in whatever colour it is handed, so the two cannot diverge in practice.
    public static let routeMarker = Color.white

    /// The surface behind the two figures the route card lays over the bottom of its map.
    ///
    /// **`backgroundDark`'s hue carried at an opacity, and the opacity is the whole of why it is a token
    /// and not a call-site modifier.** The caption sits *on* the drawing rather than beside it, so it
    /// has to be opaque enough for a number to read over map labels and sheer enough that the map is
    /// still visibly behind it — and an alpha written at the call site would be a colour decision made
    /// in a `body`, which is what this file exists to hold. It is deliberately not `cardBackground`,
    /// which would draw a second card inside the map, nor `deltaPillFill`, whose wash leaves map
    /// lettering legible through a figure.
    public static let routeOverlayFill = Color(red: 0.05, green: 0.06, blue: 0.08).opacity(0.86)

    // MARK: Segmented control

    /// The recessed track behind the profile page's `UNITS` control.
    ///
    /// **A token of its own, and both candidates for borrowing mean something else.** `homeCard` is the
    /// filled surface of every field box on that page, and the track has to read as a *recess* rather than
    /// as a seventh box beside six of them; `ringTrack` is an unfilled gauge arc and the charts' gridline.
    /// It sits between `backgroundDark` and `homeCard` deliberately — dark enough to be a well in the
    /// page, light enough that the control is a thing the reader can see rather than a hole.
    public static let segmentedTrack = Color(red: 0.13, green: 0.15, blue: 0.18)

    /// The pill under the selected segment, and the reason the track above is as dark as it is.
    ///
    /// **It is the one step of contrast the whole control is.** A segmented control states its selection
    /// by *raising* the chosen half, so the pill has to clear both the track and `homeCard` by enough to
    /// be read at a glance — which is why it is a token rather than `ringTrack` borrowed, whose value sits
    /// within a unit of `homeCard` and would have left the selected segment nearly invisible against the
    /// boxes directly above and below it.
    public static let segmentedPill = Color(red: 0.24, green: 0.26, blue: 0.30)

    // Telemetry Pulse
    public static let livePulseCyan = Color(red: 0.0, green: 0.95, blue: 1.0)
    public static let textPrimary = Color.white
    public static let textSecondary = Color(white: 0.70)
    public static let textMuted = Color(white: 0.45)
}
