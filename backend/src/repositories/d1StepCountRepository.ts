import type { Env } from "../env";
import type { StepCount, StepCountRepository } from "../domain";

/**
 * The D1 adapter for `stepCounts`.
 *
 * **The only file in this Worker that names this table or its columns.** That is not layering for its
 * own sake: a column name paired with a property name in two places is two answers to "what does the
 * schema look like", and this resource is one of the two where guessing goes wrong — the app's local
 * `stepCounts` table is **camelCase** (`StepCountRecord` declares no `CodingKeys`, so its property
 * names *are* its column names) while every table this Worker owns is snake_case, including this one.
 * The two namings meet here and nowhere else.
 *
 * **This is the shortest adapter in the Worker, and every absence in it is a decision.** No nullable
 * column, so no `?? …` and no `null` in the bindings type's interesting half; no boolean, so no
 * `parseHasMeasurement`-style parser and no `? 1 : 0`; no vocabulary column, so no `parseHrvMetric`;
 * and no `source`, so the row type has four fields and the bindings list four values. What is left is
 * the shape every day-keyed resource's adapter has.
 *
 * **There is still no default of any kind, and on this resource that rule has teeth.** `measuredSeconds`
 * is the field that separates a measured day from a day nothing measured, so a `?? 0` on the way in or
 * on the way out would convert one state into the other and nothing downstream could tell. Column
 * values cross this file unchanged; the only number computed here is `upsertMany`'s `changes` tally,
 * which is a report from the driver rather than a reading. Grep for `??` before adding one to a
 * binding list or a mapper.
 */

/**
 * A row exactly as D1 hands it back — snake_case, and not one nullable column.
 *
 * Spelled out rather than derived from `StepCount` so the compiler holds both ends of the mapping:
 * adding a property to `StepCount` without adding it here is a type error in `toStepCount`, which is
 * the one place a new column can be forgotten.
 */
interface StepCountRow {
  readonly user_id: string;
  readonly date: string;
  readonly step_count: number;
  readonly measured_seconds: number;
}

/**
 * The columns, named once because three statements select them and a `SELECT *` would make the
 * mapper's contract depend on the table's column order — which a later `ALTER TABLE` is free to
 * change without any file here mentioning it.
 */
const COLUMNS = ["user_id", "date", "step_count", "measured_seconds"].join(", ");

/**
 * Map a row to the domain type.
 *
 * Four straight copies. There is nothing to parse, nothing to convert and nothing to default: the
 * table has no boolean column and no nullable one, so an absent value is a schema disagreement the row
 * type has already stated rather than a case to handle — and a `0` here is a `0` because the writer
 * put it there, which on `measured_seconds` is the difference the replacement of this file's `?? 0`
 * with a straight copy preserves.
 */
function toStepCount(row: StepCountRow): StepCount {
  return {
    userId: row.user_id,
    date: row.date,
    stepCount: row.step_count,
    measuredSeconds: row.measured_seconds,
  };
}

const UPSERT = `
  INSERT INTO step_counts (${COLUMNS})
  VALUES (?, ?, ?, ?)
  ON CONFLICT (user_id, date) DO UPDATE SET
    step_count        = excluded.step_count,
    measured_seconds  = excluded.measured_seconds
`;

const SELECT_DAY = `SELECT ${COLUMNS} FROM step_counts WHERE user_id = ? AND date = ?`;

const SELECT_RANGE = `
  SELECT ${COLUMNS} FROM step_counts
  WHERE user_id = ? AND date >= ? AND date <= ?
  ORDER BY date ASC
`;

export class D1StepCountRepository implements StepCountRepository {
  constructor(private readonly db: D1Database) {}

  /** Construct from the Worker's bindings. The composition root's one line of wiring. */
  static from(env: Env): D1StepCountRepository {
    return new D1StepCountRepository(env.DB);
  }

  async findByDay(userId: string, date: string): Promise<StepCount | null> {
    const row = await this.db.prepare(SELECT_DAY).bind(userId, date).first<StepCountRow>();

    // `null`, never a zero-filled record. A day with no row is an absent row in this project, and the
    // caller — not this file — decides that absence is a 404. Unlike `strains` there is no second kind
    // of row to consider: this table has no `has_measurement` column, so a row that exists is a day
    // the strap was worn, whatever the count beside it says.
    return row === null ? null : toStepCount(row);
  }

  async listRange(userId: string, from: string, to: string): Promise<StepCount[]> {
    // Both bounds inclusive, `ORDER BY date ASC`. The keys are `YYYY-MM-DD`, which sorts
    // lexicographically in date order, so this is a plain string comparison and no date function
    // touches the column — which also means the primary key's index is usable for the range.
    const { results } = await this.db
      .prepare(SELECT_RANGE)
      .bind(userId, from, to)
      .all<StepCountRow>();

    // A day with no row is simply not in the array. There is nothing to filter out and nothing to
    // fill in: the absence is already the shape of the answer, and on this resource a gap in the
    // middle of the range is the ordinary case rather than an edge.
    return results.map(toStepCount);
  }

  async upsert(stepCount: StepCount): Promise<StepCount> {
    // One statement, one write. `ON CONFLICT … DO UPDATE` is the D1 spelling of the app's `save`,
    // which is INSERT-or-UPDATE by primary key — so a second PUT on one day updates the row rather
    // than inserting a neighbour, which is the whole reason `date` is in the primary key.
    await this.db.prepare(UPSERT).bind(...bindings(stepCount)).run();

    // Read back rather than `RETURNING`. The semantics are identical and it is still exactly one
    // write; what it buys is that the answer is provably what is on disk rather than what was sent,
    // which is the assertion `PUT` exists to make — and on this resource specifically, a
    // `measuredSeconds` of `0` that came back as something else, or a `stepCount` that came back
    // defaulted, would be caught here and nowhere else. If the read-back answers `null` the write
    // silently did not land, which is worth a 500 rather than a 404, so it throws.
    const stored = await this.findByDay(stepCount.userId, stepCount.date);
    if (stored === null) {
      throw new Error(
        `step counts upsert on ${stepCount.date} reported success but the row is absent`,
      );
    }
    return stored;
  }

  /**
   * One `batch()`, one transaction.
   *
   * `D1Database.batch` is the mechanism and it is chosen for a property rather than for speed: D1
   * runs the statements it is handed inside an implicit transaction and rolls the whole thing back if
   * any of them fails, so a chunk is **all or nothing**. That is the contract `upsertMany` promises
   * the sync above it — a request that fails is a request that wrote nothing, and therefore one that
   * can be retried without reconciling a half-applied range.
   *
   * **One prepared statement, bound many times.** `bind` returns a new statement rather than mutating
   * the one it is called on, so the single `prepare` here compiles once and the array below is 200
   * independent bindings of it. Binding the same statement object repeatedly instead would send the
   * batch's last row 200 times, which every row's key would accept and no row count would reveal.
   *
   * The cap on how many rows may arrive is **not** here — it is `MAX_BATCH_STEP_COUNTS` in the
   * service, which is the layer that owns that number, and the schema publishes it. This method
   * accepts whatever it is handed, because a port that silently truncated a list would be the worst
   * possible place to discover the limit.
   */
  async upsertMany(stepCounts: readonly StepCount[]): Promise<number> {
    // `batch([])` is a question with no answer, and the service refuses an empty list before it gets
    // here — but a port that threw on it would be a trap for the next caller, so it answers the
    // truthful `0`.
    if (stepCounts.length === 0) {
      return 0;
    }

    const statement = this.db.prepare(UPSERT);
    const results = await this.db.batch(
      stepCounts.map((stepCount) => statement.bind(...bindings(stepCount))),
    );

    // `upsert`'s read-back throw has a counterpart here, and this is it: the database must have
    // answered once per row. A batch whose results are short is a mangled statement list — a bug that
    // would otherwise be invisible, since every row that *did* land landed in the right place and the
    // range would simply be missing days that `COUNT(*)` could not distinguish from days the client
    // never sent.
    if (results.length !== stepCounts.length) {
      throw new Error(
        `step counts batch of ${stepCounts.length} answered with ${results.length} results`,
      );
    }

    // Summed rather than counted: `meta.changes` is SQLite's own tally of rows the statements wrote,
    // so the number this returns is a report from the database rather than a restatement of the
    // array's length. For an `INSERT … ON CONFLICT DO UPDATE` a matched row counts as changed even
    // when the values are byte-identical, which is what makes a replayed chunk report the same
    // number as the first send rather than reporting zero.
    return results.reduce((total, result) => total + result.meta.changes, 0);
  }
}

/**
 * Positional bindings, in `COLUMNS` order.
 *
 * A function rather than an inline array so the order is stated once: the `INSERT`'s column list and
 * this list are the same four names, and a mismatch is a value written into the wrong column — which
 * SQLite will accept whenever the types happen to line up, and which nothing downstream can detect.
 *
 * The return type still names `null` because the port's other implementations may pass one through and
 * this signature is the family's; nothing in this resource's own mapping can produce one, and the
 * absence is the point rather than an oversight.
 */
function bindings(stepCount: StepCount): (string | number | null)[] {
  return [stepCount.userId, stepCount.date, stepCount.stepCount, stepCount.measuredSeconds];
}
