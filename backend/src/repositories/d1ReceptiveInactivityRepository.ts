import type { Env } from "../env";
import type { ReceptiveInactivity, ReceptiveInactivityRepository } from "../domain";

/**
 * The D1 adapter for `receptiveInactivities` — and the only file in the Worker that names this table
 * or its columns.
 *
 * **The wire naming and the column naming differ, and this is the one place they meet.** The wire is
 * camelCase using the app's own property names (`startedAt`), the columns are snake_case
 * (`started_at`), and nothing else in the Worker translates between them. The app's own local table
 * keeps those same camelCase property names as its columns, so the two namings are not merely
 * different conventions — they are two spellings of one row, and this file is where they are allowed
 * to differ.
 *
 * **This adapter is the aggregate's shape with the aggregate removed, and every removal is visible in
 * it.** `workouts` has three tables, a joined child read, a delete-and-reinsert of both children and a
 * count taken off the parent indices of a statement list. Here there is one table, one statement per
 * write, and a `written` that is the plain sum of every `meta.changes` — because an entry is one row
 * with no children, so there is no index list to keep and no arithmetic that could count the wrong
 * thing. What it copies is the key: `PRIMARY KEY (user_id, id)` with `date` an ordinary indexed column,
 * which is what lets a day hold several entries.
 *
 * **Two nullable columns, and neither has a default anywhere in this file.** `note` and `started_at`
 * cross this adapter unchanged in both directions — no `?? ""`, no `?? null`, no `COALESCE`. The column
 * being nullable *is* the absence, so a default here would not be defensive coding; it would erase the
 * distinction between an entry nobody timed and one timed at midnight, and between an entry nobody
 * wrote and one written as an empty string. Grep for `??` before adding one to the bindings list or to
 * the mapper.
 */

/**
 * A row exactly as D1 hands it back — snake_case, and both optional columns `| null`, never optional.
 *
 * Spelled out rather than derived from `ReceptiveInactivity` so the compiler holds both ends of the
 * mapping: adding a property to the entity without adding it here is a type error in
 * `toReceptiveInactivity`, which is the one place a new column can be forgotten.
 */
interface ReceptiveInactivityRow {
  readonly user_id: string;
  readonly id: string;
  readonly date: string;
  readonly name: string;
  readonly note: string | null;
  readonly started_at: string | null;
}

/**
 * The columns, named once because three statements select them and a `SELECT *` would make the
 * mapper's contract depend on the table's column order — which a later `ALTER TABLE` is free to change
 * without any file here mentioning it.
 */
const COLUMNS = ["user_id", "id", "date", "name", "note", "started_at"].join(", ");

/**
 * Map a row to the domain type.
 *
 * Six straight copies, and the two that carry `null` are the interesting ones: `note` and `startedAt`
 * are passed through as they were stored rather than normalised on the way out. A `""` in the `note`
 * column therefore reads back as `""` and a `null` as `null` — the distinction the app's own suite
 * constructs by hand, because the importer never writes the first — and an untimed entry comes back
 * untimed rather than as `00:00:00`, which is a real clock time and would sort and print as one.
 *
 * There is nothing to parse. This resource has no boolean column, no JSON block and no vocabulary
 * column, so unlike the aggregate's adapter there is no parser beside this function and no value that
 * can be rejected here.
 */
function toReceptiveInactivity(row: ReceptiveInactivityRow): ReceptiveInactivity {
  return {
    userId: row.user_id,
    id: row.id,
    date: row.date,
    name: row.name,
    note: row.note,
    startedAt: row.started_at,
  };
}

const UPSERT = `INSERT INTO receptive_inactivities (${COLUMNS}) VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT (user_id, id) DO UPDATE SET
  date = excluded.date,
  name = excluded.name,
  note = excluded.note,
  started_at = excluded.started_at`;

const SELECT_BY_ID = `SELECT ${COLUMNS} FROM receptive_inactivities WHERE user_id = ? AND id = ?`;

/**
 * `NULLS LAST` is load-bearing and is not the default.
 *
 * SQLite sorts NULL **first** in an ascending order, so a plain `ORDER BY date, started_at` would draw
 * a day's untimed entries *above* its timed ones — and since an untimed entry is the ordinary case
 * here rather than the exception (all 62 rows the app bundles are untimed), that is most of a day's
 * rows sitting above the one or two that carry a clock. The app's own
 * `ReceptiveInactivity.isOrderedBefore` states the same three clauses and sorts `nil` last, so the two
 * agree on the order of a day; a client diffing a page against a local read would otherwise see the
 * same rows in two arrangements.
 *
 * `name` is the third clause rather than `id`, because it is the field a reader can see: two untimed
 * entries filed on one day are otherwise in whatever order the table happens to hold them, and the
 * order of a list a client diffs should not be a storage detail. It settles the pair that the first
 * two clauses leave tied, which is exactly the pair an import produces.
 */
const SELECT_WINDOW = `SELECT ${COLUMNS} FROM receptive_inactivities
WHERE user_id = ? AND date >= ? AND date <= ?
ORDER BY date ASC, started_at ASC NULLS LAST, name ASC`;

export class D1ReceptiveInactivityRepository implements ReceptiveInactivityRepository {
  constructor(private readonly db: D1Database) {}

  /** Construct from the Worker's bindings. The composition root's one line of wiring. */
  static from(env: Env): D1ReceptiveInactivityRepository {
    return new D1ReceptiveInactivityRepository(env.DB);
  }

  async findById(userId: string, id: string): Promise<ReceptiveInactivity | null> {
    // Keyed on `(user_id, id)` and never on the id alone. `id` is a UUID the client minted, and a read
    // scoped by it alone would answer with another partition's entry — this Worker's only isolation is
    // the partition column, so the pair is the addressing rule rather than a precaution.
    const row = await this.db
      .prepare(SELECT_BY_ID)
      .bind(userId, id)
      .first<ReceptiveInactivityRow>();

    // `null`, never an empty record. The caller — not this file — decides that absence is a 404.
    return row === null ? null : toReceptiveInactivity(row);
  }

  async listWindow(userId: string, from: string, to: string): Promise<ReceptiveInactivity[]> {
    // Both bounds inclusive. The keys are `YYYY-MM-DD`, which sorts lexicographically in date order, so
    // this is a plain string comparison, no date function touches the column, and
    // `receptive_inactivities_user_date` can serve the range. A single day is `from === to`, which is
    // the app's ordinary per-day read and needs no method of its own.
    const { results } = await this.db
      .prepare(SELECT_WINDOW)
      .bind(userId, from, to)
      .all<ReceptiveInactivityRow>();

    // A day with no row is simply not in the array. There is nothing to filter out and nothing to fill
    // in: on this resource a day holding several entries and a day holding none are both ordinary, so
    // the absence is already the shape of the answer.
    return results.map(toReceptiveInactivity);
  }

  async upsert(activity: ReceptiveInactivity): Promise<ReceptiveInactivity> {
    // One statement, one write. `ON CONFLICT … DO UPDATE` is the D1 spelling of the app's `save`,
    // which is INSERT-or-UPDATE by primary key — so re-sending an entry updates it rather than
    // inserting a neighbour, which is what makes a replayed import a no-op on the row count. There are
    // no children to replace, which is the whole of how this differs from the aggregate's upsert: no
    // `batch()`, because there is no second statement to be atomic with.
    await this.db.prepare(UPSERT).bind(...bindings(activity)).run();

    // Read back rather than `RETURNING`. The semantics are identical and it is still exactly one write;
    // what it buys is that the answer is provably what is on disk rather than what was sent — and on
    // this resource that is the assertion that matters, because the two nullable fields are the ones a
    // stray default would silently fold into `""` or a midnight while the response still looked
    // plausible. If the read-back answers `null` the write did not land, which is worth a 500 rather
    // than a 404, so it throws.
    const stored = await this.findById(activity.userId, activity.id);
    if (stored === null) {
      throw new Error(
        `receptive_inactivities.upsert: ${activity.id} was not readable after being written`,
      );
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
   * reconciling a half-applied run of entries.
   *
   * **One prepared statement, bound many times.** `bind` returns a new statement rather than mutating
   * the one it is called on, so the single `prepare` here compiles once and the array below is `n`
   * independent bindings of it. Binding the same statement object repeatedly instead would send the
   * batch's last entry `n` times, which every entry's key would accept and no row count would reveal.
   *
   * The cap on how many entries may arrive is **not** here — it is `MAX_BATCH_RECEPTIVE_INACTIVITIES`
   * in the service, which is the layer that owns that number, and the schema publishes it. This method
   * accepts whatever it is handed, because a port that silently truncated a list would be the worst
   * possible place to discover the limit.
   */
  async upsertMany(activities: readonly ReceptiveInactivity[]): Promise<number> {
    // `batch([])` is a question with no answer, and the service refuses an empty list before it gets
    // here — but a port that threw on it would be a trap for the next caller, so it answers the
    // truthful `0`.
    if (activities.length === 0) {
      return 0;
    }

    const statement = this.db.prepare(UPSERT);
    const results = await this.db.batch(
      activities.map((activity) => statement.bind(...bindings(activity))),
    );

    // A batch whose results are short is a mangled statement list — a bug that would otherwise be
    // invisible, since every entry that *did* land landed in the right place and the day would simply
    // be missing rows that a count could not distinguish from entries the client never sent.
    if (results.length !== activities.length) {
      throw new Error(
        `receptive inactivities batch of ${activities.length} answered with ${results.length} results`,
      );
    }

    // Summed rather than `activities.length`: `meta.changes` is SQLite's own tally of rows the
    // statements wrote, so this is a report from the database rather than a restatement of the array's
    // length. For an `INSERT … ON CONFLICT DO UPDATE` a matched row counts as changed even when every
    // value is byte-identical, which is what makes a replayed chunk report the same number as the first
    // send rather than reporting zero. **On this resource the sum and the length are the same number**,
    // because an entry is one row and has no children — the aggregate's index-list arithmetic exists
    // only because a session's route would otherwise be counted as sessions.
    return results.reduce((total, result) => total + result.meta.changes, 0);
  }
}

/**
 * Positional bindings, in `COLUMNS` order.
 *
 * A function rather than an inline array so the order is stated once: the `INSERT`'s column list and
 * this list are the same six names, and a mismatch is a value written into the wrong column — which
 * SQLite will accept whenever the types happen to line up, and which nothing downstream can detect.
 *
 * The return type names `null` because two of these six genuinely carry one. This is the longest
 * binding list in the Worker whose nullability is a fact about the resource rather than a fact about
 * one column: an untimed entry and an entry nobody wrote are both ordinary rows here.
 */
function bindings(activity: ReceptiveInactivity): (string | number | null)[] {
  return [
    activity.userId,
    activity.id,
    activity.date,
    activity.name,
    activity.note,
    activity.startedAt,
  ];
}
