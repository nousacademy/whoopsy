import type { Env } from "../env";
import type { BiometricSample, BiometricSampleRepository } from "../domain";

/**
 * The D1 adapter for `biometricSamples` — and the only file in the Worker that names this table or
 * its columns.
 *
 * **The wire naming and the column naming differ, and this is the one place they meet.** The wire is
 * camelCase using the app's *record* property names (`accelX`, `skinTemp`, `spo2Percentage`), the
 * columns are snake_case (`accel_x`, `skin_temp`, `spo2_percentage`), and nothing else in the Worker
 * translates between them. The names are the record's and not the entity's, which is the app's own
 * rule: `BiometricSample` says `accelerometerX` and `skinTemperatureCelsius` while its
 * `BiometricSampleRecord` — the row, and therefore the shape this table mirrors — says `accelX` and
 * `skinTemp`. The record is what crosses the wire; see `d1SleepRepository.ts`'s header for the same
 * rule stated on a resource where it is less obvious.
 *
 * **This is the only adapter in the Worker that handles JSON, and `d1SleepRepository.ts` is the file
 * that says a sibling does not.** That one states, of `sleeps.sleep_stages`, that it "does not import
 * `JSON`, and that is the point": the column holds an opaque blob the Worker neither reads nor
 * validates. `rr_intervals_ms` is the deliberate exception, and the distinction is what the two
 * quantities are made of. A sleep-stage segment carries interior `Date`s in unix milliseconds — an
 * encoding a decoder would have to *agree* about rather than merely parse — while a `[Double]` has no
 * interior to disagree about. So the series is published as an array of numbers, which is the honest
 * self-describing shape for it, rather than as a string that is secretly JSON and that every reader
 * would have to be told is one. One quantity, one column, one meaning — and it subsumes the app's
 * legacy lossy `rrIntervalMs` scalar, which is deliberately not carried here at all.
 *
 * **Every optional column crosses this file unchanged in both directions: no `?? 0`, no `?? null`, no
 * `COALESCE`.** The column being nullable *is* the absence, so a default here would not be defensive
 * coding — it would put a reading on a row whose channel said nothing. A `0.0` accelerometer axis is
 * the worst of them (free fall, on the *still* side of every movement threshold), and a defaulted
 * `is_on_body` would be an answer to a question the strap did not answer. Grep for `??` before adding
 * one to the bindings list or to the mapper.
 */

/**
 * A row exactly as D1 hands it back — snake_case, every optional column `| null`, never optional.
 *
 * Spelled out rather than derived from `BiometricSample` so the compiler holds both ends of the
 * mapping: adding a property to the entity without adding it here is a type error in
 * `toBiometricSample`, which is the one place a new column can be forgotten.
 *
 * `rr_intervals_ms` is `string` here and not `number[]`, because that is what the column holds: the
 * decode is a step in the mapper rather than a fact about the row, which is what keeps the parse
 * failure next to the only code that can produce it.
 */
interface BiometricSampleRow {
  readonly user_id: string;
  readonly id: string;
  readonly timestamp: string;
  readonly heart_rate: number;
  readonly rr_intervals_ms: string | null;
  readonly accel_x: number | null;
  readonly accel_y: number | null;
  readonly accel_z: number | null;
  readonly skin_temp: number | null;
  readonly spo2_percentage: number | null;
  readonly is_on_body: number | null;
  readonly is_charging: number | null;
  readonly raw_sequence_number: number | null;
}

/**
 * The columns, named once because three statements select them and a `SELECT *` would make the
 * mapper's contract depend on the table's column order — which a later `ALTER TABLE` is free to
 * change without any file here mentioning it.
 */
const COLUMNS = [
  "user_id",
  "id",
  "timestamp",
  "heart_rate",
  "rr_intervals_ms",
  "accel_x",
  "accel_y",
  "accel_z",
  "skin_temp",
  "spo2_percentage",
  "is_on_body",
  "is_charging",
  "raw_sequence_number",
].join(", ");

/**
 * Map a row to the domain type.
 *
 * Ten straight copies and three parses, and the three are the whole of what this file does that its
 * siblings do not. The R-R series comes back out of JSON, and the two booleans come back out of the
 * `0`/`1` SQLite stores them as.
 *
 * **A column that does not decode throws rather than answering `null`.** That is the opposite of the
 * defensive reading, and it is deliberate: `null` on this resource is the strap's word for *I did not
 * report this channel*, and a malformed R-R column decoded to `null` would tell every consumer
 * downstream that the strap stayed silent rather than that the row is damaged — silently disabling
 * the RMSSD path on a night that has beats in it, which is the fabrication every absence rule in this
 * codebase forbids. A 500 names the row; a fabricated absence names nothing and disables a
 * measurement. So every failure here is loud and none of them is a default.
 */
function toBiometricSample(row: BiometricSampleRow): BiometricSample {
  return {
    userId: row.user_id,
    id: row.id,
    timestamp: row.timestamp,
    heartRate: row.heart_rate,
    rrIntervalsMs: parseRrIntervals(row.rr_intervals_ms),
    accelX: row.accel_x,
    accelY: row.accel_y,
    accelZ: row.accel_z,
    skinTemp: row.skin_temp,
    spo2Percentage: row.spo2_percentage,
    isOnBody: parseFlag(row.is_on_body, "is_on_body"),
    isCharging: parseFlag(row.is_charging, "is_charging"),
    rawSequenceNumber: row.raw_sequence_number,
  };
}

/**
 * The R-R series out of its JSON text, or `null` when the notification carried none.
 *
 * The value is validated rather than trusted, and the empty array is refused alongside a malformed
 * one. Both refusals are the same rule: the contract publishes **one** spelling of "this
 * notification carried no intervals", and it is `null`. An empty list is a second spelling, which the
 * app's own BLE layer already collapses on the way in, so a stored `[]` means some writer reached the
 * table without passing through the schema — and a reader that accepted it would be maintaining a
 * second convention in the one place that exists to have one. See the DTO's `.min(1)` for the write
 * half of the same rule.
 *
 * **A negative interval is refused for that same reason and not because it would crash anything.** An
 * R-R interval is a duration — the gap between two beats — so there is no such thing as a negative
 * one, and the published schema bounds the field `.nonnegative()`. A stored negative is therefore
 * proof of the same thing a stored `[]` is: a writer that did not pass through the contract. It is the
 * argument `parseFlag` makes below about values outside a published set, and it is worth making here
 * explicitly because the failure is quiet — a negative interval sums into a shorter series and
 * differences into a *larger* RMSSD, so it reads as a calmer night rather than as a corrupt row.
 */
function parseRrIntervals(value: string | null): readonly number[] | null {
  if (value === null) {
    return null;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error(`biometric_samples.rr_intervals_ms holds ${JSON.stringify(value)}, which is not JSON`);
  }

  // Three tests rather than one, and each refuses a different way of being a non-measurement.
  //
  // `Number.isFinite` rather than `typeof === "number"`, because `JSON.parse` can produce neither
  // `NaN` nor `Infinity` but a hand-written row can hold both spellings, and either one propagated
  // into a successive-difference statistic is a number that is not a measurement.
  //
  // The non-negativity test is the contract's own bound — `BiometricSampleWriteSchema` declares
  // `.nonnegative()` — restated where the value comes back out. That restatement is the point of this
  // function rather than a duplication of it: a bound enforced only on the way in is a bound on the
  // API, and this adapter is the only reader of a column that a migration, a backfill or a `wrangler d1
  // execute` can write to without any schema seeing it. A row that got in another way is refused here
  // or it is served as a measurement, and the second of those is the failure this file exists to
  // prevent.
  if (
    !Array.isArray(parsed) ||
    parsed.length === 0 ||
    !parsed.every((entry) => typeof entry === "number" && Number.isFinite(entry) && entry >= 0)
  ) {
    throw new Error(
      `biometric_samples.rr_intervals_ms holds ${JSON.stringify(value)}, which is not a non-empty array of non-negative finite numbers`,
    );
  }

  return parsed as number[];
}

/**
 * A `0`/`1` column read as the boolean it stands for, or `null` when the strap did not say.
 *
 * A truthiness test would be wrong here — `Boolean(1)` and `Boolean(2)` are both `true`, and `2` is a
 * value no writer of this column can produce — so anything outside the set is a throw naming the
 * value, mirroring `parseHasMeasurement` in `d1StrainRepository.ts`. The nullable case is this
 * resource's own addition: `NULL` is not a third truth value, it is the channel being absent, and it
 * passes through untouched rather than being resolved to one of the two answers the app's own mapper
 * would pick.
 */
function parseFlag(value: number | null, column: string): boolean | null {
  if (value === null) {
    return null;
  }

  if (value === 0) {
    return false;
  }

  if (value === 1) {
    return true;
  }

  throw new Error(`biometric_samples.${column} holds ${JSON.stringify(value)}, which is neither 0 nor 1`);
}

const UPSERT = `INSERT INTO biometric_samples (${COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (user_id, id) DO UPDATE SET
  timestamp = excluded.timestamp,
  heart_rate = excluded.heart_rate,
  rr_intervals_ms = excluded.rr_intervals_ms,
  accel_x = excluded.accel_x,
  accel_y = excluded.accel_y,
  accel_z = excluded.accel_z,
  skin_temp = excluded.skin_temp,
  spo2_percentage = excluded.spo2_percentage,
  is_on_body = excluded.is_on_body,
  is_charging = excluded.is_charging,
  raw_sequence_number = excluded.raw_sequence_number`;

const SELECT_BY_ID = `SELECT ${COLUMNS} FROM biometric_samples WHERE user_id = ? AND id = ?`;

/**
 * An instant range rather than a day range, and the two bounds are inclusive.
 *
 * `timestamp` is stored in one canonical UTC spelling, so this is a plain string comparison: no date
 * function touches the column and `biometric_samples_user_timestamp` serves the range. That is the
 * reason the contract fixes the spelling to exactly three fractional digits and a `Z` — a format with
 * more than one spelling is a format whose comparisons are somebody's guess about which spelling the
 * other side used.
 *
 * **The second clause is a tiebreak, and it is not arrival order.** The app orders `timestamp ASC, id
 * ASC` too, but its `id` is a local autoincrement and therefore *is* arrival order; this one is
 * client-derived and therefore arbitrary. The primary order is reproduced exactly and two samples
 * sharing a millisecond get a stable order here without getting their original one — a client must
 * not read the tiebreak as meaning anything. The index is on `(user_id, timestamp)` and cannot serve
 * the `id` clause, which is a sort over one millisecond's rows rather than over the window.
 */
const SELECT_WINDOW = `SELECT ${COLUMNS} FROM biometric_samples
WHERE user_id = ? AND timestamp >= ? AND timestamp <= ?
ORDER BY timestamp ASC, id ASC`;

export class D1BiometricSampleRepository implements BiometricSampleRepository {
  constructor(private readonly db: D1Database) {}

  /** Construct from the Worker's bindings. The composition root's one line of wiring. */
  static from(env: Env): D1BiometricSampleRepository {
    return new D1BiometricSampleRepository(env.DB);
  }

  async findById(userId: string, id: string): Promise<BiometricSample | null> {
    // Keyed on `(user_id, id)` and never on the id alone. `id` is a client-derived string, and a read
    // scoped by it alone would answer with another partition's sample — this Worker's only isolation is
    // the partition column, so the pair is the addressing rule rather than a precaution.
    const row = await this.db.prepare(SELECT_BY_ID).bind(userId, id).first<BiometricSampleRow>();

    // `null`, never an empty record. The caller — not this file — decides that absence is a 404.
    return row === null ? null : toBiometricSample(row);
  }

  async listWindow(userId: string, from: string, to: string): Promise<BiometricSample[]> {
    // Both bounds inclusive, which is the app's own read: an instant range has no natural half-open
    // form the way a day chunk does, and a chunked sync overlapping at one millisecond re-sends that
    // sample as an upsert of an identical row rather than as a duplicate.
    const { results } = await this.db
      .prepare(SELECT_WINDOW)
      .bind(userId, from, to)
      .all<BiometricSampleRow>();

    // A window the strap did not cover is an empty array and not an error. On this resource that is the
    // ordinary answer — no strap has filled this table on any database this Worker has run against —
    // and there is nothing to fill in, because a sample the app never recorded has no value to guess.
    return results.map(toBiometricSample);
  }

  async upsert(sample: BiometricSample): Promise<BiometricSample> {
    // One statement, one write. `ON CONFLICT … DO UPDATE` is the D1 spelling of the app's `save`, which
    // is INSERT-or-UPDATE by primary key — so re-sending a sample updates it rather than inserting a
    // neighbour, which is what makes a replayed chunk a no-op on the row count. There are no children
    // to replace: an R-R interval is a number in a column rather than a row of its own, because it has
    // no identity to address and the app's own `v8` stores it the same way.
    await this.db.prepare(UPSERT).bind(...bindings(sample)).run();

    // Read back rather than `RETURNING`. The semantics are identical and it is still exactly one write;
    // what it buys is that the answer is provably what is on disk rather than what was sent — and on
    // this resource that is the assertion that matters, because nine of these thirteen columns are
    // nullable and a stray default anywhere in the binding list would be invisible in the response. If
    // the read-back answers `null` the write did not land, which is worth a 500 rather than a 404, so it
    // throws.
    const stored = await this.findById(sample.userId, sample.id);
    if (stored === null) {
      throw new Error(`biometric_samples.upsert: ${sample.id} was not readable after being written`);
    }

    return stored;
  }

  /**
   * One `batch()`, one transaction.
   *
   * `D1Database.batch` is the mechanism and it is chosen for a property rather than for speed: D1 runs
   * the statements it is handed inside an implicit transaction and rolls the whole thing back if any of
   * them fails, so a chunk is **all or nothing**. That is the contract the sync above it depends on — a
   * request that fails is a request that wrote nothing, and therefore one that can be retried without
   * reconciling a half-applied run of samples.
   *
   * **One prepared statement, bound many times.** `bind` returns a new statement rather than mutating
   * the one it is called on, so the single `prepare` here compiles once and the array below is `n`
   * independent bindings of it. Binding the same statement object repeatedly instead would send the
   * batch's last sample `n` times, which every sample's key would accept and no row count would reveal.
   *
   * The cap on how many samples may arrive is **not** here — it is `MAX_BATCH_BIOMETRIC_SAMPLES` in the
   * service, which is the layer that owns that number, and the schema publishes it. This method accepts
   * whatever it is handed, because a port that silently truncated a list would be the worst possible
   * place to discover the limit.
   */
  async upsertMany(samples: readonly BiometricSample[]): Promise<number> {
    // `batch([])` is a question with no answer, and the service refuses an empty list before it gets
    // here — but a port that threw on it would be a trap for the next caller, so it answers the
    // truthful `0`.
    if (samples.length === 0) {
      return 0;
    }

    const statement = this.db.prepare(UPSERT);
    const results = await this.db.batch(samples.map((sample) => statement.bind(...bindings(sample))));

    // A batch whose results are short is a mangled statement list — a bug that would otherwise be
    // invisible, since every sample that *did* land landed in the right place and the window would
    // simply be missing rows that a count could not distinguish from samples the client never sent.
    if (results.length !== samples.length) {
      throw new Error(
        `biometric samples batch of ${samples.length} answered with ${results.length} results`,
      );
    }

    // Summed rather than `samples.length`: `meta.changes` is SQLite's own tally of rows the statements
    // wrote, so this is a report from the database rather than a restatement of the array's length. For
    // an `INSERT … ON CONFLICT DO UPDATE` a matched row counts as changed even when every value is
    // byte-identical, which is what makes a replayed chunk report the same number as the first send
    // rather than reporting zero. **On this resource the sum and the length are the same number**,
    // because a sample is one row and has no children.
    return results.reduce((total, result) => total + result.meta.changes, 0);
  }
}

/**
 * Positional bindings, in `COLUMNS` order.
 *
 * A function rather than an inline array so the order is stated once: the `INSERT`'s column list and
 * this list are the same thirteen names, and a mismatch is a value written into the wrong column —
 * which SQLite will accept whenever the types happen to line up, and which nothing downstream can
 * detect. On this resource that is a live risk rather than a theoretical one: nine of these thirteen
 * are numbers, so an off-by-one among the accelerometer axes or the two percentages type-checks.
 *
 * **The two conversions happen here and only here.** The R-R series is `JSON.stringify`ed, because
 * SQLite has no array type and the column is `TEXT`; and the two booleans are written as `0`/`1`,
 * because SQLite has no boolean storage and the columns carry a `CHECK (… IN (0, 1))`. Both are the
 * inverse of a parse in the mapper above, and `null` passes through both untouched — the one value
 * that must never be converted, because it is the strap's own word for a channel it did not report.
 */
function bindings(sample: BiometricSample): (string | number | null)[] {
  return [
    sample.userId,
    sample.id,
    sample.timestamp,
    sample.heartRate,
    sample.rrIntervalsMs === null ? null : JSON.stringify(sample.rrIntervalsMs),
    sample.accelX,
    sample.accelY,
    sample.accelZ,
    sample.skinTemp,
    sample.spo2Percentage,
    sample.isOnBody === null ? null : sample.isOnBody ? 1 : 0,
    sample.isCharging === null ? null : sample.isCharging ? 1 : 0,
    sample.rawSequenceNumber,
  ];
}
