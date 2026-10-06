-- The second resource this Worker owns, and the first that is an aggregate: one `workouts` row with
-- its own `workout_route_points` and `workout_splits` children, written and read as one thing.
--
-- **This table breaks the day-key rule on purpose, and it must stay broken.** `recoveries` is
-- primary-keyed on `date` because a day holds exactly one recovery, and `sleeps` and `strains` are
-- keyed the same way for the same reason. A day holds *several* workouts — two runs and a ride is an
-- ordinary Tuesday — so the row's identity is the session's own `id` and `date` is an ordinary
-- indexed lookup column. A `PRIMARY KEY (user_id, date)` here would make the second session on a day
-- silently overwrite the first, and the app's own table has carried that rule since `v6`. It is why
-- the read path (`SELECT_WINDOW`) returns an array and why `GET /v1/workouts/{id}` addresses one
-- session rather than one day.
--
-- **The day is a column and not a derivation.** `date` is the client's `startOfDay(startedAt)` in
-- the device's own calendar, handed over in the body rather than computed here: a Worker in UTC
-- cannot know which zone filed a 22:40 session on the day it started or the day it ended, and
-- deriving it would be wrong by hours for every caller west of Greenwich. Nothing in this schema
-- checks it against `started_at` for that reason, and the app snaps it centrally in
-- `LocalDatabaseManager.saveWorkout` on its own side.
--
-- **`user_id` is on all three tables, including the children.** The header is a selection and not a
-- credential, so partition scoping is the only isolation this Worker has: a child delete or read
-- keyed on `workout_id` alone would cross partitions the moment two installs generated the same id
-- — which for a UUID they will not, and for a client that has been rewritten to send its own ids
-- they might. It costs four characters a row and removes the assumption.
--
-- **There is no foreign key, and the adapter is the mechanism instead.** The app declares
-- `onDelete: .cascade` on both children and then deletes them explicitly by `workout_id` rather than
-- trusting it, because GRDB runs migrations with foreign keys deferred. This schema takes the second
-- half of that and leaves the declaration out: the upsert deletes both children and re-inserts them
-- in the same `batch()`, so a constraint here would be one nothing ever exercises — a claim rather
-- than a guarantee. If a delete path is ever added, revisit this line first.
--
-- **`seq` on the children is order, and it is not derivable from anything else here.** A route is an
-- ordered list of fixes and the wire carries it as an array; a stored order that is not written down
-- is an order that is not preserved. Ordering by `timestamp` would look right and be wrong for two
-- fixes sharing an instant, and ordering by `id` would be ordering by a random UUID. Both children
-- therefore carry the index the client sent, and both read back `ORDER BY seq ASC` — so what a
-- client PUTs is what a client GETs, byte for byte, which is the whole contract of a sync.
--
-- **The rule for this file's own shape.** A migration is frozen once shipped: D1 records an applied
-- migration's *identifier* and does not checksum the body, so a schema change is a new numbered file
-- and never an edit to this one. And a migration file must not end on a comment — `readD1Migrations`
-- splits on statements and attaches a comment to the statement that follows it, so a trailing
-- comment becomes a statement of its own and D1 refuses it with `SQL code did not contain a
-- statement`, arriving as a failing *suite* that names no line. End the file on a `;` and nothing
-- else.

CREATE TABLE workouts (
    user_id             TEXT    NOT NULL,
    id                  TEXT    NOT NULL,
    date                TEXT    NOT NULL,
    started_at          TEXT    NOT NULL,
    ended_at            TEXT    NOT NULL,
    strain              REAL,
    average_heart_rate  INTEGER,
    max_heart_rate      INTEGER,
    source              TEXT,
    activity_name       TEXT,
    hr_zone_percents    TEXT,
    steps               INTEGER,
    offline_region_id   TEXT,
    PRIMARY KEY (user_id, id)
);

-- The window read's only index: `WHERE user_id = ? AND date >= ? AND date <= ?`. The primary key
-- above is `(user_id, id)` and cannot serve it, because a range over `date` is not a range over the
-- second column of that key. `date` sorts lexicographically because it is a fixed-width
-- `YYYY-MM-DD`, which is what makes the filter a plain BETWEEN rather than a date function.
CREATE INDEX workouts_user_date ON workouts (user_id, date);

CREATE TABLE workout_route_points (
    user_id     TEXT    NOT NULL,
    id          TEXT    NOT NULL,
    workout_id  TEXT    NOT NULL,
    seq         INTEGER NOT NULL,
    latitude    REAL    NOT NULL,
    longitude   REAL    NOT NULL,
    timestamp   TEXT    NOT NULL,
    heart_rate  INTEGER NOT NULL,
    PRIMARY KEY (user_id, id)
);

-- The child reads are keyed on `(user_id, workout_id)`, which the primary key above does not cover.
CREATE INDEX workout_route_points_workout ON workout_route_points (user_id, workout_id);

CREATE TABLE workout_splits (
    user_id     TEXT    NOT NULL,
    id          TEXT    NOT NULL,
    workout_id  TEXT    NOT NULL,
    seq         INTEGER NOT NULL,
    elapsed     REAL    NOT NULL,
    strain      REAL    NOT NULL,
    PRIMARY KEY (user_id, id)
);

CREATE INDEX workout_splits_workout ON workout_splits (user_id, workout_id);
