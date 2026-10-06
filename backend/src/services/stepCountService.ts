import type { StepCount, StepCountRepository } from "../domain";
import { addDays } from "../utils/days";
import { ApiRefusal, type ApiErrorCode } from "../utils/errors";

/**
 * Policy for `stepCounts` — what is neither HTTP nor SQL.
 *
 * Three things live here and nothing else does: **the window arithmetic**, which is the only place a
 * `days` number becomes a pair of day keys; **the absence decision**, which on this resource is the
 * whole of it — a day with no row is `null`, and the caller turns that into a 404; and **the batch's
 * three refusals**, which are the same three every day-keyed resource states.
 *
 * **This file is the shortest of the five services, and what is missing from it is the point.** There
 * is no `hasMeasurement` decision to forward, as `strains` has; no nullable field to pass through
 * untouched, as `sleeps` has; and no ordering rule to restate, because neither of this resource's two
 * fields is an instant. What is left is the shape every day-keyed resource has and nothing this one
 * adds — which is what a resource with no second producer and no unmeasured row actually looks like
 * in this layer.
 *
 * **One field still carries a rule, and it is `measuredSeconds`.** It is the field that separates a
 * *measured* day of no walking — a real `0` count — from a day nothing measured, which is an absent
 * row. So the trap `sleepService`'s long "`null` is a value" paragraph describes has an exact
 * analogue here: **no default of any kind may be applied to this field**, because a `?? 0` would
 * publish the second state as the first. That is the whole of this file's field-level policy, and it
 * is stated on `writeDay` below.
 *
 * There is deliberately no `D1Database`, no `Request`/`Response`, no status code and no Zod import in
 * this file. That is what makes it exercisable against a fake port with no Worker and no database, and
 * it is the rule `services/index.ts` states.
 */

/**
 * The widest window this endpoint will answer.
 *
 * `4000` is not invented: it is the value the iOS app's own suite passes to `getSleepHistory(days:)`
 * when it wants "everything that is there", and the same number is what a client porting a step-
 * history call has in hand. The cap exists so that a typo'd `days` cannot ask a database for a hundred
 * thousand days of range scan, and it is set above any real history rather than below it so that the
 * legitimate call is never the one refused.
 *
 * **Deliberately not `MAX_WINDOW_DAYS`, `MAX_STRAIN_WINDOW_DAYS` or `MAX_SLEEP_WINDOW_DAYS`**, even
 * though all four are equal today. `services/index.ts` gives the rule for the batch constants and it
 * applies here unchanged: the day one is retuned for cost, a shared constant would move the other
 * three's published limits with it and nothing would say so. Four resources whose windows happen to
 * match are still four published limits — and this one is the most tempting of the four to merge,
 * being the newest and therefore the one nobody has a reason to change.
 */
export const MAX_STEP_COUNT_WINDOW_DAYS = 4000;

/**
 * The most rows one `POST /v1/step-counts/batch` may carry.
 *
 * **Measured rather than guessed, and the measurement is what it is a cap on.** The app's real corpus
 * is a day-keyed row per day the strap was worn — the same order of magnitude as the sleep history's
 * 910 nights, which is the largest push this family of endpoints will ever see from the device it was
 * written for. At 200 rows a request that is five round trips, which a phone does on a coffee break,
 * and a chunk of 910 in one request is not obviously safe to send — D1 documents limits on a request's
 * size and on the work one invocation does.
 *
 * **A step row is the narrowest in the Worker and the cap is still the same number.** Four columns
 * against a night's sixteen, and no blob — so a chunk of 200 days is a materially *smaller* body than
 * a chunk of 200 nights, and that is a fact worth knowing rather than a reason to pick a larger
 * number. The cap is on *rows*, which is what the client chunks by and what the wire documents; a byte
 * ceiling would be a second, invisible limit that a client could only discover by failing. A resource
 * whose rows are small does not need a different cap, it needs the same one for the same reason: it is
 * the number of statements one invocation may put in a transaction.
 *
 * **Deliberately not `MAX_BATCH_ROWS`, `MAX_BATCH_STRAINS`, `MAX_BATCH_SLEEPS` or
 * `MAX_BATCH_WORKOUTS`**, which are the same `200` and the same reasoning, for the reason spelled out
 * on those constants: retuning the sleep one for cost would otherwise move this one's published limit
 * with it and nothing would say so. This is the fifth constant in that family and it is not an alias.
 *
 * The cap is stated here, in the layer that owns the number, and imported by the schema that publishes
 * it — the same arrangement `MAX_STEP_COUNT_WINDOW_DAYS` has, and for the same reason: a client should
 * be able to read the limit out of the OpenAPI document rather than discover it, and there must be one
 * place to change it rather than two that agree today.
 */
export const MAX_BATCH_STEP_COUNTS = 200;

/**
 * One day-range write's payload: the stored fields, less the two the request already determines.
 *
 * Derived from `StepCount` rather than written out, so a column added to the domain type is a compile
 * error here until it is accepted or explicitly excluded — the alternative is a new field that
 * silently never leaves the request body.
 */
export type StepCountInput = Omit<StepCount, "userId" | "date">;

/**
 * One row of a bulk write: the same stored fields, plus the day each row is filed under.
 *
 * `date` is back on the type, where `StepCountInput` deliberately drops it, because a batch has no
 * path to carry it. That is the whole reason the two types are not one: on a `PUT` the day is in the
 * URL and a body holding one is a `400`, while in a batch every row must name its own day or the
 * request means nothing.
 */
export type StepCountBatchEntry = StepCountInput & { readonly date: string };

/**
 * A refusal this layer made, carrying the code the API publishes for it.
 *
 * The *code* is HTTP vocabulary and the *message* is this layer's — the service knows why a range was
 * refused and the route knows what status that becomes, so the two halves stay where the knowledge
 * is. The route maps the code to a status and does not restate the reason.
 *
 * The shared half — the code field and the `body` builder — lives on `ApiRefusal`, which is what
 * `routes/errors.ts` catches. This class exists for its *name*: the log line says `StepCountError`
 * rather than `ApiRefusal`, so a stack names the resource that refused. `errorHandler` tests the base
 * class deliberately, so a new resource's refusal needs no edit there.
 */
export class StepCountError extends ApiRefusal {
  constructor(code: ApiErrorCode, message: string) {
    super(code, message);
    this.name = "StepCountError";
  }
}

export class StepCountService {
  constructor(private readonly repository: StepCountRepository) {}

  /**
   * One day's row, or `null` when that day has no row.
   *
   * `null` rather than a zero-filled record, and rather than a throw: whether an absent day is a 404
   * or a 200 with a body is an HTTP question and belongs to the route. This method answers the only
   * question it can — is there a row?
   *
   * **On this resource `null` is the whole absence there is**, which is where it parts company with
   * `strainService.readDay`. `strains` answers a row and not a measurement, because it stores a
   * `hasMeasurement` flag that can say `false` on a row that exists, so its route has two cases to
   * tell apart. `stepCounts` has no such column — the app's own flag is a computed property over
   * `measuredSeconds` — so a row that exists is a day the strap was worn, and there is no second kind
   * of row for this method to forward. The route therefore checks `=== null` and nothing else,
   * exactly as `recoveries` does.
   *
   * `date` is trusted to be a day key. It has already round-tripped through `parseDayKey` at the
   * route's param schema, and re-deriving it here would be a second statement of the day-key rule
   * with its own chance of disagreeing.
   */
  async readDay(userId: string, date: string): Promise<StepCount | null> {
    return this.repository.findByDay(userId, date);
  }

  /**
   * The window `days` back from `endingOn`, **inclusive at both ends**.
   *
   * This reproduces `LocalDatabaseManager.historyWindow(days:endingOn:)` exactly, including its
   * off-by-one: the app computes `from = endingOn − days` and bounds both ends inclusively, so
   * **`days = 14` spans 15 calendar days**. That is mirrored rather than corrected on purpose — a
   * client porting an existing call passes the same number and must get the same rows back — and it
   * is pinned by a test so it is a fact written down rather than a surprise found later. It is also
   * the *same* off-by-one `recoveries`, `strains` and `sleeps` reproduce, because all four call the
   * one helper; a resource that "fixed" it here would make one of the four windows mean something
   * different from the other three.
   *
   * The read is `[from, to]` and not a count, so a day inside the window with no row is simply absent
   * from the answer. There is no padding and no placeholder — on this resource that is emphatically
   * the ordinary case rather than an edge, since the strap is worn intermittently and a day it was
   * not on the wrist is a hole in the middle of the range rather than a missing tail.
   */
  async readWindow(userId: string, days: number, endingOn: string): Promise<StepCount[]> {
    // Both bounds are also stated in the query schema, which is what publishes them in the OpenAPI
    // document — a client should be able to read the limit rather than discover it. They are
    // repeated here because this is the layer that owns them: `MAX_STEP_COUNT_WINDOW_DAYS` is defined
    // here and imported by the schema, not the other way round, and a caller arriving at this method
    // from the generator script or a test has passed through no schema at all.
    if (days > MAX_STEP_COUNT_WINDOW_DAYS) {
      throw new StepCountError(
        "invalid_request",
        `days must be at most ${MAX_STEP_COUNT_WINDOW_DAYS}, got ${days}`,
      );
    }

    if (days < 0) {
      throw new StepCountError(
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
   * An upsert rather than an insert, because that is what the app's day-row write is: GRDB's `save`
   * is INSERT-or-UPDATE by primary key, so a `PUT` to a day that already has a row replaces it. The
   * `date` is taken from the path and the body carries none, so the two can never disagree.
   *
   * **Both fields are passed through as they arrived, and `measuredSeconds` is the one that matters.**
   * There is no `?? 0`, no `Math.max(0, …)` and no default of any kind. A `measuredSeconds` of `0`
   * that a client really sent stays `0` and means the strap was worn and moved for no measurable
   * time; a `measuredSeconds` the server filled in would mean a day nothing measured, published as a
   * day that was. That is the fabrication this resource's absence rule exists to prevent, and unlike
   * `sleeps`' six nullable fields there is no second spelling of absence here to fall back on — the
   * row's existence *is* the claim that something was measured, so nothing may manufacture one.
   */
  async writeDay(userId: string, date: string, input: StepCountInput): Promise<StepCount> {
    return this.repository.upsert({ userId, date, ...input });
  }

  /**
   * Write a chunk of days, and answer with how many rows the database reported writing.
   *
   * This is the app's sync of a long worn history in five requests instead of nine hundred. The chunk
   * is written by `upsertMany`, which is atomic — so a throw here means nothing was written and the
   * same body can be sent again.
   *
   * **Idempotent by the same key `writeDay` is.** Every row is upserted on `(userId, date)`, so a
   * chunk replayed after a timeout that the client never saw the answer to rewrites each row with the
   * values it already holds: no duplicates, no row count moved, and no need for the client to know
   * whether the first attempt landed. That is the property a retry needs and the reason this endpoint
   * is `POST /batch` rather than a `PUT` on the collection — a `PUT` on `/v1/step-counts` would say
   * "these are the days", and a sync that says that has to delete the ones it left out, which on a
   * history full of days the strap was not worn is a promise about deleting most of the user's record.
   *
   * The three refusals below are the schema's rules restated in the layer that owns them, the same
   * way `readWindow` restates its two: a caller reaching this method from a script or a test has
   * passed through no schema at all.
   */
  async writeMany(userId: string, entries: readonly StepCountBatchEntry[]): Promise<number> {
    // An empty batch is a client that has not decided what to send. Answering `200` with `written: 0`
    // would make that look like a successful sync of nothing, which is the failure this project's
    // absence rules exist to keep visible.
    if (entries.length === 0) {
      throw new StepCountError("invalid_request", "rows must not be empty");
    }

    if (entries.length > MAX_BATCH_STEP_COUNTS) {
      throw new StepCountError(
        "invalid_request",
        `rows must hold at most ${MAX_BATCH_STEP_COUNTS} days, got ${entries.length}`,
      );
    }

    // Two rows for one day in one request is a client that has computed its day set twice and
    // disagreed with itself. It would also be *silently* harmless — the second write wins, and the
    // row that ends up on disk is whichever the array happened to put last — which is precisely why
    // it is refused rather than allowed to be resolved by ordering. The stakes are lower here than on
    // a night, which carries sixteen fields; on this resource there are two, so the disagreement
    // could only be about a count or a span. It is refused anyway, because the rule is the family's
    // and a resource that made an exception for being narrow would be the one a reader has to
    // remember.
    const days = new Set(entries.map((entry) => entry.date));
    if (days.size !== entries.length) {
      const repeated = entries.length - days.size;
      throw new StepCountError(
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
