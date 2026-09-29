import Foundation

/// WHOOP's published list of activity names — the vocabulary the edit sheet's picker offers.
///
/// ## Why this is a list and not a table of glyphs
///
/// `ActivityGlyph` already maps a *handful* of names to SF Symbols. This is the catalogue those names
/// are drawn for: the set WHOOP lets a user choose from, published as
/// `support.whoop.com/s/article/List-of-WHOOP-Activities`. The two types answer different questions —
/// this one says **which names exist**, `ActivityGlyph` says **what mark one draws** — and most entries
/// here have no glyph, which is `ActivityGlyph.fallback`'s ordinary case rather than a gap.
///
/// It lives in `Domain/Entities/` beside `ActivityName`, not in the sheet's folder, for the reason
/// that type records: this is a fact about the labels WHOOP writes, and `Domain` imports only
/// `Foundation`. A presentation type cannot hold it — the picker is one reader and a future one (a
/// validator, a default-activity setting) would not be a screen.
///
/// ## This is WHOOP's list *curated*, and the differences from the published one are deliberate
///
/// The list began as WHOOP's published page with its footnote markers stripped. It is no longer a
/// reproduction of it, and **the counts must never be "corrected" back to the published total** —
/// five published names are deliberately absent and three are deliberately present.
///
/// - **Absent: `Barre`, `Barre3` and `Barry's`.** Studio brands rather than activities, and whoop-specific.
/// - **Absent: `WHOOP Labs` and `Cycling`**, both dropped by the user. WHOOP's own lab programme is the
///   fourth of the whoop-specific entries — a service rather than something a user performs — and
///   `Cycling` is the generic word the two biking names below make redundant. Neither has a producer in
///   this app: the bundled `workouts.csv` writes **0 rows** under each of them, against `Road Biking`'s
///   12, so removing them takes no name the export actually contains out of the picker.
/// - **Present: `Road Biking`**, which WHOOP's page does not carry. The bundled `workouts.csv` writes it
///   on **12 rows** carrying real telemetry (14.8 km, 171 bpm max, 30 min in zone 4), so the picker has
///   to be able to offer back a name the export actually contains.
/// - **Present: `Fast`** — the user's own addition, so that a fasting window recorded in the Zero
///   tracker can be synced here. `ZeroFastingImporter` is that sync. See `fastingName`'s comment.
/// - **Present: `Activity`**, WHOOP's abstention word — `abstentionName` below. It is the third addition
///   and by row count much the largest: the stored name on 197 of the export's 673 workout rows.
///
/// The three present ones are also collected as `unpublishedNames`, so the divergence this comment
/// describes is a value a test can check rather than prose a reader has to re-derive. The three absent
/// ones have no such value and could not: a name this type does not hold has nothing to name it by.
///
/// ## The `*` and `^` markers are stripped
///
/// WHOOP publishes two footnotes against this list: `*` denotes activities where **Muscular Strain is
/// automatically calculated**, and `^` denotes activities that contribute to **Strength Activity Time
/// in Healthspan**. Neither quantity is computed anywhere in this app — `CLAUDE.md` records
/// `STRENGTH ACTIVITY TIME` as "the one row with no producer at all", and there is no muscular-strain
/// model either. Carrying the glyphs into the picker would put a superscript on a row promising a
/// computation that does not exist, which is the absence rule applied to a capability: the app says
/// nothing rather than claiming it.
///
/// ## What is kept as published, and why nothing is tidied
///
/// The names are WHOOP's own strings and are compared to stored ones by `ActivityName.normalised`,
/// which only trims and lowercases — so `Hurling/Camogie`, `Spikeball®`, `Infared Sauna` (WHOOP's own
/// spelling) and `Archercy` (their own typo) are all kept as published rather than corrected. A
/// "fixed" name is a name that no longer matches what a future export writes.
public enum WhoopActivityCatalog {

    /// WHOOP's abstention word, and the first row of `strainActivities`.
    ///
    /// **It is not on WHOOP's published list, and it has to be here anyway.** `Activity` is what their
    /// classifier writes when it declines to categorise a session, and it is the stored
    /// `activityName` on **197 of the bundled export's 673 rows** — the single most common value in the
    /// file. A picker that could not offer it would leave those 197 sessions opening on a list with
    /// nothing selected, which reads as a bug rather than as an abstention.
    public static let abstentionName = "Activity"

    /// `Fast`, and the first row of `recoveryActivities`.
    ///
    /// **It is not on WHOOP's published list, and the reason it is here is the producer behind it.**
    /// The user asked for it so that a fasting window recorded in **Zero** (a fasting tracker) could be
    /// synced into this app, and `ZeroFastingImporter` is that sync: it writes one `workouts` row per
    /// completed fast, labelled `zero_fasting`, carrying this name. The name is also independently
    /// **selectable** — the edit sheet's picker offers it and `SAVE` stores it — which is what a user
    /// recording a fast by hand needs.
    ///
    /// **The word is `Fast` and not `Fasting`.** The `ACTIVITIES` row draws a name uppercased under its
    /// figure, so `Fast` renders as `FAST` beside `SLEEP` — two short nouns over two durations. The
    /// longer word is the one WHOOP's page does not carry either way, so nothing is being corrected
    /// here; this is the user's own string, chosen for the row it is drawn on.
    ///
    /// It sits in the Recovery list because it is not a cardiovascular load: the type comment's test
    /// for that split is whether a strain figure describes the session, and a fasting window is time
    /// held rather than work done. **Its figures are the consequence**: a session synced from Zero has
    /// no strap data behind it at all, so `strain`, `averageHeartRate` and `maxHeartRate` are all `nil`
    /// — they were non-optional until `v18` precisely because this producer had not arrived, and a `0`
    /// would have read as a measurement. `steps` and `hrZonePercents` were already optional and are
    /// `nil` for the same reason. `ActivityFigure` draws the two dashes that follow.
    ///
    /// It is **prepended** rather than sorted in, for `abstentionName`'s reason: its position is a
    /// decision this type makes rather than a consequence of the letter it starts with.
    public static let fastingName = "Fast"

    /// The Strain Activities, as published, with the marker glyphs removed — **less the five names the
    /// app drops and plus `Road Biking`**. See the type comment for both directions, and do not read
    /// this list's length against WHOOP's published total.
    ///
    /// `abstentionName` is prepended rather than sorted in, so its position is a decision this type
    /// makes and not a consequence of the letter it starts with — it is the abstention rather than a
    /// sport, and a reader looking for it wants it where WHOOP's own list would not have put it.
    public static let strainActivities: [String] = [abstentionName] + [
        "Archercy", "Assault Bike", "Australian Rules Football", "Babywearing", "Badminton", "Ballet",
        "Bartending", "Baseball", "Basketball", "Billiards",
        "Bodybuilding", "Bouldering", "Bowling", "Box Fitness", "Boxing", "Breakdancing", "Caddying",
        "Canoeing", "Cheerleading", "Chess", "Circus Arts", "Cleaning", "Climber", "Coaching",
        "Commuting", "Cooking", "Cricket", "Cross Country Skiing", "Curling", "Dance",
        "Darts", "Dedicated Parenting", "Disc Golf", "Diving", "Dog Walking", "Driving", "Duathlon",
        "Elliptical", "F45 Training", "Fencing", "Field Hockey", "Firefighting", "Fishing", "Football",
        "Freediving", "Functional Fitness", "Gaelic Football", "Gaming", "Golf", "Gymnastics",
        "Handball", "High-Stress Work", "HIIT", "Hiking", "Horseback Riding", "Hot Yoga",
        "Hurling/Camogie", "Ice Hockey", "Ice Skating", "Inline Skating", "Jiu Jitsu", "Judo",
        "Jumping Rope", "Kayaking", "Kickboxing", "Kite boarding", "Lacrosse", "Manual Labor",
        "Martial Arts", "Motocross", "Motor Racing", "Mountain Biking", "Mountaineering", "Muay Thai",
        "Musical Performance", "Netball", "Nordic Walking", "Nursing a Baby", "Obstacle Course Racing",
        "Operations - Flying", "Operations - Medical", "Operations - Tactical", "Operations - Water",
        "Other", "Paddle Tennis", "Paddleboarding", "Padel", "Paintball", "Parkour", "Pickleball",
        "Pilates", "Polo", "Poker", "Powerlifting", "Public Speaking", "Pumping", "Racquetball",
        "Race Walking", "Refereeing", "Reformer Pilates", "Road Biking", "Rock Climbing", "Roller Hockey", "Rowing",
        "Rucking", "Rugby", "Running", "Sailing", "Scootering", "Sculpt Yoga", "Skateboarding",
        "Ski Touring", "Skiing", "Skydiving", "Snowshoeing", "Snow Shoveling", "Snowboarding", "Soccer",
        "Softball", "Solidcore", "Spikeball®", "Spin", "Sport Fishing", "Sprint Training", "Squash",
        "Stadium Steps", "Stage Performance", "Stairmaster", "Stroller Jogging", "Stroller Walking",
        "Surfing", "Swimming", "Table Tennis/Ping Pong", "Taekwondo", "Tennis", "Thrill Ride",
        "Toddler wearing", "Track & Field", "Trail Running", "Trampoline", "Triathlon", "Ultimate",
        "Unicycling", "Volleyball", "Wakeboarding", "Walking", "Watching Sports", "Water Polo",
        "Water Skiing", "Weightlifting", "Wheelchair Pushing", "Winter Biathlon",
        "Wrestling", "Yard Work/Gardening", "Yoga",
    ]

    /// The Recovery Activities, as published, with the marker glyphs removed — **plus `fastingName`**.
    ///
    /// **Kept as a separate list rather than merged, because WHOOP separates them and the split is
    /// real**: these are sessions with no meaningful cardiovascular load — a sauna, a massage, a
    /// breathing exercise — and the Strain Activities above are the ones a strain figure describes.
    ///
    /// **Nothing about the storage prevents one being picked.** `WorkoutSession.activityName` is a
    /// `String?` with no vocabulary constraint behind it, so a recovery activity is an ordinary row;
    /// it is offered here because WHOOP offers it, and the sheet draws the two groups as two sections
    /// so a reader can see which list a name came from.
    public static let recoveryActivities: [String] = [fastingName] + [
        "Acupuncture", "Air Compression", "Air Compression (Normatec)", "Breathwork",
        "Bright Light Therapy", "Chiropractor", "Cold Shower", "Contrast Therapy",
        "Cuddling with Child", "Dry Sauna", "Foam Rolling", "Guided Breathing - Increase Alertness",
        "Guided Breathing - Increase Relaxation", "Hot Tub", "Ice Bath", "Infared Sauna", "Knitting",
        "Massage Therapy", "Meditation", "Non-sleep, deep rest", "Other - Recovery",
        "Percussive Massage", "Percussive Massage (Hypervolt)", "Playing with Child", "QiGong",
        "Red Light Therapy", "Restorative Yoga", "Sound healing", "Steam Room", "Stretching",
        "Tai Chi", "Warm Bath",
    ]

    /// Both lists, for a caller that wants the whole vocabulary rather than one section of it.
    ///
    /// The order is `strainActivities` then `recoveryActivities`, which is the order the picker draws
    /// them in — so a `List` built from this and a `List` built from the two sections walk the same
    /// names in the same order, and a test sweeping one is sweeping the other.
    public static var allNames: [String] { strainActivities + recoveryActivities }

    /// The names this catalogue offers that **WHOOP's published list does not carry** — the whole of
    /// the difference between it and the page it began as.
    ///
    /// It exists so that difference is **stated and assertable rather than left to be re-derived**. The
    /// type comment already says the catalogue is curated and names the two directions of the
    /// divergence; this is the same fact as a value, so a reader comparing the list against WHOOP's
    /// page has one place to look and a test has something to compare against the two sections. The
    /// other direction — the five names in the published list that are deliberately absent — is not
    /// representable here and could not be: a name this type does not hold has no value to name it by,
    /// so it is stated in the comment above and nowhere else.
    ///
    /// **A membership test, not a scheme.** Nothing branches on this and no producer consults it; it is
    /// a record. A name added to either list for a reason WHOOP's page does not carry belongs here too,
    /// which is the one maintenance rule it has.
    public static let unpublishedNames: [String] = [abstentionName, fastingName, "Road Biking"]

    /// Whether `name` is one of the names this catalogue offers.
    ///
    /// **It compares through `ActivityName.matches` and not with `==`**, which is the whole reason this
    /// is a function on the catalogue rather than a `contains` at the picker's call site. The question
    /// the picker asks is "is the session's stored name already one of my rows", and a stored name
    /// arrived from a file with no casing rule — so `"basketball"`, `"  Basketball "` and `"Basketball"`
    /// are all this catalogue's `Basketball`, and a raw comparison would offer an extra *current* row
    /// for a name that is the very next row in the list, selected twice in two places.
    ///
    /// `nil` and `""` are both `false`, because `ActivityName.normalised` answers `nil` for a name with
    /// nothing in it and an empty name is not a name WHOOP publishes — it is the absence of one, which
    /// is what the sheet's own fallback row is for.
    public static func contains(_ name: String?) -> Bool {
        guard ActivityName.normalised(name) != nil else { return false }
        return allNames.contains { ActivityName.matches($0, name) }
    }
}
