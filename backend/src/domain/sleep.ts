/**
 * The `sleeps` port: the domain type and the interface.
 *
 * This file knows a *shape*, not a table. The column names live one file over, in
 * `d1SleepRepository.ts`, which is the only file in this Worker that names a table or a column — so
 * "what the schema looks like" has exactly one answer and the service above it can be exercised
 * against a fake with no D1 anywhere.
 *
 * There is no vocabulary constant here, where `recovery.ts` has `HRV_METRICS`: a night carries no
 * categorical column. Its one non-numeric field is `source`, and that is free text rather than a set
 * anything is derived from.
 *
 * **Six fields are `| null` and each one is a real state rather than a hole.** They are the reason
 * this type is worth reading before writing an adapter: `?? 0` on any of them converts "the estimator
 * declined" or "the export carries no such column" into a measurement, and on this resource three of
 * the six have a model on the other side that would then be run over an imported row.
 */

/**
 * One night's sleep, filed under the day it *woke* on.
 *
 * Mirrors `SleepRecord` in the iOS app, field for field, with `userId` — the partition the local
 * schema has no equivalent for — and with `date` as a `YYYY-MM-DD` day key rather than an instant.
 *
 * **`date` is the wake day, and that is the app's convention rather than this API's.** The local
 * `sleeps` table is primary-keyed on `startOfDay(Wake onset)`: `CalculateRecoveryUseCase` writes
 * `date.startOfDay` and reads the night *for that same date*, so a recovery row for a day is computed
 * from the night that ended on that day's morning. The bundled export is keyed the same way and for
 * the same reason — keying its 935 rows on `Cycle start` instead collapses them onto 753 days.
 *
 * **`sleepStages` is an opaque `string`, and that is the one field here that is not the app's own
 * shape.** On the phone it is `[SleepStageSegment]?`; on this side of the boundary it is the JSON text
 * the column holds, stored and handed back unchanged. The reasoning is on the schema that publishes
 * it (`dto/sleeps.ts`), and the short version is that this Worker never reads into the blob
 * and takes no opinion about it — parsing it here would be a second decoder that has to agree with the
 * app's `Codable` one forever, and the wire's instant format is not what is inside it.
 */
export interface Sleep {
  /** The owner. Carried, not yet trusted: nothing in this Worker verifies it. */
  readonly userId: string;
  /** The day key, `YYYY-MM-DD` — the wake day. Always `startOfDay` on the device. */
  readonly date: string;

  /** When the night began, as a canonical UTC instant string. */
  readonly startTime: string;
  /** When it ended, likewise. Refused by the write bodies if it does not follow `startTime`. */
  readonly endTime: string;

  /**
   * Sleep performance as a percentage — **the app's own figure, not WHOOP's column**.
   *
   * Every stored row holds `clamp(asleep ÷ need × 100, 0, 100)` computed on the device, so one formula
   * covers all 910 imported nights and every night after. The export's own `Sleep performance %` is
   * parsed and read by nothing.
   */
  readonly sleepPerformance: number;

  /** The night's requirement in seconds. A value below the eight-hour baseline is real — see `v10`. */
  readonly totalSleepNeeded: number;

  /** The three sleep stages, in seconds. Their sum is the asleep total the performance divides. */
  readonly lightSleep: number;
  readonly deepSleep: number;
  readonly remSleep: number;
  /** The fourth stage total, in seconds. `asleep + awake == duration` is the identity a reader checks. */
  readonly awakeTime: number;

  /** Breaths per minute, derived from the R-R series — so absent on every night it cannot support. */
  readonly respiratoryRate: number | null;
  /** Only a night the actigraphy classifier could read has one; every imported night is `null`. */
  readonly disturbanceCount: number | null;
  /** WHOOP's own whole-percent consistency. `null` is "not scored", which is not a score of zero. */
  readonly sleepConsistency: number | null;
  /** The accumulated deficit in seconds. The two producers' values are different quantities. */
  readonly sleepDebt: number | null;

  /**
   * The night's stage timeline, as JSON text, handed through untouched.
   *
   * `null` for every imported night and every night the strap did not stage — the export reports stage
   * *totals* and no timeline, so an imported night can never have one. An empty array is never stored;
   * see the migration for why `nil` is that state's only representation.
   */
  readonly sleepStages: string | null;

  /**
   * Provenance (`whoop_export`, …). NULL when this app measured it, and on every pre-column row.
   *
   * It carries more weight here than on any other resource: it is the only thing separating the two
   * producers of `sleepPerformance`, `sleepConsistency`, `sleepDebt` and `respiratoryRate`.
   */
  readonly source: string | null;
}

/**
 * The storage port for `sleeps`.
 *
 * Four methods: read one day, read a range of days, write one day, write many days — the same four
 * `RecoveryRepository` and `StrainRepository` declare, and deliberately not a shared interface with
 * either. Three resources that happen to have the same verbs today are three resources; a common port
 * would make every future divergence between them a change to a type all three depend on.
 *
 * Nothing here decides what a missing row *means* — `findByDay` answering `null` is a fact about
 * storage, and turning that into a 404 is the service's job — and nothing here takes a `Request`, a
 * `Response` or a status code.
 *
 * **There is no `hasMeasurement` here, and its absence is this resource's one structural difference
 * from `strains`.** The local `sleeps` table has no such column: a night the classifier could not read
 * is an absent row rather than a row carrying zeroes, which is how `AnalyzeSleepUseCase` has always
 * behaved — it returns `SleepSession?` and writes nothing. So the absence rule here is `recoveries`'
 * rather than `strains`': a day with no row is a 404, and there is no second kind of row to tell apart
 * from a reading.
 */
export interface SleepRepository {
  /** The row for one day, or `null` if that day has no row. Never a zero-filled record. */
  findByDay(userId: string, date: string): Promise<Sleep | null>;

  /**
   * The rows in `[from, to]`, **inclusive at both ends**, oldest first.
   *
   * A day with no row is *absent from the array* rather than represented by a placeholder — the same
   * rule `findByDay` follows, and the same rule the other two day-keyed resources follow.
   */
  listRange(userId: string, from: string, to: string): Promise<Sleep[]>;

  /**
   * Insert or replace the row for `sleep.date`, and answer with the row as it is on disk.
   *
   * The read-back is the point rather than a convenience: `PUT` answers with what the database
   * actually holds, so a caller can see that a `null` stayed `null` and was not folded into a `0` by a
   * default somewhere in the write path. That matters more on this resource than on either sibling —
   * three of its fields have a model on the other side that would happily produce a number — and it is
   * the assertion a screenshot cannot make.
   *
   * Semantically this is the app's `saveSleep`, whose GRDB `save` is INSERT-or-UPDATE by primary key.
   */
  upsert(sleep: Sleep): Promise<Sleep>;

  /**
   * Insert or replace every row in `sleeps`, **all of them or none of them**, and answer with how many
   * the database reported writing.
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
  upsertMany(sleeps: readonly Sleep[]): Promise<number>;
}
