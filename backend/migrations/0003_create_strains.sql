-- The third resource this Worker owns, and the second cut from `0001`'s shape rather than `0002`'s:
-- one row per measured day, keyed on the day. A day holds exactly one strain, so this table is
-- `recoveries`' sibling and `workouts`' opposite — no children, no `seq`, no id.
--
-- **It mirrors the local `strains` table column for column, and the local table is where the surprise
-- is.** `StrainRecord` declares no `CodingKeys`, so on the phone its property names *are* its column
-- names and they are camelCase — `strainScore`, `averageHeartRate`, `hasMeasurement`. Every column
-- here is snake_case, because that is this database's spelling for all three resources. Nothing
-- reconciles the two and nothing needs to: the wire carries the app's own property names, and how
-- this Worker stores them is its own business. What follows is the rule worth keeping — read the
-- app's record before naming a column here, rather than the name you expect from `recoveries`.
--
-- **Frozen once shipped.** D1, like GRDB, records an applied migration's *identifier* and does not
-- checksum the body (`d1_migrations`), so a schema change is a new numbered file and never an edit to
-- this one — including `0001` and `0002`.
--
-- **A migration file must not end on a comment.** `readD1Migrations` splits each file with wrangler's
-- `unstable_splitSqlQuery`, which attaches a comment to the statement that *follows* it — so a
-- comment with no statement after it becomes a statement in its own right, and D1 refuses it with
-- `D1_ERROR: SQL code did not contain a statement.` Measured, and the shape of the failure is worth
-- knowing: it arrives as a failing *suite* rather than a failing test, names no line of this file, and
-- points at `applyD1Migrations` in the setup file instead. So keep every paragraph above the SQL it
-- introduces, and end the file on a `;` and nothing else.

CREATE TABLE strains (
    -- The partition, carried and not trusted: `X-Whoopsy-User-Id` is a placeholder identity that
    -- nothing verifies, and what lands here is sha256 of it rather than the header itself. First, so
    -- `(user_id, date)` is a prefix of anything built from it.
    user_id             TEXT    NOT NULL,

    -- The day key. TEXT 'YYYY-MM-DD' for `recoveries.date`'s reasons verbatim: it is a calendar day
    -- and not an instant, `StrainRecord.date` is always `startOfDay` in the *device's* calendar, and
    -- this server cannot re-derive the client's midnight without the client's zone. It also sorts
    -- lexicographically in date order, which is what makes the range read a plain BETWEEN.
    date                TEXT    NOT NULL,

    -- WHOOP's own 0–21 scale. REAL and not INTEGER: the entity rounds to one decimal
    -- (`(score * 10).rounded() / 10`) and the export's `Day Strain` column carries figures like 4.1.
    strain_score        REAL    NOT NULL,

    -- Kilojoules, not kilocalories — the entity's `activeCalories` is converted through 4.184 on the
    -- way in and back on the way out, and this column holds the stored unit. **A zero here is a
    -- legitimate measured value**, not an absence: it is what a scored day with no weight on file
    -- produces, since the calorie estimate returns `nil` without one. It must never be read as one,
    -- and it is the reason `has_measurement` below exists rather than being derivable from a figure.
    kilojoules          REAL    NOT NULL,

    -- Both rates are non-negative rather than positive, which is a deliberate difference from
    -- `recoveries.resting_heart_rate`. An unmeasured placeholder row carries zeroes in both and is
    -- legitimately on the wire, distinguished by the flag below rather than by its rates — so a
    -- `> 0` constraint here would refuse a row the app really holds, and there is no rate that could
    -- stand in as the discriminator without either losing a measured row or inventing one.
    average_heart_rate  INTEGER NOT NULL,
    max_heart_rate      INTEGER NOT NULL,

    -- The app's own stored flag, carried rather than derived, because the score cannot carry it: the
    -- export's `Day Strain` holds exactly `0.0` on two real days, so a reader keying measuredness on
    -- the score alone would call two genuine rest days unmeasured. SQLite has no boolean, so it is an
    -- integer with its domain stated here rather than left to the writer.
    has_measurement     INTEGER NOT NULL CHECK (has_measurement IN (0, 1)),

    -- Provenance ('whoop_export', …). Nullable and undefaulted, matching the local column: NULL is
    -- the honest value for "this app measured it" and for every row written before the column existed.
    source              TEXT,

    -- The day-key convention stated as a constraint — one row per (owner, day) — and that constraint
    -- is also this table's only index. It *is* the index the single-day read and the range read both
    -- use (`WHERE user_id = ? AND date >= ? AND date <= ? ORDER BY date`), so a separate index on
    -- (user_id, date) would be a byte-for-byte duplicate of it. SQLite reports this one as
    -- `sqlite_autoindex_strains_1`.
    PRIMARY KEY (user_id, date)
);
