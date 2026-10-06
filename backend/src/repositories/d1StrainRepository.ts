import type { Env } from "../env";
import type { Strain, StrainRepository } from "../domain";

/**
 * The D1 adapter for `strains`.
 *
 * **The only file in this Worker that names a table or a column.** That is not layering for its own
 * sake: a column name paired with a property name in two places is two answers to "what does the
 * schema look like", and this resource is the one where guessing goes wrong — the app's local
 * `strains` table is **camelCase** (`StrainRecord` declares no `CodingKeys`, so its property names
 * *are* its column names) while every table this Worker owns is snake_case, including this one. The
 * two namings meet here and nowhere else.
 *
 * There is **no `?? 0` anywhere in this file**, and its absence is the load. `source` comes back from
 * D1 as `null` and goes out as `null`; a defensive default here would convert a row written before
 * the column existed into one attributed to `""`. That is a rule about **column values**, and it is
 * why `upsertMany`'s `meta.changes` is read as the number the driver types it as rather than
 * defaulted — the one place a tally appears in this file is not a reading, and it is not the
 * exception that reopens the rule. Grep for `??` before adding one to a bindings list or a mapper.
 *
 * `has_measurement` is the one column that is not a reading at all, and it is handled the same way
 * for a different reason: SQLite has no boolean, so the value is an integer that must be `0` or `1`,
 * and the mapper **throws** on anything else rather than picking the truthy branch. See
 * `parseHasMeasurement`.
 */

/**
 * A row exactly as D1 hands it back — snake_case, `source` nullable, `has_measurement` an integer.
 *
 * Spelled out rather than derived from `Strain` so the compiler holds both ends of the mapping:
 * adding a property to `Strain` without adding it here is a type error in `toStrain`, which is the
 * one place a new column can be forgotten.
 */
interface StrainRow {
  readonly user_id: string;
  readonly date: string;
  readonly strain_score: number;
  readonly kilojoules: number;
  readonly average_heart_rate: number;
  readonly max_heart_rate: number;
  readonly has_measurement: number;
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
  "strain_score",
  "kilojoules",
  "average_heart_rate",
  "max_heart_rate",
  "has_measurement",
  "source",
].join(", ");

/**
 * Map a row to the domain type.
 *
 * `has_measurement` goes through `parseHasMeasurement` rather than a truthiness test, and the
 * difference is not pedantry: `Boolean(row.has_measurement)` would read any non-zero integer as
 * measured, including one a hand-run `UPDATE` or a future writer put there. The column has a
 * `CHECK (has_measurement IN (0, 1))` behind it, so a value outside that set means something wrote
 * with the constraint off — and on this column the failure mode is the exact one the flag exists to
 * prevent, a placeholder presenting itself as a reading.
 *
 * Every other field is a straight copy. There is no `?? 0` and no default: `source` is `null` when
 * the column is `NULL`, and the three numeric columns have no nullable spelling at all, so an absent
 * one is a schema disagreement that the row type has already stated rather than a case to handle.
 */
function toStrain(row: StrainRow): Strain {
  return {
    userId: row.user_id,
    date: row.date,
    strainScore: row.strain_score,
    kilojoules: row.kilojoules,
    averageHeartRate: row.average_heart_rate,
    maxHeartRate: row.max_heart_rate,
    hasMeasurement: parseHasMeasurement(row.has_measurement),
    source: row.source,
  };
}

/**
 * The `0`/`1` column read as the boolean it stands for, or a throw naming the value.
 *
 * Modelled on `parseHrvMetric`'s temperament rather than on a cast, and for the same class of
 * reason: a default here would be a plausible wrong answer on a row nothing downstream can check.
 * The asymmetry worth stating is that this one is not about a vocabulary — there are exactly two
 * legal values and the schema says so — so reaching the throw means the constraint was bypassed
 * rather than that a new case was added and this file missed it.
 */
function parseHasMeasurement(value: number): boolean {
  if (value === 0) {
    return false;
  }
  if (value === 1) {
    return true;
  }
  throw new Error(
    `strains.has_measurement holds ${JSON.stringify(value)}, which is neither 0 nor 1`,
  );
}

const UPSERT = `
  INSERT INTO strains (${COLUMNS})
  VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT (user_id, date) DO UPDATE SET
    strain_score        = excluded.strain_score,
    kilojoules          = excluded.kilojoules,
    average_heart_rate  = excluded.average_heart_rate,
    max_heart_rate      = excluded.max_heart_rate,
    has_measurement     = excluded.has_measurement,
    source              = excluded.source
`;

const SELECT_DAY = `SELECT ${COLUMNS} FROM strains WHERE user_id = ? AND date = ?`;

const SELECT_RANGE = `
  SELECT ${COLUMNS} FROM strains
  WHERE user_id = ? AND date >= ? AND date <= ?
  ORDER BY date ASC
`;

export class D1StrainRepository implements StrainRepository {
  constructor(private readonly db: D1Database) {}

  /** Construct from the Worker's bindings. The composition root's one line of wiring. */
  static from(env: Env): D1StrainRepository {
    return new D1StrainRepository(env.DB);
  }

  async findByDay(userId: string, date: string): Promise<Strain | null> {
    const row = await this.db.prepare(SELECT_DAY).bind(userId, date).first<StrainRow>();

    // `null`, never a zero-filled record. A day with no row is an absent row in this project, and the
    // caller — not this file — decides that absence is a 404. Note that this answers a *row*, not a
    // measurement: an unmeasured row that exists comes back holding its zeroes and its `false`, and
    // withholding it is the service's decision rather than this one's.
    return row === null ? null : toStrain(row);
  }

  async listRange(userId: string, from: string, to: string): Promise<Strain[]> {
    // Both bounds inclusive, `ORDER BY date ASC`. The keys are `YYYY-MM-DD`, which sorts
    // lexicographically in date order, so this is a plain string comparison and no date function
    // touches the column — which also means the primary key's index is usable for the range.
    const { results } = await this.db.prepare(SELECT_RANGE).bind(userId, from, to).all<StrainRow>();

    // A day with no row is simply not in the array. There is nothing to filter out and nothing to
    // fill in: the absence is already the shape of the answer.
    return results.map(toStrain);
  }

  async upsert(strain: Strain): Promise<Strain> {
    // One statement, one write. `ON CONFLICT … DO UPDATE` is the D1 spelling of the app's `save`,
    // which is INSERT-or-UPDATE by primary key — so a second PUT on one day updates the row rather
    // than inserting a neighbour, which is the whole reason `date` is in the primary key.
    await this.db.prepare(UPSERT).bind(...bindings(strain)).run();

    // Read back rather than `RETURNING`. The semantics are identical and it is still exactly one
    // write; what it buys is that the answer is provably what is on disk rather than what was sent,
    // which is the assertion `PUT` exists to make — a `null` that came back as a `0`, or a `false`
    // that came back as a `1`, would be caught here and nowhere else. If the read-back ever answers
    // `null` the write silently did not land, which is worth a 500 rather than a 404, so it throws.
    const stored = await this.findByDay(strain.userId, strain.date);
    if (stored === null) {
      throw new Error(`strains upsert on ${strain.date} reported success but the row is absent`);
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
   * The cap on how many rows may arrive is **not** here — it is `MAX_BATCH_STRAINS` in the service,
   * which is the layer that owns that number, and the schema publishes it. This method accepts
   * whatever it is handed, because a port that silently truncated a list would be the worst possible
   * place to discover the limit.
   */
  async upsertMany(strains: readonly Strain[]): Promise<number> {
    // `batch([])` is a question with no answer, and the service refuses an empty list before it gets
    // here — but a port that threw on it would be a trap for the next caller, so it answers the
    // truthful `0`.
    if (strains.length === 0) {
      return 0;
    }

    const statement = this.db.prepare(UPSERT);
    const results = await this.db.batch(strains.map((strain) => statement.bind(...bindings(strain))));

    // `upsert`'s read-back throw has a counterpart here, and this is it: the database must have
    // answered once per row. A batch whose results are short is a mangled statement list — a bug that
    // would otherwise be invisible, since every row that *did* land landed in the right place and the
    // range would simply be missing days that `COUNT(*)` could not distinguish from days the client
    // never sent.
    if (results.length !== strains.length) {
      throw new Error(`strains batch of ${strains.length} answered with ${results.length} results`);
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
 * this list are the same eight names, and a mismatch is a value written into the wrong column — which
 * SQLite will accept whenever the types happen to line up, and which nothing downstream can detect.
 *
 * The boolean is converted here and **only** here (`? 1 : 0`), because SQLite has no boolean storage
 * class and a driver left to guess at one is a driver whose guess is a version's behaviour rather
 * than this file's statement. `parseHasMeasurement` is the other half of that pair.
 */
function bindings(strain: Strain): (string | number | null)[] {
  return [
    strain.userId,
    strain.date,
    strain.strainScore,
    strain.kilojoules,
    strain.averageHeartRate,
    strain.maxHeartRate,
    strain.hasMeasurement ? 1 : 0,
    strain.source,
  ];
}
