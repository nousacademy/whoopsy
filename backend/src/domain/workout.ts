/**
 * The `workouts` aggregate, as a shape rather than a table.
 *
 * This file knows a *shape*, not a table: no SQL, no column name, no `D1Database`. The adapter
 * behind it (`d1WorkoutRepository.ts`) is the only file in the Worker that names a table or a
 * column, which is what lets a service be exercised against an in-memory fake of this interface
 * with no database in the room.
 *
 * **The aggregate is three things read as one.** A session owns an ordered list of GPS fixes and an
 * ordered list of splits; the app writes all three in one transaction (`saveWorkout`), deletes all
 * three explicitly (`deleteWorkout`), and fetches the children per session on every read
 * (`GRDBWorkoutRepository.makeSessions`). Three endpoints over one aggregate would allow a
 * half-written session — a route stored against a workout that was never written — so there is one
 * pair of read/write methods and the children ride inside the session.
 *
 * **A session's identity is its `id`, not its day.** A day holds several workouts, so `date` is an
 * ordinary field rather than the key: this is the one place in the Worker where the day-key rule is
 * deliberately not the rule. See `migrations/0002_create_workouts.sql`.
 *
 * **`date` is the device's day, and the Worker cannot compute it.** It is `startOfDay(startedAt)`
 * in the client's own calendar, which a UTC server cannot derive from an instant: a 22:40 session
 * is the 22nd to a caller in New York and the 23rd to one in Berlin, and both are right. It is
 * therefore carried on the wire and stored verbatim, and nothing here cross-checks it against
 * `startedAt`.
 *
 * **`null` is an absence on every optional field, and it is never a zero.** `steps: null` is "no
 * motion was seen", which is a different answer from a measured `0`; `strain: null` is a session
 * that measured nothing (a fast), not a session that scored nothing; `hrZonePercents: null` is a
 * session with no zone block, which is not `[0, 0, 0, 0, 0]` — that array is a real reading of a
 * session that never left zone 1, and 45 of the app's 673 imported rows carry it. `?? 0` must not
 * appear anywhere in the adapter.
 */

/**
 * The id shape the app can read back.
 *
 * Not decoration, and not a general-purpose UUID rule: `GRDBWorkoutRepository.makeSessions` builds a
 * `UUID` from each stored id and **silently skips the row** when that fails. So an id this Worker
 * accepted but the app cannot parse is a row that is written, is returned by every read here, and
 * appears on no screen — an import that reports success and delivers nothing, which is the exact
 * failure the app's own docs record against string ids. Refusing it at the boundary is what makes
 * the two sides agree about what a stored session is.
 *
 * It is allowed to be any version and either case, because `UUID(uuidString:)` is: the app mints v4
 * ids for a live session and derives ids from instants for an import, and neither carries a
 * meaningful version nibble.
 */
export const WORKOUT_ID_PATTERN =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

/**
 * How many zone shares a block carries: WHOOP's five bands, zone 1 first.
 *
 * A named constant rather than a `5` in three places, because the three places disagreeing is
 * invisible — the schema would accept four, the adapter would store four, and the screen would draw
 * a short column with a band missing.
 */
export const ZONE_COUNT = 5;

/** One GPS fix on a session's route. */
export interface WorkoutRoutePoint {
  /** The app's own row id. Carried so a round trip restores a local database, not just a picture. */
  readonly id: string;
  readonly latitude: number;
  readonly longitude: number;
  /** An instant, in the canonical form `parseInstant` accepts. */
  readonly timestamp: string;
  readonly heartRate: number;
}

/** One lap of a session. No producer exists yet — there is no lap model in the app. */
export interface WorkoutSplit {
  readonly id: string;
  readonly elapsed: number;
  readonly strain: number;
}

/** A recorded session and everything filed under it. */
export interface Workout {
  readonly userId: string;
  /** The session's identity. A UUID string — see `WORKOUT_ID_PATTERN`. */
  readonly id: string;
  /** The device's day key: `YYYY-MM-DD`, `startOfDay(startedAt)` in the client's calendar. */
  readonly date: string;
  /** An instant. Sorts lexicographically because the wire form is fixed-width UTC. */
  readonly startedAt: string;
  readonly endedAt: string;
  /**
   * The five zone shares, in the app's order (zone 1 first), or `null` for a session with no zone
   * block. Five whole percents summing to at most 100 — the remainder is time below zone 1, which
   * belongs to no band, so a session that never reached zone 1 is `[0, 0, 0, 0, 0]` and not `null`.
   */
  readonly hrZonePercents: readonly number[] | null;
  readonly strain: number | null;
  readonly averageHeartRate: number | null;
  readonly maxHeartRate: number | null;
  /** `null` for a session this app recorded; a producer label (`"whoop_export"`) otherwise. */
  readonly source: string | null;
  readonly activityName: string | null;
  /** `null` is "no motion seen", which is not a measured `0`. */
  readonly steps: number | null;
  readonly offlineRegionID: string | null;
  readonly route: readonly WorkoutRoutePoint[];
  readonly splits: readonly WorkoutSplit[];
}

/**
 * The storage the service is written against.
 *
 * Three methods rather than five, because the children have no identity of their own outside their
 * session: there is no `saveRoutePoint` and no read that returns one, so a route fix is only ever
 * written as part of the session that owns it.
 *
 * **`listWindow` answers the day-keyed question and there is deliberately no `covering` sibling.**
 * The app reads two things over that column: *which day is this row filed on* (`getWorkouts(for:)`)
 * and *which sessions were underway on this day* (`getWorkouts(covering:)`, a half-open overlap
 * that draws an 86-hour fast on all five of its days). Only the first is published here, and the
 * reason is that the second needs the **device's** midnight instant — the overlap is
 * `started_at < day.startOfNextDay(deviceZone) && ended_at > day.startOfDay(deviceZone)`, and a UTC
 * Worker handed a `YYYY-MM-DD` key cannot reconstruct either bound. Publishing it would mean
 * answering a question about a timezone the request does not carry, wrong by hours for every
 * caller, and wrong in the one direction that looks plausible: a session near midnight filed on the
 * neighbouring day. It is a presentation question and the device answers it locally, from the rows
 * this window read hands it.
 */
export interface WorkoutRepository {
  /** One session with its children, or `null` when the partition holds no such id. */
  findById(userId: string, id: string): Promise<Workout | null>;
  /**
   * Sessions filed on the days `from`…`to` inclusive, oldest first, each with its children.
   *
   * Ordered by `date`, then `started_at`, then `id`: two sessions on one day have a stable order
   * here, because a client diffing two responses should see the same list twice.
   */
  listWindow(userId: string, from: string, to: string): Promise<Workout[]>;
  /**
   * Write one session and its children as a unit, answering what is now stored.
   *
   * INSERT-or-UPDATE by `(user_id, id)`, mirroring GRDB's `save`: a re-sent session is a new
   * measurement of the same session, not a duplicate row. The children are replaced rather than
   * merged — the request carries the whole array, so an empty one is an affirmative "this session
   * has no route" and must clear a stored one.
   */
  upsert(workout: Workout): Promise<Workout>;
  /**
   * Write many sessions as one unit, answering **how many sessions** were written.
   *
   * Not how many rows: a session with a 2,000-point route touches 2,003 rows, and a batch's total
   * would then be a function of how much GPS a run collected rather than of what was sent. The
   * adapter counts the parent upserts alone.
   */
  upsertMany(workouts: readonly Workout[]): Promise<number>;
}
