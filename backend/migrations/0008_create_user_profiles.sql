-- The eighth resource this Worker owns, the first keyed on nothing but its owner, and the first whose
-- table can hold at most one row per partition.
--
-- **This is a singleton, and that is a shape no other resource here has.** Every sibling is a
-- collection: `recoveries` has a row per day, `workouts` a row per session, `biometric_samples` a row
-- per notification. A profile is one row per person, and the app's own storage says so rather than
-- implying it -- `UserProfileRecord.databaseTableName` is `user_profiles` and its primary key is a
-- literal `id: String = "primary"`, one per database. Its repository mirrors that in its interface:
-- `getUserProfile()` and `saveUserProfile(_:)` take **no id at all**, because there is no question a
-- caller could ask an id that the partition has not already answered.
--
-- **`id` is therefore deliberately absent, and its absence is the migration's sharpest decision.**
-- The direct translation of `PRIMARY KEY (id)` into this Worker would be `PRIMARY KEY (user_id, id)`,
-- and that is wrong in a way worth spelling out: `"primary"` is a local-storage constant with no
-- meaning outside the file it was written in, so publishing it would put a field on the wire whose
-- only legal value is that word -- and admitting any other value would let a client mint a second row
-- that the singleton read could not disambiguate. The partition column *is* the identity here, so
-- `PRIMARY KEY (user_id)` is the whole key and there is no id to carry.
--
-- **The two heart rates are NOT NULL and the five other fields are nullable, and the split is the
-- app's own.** `maxHeartRate` and `restingHeartRate` are the inputs the Karvonen zone table cannot be
-- built without -- `StrainAccumulatorMath.computeZones` reads both and has a 20 bpm floor on their
-- reserve -- so an absent one is not an absence a screen can draw, it is a table that cannot be
-- computed at all; the app's `GRDBUserProfileRepository` returns a cold-start 190/60 rather than a
-- row with a hole in it. The other five are *declared* facts: the user supplies them, the user is the
-- sensor, and `NULL` is the honest value for one nobody has supplied. **No default is applied to any
-- of the five**, because a defaulted body metric is the fabrication this project's absence rule
-- forbids everywhere -- on this table the dangerous instance is a weight, which
-- `StrainAccumulatorMath.estimateCalories` divides into, so a fabricated one scales a calorie figure
-- by a body the user never described.
--
-- **`birth_date` is a day key and not an instant.** A birthday is a calendar date: the user supplies a
-- day, not a moment, and storing an instant would invent a time of day and a UTC offset they never
-- gave. It is `TEXT` in the same `YYYY-MM-DD` spelling as `recoveries.date`, which sorts
-- lexicographically in date order and needs no date function to read back. The client converts at the
-- boundary -- its own column is a `.datetime` -- and that conversion is the one place a
-- `startOfDay` snap can be got wrong; see the field's description in `dto/userProfiles.ts`.
--
-- **`gender` is `TEXT` holding the app's own raw value.** `UserProfile.Gender` is a `String`-backed
-- enum (`man`, `woman`, `nonBinary`, `preferNotToSay`) and the raw string is what a reader can see in
-- `sqlite3`, which is why the app stores it that way rather than as an ordinal. It is nullable for
-- the rule this app holds for the whole enum: an unrecognised word reads back as `nil` rather than
-- being guessed at, and "the user did not say" is a distinct answer from any of the four words.
--
-- **The primary key is this table's only index.** The one read path is `WHERE user_id = ?`, which the
-- key serves exactly, so a separate index on `(user_id)` would be a byte-for-byte duplicate of the
-- one SQLite builds for the primary key -- `0001`'s argument, applied to a table with one column
-- fewer. There is no window read here and no second lookup column, because a singleton has no range
-- to ask for and no sibling rows to order against.
--
-- **The rule for this file's own shape.** A migration is frozen once shipped: D1 records an applied
-- migration's *identifier* and does not checksum the body (`d1_migrations`), so a schema change is a
-- new numbered file and never an edit to this one. And a migration file must not end on a comment --
-- `readD1Migrations` splits on statements and attaches a comment to the statement that follows it, so
-- a trailing comment becomes a statement of its own and D1 refuses it with `SQL code did not contain
-- a statement`, arriving as a failing *suite* that names no line. End the file on a `;` and nothing
-- else.

CREATE TABLE user_profiles (
    user_id             TEXT    NOT NULL,
    max_heart_rate      INTEGER NOT NULL,
    resting_heart_rate  INTEGER NOT NULL,
    weight_kg           REAL,
    name                TEXT,
    birth_date          TEXT,
    gender              TEXT,
    height_cm           REAL,
    PRIMARY KEY (user_id)
);
