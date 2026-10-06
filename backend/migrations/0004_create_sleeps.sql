-- The fourth resource this Worker owns, and the third cut from `0001`'s shape: one row per measured
-- night, keyed on the day. A day holds exactly one night, so this table is `recoveries`' and
-- `strains`' sibling and `workouts`' opposite — no children, no `seq`, no id. `0002` already named it
-- when it listed the three tables that break away from `workouts`' rule; this is that table.
--
-- **The day is the night's *wake* day, not the day it began on.** A night that starts at 23:40 on the
-- 21st and ends at 07:10 on the 22nd is filed under `2026-08-22`, which is the app's own convention
-- and not a choice made here: `CalculateRecoveryUseCase` writes `date.startOfDay` and reads the sleep
-- session *for that same date*, so a recovery row for a day comes from the night that ended on that
-- day's morning. The export is keyed the same way — on `Wake onset`, not `Cycle start` — and keying it
-- the other way collapses 935 export rows onto 753 days. So the boundary fields below are *not*
-- `date` plus an offset, and nothing here should be re-derived from them.
--
-- **It mirrors the local `sleeps` table column for column, and that table is the one whose record
-- has a `CodingKeys`.** `SleepRecord` maps its camelCase properties onto these snake_case names
-- explicitly (`startTime` → `start_time`), so unlike `strains` — whose local columns are camelCase
-- because `StrainRecord` declares no `CodingKeys` — the two schemas here already agree on spelling.
-- The wire is the app's *property* names either way (`startTime`, `sleepPerformance`), and the
-- mapping between the wire's naming and this one lives in exactly one file, `d1SleepRepository.ts`.
--
-- **Six columns are nullable because the app really holds no value for them, and each absence is a
-- distinct, expected state rather than a hole to fill with a plausible number.** `respiratory_rate`
-- exists only for a night whose R-R series can support an estimate (the strap has no respiratory
-- *sensor*), `disturbance_count` only for a night the actigraphy classifier could read,
-- `sleep_consistency` for a night with four priors to score against, `sleep_debt` for a night WHOOP
-- supplied one for, `sleep_stages` for a night the strap staged at all — the export reports stage
-- *totals* and no timeline, so every imported night has none and never can — and `source`, whose NULL
-- is the honest value for a night this app measured itself rather than for one nobody recorded a
-- provenance for. A defaulted `14.0` rate or
-- a `0` debt is a fabricated reading of exactly the kind this project's absence rule forbids: a `0`
-- consistency would claim a night maximally inconsistent with its own history, and a `0` debt a night
-- in perfect credit.
--
-- **Frozen once shipped.** D1, like GRDB, records an applied migration's *identifier* and does not
-- checksum the body (`d1_migrations`), so a schema change is a new numbered file and never an edit to
-- this one — including `0001`, `0002` and `0003`.
--
-- **A migration file must not end on a comment.** `readD1Migrations` splits each file with wrangler's
-- `unstable_splitSqlQuery`, which attaches a comment to the statement that *follows* it — so a
-- comment with no statement after it becomes a statement in its own right, and D1 refuses it with
-- `D1_ERROR: SQL code did not contain a statement.` Measured, and the shape of the failure is worth
-- knowing: it arrives as a failing *suite* rather than a failing test, names no line of this file, and
-- points at `applyD1Migrations` in the setup file instead. So keep every paragraph above the SQL it
-- introduces, and end the file on a `;` and nothing else.

CREATE TABLE sleeps (
    -- The partition, carried and not trusted: `X-Whoopsy-User-Id` is a placeholder identity that
    -- nothing verifies, and what lands here is sha256 of it rather than the header itself. First, so
    -- `(user_id, date)` is a prefix of anything built from it.
    user_id             TEXT    NOT NULL,

    -- The day key, and the night's *wake* day rather than its onset's. TEXT 'YYYY-MM-DD' for
    -- `recoveries.date`'s reasons verbatim: it is a calendar day and not an instant, `SleepRecord.date`
    -- is always `startOfDay` in the *device's* calendar, and this server cannot re-derive the client's
    -- midnight without the client's zone. It also sorts lexicographically in date order, which is what
    -- makes the range read a plain BETWEEN.
    date                TEXT    NOT NULL,

    -- The night's two boundaries, as instants in the one spelling the wire accepts: ISO-8601,
    -- canonical UTC, exactly three fractional digits. TEXT rather than an integer because that is what
    -- the client sends and a sync's job is to hand back the string it was given — see `InstantSchema`.
    -- Nothing in this schema checks that `end_time` comes after `start_time`, deliberately: the write
    -- bodies refuse a reversed pair before it can reach here, and a constraint on a value the API
    -- cannot produce would be a claim rather than a guarantee — the same reasoning `0002` gives for
    -- its two instants.
    start_time          TEXT    NOT NULL,
    end_time            TEXT    NOT NULL,

    -- Sleep performance, as a percentage. **This is the app's own figure and not WHOOP's column.** The
    -- export's `Sleep performance %` is parsed and read by nothing; every stored row holds
    -- `clamp(asleep ÷ need × 100, 0, 100)` computed by the app, so that one formula covers all 910
    -- imported nights and every night after. REAL because it is a derived ratio rather than a reading.
    sleep_performance   REAL    NOT NULL,

    -- The night's requirement, in seconds. Not derived from anything else in this row — a strap
    -- night's is `SleepNeedMath`'s baseline plus a fitted term over the previous day's strain, an
    -- imported night's is WHOOP's own `Sleep need (min)` converted, and the two are different models
    -- that this column deliberately does not distinguish. **A need below the eight-hour baseline
    -- exists in this database and is correct**: 53 of the export's nights carry one, and the formula
    -- cannot produce it.
    total_sleep_needed  REAL    NOT NULL,

    -- The night's four stage totals in seconds. `light + deep + rem` is the asleep total the
    -- performance above divides, and `awake_time` is the fourth row of the same card — the identity
    -- `asleep + awake == duration` is what a reader adding the column up on the screen reaches, so
    -- none of the four is derivable from the other three plus the boundaries without restating the
    -- night's own arithmetic. All four are non-negative and a zero is a real measurement: a night with
    -- no deep sleep at all is in the bundled export (2024-12-10, 15h40m of light).
    light_sleep         REAL    NOT NULL,
    deep_sleep          REAL    NOT NULL,
    rem_sleep           REAL    NOT NULL,
    awake_time          REAL    NOT NULL,

    -- Breaths per minute, derived from the R-R series rather than read off a sensor — so it exists
    -- only for a night whose beats can support an estimate, and is NULL otherwise. Undefaulted,
    -- because a plausible constant here would be a fabricated reading on every night the estimator
    -- declined to produce one.
    respiratory_rate    REAL,

    -- How many times the night's sleep was disturbed. Exists only for a night the actigraphy
    -- classifier could read, so it is NULL on every imported night — the export has no such column.
    disturbance_count   INTEGER,

    -- WHOOP's own Sleep Consistency for the night, a whole percent. Nullable for two separate reasons
    -- and both are real states: a row written before the client's `v9` has none, and a strap night
    -- with fewer than four priors has none either. A `0` would be a claim — a night maximally
    -- inconsistent with its own history — which is why this is undefaulted.
    sleep_consistency   INTEGER,

    -- The accumulated Sleep Debt for the night, in seconds. **The two producers are different
    -- quantities and only one of them is a term of the need above it**: WHOOP's need is a total that
    -- contains `need_from_sleep_debt`, while `SleepNeedMath` omits any debt term, so `need − debt` is
    -- WHOOP's base-plus-strain on an imported night and a base requirement short by the whole deficit
    -- on a strap night. Nothing but `source` distinguishes them, which is why the app's breakdown card
    -- gates on provenance rather than on this column being non-NULL.
    sleep_debt          REAL,

    -- The night's stage timeline, one segment per 30-second epoch in the order they occurred, as
    -- **JSON text**. This Worker never reads into it: it is a client-encoded blob that is stored and
    -- handed back unchanged, which is why the column is opaque here and why the wire carries it as a
    -- string rather than as an array of objects. Two things about its interior are worth knowing
    -- before writing one by hand: the segment `Date`s are **unix milliseconds**, and an empty array is
    -- never written — a night with no stages and a night that was never staged are the same thing, and
    -- `nil` is that thing's only representation.
    sleep_stages        TEXT,

    -- Provenance ('whoop_export', …). Nullable and undefaulted, matching the local column: NULL is the
    -- honest value for "this app measured it" and for every row written before the column existed. It
    -- carries more weight on this table than on any other, because it is the only marker separating
    -- two producers of `sleep_performance`, `sleep_consistency`, `sleep_debt` and `respiratory_rate`.
    source              TEXT,

    -- The day-key convention stated as a constraint — one row per (owner, night) — and that constraint
    -- is also this table's only index. It *is* the index the single-day read and the range read both
    -- use (`WHERE user_id = ? AND date >= ? AND date <= ? ORDER BY date`), so a separate index on
    -- (user_id, date) would be a byte-for-byte duplicate of it. SQLite reports this one as
    -- `sqlite_autoindex_sleeps_1`.
    PRIMARY KEY (user_id, date)
);
