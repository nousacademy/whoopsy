import type { ReceptiveInactivity, ReceptiveInactivityRepository } from "../domain";
import { addDays } from "../utils/days";
import { ApiRefusal, type ApiErrorCode } from "../utils/errors";
import { MAX_WINDOW_DAYS } from "./recoveryService";

/**
 * Policy for `receptive_inactivities` — what is neither HTTP nor SQL.
 *
 * There is less of it here than in any other service in this Worker, and the shortness is the whole
 * point of the file. The window arithmetic is `recoveries`' and is reused rather than restated; the
 * duplicate check is on **`id`**, which is `workouts`' inversion and the reason these two cannot share
 * a batch validator; and everything else that a sibling's policy covers is **absent because the shape
 * has nothing for it to be about**:
 *
 * - No **boundary pair**, so no `endedAt`-after-`startedAt` rule and no `parseInstant` import. Every
 *   other service here that parses an instant does so to *compare* two of them, and this row holds one
 *   optional instant and nothing for it to precede.
 * - No **aggregate caps**, so no per-session route or split bound and no batch total. An entry is one
 *   row with no children, which makes the row cap the work cap.
 * - No **measured field**, so no `hasMeasurement` rule, no reserved-zero guard and no share that must
 *   sum to at most 100. Nothing on this row is a reading.
 *
 * What is left is the three refusals every batch in this Worker makes, and they are stated here rather
 * than only in the schema for the reason `readWindow` states its two: **a caller arriving from a script
 * or a test has passed through no schema at all.**
 *
 * There is deliberately no `D1Database`, no `Request`/`Response`, no status code and no Zod import in
 * this file. See `services/index.ts`.
 */

/**
 * The most entries one `POST /v1/receptive-inactivities/batch` may carry.
 *
 * `200` like every other batch cap in this Worker, and separate from them on the rule those four names
 * already carry — but here the equality is closer to an alias than anywhere else, so the argument has
 * to be made rather than inherited twice over. The *cost* is what a cap is a cap on: a recovery is one
 * statement, a session is at least three before its children, and an entry here is **exactly one** —
 * the cheapest row this API writes. So this is not sized for cost, because nothing about the cost
 * separates it from `MAX_BATCH_ROWS`; it is sized against the **corpus**, which is what makes it a real
 * number rather than a copy. The app's bundled note file is 62 entries over 57 days, and a full first
 * sync is one request at this cap with room to spare for a user who has kept notes for a decade — 200
 * entries in one statement list is far below where D1's per-invocation work starts to matter, and the
 * cap exists so that a typo'd array cannot ask for a hundred thousand.
 *
 * It stays its own name rather than importing `MAX_BATCH_ROWS` for the reason the barrel gives: two
 * resources whose limits happen to match are still two *published* limits, and one resource's ceiling
 * must not be movable by retuning another's.
 */
export const MAX_BATCH_RECEPTIVE_INACTIVITIES = 200;

/**
 * An entry's stored fields, less the two the request determines.
 *
 * Derived from `ReceptiveInactivity` rather than written out, so a field added to the domain type is a
 * compile error here until it is accepted or explicitly excluded — the alternative is a column that
 * silently never leaves a request body. `id` is dropped because it is in the path of the `PUT` this
 * type belongs to; `userId` because it comes from the header, and a body carrying one would be a
 * second opinion about whose row this is.
 *
 * **`date` is *on* this type, and here that is forced rather than chosen.** A session's day is at least
 * derivable in principle from its start instant, and `workouts` still takes it from the body because a
 * UTC Worker cannot do that derivation in the caller's calendar. This row has no `endedAt` at all and
 * its `startedAt` may be absent, so when no time was given there is nothing to derive the day *from* —
 * the day is the one the client's screen was showing, and only the client can state it.
 */
export type ReceptiveInactivityInput = Omit<ReceptiveInactivity, "userId" | "id">;

/**
 * One entry of a bulk write: the same stored fields, plus the identity the path would have carried.
 *
 * `id` is back on the type, where `ReceptiveInactivityInput` deliberately drops it, because a batch has
 * no path to put it in. That is the whole reason the two types are not one — the same split
 * `WorkoutInput`/`WorkoutBatchEntry` draws, and the same one `recoveries` draws between its own pair
 * with `date` in place of `id`.
 */
export type ReceptiveInactivityBatchEntry = Omit<ReceptiveInactivity, "userId">;

/**
 * A refusal this layer made, carrying the code the API publishes for it.
 *
 * Its own name so a log line says `ReceptiveInactivityError` rather than `ApiRefusal` and a stack names
 * the resource that refused; the code field and the `body` builder are `ApiRefusal`'s, which is what
 * the route's single catch arm tests.
 */
export class ReceptiveInactivityError extends ApiRefusal {
  constructor(code: ApiErrorCode, message: string) {
    super(code, message);
    this.name = "ReceptiveInactivityError";
  }
}

export class ReceptiveInactivityService {
  constructor(private readonly repository: ReceptiveInactivityRepository) {}

  /**
   * One entry, or `null` when this partition holds no such id.
   *
   * `null` rather than a throw, and rather than a record of nulls: whether an absent id is a `404` or a
   * `200` is an HTTP question and belongs to the route. This answers the only question it can — is
   * there a row?
   *
   * `id` is trusted to be a UUID string. It has already round-tripped through
   * `RECEPTIVE_INACTIVITY_ID_PATTERN` at the route's param schema, and re-testing it here would be a
   * second statement of that rule with its own chance of disagreeing — `RecoveryService.readDay`
   * declines the same re-derivation for its day key.
   */
  async readOne(userId: string, id: string): Promise<ReceptiveInactivity | null> {
    return this.repository.findById(userId, id);
  }

  /**
   * The window `days` back from `endingOn`, **inclusive at both ends**, oldest entry first.
   *
   * The off-by-one is `recoveries`' and is inherited rather than re-derived — see
   * `RecoveryService.readWindow`, which carries the argument in full. What is this resource's own is
   * the shape of the answer: an **array**, because a day holds several entries, and no padding for a
   * day that has none.
   *
   * **A single day is `days = 0`**, and that is the app's ordinary read rather than a degenerate case
   * of the window: its own port takes a date and returns that day's entries, so the day-shaped read is
   * the *common* call here and the wide one is the exception. That is also why the resource is mounted
   * at a collection with an `{id}` beside it rather than at a `{date}` — there is no per-day endpoint
   * to reach for, and there should not be one, because a day-shaped path would be a second way to ask a
   * question `days=0` already answers.
   */
  async readWindow(userId: string, days: number, endingOn: string): Promise<ReceptiveInactivity[]> {
    // Both bounds are also stated in the query schema, which is what publishes them in the OpenAPI
    // document — a client should be able to read the limit rather than discover it. They are repeated
    // here because this is the layer that owns them: `MAX_WINDOW_DAYS` is defined in
    // `recoveryService.ts` and imported by the schema, not the other way round, and a caller arriving
    // at this method from the generator script or a test has passed through no schema at all.
    if (days > MAX_WINDOW_DAYS) {
      throw new ReceptiveInactivityError(
        "invalid_request",
        `days must be at most ${MAX_WINDOW_DAYS}, got ${days}`,
      );
    }

    if (days < 0) {
      throw new ReceptiveInactivityError(
        "invalid_request",
        `days must not be negative, got ${days}`,
      );
    }

    // The subtraction is the app's: `from = endingOn − days`, inclusive at both ends, which is why
    // `days = 14` answers with 15 days. See the doc comment above.
    return this.repository.listWindow(userId, addDays(endingOn, -days), endingOn);
  }

  /**
   * Write one entry, addressed by its id, and answer with it as it is on disk.
   *
   * An upsert, because that is what the app's own `save` is: GRDB's `save` is INSERT-or-UPDATE by
   * primary key, so a `PUT` to an id that already has a row replaces it and keeps its identity. The
   * `id` comes from the path and the body carries none, so the two can never disagree.
   *
   * **Two fields are nullable here and neither is defaulted anywhere on the way through.** `note` and
   * `startedAt` cross this method exactly as they arrived: a client that omits one and a client that
   * sends `null` mean the same thing, and `?? null` appears nowhere — the column being nullable *is*
   * the absence, so a default would not be defensive coding, it would erase the difference between an
   * entry nobody timed and one timed at midnight, and between an entry nobody wrote and one written as
   * an empty string. `""` is refused by the schema rather than normalised to `null`, because it is a
   * value nobody supplied rather than the absence of one.
   *
   * **`startedAt` is not parsed here, and the omission is deliberate.** `WorkoutService` parses both of
   * a session's instants because it has to *order* them, and the ordering rule is policy this layer
   * owns. This row holds one optional instant with nothing to precede, so the only rule left would be
   * "the string is a canonical instant" — which is a statement about a *shape*, and shapes are the
   * schema's. The instant is stored verbatim and `date` is what says which day it belongs to; the
   * client rebuilds its hour and minute onto that day, so a value here is a time-of-day on the day
   * beside it and nothing in this layer can add to that.
   */
  async writeOne(
    userId: string,
    id: string,
    input: ReceptiveInactivityInput,
  ): Promise<ReceptiveInactivity> {
    return this.repository.upsert({ userId, id, ...input });
  }

  /**
   * Write a chunk of entries as one unit, answering how many **entries** the database wrote.
   *
   * Entries and rows are the same number on this resource — an entry has no children — and the port
   * still says *entries* rather than rows, because that is the quantity `POST /batch` publishes and a
   * caller should not have to know that this resource's arithmetic happens to be the identity.
   *
   * **Idempotent by the same key `writeOne` is**, and on this resource that is what makes the app's
   * import safe to press twice: every entry lands on the same `(userId, id)` pair, and the id is
   * *derived* from the entry's own date, type and text rather than minted, so a replayed chunk rewrites
   * each entry with the values it already holds — no duplicates, no row count moved, and no need for
   * the client to know whether the first attempt landed. That is why this is `POST /batch` and not a
   * `PUT` on the collection: a `PUT` on `/v1/receptive-inactivities` would say "these are the entries",
   * and a sync that says that has to delete the ones it left out — a promise about deletion this API
   * does not make anywhere, and on this resource the one the app's own port asks for and cannot have.
   *
   * The three refusals below are the schema's rules restated in the layer that owns them.
   */
  async writeMany(userId: string, entries: readonly ReceptiveInactivityBatchEntry[]): Promise<number> {
    // An empty batch is a client that has not decided what to send. Answering `200` with `written: 0`
    // would make that look like a successful sync of nothing, which is the failure this project's
    // absence rules exist to keep visible.
    if (entries.length === 0) {
      throw new ReceptiveInactivityError("invalid_request", "rows must not be empty");
    }

    if (entries.length > MAX_BATCH_RECEPTIVE_INACTIVITIES) {
      throw new ReceptiveInactivityError(
        "invalid_request",
        `rows must hold at most ${MAX_BATCH_RECEPTIVE_INACTIVITIES} entries, got ${entries.length}`,
      );
    }

    // Uniqueness is on `id` here and on `date` in `recoveries`, and the inversion is the resource's
    // whole shape: a day holds several entries, so two rows sharing a date are an ordinary night — the
    // case this table's id-keyed primary key exists for — while two sharing an id are a client that has
    // minted one identity twice, or an importer whose derivation has stopped being a function of the
    // entry's own fields. Refused rather than resolved by ordering, because the second write would win
    // silently and the row left on disk would be whichever the array happened to put last.
    const ids = new Set(entries.map((entry) => entry.id));
    if (ids.size !== entries.length) {
      const repeated = entries.length - ids.size;
      throw new ReceptiveInactivityError(
        "invalid_request",
        `rows carry ${repeated} repeated ${repeated === 1 ? "id" : "ids"}; a batch must name each entry once`,
      );
    }

    return this.repository.upsertMany(entries.map((entry) => ({ userId, ...entry })));
  }
}
