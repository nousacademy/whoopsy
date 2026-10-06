import type { Env } from "../env";
import { HRV_METRICS, type HrvMetric, type Recovery, type RecoveryRepository } from "../domain";

/**
 * The D1 adapter for `recoveries`.
 *
 * **The only file in this Worker that names a table or a column.** That is not layering for its own
 * sake: a column name paired with a property name in two places is two answers to "what does the
 * schema look like", and this repo has already paid for that once — `RecoveryRecord`'s `CodingKeys`
 * map `skinTemp` to `skin_temperature` and `spo2` to `spo2_percentage`, so the wire names and the
 * column names genuinely differ, and a second mapper would be a second chance to get that wrong.
 *
 * There is **no `?? 0` anywhere in this file**, and its absence is the load. NULL comes back from D1
 * as `null` and goes out as `null`; the whole point of the nullable columns is that a reading the
 * strap did not report is *absent* rather than zero, and a defensive default here would silently
 * convert every unmeasured night into a measured flatline. That is a rule about **column values**, and
 * it is why `upsertMany`'s `meta.changes` is read as the number the driver types it as rather than
 * defaulted — the one place a tally appears in this file is not a reading, and it is not the
 * exception that reopens the rule. Grep for `??` before adding one to a bindings list or a mapper.
 */

/**
 * A row exactly as D1 hands it back — snake_case, and every nullable column `| null`.
 *
 * Spelled out rather than derived from `Recovery` so the compiler holds both ends of the mapping:
 * adding a property to `Recovery` without adding it here is a type error in `toRecovery`, which is
 * the one place a new column can be forgotten.
 */
interface RecoveryRow {
  readonly user_id: string;
  readonly date: string;
  readonly recovery_score: number;
  readonly resting_heart_rate: number;
  readonly hrv_value_ms: number;
  readonly hrv_metric: string;
  readonly skin_temperature: number | null;
  readonly spo2_percentage: number | null;
  readonly respiratory_rate: number | null;
  readonly source: string | null;
}

/**
 * The columns, named once because three statements select them and a `SELECT *` would make the
 * mapper's contract depend on the table's column order — which a later `ALTER TABLE` is free to
 * change without any file here mentioning it.
 */
const COLUMNS = [
  "user_id",
  "date",
  "recovery_score",
  "resting_heart_rate",
  "hrv_value_ms",
  "hrv_metric",
  "skin_temperature",
  "spo2_percentage",
  "respiratory_rate",
  "source",
].join(", ");

/**
 * Map a row to the domain type.
 *
 * The `hrv_metric` arm **throws** rather than falling back to `"rmssd"`. A default here would be the
 * precise failure this project's absence rules exist to prevent: RMSSD and SDNN are different
 * quantities on different scales and never share a baseline, so coercing an unrecognised value into
 * one of them would put a real number on a row under the wrong name and mis-score every baseline
 * that day joined. The column is `NOT NULL` and the only writer is this Worker, behind a Zod union —
 * so an unrecognised value means something wrote outside the contract, and a 500 naming the value is
 * a better outcome than a plausible wrong answer.
 */
function toRecovery(row: RecoveryRow): Recovery {
  return {
    userId: row.user_id,
    date: row.date,
    recoveryScore: row.recovery_score,
    restingHeartRate: row.resting_heart_rate,
    hrvValueMs: row.hrv_value_ms,
    hrvMetric: parseHrvMetric(row.hrv_metric),
    skinTemperature: row.skin_temperature,
    spo2Percentage: row.spo2_percentage,
    respiratoryRate: row.respiratory_rate,
    source: row.source,
  };
}

function parseHrvMetric(value: string): HrvMetric {
  const known = HRV_METRICS.find((metric) => metric === value);
  if (known === undefined) {
    throw new Error(
      `recoveries.hrv_metric holds ${JSON.stringify(value)}, which is not a known metric`,
    );
  }
  return known;
}

const UPSERT = `
  INSERT INTO recoveries (${COLUMNS})
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT (user_id, date) DO UPDATE SET
    recovery_score     = excluded.recovery_score,
    resting_heart_rate = excluded.resting_heart_rate,
    hrv_value_ms       = excluded.hrv_value_ms,
    hrv_metric         = excluded.hrv_metric,
    skin_temperature   = excluded.skin_temperature,
    spo2_percentage    = excluded.spo2_percentage,
    respiratory_rate   = excluded.respiratory_rate,
    source             = excluded.source
`;

const SELECT_DAY = `SELECT ${COLUMNS} FROM recoveries WHERE user_id = ? AND date = ?`;

const SELECT_RANGE = `
  SELECT ${COLUMNS} FROM recoveries
  WHERE user_id = ? AND date >= ? AND date <= ?
  ORDER BY date ASC
`;

export class D1RecoveryRepository implements RecoveryRepository {
  constructor(private readonly db: D1Database) {}

  /** Construct from the Worker's bindings. The composition root's one line of wiring. */
  static from(env: Env): D1RecoveryRepository {
    return new D1RecoveryRepository(env.DB);
  }

  async findByDay(userId: string, date: string): Promise<Recovery | null> {
    const row = await this.db
      .prepare(SELECT_DAY)
      .bind(userId, date)
      .first<RecoveryRow>();

    // `null`, never a zero-filled record. An unmeasured day is an absent row in this project, and the
    // caller — not this file — decides that absence is a 404.
    return row === null ? null : toRecovery(row);
  }

  async listRange(userId: string, from: string, to: string): Promise<Recovery[]> {
    // Both bounds inclusive, `ORDER BY date ASC`. The keys are `YYYY-MM-DD`, which sorts
    // lexicographically in date order, so this is a plain string comparison and no date function
    // touches the column — which also means the primary key's index is usable for the range.
    const { results } = await this.db
      .prepare(SELECT_RANGE)
      .bind(userId, from, to)
      .all<RecoveryRow>();

    // A day with no row is simply not in the array. There is nothing to filter out and nothing to
    // fill in: the absence is already the shape of the answer.
    return results.map(toRecovery);
  }

  async upsert(recovery: Recovery): Promise<Recovery> {
    // One statement, one write. `ON CONFLICT … DO UPDATE` is the D1 spelling of the app's `save`,
    // which is INSERT-or-UPDATE by primary key — so a second PUT on one day updates the row rather
    // than inserting a neighbour, which is the whole reason `date` is in the primary key.
    await this.db.prepare(UPSERT).bind(...bindings(recovery)).run();

    // Read back rather than `RETURNING`. The semantics are identical and it is still exactly one
    // write; what it buys is that the answer is provably what is on disk rather than what was sent,
    // which is the assertion `PUT` exists to make — a `null` that came back as a `0` would be caught
    // here and nowhere else. If the read-back ever answers `null` the write silently did not land,
    // which is worth a 500 rather than a 404, so it throws.
    const stored = await this.findByDay(recovery.userId, recovery.date);
    if (stored === null) {
      throw new Error(`recoveries upsert on ${recovery.date} reported success but the row is absent`);
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
   * The cap on how many rows may arrive is **not** here — it is `MAX_BATCH_ROWS` in the service, which
   * is the layer that owns that number, and the schema publishes it. This method accepts whatever it
   * is handed, because a port that silently truncated a list would be the worst possible place to
   * discover the limit.
   */
  async upsertMany(recoveries: readonly Recovery[]): Promise<number> {
    // `batch([])` is a question with no answer, and the service refuses an empty list before it gets
    // here — but a port that threw on it would be a trap for the next caller, so it answers the
    // truthful `0`.
    if (recoveries.length === 0) {
      return 0;
    }

    const statement = this.db.prepare(UPSERT);
    const results = await this.db.batch(
      recoveries.map((recovery) => statement.bind(...bindings(recovery))),
    );

    // `upsert`'s read-back throw has a counterpart here, and this is it: the database must have
    // answered once per row. A batch whose results are short is a mangled statement list — a bug that
    // would otherwise be invisible, since every row that *did* land landed in the right place and the
    // range would simply be missing days that `COUNT(*)` could not distinguish from days the client
    // never sent.
    if (results.length !== recoveries.length) {
      throw new Error(
        `recoveries batch of ${recoveries.length} answered with ${results.length} results`,
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
 * this list are the same ten names, and a mismatch is a value written into the wrong column — which
 * SQLite will accept whenever the types happen to line up, and which nothing downstream can detect.
 */
function bindings(recovery: Recovery): (string | number | null)[] {
  return [
    recovery.userId,
    recovery.date,
    recovery.recoveryScore,
    recovery.restingHeartRate,
    recovery.hrvValueMs,
    recovery.hrvMetric,
    recovery.skinTemperature,
    recovery.spo2Percentage,
    recovery.respiratoryRate,
    recovery.source,
  ];
}
