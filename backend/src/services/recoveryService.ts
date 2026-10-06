import type { Recovery, RecoveryRepository } from "../domain";
import { addDays } from "../utils/days";
import { ApiRefusal, type ApiErrorCode } from "../utils/errors";

/**
 * Policy for `recoveries` — what is neither HTTP nor SQL.
 *
 * Three things live here and nothing else does: **the window arithmetic**, which is the only place a
 * `days` number becomes a pair of day keys; **the absence decision**, which is that a day with no
 * row is `null` and the caller turns that into a 404; and **passing `source` through untouched**,
 * never defaulted, because a value this layer invented would be provenance that no producer claimed.
 *
 * There is deliberately no `D1Database`, no `Request`/`Response`, no status code and no Zod import in
 * this file. That is what makes it exercisable against a fake port with no Worker and no database,
 * and it is the rule `services/index.ts` states.
 */

/**
 * The widest window this endpoint will answer.
 *
 * `4000` is not invented: it is the value the iOS app's own suite passes to
 * `getRecoveryHistory(days:)` when it wants "everything that is there". The cap exists so that a
 * typo'd `days` cannot ask a database for a hundred thousand days of range scan, and it is set
 * above any real history rather than below it so that the legitimate call is never the one refused.
 */
export const MAX_WINDOW_DAYS = 4000;

/**
 * The most rows one `POST /v1/recoveries/batch` may carry.
 *
 * **Measured rather than guessed, and the measurement is what it is a cap on.** The app's real corpus
 * is the bundled WHOOP export: 910 recoveries over 910 distinct days, which is the largest push this
 * endpoint will ever see from the device it was written for. At 200 rows a request that is five
 * round trips, which a phone does on a coffee break and a chunk of 910 in one request is not
 * obviously safe to send — D1 documents limits on a request's size and on the work one invocation
 * does, and a body carrying nine hundred rows is where those start to matter.
 *
 * The cap is stated here, in the layer that owns the number, and imported by the schema that
 * publishes it — the same arrangement `MAX_WINDOW_DAYS` has, and for the same reason: a client should
 * be able to read the limit out of the OpenAPI document rather than discover it, and there must be
 * one place to change it rather than two that agree today.
 */
export const MAX_BATCH_ROWS = 200;

/**
 * A day-range write's payload: the stored fields, less the two the request already determines.
 *
 * Derived from `Recovery` rather than written out, so a column added to the domain type is a
 * compile error here until it is accepted or explicitly excluded — the alternative is a new field
 * that silently never leaves the request body.
 */
export type RecoveryInput = Omit<Recovery, "userId" | "date">;

/**
 * One row of a bulk write: the same stored fields, plus the day each row is filed under.
 *
 * `date` is back on the type, where `RecoveryInput` deliberately drops it, because a batch has no
 * path to carry it. That is the whole reason the two types are not one: on a `PUT` the day is in the
 * URL and a body holding one is a `400`, while in a batch every row must name its own day or the
 * request means nothing.
 */
export type RecoveryBatchEntry = RecoveryInput & { readonly date: string };

/**
 * A refusal this layer made, carrying the code the API publishes for it.
 *
 * The *code* is HTTP vocabulary and the *message* is this layer's — the service knows why a range
 * was refused and the route knows what status that becomes, so the two halves stay where the
 * knowledge is. The route maps the code to a status and does not restate the reason.
 *
 * The shared half — the code field and the `body` builder — lives on `ApiRefusal`, which is what
 * `routes/errors.ts` catches. This class exists for its *name*: the log line says `RecoveryError`
 * rather than `ApiRefusal`, so a stack names the resource that refused.
 */
export class RecoveryError extends ApiRefusal {
  constructor(code: ApiErrorCode, message: string) {
    super(code, message);
    this.name = "RecoveryError";
  }
}

export class RecoveryService {
  constructor(private readonly repository: RecoveryRepository) {}

  /**
   * One day's reading, or `null` when that day has no measurement.
   *
   * `null` rather than a zero-filled record, and rather than a throw: whether an absent day is a 404
   * or a 200 with a body is an HTTP question and belongs to the route. This method answers the only
   * question it can — is there a row?
   *
   * `date` is trusted to be a day key. It has already round-tripped through `parseDayKey` at the
   * route's param schema, and re-deriving it here would be a second statement of the day-key rule
   * with its own chance of disagreeing.
   */
  async readDay(userId: string, date: string): Promise<Recovery | null> {
    return this.repository.findByDay(userId, date);
  }

  /**
   * The window `days` back from `endingOn`, **inclusive at both ends**.
   *
   * This reproduces `LocalDatabaseManager.historyWindow(days:endingOn:)` exactly, including its
   * off-by-one: the app computes `from = endingOn − days` and bounds both ends inclusively, so
   * **`days = 14` spans 15 calendar days**. That is mirrored rather than corrected on purpose — a
   * client porting an existing call passes the same number and must get the same rows back — and it
   * is pinned by a test so it is a fact written down rather than a surprise found later.
   *
   * The read is `[from, to]` and not a count, so a day inside the window with no measurement is
   * simply absent from the answer. There is no padding and no placeholder.
   */
  async readWindow(userId: string, days: number, endingOn: string): Promise<Recovery[]> {
    // Both bounds are also stated in the query schema, which is what publishes them in the OpenAPI
    // document — a client should be able to read the limit rather than discover it. They are
    // repeated here because this is the layer that owns them: `MAX_WINDOW_DAYS` is defined here and
    // imported by the schema, not the other way round, and a caller arriving at this method from the
    // generator script or a test has passed through no schema at all.
    if (days > MAX_WINDOW_DAYS) {
      throw new RecoveryError(
        "invalid_request",
        `days must be at most ${MAX_WINDOW_DAYS}, got ${days}`,
      );
    }

    if (days < 0) {
      throw new RecoveryError(
        "invalid_request",
        `days must not be negative, got ${days}`,
      );
    }

    // The subtraction is the app's: `from = endingOn − days`, inclusive at both ends, which is why
    // `days = 14` answers with 15 days. See the doc comment above.
    const from = addDays(endingOn, -days);

    return this.repository.listRange(userId, from, endingOn);
  }

  /**
   * Write one day, and answer with the row as it is on disk.
   *
   * An upsert rather than an insert, because that is what the app's `saveRecovery` is: GRDB's `save`
   * is INSERT-or-UPDATE by primary key, so a `PUT` to a day that already has a row replaces it. The
   * `date` is taken from the path and the body carries none, so the two can never disagree.
   *
   * Every nullable field is passed through as it arrived. `?? null` appears nowhere, and neither
   * does a default of any kind: a client that omits `source` and a client that sends `source: null`
   * mean the same thing, and this layer must not invent a third answer for either.
   */
  async writeDay(userId: string, date: string, input: RecoveryInput): Promise<Recovery> {
    return this.repository.upsert({ userId, date, ...input });
  }

  /**
   * Write a chunk of days, and answer with how many rows the database reported writing.
   *
   * This is the app's first sync in one request instead of nine hundred. The chunk is written by
   * `upsertMany`, which is atomic — so a throw here means nothing was written and the same body can
   * be sent again.
   *
   * **Idempotent by the same key `writeDay` is.** Every row is upserted on `(userId, date)`, so a
   * chunk replayed after a timeout that the client never saw the answer to rewrites each row with the
   * values it already holds: no duplicates, no row count moved, and no need for the client to know
   * whether the first attempt landed. That is the property a retry needs and the reason this endpoint
   * is `POST /batch` rather than a `PUT` on the collection — a `PUT` on `/v1/recoveries` would say
   * "these are the days", and a sync that says that has to delete the ones it left out, which is a
   * promise about deletion this API does not make.
   *
   * The three refusals below are the schema's rules restated in the layer that owns them, the same
   * way `readWindow` restates its two: a caller reaching this method from a script or a test has
   * passed through no schema at all.
   */
  async writeMany(userId: string, entries: readonly RecoveryBatchEntry[]): Promise<number> {
    // An empty batch is a client that has not decided what to send. Answering `200` with `written: 0`
    // would make that look like a successful sync of nothing, which is the failure this project's
    // absence rules exist to keep visible.
    if (entries.length === 0) {
      throw new RecoveryError("invalid_request", "rows must not be empty");
    }

    if (entries.length > MAX_BATCH_ROWS) {
      throw new RecoveryError(
        "invalid_request",
        `rows must hold at most ${MAX_BATCH_ROWS} days, got ${entries.length}`,
      );
    }

    // Two rows for one day in one request is a client that has computed its day set twice and
    // disagreed with itself. It would also be *silently* harmless — the second write wins, and the
    // row that ends up on disk is whichever the array happened to put last — which is precisely why
    // it is refused rather than allowed to be resolved by ordering.
    const days = new Set(entries.map((entry) => entry.date));
    if (days.size !== entries.length) {
      const repeated = entries.length - days.size;
      throw new RecoveryError(
        "invalid_request",
        `rows carry ${repeated} repeated ${repeated === 1 ? "day" : "days"}; a batch must name each day once`,
      );
    }

    // `date` is spread back on rather than passed separately, because for a batch the day is part of
    // the payload — which is the one place this differs from `writeDay`, where the path supplies it
    // and the body is forbidden from carrying it.
    return this.repository.upsertMany(entries.map((entry) => ({ userId, ...entry })));
  }
}
