/**
 * The `stepCounts` port: the domain type and the interface.
 *
 * This file knows a *shape*, not a table. The column names live one file over, in
 * `d1StepCountRepository.ts`, which is the only file in this Worker that names a table or a column —
 * so "what the schema looks like" has exactly one answer and the service above it can be exercised
 * against a fake with no D1 anywhere.
 *
 * There is no vocabulary constant here, where `recovery.ts` has `HRV_METRICS`: a day's step count
 * carries no categorical column at all. There is also no `source`, and that absence is this
 * resource's rather than an oversight — see the migration, and the note on `StepCount` below.
 *
 * **Nothing here is nullable, and that is the whole of what this file is worth reading for.** Every
 * field is a plain number or a plain string, because a day the strap did not measure is an *absent
 * row* rather than a row of nulls: `recoveries`' absence rule, which this resource shares, rather
 * than `sleeps`' six nullable columns. The one distinction the type carries is *inside* a field
 * rather than between fields — see `measuredSeconds`.
 */

/**
 * One day's step count, filed under the day the motion happened on.
 *
 * Mirrors `StepCountRecord` in the iOS app, field for field, with `userId` — the partition the local
 * schema has no equivalent for — and with `date` as a `YYYY-MM-DD` day key rather than an instant.
 * The local record declares no `CodingKeys`, so its property names *are* its column names; that is
 * the phone's convention and not this one's, and the mapping between the two spellings lives in
 * `d1StepCountRepository.ts` alone.
 *
 * **`hasMeasurement` is deliberately not a member here, where the iOS `StepCount` has one.**
 * On the phone it is a *computed* property — `measuredSeconds > 0` — so there is nothing for this
 * Worker to carry: the wire publishes `measuredSeconds` and the client derives the flag from it. That
 * is also why there is no `has_measurement` column and why this resource takes `recoveries`' absence
 * rule rather than `strains`': a day with no row is a 404, and there is no second kind of row to tell
 * apart from a reading.
 *
 * **`stepCount` is a whole number and a measured `0` is a real value.** A day of no walking that the
 * strap did wear is a `0` on a row with positive `measuredSeconds` — not an absent row and not a
 * dash. The pair is what makes that legible: the count says what was counted, the seconds say whether
 * anything was measured at all.
 */
export interface StepCount {
  /** The owner. Carried, not yet trusted: nothing in this Worker verifies it. */
  readonly userId: string;
  /** The day key, `YYYY-MM-DD`. Always `startOfDay` on the device. */
  readonly date: string;

  /**
   * How many steps the strap's pedometer counted that day.
   *
   * The strap is the only producer of this number: the live IMU stream and a banked drain are the
   * same measurement of the same motion by the same sensor, which is why there is no `source` column
   * beside it — one day is routinely fed by both and a per-row label could not be written honestly.
   */
  readonly stepCount: number;

  /**
   * Seconds of motion the count came from, as the accumulator summed it.
   *
   * **This is the field that separates a measured day of no walking from a day nothing measured**,
   * and it is why a default of any kind on it would be a fabricated reading: `measuredSeconds > 0` is
   * the client's `hasMeasurement` and the same test its writer gates on, so a `0` here beside a
   * `stepCount` of `0` would claim the strap was worn and counted nothing.
   */
  readonly measuredSeconds: number;
}

/**
 * The storage port for `stepCounts`.
 *
 * Four methods: read one day, read a range of days, write one day, write many days — the same four
 * `RecoveryRepository`, `SleepRepository` and `StrainRepository` declare, and deliberately not a
 * shared interface with any of them. Four resources that happen to have the same verbs today are four
 * resources; a common port would make every future divergence between them a change to a type all
 * four depend on.
 *
 * Nothing here decides what a missing row *means* — `findByDay` answering `null` is a fact about
 * storage, and turning that into a 404 is the service's job — and nothing here takes a `Request`, a
 * `Response` or a status code.
 *
 * **There is no `hasMeasurement` here, and its absence is this resource's one structural difference
 * from `strains`.** Neither the local table nor this one has such a column, and the entity's own flag
 * is computed from `measuredSeconds`, so a row that exists is a day that was measured and there is no
 * second kind of row for a route to tell apart. The absence rule is therefore `recoveries`'.
 */
export interface StepCountRepository {
  /** The row for one day, or `null` if that day has no row. Never a zero-filled record. */
  findByDay(userId: string, date: string): Promise<StepCount | null>;

  /**
   * The rows in `[from, to]`, **inclusive at both ends**, oldest first.
   *
   * A day with no row is *absent from the array* rather than represented by a placeholder — the same
   * rule `findByDay` follows, and the same rule the other three day-keyed resources follow. On this
   * resource that is the ordinary case rather than an edge: a day the user did not wear the strap is
   * a hole in the middle of the range.
   */
  listRange(userId: string, from: string, to: string): Promise<StepCount[]>;

  /**
   * Insert or replace the row for `stepCount.date`, and answer with the row as it is on disk.
   *
   * The read-back is the point rather than a convenience: `PUT` answers with what the database
   * actually holds, so a caller can see that a `0` was stored as a `0` and that nothing in the write
   * path defaulted `measuredSeconds` — which on this resource is the difference between a measured
   * day of no walking and a day nothing measured.
   *
   * Semantically this is the app's own day-row write, whose GRDB `save` is INSERT-or-UPDATE by
   * primary key.
   */
  upsert(stepCount: StepCount): Promise<StepCount>;

  /**
   * Insert or replace every row in `stepCounts`, **all of them or none of them**, and answer with how
   * many the database reported writing.
   *
   * The atomicity is the contract, not an implementation detail of the adapter: the caller is a sync
   * that resends a chunk it is not sure landed, and a bulk write that partly applied would leave a
   * half-uploaded range that nothing can detect and no retry can repair. A chunk that throws wrote
   * nothing, which is what makes a retry safe.
   *
   * The rows are keyed on `(userId, date)` exactly as `upsert` is, so replaying a chunk is a no-op in
   * effect — every row is rewritten with the values it already holds and `COUNT(*)` does not move.
   *
   * **It deliberately does not read back**, where `upsert` deliberately does. Reading 200 rows back
   * costs a second round trip whose result a syncing client cannot act on, and the property the
   * single-day read-back exists for is asserted here the same way it is anywhere else: by reading the
   * range afterwards. The returned count is the database's own `changes` tally, so it is a report of
   * what was written rather than an echo of what was sent.
   */
  upsertMany(stepCounts: readonly StepCount[]): Promise<number>;
}
