-- The seventh resource this Worker owns, the third keyed on an id, and the first whose lookup column
-- is an instant rather than a day.
--
-- **The key is client-derived, and here that is forced rather than chosen.** `workouts` and
-- `receptive_inactivities` are keyed on an id because a day holds several of each; this table is
-- keyed on one because the app has no identity for a sample that could travel. The phone's local row
-- identity is an autoincrement `Int` assigned by that device's own SQLite, and it does not reach the
-- app's entity at all: `GRDBBiometricRepository.saveSamples` never writes it and `makeSample` never
-- reads it, so every read mints a fresh identity. Handing that integer to this table would mean two
-- devices in one partition both minting from 1 and silently overwriting each other, which is the
-- defect an id key exists to prevent. The wire id is therefore a client-derived string, and the
-- derivation is the producer's business and not this table's — on `0006`'s rule. The one property
-- this schema needs from it is that it be **deterministic**: re-sending the same sample must produce
-- the same id, which is what makes a replayed chunk an upsert rather than a second row.
--
-- **The instant is the lookup column, and a day-keyed window is not available here.** Every other
-- resource in this Worker reads a range of `date` keys, and on those a day is one row — which is why
-- their windows are counted in days and reach back thousands of them. A day of this table is up to
-- 86,400 rows at 1 Hz, so the same shape would make "give me last month" a read no Worker should be
-- asked for. The window is an instant range over `timestamp` instead, and the app's own port takes
-- both bounds from the caller for the same reason. `timestamp` is stored in the one canonical UTC
-- spelling the contract publishes — exactly three fractional digits and a `Z` — which is what makes
-- a range over this TEXT column a chronological range rather than a lexicographic accident.
--
-- **`rr_intervals_ms` is JSON text, and it subsumes the legacy lossy scalar rather than sitting
-- beside it.** The app's table carries two columns for one quantity: `rrIntervalMs`, the first
-- interval of a notification, kept from before the series existed, and `rrIntervalsMs`, the whole
-- series. Only the series is published. A single notification may carry several intervals and they
-- are **adjacent beats by definition**, so the scalar is a lossy duplicate of a value the wire
-- already carries; two spellings of one quantity on the wire are two answers that can disagree, and
-- the app's own `rrSeries` already collapses them on read, so a row that arrives with only the series
-- reads back identically. The column is `TEXT` holding a JSON array of numbers, which is the one
-- place in this Worker a value is encoded rather than stored plainly — argued in
-- `d1BiometricSampleRepository.ts`, where the decode lives.
--
-- **Every other channel is nullable, and each is an expected absence rather than a zero.** A
-- notification carries what the strap happened to measure: an R-R series is absent when the
-- characteristic's R-R bit is unset, a skin temperature when the optical engine reported none, a
-- `spo2_percentage` when the pulse-oximetry estimate was not produced, a packet sequence number when
-- the frame did not come off the flash. `NULL` is the column's word for "nothing was given" and no
-- default is applied on either side, because a fabricated `0` on any of these is a reading somebody
-- took rather than a channel that said nothing — the absence rule this Worker applies to every
-- optional column. **`heart_rate` is the one channel that is `NOT NULL`**, because a sample exists
-- only when the decoder had a pulse to report; it is stored unrounded and may legitimately be `0`,
-- which is why the contract bounds it at `nonnegative` and not at `positive`.
--
-- **The three accelerometer axes are nullable independently, and that is deliberate.** The strap
-- sends the triplet as one record, so all three are present together or none is — but "none" is
-- expressed by three `NULL`s and not by a fourth flag, and this schema does not constrain them to
-- agree. The app's own rule is that a partial triplet is storable and means *motion was not
-- measurable on this row*: `accelerationMagnitude` is `nil` unless every axis is present, so a
-- defined reading exists for the partial case and a `CHECK` refusing it would reject a row the
-- storage already holds. A `0.0` here would be worse than an absent one — free fall is physically
-- unreachable on a body and lands on the *still* side of every movement threshold.
--
-- **The two booleans are a closed set, and the app's own read-side defaults are not copied.** The
-- local table is SQLite with GRDB, where a `Bool` is an `INTEGER` `0`/`1`; the app's mapper resolves
-- an absent `is_on_body` to `true` and an absent `is_charging` to `false` when it builds its entity.
-- This table keeps `NULL` as `NULL`, because those two defaults turn "the strap did not say" into two
-- opposite measurements. The `CHECK` is the one `0003` already carries on `has_measurement`, applied
-- to a nullable column: the constraint passes when the value is `NULL`, so it closes the set without
-- inventing a value.
--
-- **The rule for this file's own shape.** A migration is frozen once shipped: D1 records an applied
-- migration's *identifier* and does not checksum the body, so a schema change is a new numbered file
-- and never an edit to this one. And a migration file must not end on a comment — `readD1Migrations`
-- splits on statements and attaches a comment to the statement that follows it, so a trailing
-- comment becomes a statement of its own and D1 refuses it with `SQL code did not contain a
-- statement`, arriving as a failing *suite* that names no line. End the file on a `;` and nothing
-- else.

CREATE TABLE biometric_samples (
    user_id              TEXT    NOT NULL,
    id                   TEXT    NOT NULL,
    timestamp            TEXT    NOT NULL,
    heart_rate           INTEGER NOT NULL,
    rr_intervals_ms      TEXT,
    accel_x              REAL,
    accel_y              REAL,
    accel_z              REAL,
    skin_temp            REAL,
    spo2_percentage      REAL,
    is_on_body           INTEGER CHECK (is_on_body IN (0, 1)),
    is_charging          INTEGER CHECK (is_charging IN (0, 1)),
    raw_sequence_number  INTEGER,
    PRIMARY KEY (user_id, id)
);

-- The window read's only index: `WHERE user_id = ? AND timestamp >= ? AND timestamp <= ?`. The
-- primary key above is `(user_id, id)` and cannot serve it, because a range over `timestamp` is not a
-- range over the second column of that key. The ordering is `timestamp ASC, id ASC` and the second
-- half of it is *not* served by this index — id is not in it — but that is the tiebreak alone, and a
-- tie is two samples in the same millisecond.
CREATE INDEX biometric_samples_user_timestamp ON biometric_samples (user_id, timestamp);
