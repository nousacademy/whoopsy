import type { Env } from "../env";
import type { Sleep, SleepRepository } from "../domain";

/**
 * The D1 adapter for `sleeps`.
 *
 * **The only file in this Worker that names a table or a column.** That is not layering for its own
 * sake: a column name paired with a property name in two places is two answers to "what does the
 * schema look like", and on this table the pairing is the widest in the Worker — sixteen columns, six
 * of them nullable, and three of those six backed by a model on the client that would happily produce a
 * number if a `??` here invited one.
 *
 * There is **no `?? 0` anywhere in this file**, and its absence is the load. `respiratory_rate` comes
 * back from D1 as `null` and goes out as `null`; a defensive default here would turn "the estimator
 * declined, the series could not support one" into `14.0` breaths per minute on a night nobody
 * measured a breath on — and `sleep_debt`'s equivalent would turn a night WHOOP declined to score into
 * a night in perfect credit. Grep for `??` before adding one to a bindings list or a mapper.
 *
 * **`sleep_stages` is opaque here and there is no JSON in this file at all.** The column holds the
 * client's own encoding of the night's timeline and this Worker never reads into it: the string is
 * bound on the way in and copied on the way out, byte for byte. Parsing it would be a second decoder
 * that has to agree with the app's `Codable` one forever, and it would have to agree about a detail
 * the wire's own instant format does not cover — the `Date`s inside that blob are unix *milliseconds*.
 * So this file does not import `JSON`, and that is the point.
 */

/**
 * A row exactly as D1 hands it back — snake_case, six columns nullable.
 *
 * Spelled out rather than derived from `Sleep` so the compiler holds both ends of the mapping: adding
 * a property to `Sleep` without adding it here is a type error in `toSleep`, which is the one place a
 * new column can be forgotten.
 */
interface SleepRow {
  readonly user_id: string;
  readonly date: string;
  readonly start_time: string;
  readonly end_time: string;
  readonly sleep_performance: number;
  readonly total_sleep_needed: number;
  readonly light_sleep: number;
  readonly deep_sleep: number;
  readonly rem_sleep: number;
  readonly awake_time: number;
  readonly respiratory_rate: number | null;
  readonly disturbance_count: number | null;
  readonly sleep_consistency: number | null;
  readonly sleep_debt: number | null;
  readonly sleep_stages: string | null;
  readonly source: string | null;
}

/**
 * The columns, named once because three statements select them and a `SELECT *` would make the
 * mapper's contract depend on the table's column order — which a later `ALTER TABLE` is free to
 * change without any file here mentioning it. On a sixteen-column table that is not hypothetical.
 *
 * The order here is the order of `bindings` below and the order of the `INSERT`'s placeholders. Those
 * three lists are one list written three times, which is why they sit adjacent: a mismatch is a value
 * written into the wrong column, and SQLite accepts that silently whenever the types happen to line up
 * — `light_sleep` and `deep_sleep` are both `REAL` and adjacent, so swapping them is a night whose
 * stages changed with nothing anywhere reporting it.
 */
const COLUMNS = [
  "user_id",
  "date",
  "start_time",
  "end_time",
  "sleep_performance",
  "total_sleep_needed",
  "light_sleep",
  "deep_sleep",
  "rem_sleep",
  "awake_time",
  "respiratory_rate",
  "disturbance_count",
  "sleep_consistency",
  "sleep_debt",
  "sleep_stages",
  "source",
].join(", ");

/**
 * Map a row to the domain type.
 *
 * A straight copy of all sixteen fields, and on this table that is a decision worth stating: there is
 * no `?? 0`, no `?? false` and no `Boolean(...)`, because there is no column here that needs
 * interpreting. Three siblings have one — `recoveries`' `hrv_metric` vocabulary, `strains`'
 * `has_measurement` integer, `workouts`' `hr_zone_percents` blob — and this table has none: the six
 * nullable columns are nullable in the domain type too, so their `null` passes through as the same
 * `null` rather than being a case to handle.
 *
 * `sleep_stages` is copied as the string it is. Nothing in this Worker parses it, so nothing here can
 * disagree with the client about what is inside it.
 */
function toSleep(row: SleepRow): Sleep {
  return {
    userId: row.user_id,
    date: row.date,
    startTime: row.start_time,
    endTime: row.end_time,
    sleepPerformance: row.sleep_performance,
    totalSleepNeeded: row.total_sleep_needed,
    lightSleep: row.light_sleep,
    deepSleep: row.deep_sleep,
    remSleep: row.rem_sleep,
    awakeTime: row.awake_time,
    respiratoryRate: row.respiratory_rate,
    disturbanceCount: row.disturbance_count,
    sleepConsistency: row.sleep_consistency,
    sleepDebt: row.sleep_debt,
    sleepStages: row.sleep_stages,
    source: row.source,
  };
}

const UPSERT = `
  INSERT INTO sleeps (${COLUMNS})
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT (user_id, date) DO UPDATE SET
    start_time          = excluded.start_time,
    end_time            = excluded.end_time,
    sleep_performance   = excluded.sleep_performance,
    total_sleep_needed  = excluded.total_sleep_needed,
    light_sleep         = excluded.light_sleep,
    deep_sleep          = excluded.deep_sleep,
    rem_sleep           = excluded.rem_sleep,
    awake_time          = excluded.awake_time,
    respiratory_rate    = excluded.respiratory_rate,
    disturbance_count   = excluded.disturbance_count,
    sleep_consistency   = excluded.sleep_consistency,
    sleep_debt          = excluded.sleep_debt,
    sleep_stages        = excluded.sleep_stages,
    source              = excluded.source
`;

const SELECT_DAY = `SELECT ${COLUMNS} FROM sleeps WHERE user_id = ? AND date = ?`;

const SELECT_RANGE = `
  SELECT ${COLUMNS} FROM sleeps
  WHERE user_id = ? AND date >= ? AND date <= ?
  ORDER BY date ASC
`;

export class D1SleepRepository implements SleepRepository {
  constructor(private readonly db: D1Database) {}

  /** Construct from the Worker's bindings. The composition root's one line of wiring. */
  static from(env: Env): D1SleepRepository {
    return new D1SleepRepository(env.DB);
  }

  async findByDay(userId: string, date: string): Promise<Sleep | null> {
    const row = await this.db.prepare(SELECT_DAY).bind(userId, date).first<SleepRow>();

    // `null`, never a zero-filled record. A night with no row is an absent row in this project — and
    // on this table that is the *only* absence there is, because the local schema carries no
    // `hasMeasurement` flag: a night the classifier could not read is not written at all. So unlike
    // `strains`, where a row that exists is answered whatever it holds, there is no second kind of row
    // for this method to distinguish. The caller decides that `null` is a 404.
    return row === null ? null : toSleep(row);
  }

  async listRange(userId: string, from: string, to: string): Promise<Sleep[]> {
    // Both bounds inclusive, `ORDER BY date ASC`. The keys are `YYYY-MM-DD`, which sorts
    // lexicographically in date order, so this is a plain string comparison and no date function
    // touches the column — which also means the primary key's index is usable for the range.
    const { results } = await this.db.prepare(SELECT_RANGE).bind(userId, from, to).all<SleepRow>();

    // A day with no row is simply not in the array. There is nothing to filter out and nothing to fill
    // in: the absence is already the shape of the answer.
    return results.map(toSleep);
  }

  async upsert(sleep: Sleep): Promise<Sleep> {
    // One statement, one write. `ON CONFLICT … DO UPDATE` is the D1 spelling of the app's `save`,
    // which is INSERT-or-UPDATE by primary key — so a second PUT on one night updates the row rather
    // than inserting a neighbour, which is the whole reason `date` is in the primary key.
    await this.db.prepare(UPSERT).bind(...bindings(sleep)).run();

    // Read back rather than `RETURNING`. The semantics are identical and it is still exactly one
    // write; what it buys is that the answer is provably what is on disk rather than what was sent,
    // which is the assertion `PUT` exists to make — and on this resource that is three nullable fields
    // whose round trip is the only evidence that a model was not silently run over an imported night.
    // If the read-back ever answers `null` the write silently did not land, which is worth a 500
    // rather than a 404, so it throws.
    const stored = await this.findByDay(sleep.userId, sleep.date);
    if (stored === null) {
      throw new Error(`sleeps upsert on ${sleep.date} reported success but the row is absent`);
    }
    return stored;
  }

  /**
   * One `batch()`, one transaction.
   *
   * `D1Database.batch` is the mechanism and it is chosen for a property rather than for speed: D1 runs
   * the statements it is handed inside an implicit transaction and rolls the whole thing back if any
   * of them fails, so a chunk is **all or nothing**. That is the contract `upsertMany` promises the
   * sync above it — a request that fails is a request that wrote nothing, and therefore one that can be
   * retried without reconciling a half-applied range.
   *
   * **One prepared statement, bound many times.** `bind` returns a new statement rather than mutating
   * the one it is called on, so the single `prepare` here compiles once and the array below is 200
   * independent bindings of it. Binding the same statement object repeatedly instead would send the
   * batch's last row 200 times, which every row's key would accept and no row count would reveal.
   *
   * The cap on how many rows may arrive is **not** here — it is `MAX_BATCH_SLEEPS` in the service,
   * which is the layer that owns that number, and the schema publishes it. This method accepts whatever
   * it is handed, because a port that silently truncated a list would be the worst possible place to
   * discover the limit.
   */
  async upsertMany(sleeps: readonly Sleep[]): Promise<number> {
    // `batch([])` is a question with no answer, and the service refuses an empty list before it gets
    // here — but a port that threw on it would be a trap for the next caller, so it answers the
    // truthful `0`.
    if (sleeps.length === 0) {
      return 0;
    }

    const statement = this.db.prepare(UPSERT);
    const results = await this.db.batch(sleeps.map((sleep) => statement.bind(...bindings(sleep))));

    // `upsert`'s read-back throw has a counterpart here, and this is it: the database must have
    // answered once per row. A batch whose results are short is a mangled statement list — a bug that
    // would otherwise be invisible, since every row that *did* land landed in the right place and the
    // range would simply be missing days that `COUNT(*)` could not distinguish from days the client
    // never sent.
    if (results.length !== sleeps.length) {
      throw new Error(`sleeps batch of ${sleeps.length} answered with ${results.length} results`);
    }

    // Summed rather than counted: `meta.changes` is SQLite's own tally of rows the statements wrote,
    // so the number this returns is a report from the database rather than a restatement of the
    // array's length. For an `INSERT … ON CONFLICT DO UPDATE` a matched row counts as changed even
    // when the values are byte-identical, which is what makes a replayed chunk report the same number
    // as the first send rather than reporting zero.
    return results.reduce((total, result) => total + result.meta.changes, 0);
  }
}

/**
 * Positional bindings, in `COLUMNS` order.
 *
 * A function rather than an inline array so the order is stated once: the `INSERT`'s column list, the
 * placeholders and this list are the same sixteen names, and a mismatch is a value written into the
 * wrong column — which SQLite will accept whenever the types happen to line up, and which nothing
 * downstream can detect.
 *
 * The six nullable fields are bound as-is. There is no `?? 0` and no `?? ""` here, and that is the
 * whole of what this resource's write path has to get right: a `null` respiratory rate must reach the
 * column as `NULL`, because the estimator declining and the estimator returning a number are different
 * facts and only one of them is a measurement.
 *
 * `sleepStages` is passed through as the string it is. Nothing here parses or re-serialises it, so
 * what a client PUTs is what a client GETs, byte for byte — which is the whole contract of a sync.
 */
function bindings(sleep: Sleep): (string | number | null)[] {
  return [
    sleep.userId,
    sleep.date,
    sleep.startTime,
    sleep.endTime,
    sleep.sleepPerformance,
    sleep.totalSleepNeeded,
    sleep.lightSleep,
    sleep.deepSleep,
    sleep.remSleep,
    sleep.awakeTime,
    sleep.respiratoryRate,
    sleep.disturbanceCount,
    sleep.sleepConsistency,
    sleep.sleepDebt,
    sleep.sleepStages,
    sleep.source,
  ];
}
