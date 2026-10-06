import type { Env } from "../env";
import {
  ZONE_COUNT,
  type Workout,
  type WorkoutRepository,
  type WorkoutRoutePoint,
  type WorkoutSplit,
} from "../domain";

/**
 * The D1 implementation of `WorkoutRepository` — and the only file in the Worker that names one of
 * the three workout tables, or any of their columns.
 *
 * Mirrors the app's local `v6_recorded_workouts` schema column for column, plus two things the
 * local schema has no equivalent for: the `user_id` owner on all three tables, and `seq` on the two
 * children. Both are argued in `migrations/0002_create_workouts.sql`; the short version is that this
 * Worker's isolation is the partition column and the app's route order is a property of a local file
 * that a shared table has to be told about.
 *
 * **The wire naming and the column naming differ, and this is the one place they meet.** The wire is
 * camelCase using the app's own record property names (`hrZonePercents`, `offlineRegionID`); the
 * columns are snake_case. Nothing else in the Worker translates between them — a second mapper would
 * be a second answer to "what is this field called over there".
 *
 * Four things the writes do that are worth knowing before changing any of them:
 *
 * **A write is a batch, so it is one transaction.** The parent upsert, both child deletes and every
 * child insert go into a single `db.batch()`, which D1 runs atomically. That is `saveWorkout`'s
 * shape, and it is what makes "the children are whatever this request said they are" true rather
 * than eventually true.
 *
 * **The children are deleted and re-inserted rather than merged.** The request carries the whole
 * array, so an empty route is an affirmative claim that the session has none — it has to clear a
 * stored one, or a user who turned route recording off and re-synced would keep the old path
 * forever. This is also why the schema makes `route` and `splits` required fields rather than
 * optional ones: a body that could omit `route` would silently wipe a stored route, and the failure
 * would look like data loss with no request that looks wrong.
 *
 * **The delete is keyed on `(user_id, workout_id)` and not on the id alone.** A delete scoped only
 * by `workout_id` crosses partitions, and the app's own `deleteWorkout` carries the same pair for
 * the same reason.
 *
 * **`written` counts sessions, not rows.** A session with a 2,000-point route touches 2,003 rows in
 * the batch, so summing every statement's `meta.changes` would make the batch's answer a function of
 * how much GPS a run collected. Only the parent upserts are summed.
 */

/** A `workouts` row as D1 hands it back. Every nullable column is `| null`, never optional. */
interface WorkoutRow {
  readonly user_id: string;
  readonly id: string;
  readonly date: string;
  readonly started_at: string;
  readonly ended_at: string;
  readonly strain: number | null;
  readonly average_heart_rate: number | null;
  readonly max_heart_rate: number | null;
  readonly source: string | null;
  readonly activity_name: string | null;
  readonly hr_zone_percents: string | null;
  readonly steps: number | null;
  readonly offline_region_id: string | null;
}

interface RoutePointRow {
  readonly id: string;
  readonly workout_id: string;
  readonly latitude: number;
  readonly longitude: number;
  readonly timestamp: string;
  readonly heart_rate: number;
}

interface SplitRow {
  readonly id: string;
  readonly workout_id: string;
  readonly elapsed: number;
  readonly strain: number;
}

const WORKOUT_COLUMNS = [
  "user_id",
  "id",
  "date",
  "started_at",
  "ended_at",
  "strain",
  "average_heart_rate",
  "max_heart_rate",
  "source",
  "activity_name",
  "hr_zone_percents",
  "steps",
  "offline_region_id",
].join(", ");

/**
 * The child column lists, held as field names rather than written into the SQL twice.
 *
 * **The two lists exist because one of the two reads that use them is a join.** The window's children
 * are fetched in one statement per child table, joined to `workouts` so the window's day bounds scope
 * them — and in that statement a bare `id` is **ambiguous**, because `workouts` has one too. D1
 * refuses it with `D1_ERROR: ambiguous column name: id at offset 7`, which is a 500 on every window
 * read that has any children at all: the single-session read is a plain select and works, so the
 * defect is unreachable from `GET /v1/workouts/{id}` and shows up only on the list endpoint.
 *
 * Writing the fields once and prefixing them for the joined reads is what keeps the two spellings
 * from drifting: the selects the join does not touch stay unqualified, and the pair stays one list.
 */
const ROUTE_POINT_FIELDS = ["id", "workout_id", "latitude", "longitude", "timestamp", "heart_rate"];

const SPLIT_FIELDS = ["id", "workout_id", "elapsed", "strain"];

const ROUTE_POINT_COLUMNS = ROUTE_POINT_FIELDS.join(", ");

const SPLIT_COLUMNS = SPLIT_FIELDS.join(", ");

/** The same lists against the children's own alias `p`, for the two joined window reads below. */
const ROUTE_POINT_COLUMNS_OF_P = ROUTE_POINT_FIELDS.map((field) => `p.${field}`).join(", ");

const SPLIT_COLUMNS_OF_P = SPLIT_FIELDS.map((field) => `p.${field}`).join(", ");

/**
 * Read one stored session into the domain shape.
 *
 * The zone block is decoded here rather than in a caller, and a value that is not five numbers
 * **throws** instead of being coerced: a row this Worker did not write is not a row to guess about,
 * and defaulting it to `null` would erase the difference between a corrupt block and a session that
 * has none. Same rule as `parseHrvMetric` in the recoveries adapter.
 */
function parseHrZonePercents(value: string): number[] {
  const parsed: unknown = JSON.parse(value);

  if (!Array.isArray(parsed) || parsed.some((share) => typeof share !== "number")) {
    throw new Error(
      `workouts.hr_zone_percents holds ${JSON.stringify(value)}, which is not a JSON array of numbers`,
    );
  }

  if (parsed.length !== ZONE_COUNT) {
    throw new Error(
      `workouts.hr_zone_percents holds ${parsed.length} shares, and a zone block is ${ZONE_COUNT}`,
    );
  }

  return parsed as number[];
}

function toWorkout(
  row: WorkoutRow,
  route: readonly WorkoutRoutePoint[],
  splits: readonly WorkoutSplit[],
): Workout {
  return {
    userId: row.user_id,
    id: row.id,
    date: row.date,
    startedAt: row.started_at,
    endedAt: row.ended_at,
    strain: row.strain,
    averageHeartRate: row.average_heart_rate,
    maxHeartRate: row.max_heart_rate,
    source: row.source,
    activityName: row.activity_name,
    hrZonePercents:
      row.hr_zone_percents === null ? null : parseHrZonePercents(row.hr_zone_percents),
    steps: row.steps,
    offlineRegionID: row.offline_region_id,
    route,
    splits,
  };
}

function toRoutePoint(row: RoutePointRow): WorkoutRoutePoint {
  return {
    id: row.id,
    latitude: row.latitude,
    longitude: row.longitude,
    timestamp: row.timestamp,
    heartRate: row.heart_rate,
  };
}

function toSplit(row: SplitRow): WorkoutSplit {
  return { id: row.id, elapsed: row.elapsed, strain: row.strain };
}

const UPSERT = `INSERT INTO workouts (${WORKOUT_COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (user_id, id) DO UPDATE SET
  date = excluded.date,
  started_at = excluded.started_at,
  ended_at = excluded.ended_at,
  strain = excluded.strain,
  average_heart_rate = excluded.average_heart_rate,
  max_heart_rate = excluded.max_heart_rate,
  source = excluded.source,
  activity_name = excluded.activity_name,
  hr_zone_percents = excluded.hr_zone_percents,
  steps = excluded.steps,
  offline_region_id = excluded.offline_region_id`;

const SELECT_BY_ID = `SELECT ${WORKOUT_COLUMNS} FROM workouts WHERE user_id = ? AND id = ?`;

// Both ends inclusive, oldest first. The tie-breaks after `date` are what make two sessions on one
// day come back in a stable order — `started_at` is a fixed-width UTC instant, so it sorts
// chronologically as text, and `id` settles two sessions that started in the same millisecond.
const SELECT_WINDOW = `SELECT ${WORKOUT_COLUMNS} FROM workouts
WHERE user_id = ? AND date >= ? AND date <= ?
ORDER BY date ASC, started_at ASC, id ASC`;

const DELETE_ROUTE_POINTS = "DELETE FROM workout_route_points WHERE user_id = ? AND workout_id = ?";

const DELETE_SPLITS = "DELETE FROM workout_splits WHERE user_id = ? AND workout_id = ?";

// `seq` is bound from the array's own index, which is what makes `ORDER BY seq` a round trip rather
// than a sort.
const INSERT_ROUTE_POINT = `INSERT INTO workout_route_points
  (user_id, id, workout_id, seq, latitude, longitude, timestamp, heart_rate)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)`;

const INSERT_SPLIT = `INSERT INTO workout_splits
  (user_id, id, workout_id, seq, elapsed, strain)
VALUES (?, ?, ?, ?, ?, ?)`;

const SELECT_ROUTE_POINTS_FOR_WORKOUT = `SELECT ${ROUTE_POINT_COLUMNS} FROM workout_route_points
WHERE user_id = ? AND workout_id = ?
ORDER BY seq ASC`;

const SELECT_SPLITS_FOR_WORKOUT = `SELECT ${SPLIT_COLUMNS} FROM workout_splits
WHERE user_id = ? AND workout_id = ?
ORDER BY seq ASC`;

// The window's children in one query rather than one per session: a 673-session window would
// otherwise be 674 round trips. The join is what scopes them, and it reads the `(user_id, date)`
// index on `workouts` — no id list is bound, so this does not meet D1's 100-parameter ceiling
// however many sessions the window holds.
//
// **Every column is qualified against the children's own alias, and the alias is not decoration.**
// Both of these select over `workout_route_points p JOIN workouts w`, and both tables carry an `id`,
// a `user_id` and a `date`-adjacent set of names — so an unqualified `id` in the select list is an
// error rather than a preference, and an unqualified `user_id` in the predicate would silently scope
// the read by the *session's* owner rather than the child's. Qualifying all of them, rather than only
// the one the parser complains about, is what keeps a column added to these tables from arriving
// ambiguous.
const SELECT_ROUTE_POINTS_IN_WINDOW = `SELECT ${ROUTE_POINT_COLUMNS_OF_P} FROM workout_route_points p
JOIN workouts w ON w.user_id = p.user_id AND w.id = p.workout_id
WHERE p.user_id = ? AND w.date >= ? AND w.date <= ?
ORDER BY p.workout_id ASC, p.seq ASC`;

const SELECT_SPLITS_IN_WINDOW = `SELECT ${SPLIT_COLUMNS_OF_P} FROM workout_splits p
JOIN workouts w ON w.user_id = p.user_id AND w.id = p.workout_id
WHERE p.user_id = ? AND w.date >= ? AND w.date <= ?
ORDER BY p.workout_id ASC, p.seq ASC`;

/** Group child rows by the session they belong to, preserving the order the query returned them in. */
function groupByWorkout<Row extends { readonly workout_id: string }>(
  rows: readonly Row[],
): Map<string, Row[]> {
  const grouped = new Map<string, Row[]>();

  for (const row of rows) {
    const existing = grouped.get(row.workout_id);
    if (existing === undefined) {
      grouped.set(row.workout_id, [row]);
    } else {
      existing.push(row);
    }
  }

  return grouped;
}

function bindings(workout: Workout): (string | number | null)[] {
  return [
    workout.userId,
    workout.id,
    workout.date,
    workout.startedAt,
    workout.endedAt,
    workout.strain,
    workout.averageHeartRate,
    workout.maxHeartRate,
    workout.source,
    workout.activityName,
    // A `[Double]?` has no column type of its own — D1 has no array binding — so the block is
    // JSON-encoded into a `.text` column, exactly as the app stores it locally.
    workout.hrZonePercents === null ? null : JSON.stringify(workout.hrZonePercents),
    workout.steps,
    workout.offlineRegionID,
  ];
}

/**
 * One session's statements, **with the parent upsert first**.
 *
 * That ordering is a contract rather than an implementation detail: `upsertMany` needs to know which
 * result indices are parent upserts in order to count sessions rather than rows, and it reads that
 * off the position rather than off a second parallel array.
 *
 * A session with no children still emits both deletes. That is three statements where one would do
 * for a session that has never had a route, and it is the price of the rule above: the deletes are
 * what make an empty array mean "no route" instead of "no change".
 */
function statementsFor(db: D1Database, workout: Workout): D1PreparedStatement[] {
  const statements: D1PreparedStatement[] = [
    db.prepare(UPSERT).bind(...bindings(workout)),
    db.prepare(DELETE_ROUTE_POINTS).bind(workout.userId, workout.id),
  ];

  workout.route.forEach((point, seq) => {
    statements.push(
      db
        .prepare(INSERT_ROUTE_POINT)
        .bind(
          workout.userId,
          point.id,
          workout.id,
          seq,
          point.latitude,
          point.longitude,
          point.timestamp,
          point.heartRate,
        ),
    );
  });

  statements.push(db.prepare(DELETE_SPLITS).bind(workout.userId, workout.id));

  workout.splits.forEach((split, seq) => {
    statements.push(
      db.prepare(INSERT_SPLIT).bind(workout.userId, split.id, workout.id, seq, split.elapsed, split.strain),
    );
  });

  return statements;
}

export class D1WorkoutRepository implements WorkoutRepository {
  constructor(private readonly db: D1Database) {}

  static from(env: Env): D1WorkoutRepository {
    return new D1WorkoutRepository(env.DB);
  }

  async findById(userId: string, id: string): Promise<Workout | null> {
    const row = await this.db
      .prepare(SELECT_BY_ID)
      .bind(userId, id)
      .first<WorkoutRow>();

    if (row === null) {
      return null;
    }

    return this.attach(userId, row);
  }

  async listWindow(userId: string, from: string, to: string): Promise<Workout[]> {
    const { results } = await this.db
      .prepare(SELECT_WINDOW)
      .bind(userId, from, to)
      .all<WorkoutRow>();

    if (results.length === 0) {
      // Two more queries would both come back empty. A window the export never covered is the
      // ordinary case on a fresh install, and it should cost one statement.
      return [];
    }

    const points = groupByWorkout(
      (
        await this.db
          .prepare(SELECT_ROUTE_POINTS_IN_WINDOW)
          .bind(userId, from, to)
          .all<RoutePointRow>()
      ).results,
    );

    const splits = groupByWorkout(
      (
        await this.db.prepare(SELECT_SPLITS_IN_WINDOW).bind(userId, from, to).all<SplitRow>()
      ).results,
    );

    return results.map((row) =>
      toWorkout(
        row,
        (points.get(row.id) ?? []).map(toRoutePoint),
        (splits.get(row.id) ?? []).map(toSplit),
      ),
    );
  }

  async upsert(workout: Workout): Promise<Workout> {
    await this.db.batch(statementsFor(this.db, workout));

    const stored = await this.findById(workout.userId, workout.id);
    if (stored === null) {
      // Unreachable unless the batch silently discarded the upsert, which is a defect worth a 500
      // rather than an answer that describes a row which is not there. `upsert` in the recoveries
      // adapter throws here for the same reason.
      throw new Error(`workouts.upsert: ${workout.id} was not readable after being written`);
    }

    return stored;
  }

  async upsertMany(workouts: readonly Workout[]): Promise<number> {
    if (workouts.length === 0) {
      return 0;
    }

    const statements: D1PreparedStatement[] = [];
    const parentIndices: number[] = [];

    for (const workout of workouts) {
      parentIndices.push(statements.length);
      statements.push(...statementsFor(this.db, workout));
    }

    const results = await this.db.batch(statements);

    let written = 0;
    for (const index of parentIndices) {
      const result = results[index];
      if (result !== undefined) {
        written += result.meta.changes;
      }
    }

    return written;
  }

  private async attach(userId: string, row: WorkoutRow): Promise<Workout> {
    const points = await this.db
      .prepare(SELECT_ROUTE_POINTS_FOR_WORKOUT)
      .bind(userId, row.id)
      .all<RoutePointRow>();

    const splits = await this.db
      .prepare(SELECT_SPLITS_FOR_WORKOUT)
      .bind(userId, row.id)
      .all<SplitRow>();

    return toWorkout(row, points.results.map(toRoutePoint), splits.results.map(toSplit));
  }
}
