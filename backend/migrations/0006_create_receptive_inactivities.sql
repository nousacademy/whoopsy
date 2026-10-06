-- The sixth resource this Worker owns, and the second that is keyed on an id rather than on a day.
--
-- **This table copies `workouts`' key and none of its aggregate.** A day holds several receptive
-- inactivities — two dreams and a meditation is an ordinary night — so the row's identity is its own
-- `id` and `date` is an ordinary indexed lookup column, exactly as `workouts` is. A
-- `PRIMARY KEY (user_id, date)` here would make the second dream of a night silently overwrite the
-- first, and the app's own table has carried that rule since `v21_receptive_inactivities`. What it
-- does **not** copy is the aggregate: there is no child table, no `seq`, and no third endpoint,
-- because an inactivity has no span — no `ended_at`, so no route, no splits and nothing ordered
-- inside it.
--
-- **The day is a column and not a derivation, and here that is forced rather than chosen.**
-- `started_at` is nullable, so unlike a nap — whose day is derivable from its own onset — there is
-- nothing to derive the day *from* when no time was given at all. The app's invariant is one
-- sentence: **the start time is a time-of-day on the day being viewed**, rebuilt onto the selected
-- day's year/month/day before the write, which is what makes `date == startOfDay(started_at)` true
-- whenever a time is present. Nothing in this schema checks it, for `workouts`' reason: the Worker is
-- in UTC and the caller's calendar is not.
--
-- **`note` is nullable, undefaulted, and it is both a value and an identity input.** NULL is the
-- column's word for "nothing was given" and `""` is never stored — a defaulted empty string would be
-- a value nobody supplied, which is the absence rule this Worker applies to every optional column.
-- It is *also* an input to the row's id: the app derives a UUIDv5 over `"<date>|<type>|<note>"`, so a
-- re-worded entry leaves its predecessor on the day beside it rather than overwriting it. That is a
-- property of the producer and not of this table, but it is the reason the column is not merely
-- descriptive text.
--
-- **`started_at` is the first nullable instant in this Worker, and `workouts` has none.** An
-- untimed entry is the ordinary case rather than the exception — all 60 rows of the app's bundled
-- note file are untimed — so a `NOT NULL` here would either refuse the whole import or demand a
-- fabricated clock time, which is the fabrication every absence rule in this codebase forbids.
--
-- **The rule for this file's own shape.** A migration is frozen once shipped: D1 records an applied
-- migration's *identifier* and does not checksum the body, so a schema change is a new numbered file
-- and never an edit to this one. And a migration file must not end on a comment — `readD1Migrations`
-- splits on statements and attaches a comment to the statement that follows it, so a trailing
-- comment becomes a statement of its own and D1 refuses it with `SQL code did not contain a
-- statement`, arriving as a failing *suite* that names no line. End the file on a `;` and nothing
-- else.

CREATE TABLE receptive_inactivities (
    user_id     TEXT    NOT NULL,
    id          TEXT    NOT NULL,
    date        TEXT    NOT NULL,
    name        TEXT    NOT NULL,
    note        TEXT,
    started_at  TEXT,
    PRIMARY KEY (user_id, id)
);

-- The window read's only index: `WHERE user_id = ? AND date >= ? AND date <= ?`. The primary key
-- above is `(user_id, id)` and cannot serve it, because a range over `date` is not a range over the
-- second column of that key. `date` sorts lexicographically because it is a fixed-width
-- `YYYY-MM-DD`, which is what makes the filter a plain BETWEEN rather than a date function.
CREATE INDEX receptive_inactivities_user_date ON receptive_inactivities (user_id, date);
