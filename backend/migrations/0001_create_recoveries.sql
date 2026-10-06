-- The first table this Worker owns, and the shape every later one is cut from. Mirrors the local
-- `recoveries` column for column, plus the one thing the local schema has no equivalent for: an owner.
--
-- Frozen once shipped. D1, like GRDB, records an applied migration's *identifier* and does not
-- checksum the body (`d1_migrations`), so a schema change is a new numbered file and never an edit
-- to this one. That is the rule `CLAUDE.md` already carries for the app's migrations, and it is the
-- reason `user_id` is here rather than in a later file.
--
-- **A migration file must not end on a comment.** `readD1Migrations` splits each file with wrangler's
-- `unstable_splitSqlQuery`, which attaches a comment to the statement that *follows* it — so a
-- comment with no statement after it becomes a statement in its own right, and D1 refuses it with
-- `D1_ERROR: SQL code did not contain a statement.` Measured, and the failure is worth knowing the
-- shape of: it arrives as a failing *suite* rather than a failing test, names no line of this file,
-- and points at `applyD1Migrations` in the setup file instead. So keep every paragraph above the SQL
-- it introduces, and end the file on a `;` and nothing else.

CREATE TABLE recoveries (
    -- The partition, in the FIRST migration rather than a later one, so the day a verified token
    -- arrives the table already has its owner column and no row rewrite is needed. There is no
    -- `accounts` table and nothing verifies this value yet: it is carried, not trusted.
    user_id             TEXT    NOT NULL,

    -- The day key. TEXT 'YYYY-MM-DD' — a calendar day, not an instant, and deliberately not a
    -- unix integer. `RecoveryRecord.date` is always `startOfDay` in the *device's* calendar, so its
    -- instant is a day label wearing a timestamp; in a shared table that instant makes the key
    -- timezone-dependent, and this server cannot re-derive the client's midnight without the
    -- client's zone. 'YYYY-MM-DD' also sorts lexicographically in date order, so the range read is
    -- a plain BETWEEN with an ORDER BY.
    date                TEXT    NOT NULL,

    recovery_score      INTEGER NOT NULL,
    resting_heart_rate  INTEGER NOT NULL,
    hrv_value_ms        REAL    NOT NULL,

    -- NOT NULL with no default, and the local v3 rename from `hrv_rmssd` is why: the value is
    -- meaningless without which quantity it is, and a defaulted 'rmssd' would put a metric on a row
    -- nobody chose one for.
    hrv_metric          TEXT    NOT NULL,

    -- Nullable and undefaulted, matching the local columns: a reading the strap did not report stays
    -- absent. NULL is not 0, and it is never folded into one on the way out.
    skin_temperature    REAL,
    spo2_percentage     REAL,
    respiratory_rate    REAL,

    -- Provenance ('whoop_export', …). NULL is the honest value for "this app measured it" and for
    -- every row written before the column existed.
    source              TEXT,

    -- The day-key convention stated as a constraint — one row per (owner, day) — and that constraint
    -- is also this table's only index. It *is* the index the one read path uses
    -- (`WHERE user_id = ? AND date BETWEEN ? AND ? ORDER BY date`), so a separate index on
    -- (user_id, date) would be a byte-for-byte duplicate of it. SQLite reports the primary key's own
    -- index as `sqlite_autoindex_recoveries_1`.
    PRIMARY KEY (user_id, date)
);
