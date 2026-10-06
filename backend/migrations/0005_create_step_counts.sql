-- The fifth resource this Worker owns, and the fourth cut from `0001`'s shape: one row per measured
-- day, keyed on the day. A day holds exactly one step total, so this table is `recoveries`',
-- `strains`' and `sleeps`' sibling and `workouts`' opposite — no children, no `seq`, no id. `0002`
-- already named the three tables that break away from `workouts`' rule; this is the fourth member of
-- that family rather than a new arrangement.
--
-- **The columns are snake_case here even though the local record is camelCase, and that is the
-- opposite of `sleeps` and the same as `strains`.** `StepCountRecord` declares no `CodingKeys`, so on
-- the phone its property names *are* its column names and they are `stepCount` and `measuredSeconds`
-- — while D1 is snake_case for every resource regardless, which is the rule `0003` settled for
-- exactly this case (`StrainRecord` is the other `CodingKeys`-less record, and `strains`' D1 columns
-- are still `strain_score` and `has_measurement`). Nothing reconciles the two and nothing needs to:
-- the wire carries the app's *property* names either way, and the mapping between the wire's naming
-- and this one lives in exactly one file, `d1StepCountRepository.ts`.
--
-- **There is no `has_measurement` column, and its absence is this resource's one structural
-- difference from `strains`.** The iOS `StepCount.hasMeasurement` is a *computed* property
-- (`measuredSeconds > 0`), not a stored flag, so there is no second kind of row here for a route to
-- tell apart from a reading: a row that exists with `measured_seconds = 0` is constructible — the
-- entity documents it as reader tolerance — but no writer produces one, so the absence rule here is
-- `recoveries`' rather than `strains`': a day with no row is a 404, and nothing beside the null is
-- tested.
--
-- **There is no `source` column, and that is a fact about the producer rather than an omission.**
-- Steps come from the strap and from nothing else: the live IMU stream (`0x2B`/43) and the banked
-- drain (47) are the same measurement of the same motion by the same sensor, and a single day is
-- routinely fed by both — so a per-row provenance label could not be written honestly, and
-- `StepRepository` takes no `source` parameter for the same reason. Do not add one here or on the
-- wire; do not add a HealthKit read-through as a fallback either, since a day the strap did not
-- measure would then show the phone's count instead of a dash.
--
-- **`measured_seconds` is load-bearing rather than bookkeeping.** It is the field that separates a
-- *measured* day of no walking — a real `0` count — from a day nothing measured, which is an absent
-- row. It is non-negative and a zero is a real value, which is why it is `NOT NULL` and undefaulted:
-- a default of any kind on this column would publish the second state as the first. It is `REAL`
-- because the accumulator sums clamped per-batch spans rather than counting whole seconds.
--
-- **Frozen once shipped.** D1, like GRDB, records an applied migration's *identifier* and does not
-- checksum the body (`d1_migrations`), so a schema change is a new numbered file and never an edit to
-- this one — including `0001`, `0002`, `0003` and `0004`.
--
-- **A migration file must not end on a comment.** `readD1Migrations` splits each file with wrangler's
-- `unstable_splitSqlQuery`, which attaches a comment to the statement that *follows* it — so a
-- comment with no statement after it becomes a statement in its own right, and D1 refuses it with
-- `D1_ERROR: SQL code did not contain a statement.` Measured, and the shape of the failure is worth
-- knowing: it arrives as a failing *suite* rather than a failing test, names no line of this file, and
-- points at `applyD1Migrations` in the setup file instead. So keep every paragraph above the SQL it
-- introduces, and end the file on a `;` and nothing else.

CREATE TABLE step_counts (
    -- The partition, carried and not trusted: `X-Whoopsy-User-Id` is a placeholder identity that
    -- nothing verifies, and what lands here is sha256 of it rather than the header itself. First, so
    -- `(user_id, date)` is a prefix of anything built from it.
    user_id           TEXT    NOT NULL,

    -- The day key. TEXT 'YYYY-MM-DD' for `recoveries.date`'s reasons verbatim: it is a calendar day
    -- and not an instant, `StepCountRecord.date` is always `startOfDay` in the *device's* calendar,
    -- and this server cannot re-derive the client's midnight without the client's zone. It also sorts
    -- lexicographically in date order, which is what makes the range read a plain BETWEEN.
    date              TEXT    NOT NULL,

    -- How many steps the strap's pedometer counted that day. INTEGER because it is a count and never
    -- a fraction, and NOT NULL because an absent count is an absent row rather than a null here.
    -- A zero is a measured day of no walking and is written; see `measured_seconds` below for the
    -- field that tells it apart from nothing having been measured at all.
    step_count        INTEGER NOT NULL,

    -- Seconds of motion the count above came from, as the accumulator summed them — `Σ min(5.0, Δt)`
    -- over the batches it was handed, so REAL rather than an integer second count. **This is the
    -- column that carries the absence rule on this table**: `measuredSeconds > 0` is the client's
    -- `hasMeasurement` and the same test its writer gates on, so a row holding a positive value here
    -- is a day the strap really wore, whatever `step_count` says beside it.
    measured_seconds  REAL    NOT NULL,

    -- The day-key convention stated as a constraint — one row per (owner, day) — and that constraint
    -- is also this table's only index. It *is* the index the single-day read and the range read both
    -- use (`WHERE user_id = ? AND date >= ? AND date <= ? ORDER BY date`), so a separate index on
    -- (user_id, date) would be a byte-for-byte duplicate of it. SQLite reports this one as
    -- `sqlite_autoindex_step_counts_1`.
    PRIMARY KEY (user_id, date)
);
