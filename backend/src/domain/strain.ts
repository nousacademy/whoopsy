/**
 * The `strains` port: the domain type and the interface.
 *
 * This file knows a *shape*, not a table. The column names live one file over, in
 * `d1StrainRepository.ts`, which is the only file in this Worker that names a table or a column — so
 * "what the schema looks like" has exactly one answer and the service above it can be exercised
 * against a fake with no D1 anywhere.
 *
 * There is no vocabulary constant here, where `recovery.ts` has `HRV_METRICS`: a strain row carries
 * no categorical column. Its one non-numeric field is `hasMeasurement`, and that is a boolean the
 * schema and the column both state directly rather than a set anything is derived from.
 */

/**
 * One day's strain reading.
 *
 * Mirrors `StrainRecord` in the iOS app, field for field, with `userId` — the partition the local
 * schema has no equivalent for — and with `date` as a `YYYY-MM-DD` day key rather than an instant.
 *
 * **`hasMeasurement` is carried and not inferred, and this type is where that is most visible.** The
 * app's `StrainScore.hasMeasurement` is the same claim, and its own doc gives the reason a score
 * cannot stand in for it: a genuine rest day is representable as `0.0`, WHOOP's export scores exactly
 * `0.0` on two real days, and a legacy placeholder left by a build before `v7` holds `0.0` as well.
 * So the flag is the only thing that separates them, and it is read here exactly as it is read there.
 *
 * `kilojoules` is the stored unit, not a derived figure: the entity's `activeCalories` is converted
 * through `4.184` on the way in. A `0` in it is therefore a legitimate measured value — a scored day
 * with no weight on file — and never an absence. `null` is reserved for a column that can genuinely
 * be absent, which here is `source` alone.
 */
export interface Strain {
  /** The owner. Carried, not yet trusted: nothing in this Worker verifies it. */
  readonly userId: string;
  /** The day key, `YYYY-MM-DD`. Always `startOfDay` on the device, expressed as a calendar day. */
  readonly date: string;
  /** WHOOP's 0–21 scale. `0` is a real score; `hasMeasurement` is what says whether anyone took it. */
  readonly strainScore: number;
  /** Kilojoules. `0` is a legitimate measured value — see the note above. */
  readonly kilojoules: number;
  /** `0` on an unmeasured row, which is why this is non-negative rather than positive. */
  readonly averageHeartRate: number;
  /** `0` on an unmeasured row, for the same reason. */
  readonly maxHeartRate: number;
  /** Whether the two figures above are readings. The one thing `strainScore` cannot tell you. */
  readonly hasMeasurement: boolean;
  /** Provenance (`whoop_export`, …). NULL when this app measured it, and on every pre-column row. */
  readonly source: string | null;
}

/**
 * The storage port for `strains`.
 *
 * Four methods: read one day, read a range of days, write one day, write many days — the same four
 * `RecoveryRepository` declares, and deliberately not a shared interface with it. Two resources that
 * happen to have the same verbs today are two resources; a common port would make every future
 * divergence between them a change to a type both depend on.
 *
 * Nothing here decides what a missing row *means* — `findByDay` answering `null` is a fact about
 * storage, and turning that into a 404 is the service's job — and nothing here takes a `Request`, a
 * `Response` or a status code.
 */
export interface StrainRepository {
  /** The row for one day, or `null` if that day has no row. Never a zero-filled record. */
  findByDay(userId: string, date: string): Promise<Strain | null>;

  /**
   * The rows in `[from, to]`, **inclusive at both ends**, oldest first.
   *
   * A day with no row is *absent from the array* rather than represented by a placeholder — the same
   * rule `findByDay` follows, and the reason the return type is a plain array rather than something
   * with holes in it. Note that this is a fact about rows and not about measurements: an unmeasured
   * row that exists is returned, because it is a row. Withholding it is a decision, and decisions
   * belong to the service.
   */
  listRange(userId: string, from: string, to: string): Promise<Strain[]>;

  /**
   * Insert or replace the row for `strain.date`, and answer with the row as it is on disk.
   *
   * The read-back is the point rather than a convenience: `PUT` answers with what the database
   * actually holds, so a caller can see that a `null` stayed `null` and was not folded into a `0` by
   * a default somewhere in the write path — and, on this resource, that a `false` stayed `false`
   * rather than arriving back as the `1` the column stores. Semantically this is the app's
   * `saveStrain`, whose GRDB `save` is INSERT-or-UPDATE by primary key.
   */
  upsert(strain: Strain): Promise<Strain>;

  /**
   * Insert or replace every row in `strains`, **all of them or none of them**, and answer with how
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
  upsertMany(strains: readonly Strain[]): Promise<number>;
}
