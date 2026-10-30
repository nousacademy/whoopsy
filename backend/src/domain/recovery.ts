/**
 * The `recoveries` port: the domain type and the interface.
 *
 * This file knows a *shape*, not a table. The column names live one file over, in
 * `d1RecoveryRepository.ts`, which is the only file in this Worker that names a table or a column —
 * so "what the schema looks like" has exactly one answer and the service above it can be exercised
 * against a fake with no D1 anywhere.
 *
 * The optional fields are `| null` rather than `?`, and that is a decision rather than a style. An
 * absent *key* and a key holding `null` are different claims — the first says nothing, the second
 * says "measured, and there was nothing there" — and this project has a standing rule that a
 * nullable column round-trips as NULL and never as a defaulted `0` or `""`. A `?` would let a mapper
 * drop a key by accident and still typecheck.
 */

/**
 * Which quantity `hrvValueMs` is. RMSSD and SDNN are different distributions and never share a
 * baseline.
 *
 * A const array with the type derived from it, rather than a bare union, so the vocabulary has one
 * source: the column's parser in the adapter and the Zod enum published in the OpenAPI document are
 * both built from this, and adding a metric is one line here instead of two lists that can disagree.
 */
export const HRV_METRICS = ["rmssd", "sdnn"] as const;

export type HrvMetric = (typeof HRV_METRICS)[number];

/**
 * One day's recovery reading.
 *
 * Mirrors `RecoveryRecord` in the iOS app, field for field, with `userId` — the partition the local
 * schema has no equivalent for — and with `date` as a `YYYY-MM-DD` day key rather than an instant.
 */
export interface Recovery {
  /** The owner. Carried, not yet trusted: nothing in this Worker verifies it. */
  readonly userId: string;
  /** The day key, `YYYY-MM-DD`. Always `startOfDay` on the device, expressed as a calendar day. */
  readonly date: string;
  readonly recoveryScore: number;
  readonly restingHeartRate: number;
  readonly hrvValueMs: number;
  readonly hrvMetric: HrvMetric;
  /** NULL — not `0` — when the strap did not report one. */
  readonly skinTemperature: number | null;
  readonly spo2Percentage: number | null;
  readonly respiratoryRate: number | null;
  /** Provenance (`whoop_export`, …). NULL when this app measured it, and on every pre-column row. */
  readonly source: string | null;
}

/**
 * The storage port for `recoveries`.
 *
 * Five methods: read one day, read a range of days, write one day, write many days, and remove a range
 * of days. Nothing here
 * decides what a missing row *means* — `findByDay` answering `null` is a fact about storage, and
 * turning that into a 404 is the service's job — and nothing here takes a `Request`, a `Response` or
 * a status code.
 *
 * **The fifth is the only delete in the whole Worker, and it is range-shaped on purpose.** There is no
 * `deleteDay` and no `delete(id)`: a caller asking to forget one day can name a range of one, so the
 * narrower question is a special case rather than a second door — and a per-row delete would be a verb
 * a sync could reach for to reconcile a difference, which is the thing this API has never done and
 * still does not. See `docs/BACKEND.md` for why the ruling changed.
 *
 * The bulk write is the fourth and it is not `Promise.all` over `upsert`: the app's first sync sends
 * a nine-hundred-day history, and nine hundred round trips is a request that cannot finish. See
 * `upsertMany` for what the adapter does instead.
 */
export interface RecoveryRepository {
  /** The row for one day, or `null` if that day has no measurement. Never a zero-filled record. */
  findByDay(userId: string, date: string): Promise<Recovery | null>;

  /**
   * The rows in `[from, to]`, **inclusive at both ends**, oldest first.
   *
   * A day with no measurement is *absent from the array* rather than represented by a placeholder —
   * the same rule `findByDay` follows, and the reason the return type is a plain array rather than
   * something with holes in it.
   */
  listRange(userId: string, from: string, to: string): Promise<Recovery[]>;

  /**
   * Insert or replace the row for `recovery.date`, and answer with the row as it is on disk.
   *
   * The read-back is the point rather than a convenience: `PUT` answers with what the database
   * actually holds, so a caller can see that a `null` stayed `null` and was not folded into a `0` by
   * a default somewhere in the write path. Semantically this is the app's `saveRecovery`, whose
   * GRDB `save` is INSERT-or-UPDATE by primary key.
   */
  upsert(recovery: Recovery): Promise<Recovery>;

  /**
   * Insert or replace every row in `recoveries`, **all of them or none of them**, and answer with how
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
   * single-day read-back exists for — that a `null` stayed `null` — is asserted here the same way it
   * is anywhere else: by reading the range afterwards. The returned count is the database's own
   * `changes` tally, so it is a report of what was written rather than an echo of what was sent.
   */
  upsertMany(recoveries: readonly Recovery[]): Promise<number>;

  /**
   * Delete every row in `[from, to]`, **inclusive at both ends**, and answer with how many the
   * database reported removing.
   *
   * The bounds are the ones `listRange` reads, so a caller can read a range and delete exactly what it
   * read. `0` is a real answer: a range that holds nothing is the state the caller asked for, and it is
   * what a replayed delete gets.
   *
   * **No read-back and no pre-count.** Counting first and then deleting is two statements racing each
   * other, and the number a caller is told should be what the delete did rather than what a previous
   * snapshot said.
   */
  deleteRange(userId: string, from: string, to: string): Promise<number>;
}
