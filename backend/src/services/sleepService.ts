import type { Sleep, SleepRepository } from "../domain";
import { addDays } from "../utils/days";
import { ApiRefusal, type ApiErrorCode } from "../utils/errors";

/**
 * Policy for `sleeps` — what is neither HTTP nor SQL.
 *
 * Three things live here and nothing else does: **the window arithmetic**, which is the only place a
 * `days` number becomes a pair of day keys; **the absence decision**, which on this resource is the
 * whole of it — a day with no row is `null`, and the caller turns that into a 404; and **passing six
 * nullable fields through untouched**, which is what this service has instead of `strains`'
 * `hasMeasurement` decision.
 *
 * **That substitution is the one structural difference between this file and `strainService.ts`, and
 * it buys nothing: it costs.** `strains` has one flag to forward and one trap to avoid — inferring it
 * from a figure. This resource has three fields that nothing may infer, each with a model on the client
 * that would produce a plausible number if a server invited one: a respiratory rate, a consistency
 * score and a debt. A `?? 0` here would be worse than the same mistake on `strains`, because a
 * strain's flag is a boolean the app already stores, while these three are *values a model computes* —
 * so a server that filled one in would be publishing a number the device never
 * produced. The rule is one sentence and it is stated on every layer: **every field is passed through
 * as it arrived, and `null` is a value.**
 *
 * There is deliberately no `D1Database`, no `Request`/`Response`, no status code and no Zod import in
 * this file. That is what makes it exercisable against a fake port with no Worker and no database, and
 * it is the rule `services/index.ts` states.
 */

/**
 * The widest window this endpoint will answer.
 *
 * `4000` is not invented: it is the value the iOS app's own suite passes to `getSleepHistory(days:)`
 * when it wants "everything that is there". The cap exists so that a typo'd `days` cannot ask a
 * database for a hundred thousand days of range scan, and it is set above any real history rather
 * than below it so that the legitimate call is never the one refused.
 *
 * **Deliberately not `MAX_WINDOW_DAYS` and not `MAX_STRAIN_WINDOW_DAYS`**, even though all three are
 * equal today. `services/index.ts` gives the rule for the batch trio and it applies here unchanged:
 * the day one is retuned for cost, a shared constant would move the other's published limit with it
 * and nothing would say so. Two resources whose windows happen to match are still two published
 * limits — and `sleeps` is the pair most tempting to merge with `strains`, being the two that are
 * alike rather than the two that are not.
 */
export const MAX_SLEEP_WINDOW_DAYS = 4000;

/**
 * The most rows one `POST /v1/sleeps/batch` may carry.
 *
 * **Measured rather than guessed, and the measurement is what it is a cap on.** The app's real corpus
 * is the bundled WHOOP export: 910 nights over 910 distinct days, which is the largest push this
 * endpoint will ever see from the device it was written for. At 200 rows a request that is five round
 * trips, which a phone does on a coffee break, and a chunk of 910 in one request is not obviously
 * safe to send — D1 documents limits on a request's size and on the work one invocation does.
 *
 * **A sleep row is the widest in the Worker and the cap is still the same number.** Sixteen columns
 * against a strain's eight, and one of them is a `sleep_stages` blob that can run to a couple of
 * hundred kilobytes — so a chunk of 200 nights is a materially larger body than a chunk of 200
 * strains, and that is a fact worth knowing rather than a reason to pick a different number. The cap
 * is on *rows*, which is what the client chunks by and what the wire documents; a byte ceiling would
 * be a second, invisible limit that a client could only discover by failing. If the body ever becomes
 * the binding constraint the answer is a smaller chunk on the client, not a cap here that means
 * "200 rows, unless they are long ones".
 *
 * **Deliberately not `MAX_BATCH_ROWS` and not `MAX_BATCH_STRAINS`**, which are the same `200` and the
 * same reasoning, for the reason spelled out on those constants: retuning the strain one for cost
 * would otherwise move this one's published limit with it and nothing would say so.
 *
 * The cap is stated here, in the layer that owns the number, and imported by the schema that
 * publishes it — the same arrangement `MAX_SLEEP_WINDOW_DAYS` has, and for the same reason: a client
 * should be able to read the limit out of the OpenAPI document rather than discover it, and there
 * must be one place to change it rather than two that agree today.
 */
export const MAX_BATCH_SLEEPS = 200;

/**
 * One day-range write's payload: the stored fields, less the two the request already determines.
 *
 * Derived from `Sleep` rather than written out, so a column added to the domain type is a compile
 * error here until it is accepted or explicitly excluded — the alternative is a new field that
 * silently never leaves the request body. That derivation is also what carries all six nullable
 * fields onto the wire without a line of code naming them, which is the point: a hand-written
 * interface here is where one of them would be quietly narrowed to a non-optional.
 */
export type SleepInput = Omit<Sleep, "userId" | "date">;

/**
 * One row of a bulk write: the same stored fields, plus the day each row is filed under.
 *
 * `date` is back on the type, where `SleepInput` deliberately drops it, because a batch has no path
 * to carry it. That is the whole reason the two types are not one: on a `PUT` the day is in the URL
 * and a body holding one is a `400`, while in a batch every row must name its own day or the request
 * means nothing. On this resource the day is also the *wake* day, which is the client's convention to
 * compute and this side's to store — nothing here re-derives it from the two boundary instants.
 */
export type SleepBatchEntry = SleepInput & { readonly date: string };

/**
 * A refusal this layer made, carrying the code the API publishes for it.
 *
 * The *code* is HTTP vocabulary and the *message* is this layer's — the service knows why a range was
 * refused and the route knows what status that becomes, so the two halves stay where the knowledge
 * is. The route maps the code to a status and does not restate the reason.
 *
 * The shared half — the code field and the `body` builder — lives on `ApiRefusal`, which is what
 * `routes/errors.ts` catches. This class exists for its *name*: the log line says `SleepError` rather
 * than `ApiRefusal`, so a stack names the resource that refused. `errorHandler` tests the base class
 * deliberately, so a new resource's refusal needs no edit there.
 */
export class SleepError extends ApiRefusal {
  constructor(code: ApiErrorCode, message: string) {
    super(code, message);
    this.name = "SleepError";
  }
}

export class SleepService {
  constructor(private readonly repository: SleepRepository) {}

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
   * tell apart. `sleeps` has no such column: a night the classifier could not read was never written,
   * so a row that exists is a night that was measured, and there is no second kind of row for this
   * method to forward. The route therefore checks `=== null` and nothing else, exactly as
   * `recoveries` does.
   *
   * `date` is trusted to be a day key. It has already round-tripped through `parseDayKey` at the
   * route's param schema, and re-deriving it here would be a second statement of the day-key rule
   * with its own chance of disagreeing — on a key whose convention (the *wake* day) is already the
   * one thing about this resource most likely to be misread.
   */
  async readDay(userId: string, date: string): Promise<Sleep | null> {
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
   * the *same* off-by-one `strains` and `recoveries` reproduce, because all three call the one
   * helper; a resource that "fixed" it here would make one of the three windows mean something
   * different from the other two.
   *
   * The read is `[from, to]` and not a count, so a day inside the window with no row is simply absent
   * from the answer. There is no padding and no placeholder — on a nine-hundred-day history that is
   * the ordinary case rather than an edge, since a night the user did not wear the strap is a hole in
   * the middle of the range rather than a missing tail.
   */
  async readWindow(userId: string, days: number, endingOn: string): Promise<Sleep[]> {
    // Both bounds are also stated in the query schema, which is what publishes them in the OpenAPI
    // document — a client should be able to read the limit rather than discover it. They are
    // repeated here because this is the layer that owns them: `MAX_SLEEP_WINDOW_DAYS` is defined
    // here and imported by the schema, not the other way round, and a caller arriving at this method
    // from the generator script or a test has passed through no schema at all.
    if (days > MAX_SLEEP_WINDOW_DAYS) {
      throw new SleepError(
        "invalid_request",
        `days must be at most ${MAX_SLEEP_WINDOW_DAYS}, got ${days}`,
      );
    }

    if (days < 0) {
      throw new SleepError(
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
   * An upsert rather than an insert, because that is what the app's `saveSleep` is: GRDB's `save` is
   * INSERT-or-UPDATE by primary key, so a `PUT` to a night that already has a row replaces it. The
   * `date` is taken from the path and the body carries none, so the two can never disagree.
   *
   * **Every field is passed through as it arrived, and on this resource that is the whole method.**
   * There is no `?? 0`, no `?? ""`, no `Boolean(...)` and no default of any kind: a `source` of
   * `null` stays `null`, and so do a respiratory rate, a disturbance count, a consistency score and a
   * debt. Three of those six have a model on the client that would produce a number if asked — and
   * the app's own readers tell "the estimator declined" from "the estimator answered" by exactly this
   * `null`. A server that filled one in would be publishing a reading nobody took, and it would be
   * published to the very device that knows better.
   *
   * `sleepStages` is passed through as the opaque string it is: nothing in this file parses,
   * validates or re-serialises it. The wire type is a string precisely so that no layer of this
   * Worker has to hold an opinion about the JSON inside it — see `dto/sleeps.ts` for why, and for
   * the unit the instants in that blob are in.
   */
  async writeDay(userId: string, date: string, input: SleepInput): Promise<Sleep> {
    return this.repository.upsert({ userId, date, ...input });
  }

  /**
   * Write a chunk of days, and answer with how many rows the database reported writing.
   *
   * This is the app's sync of nine hundred nights in five requests instead of nine hundred. The chunk
   * is written by `upsertMany`, which is atomic — so a throw here means nothing was written and the
   * same body can be sent again.
   *
   * **Idempotent by the same key `writeDay` is.** Every row is upserted on `(userId, date)`, so a
   * chunk replayed after a timeout that the client never saw the answer to rewrites each row with the
   * values it already holds: no duplicates, no row count moved, and no need for the client to know
   * whether the first attempt landed. That is the property a retry needs and the reason this endpoint
   * is `POST /batch` rather than a `PUT` on the collection — a `PUT` on `/v1/sleeps` would say "these
   * are the nights", and a sync that says that has to delete the ones it left out, which on a
   * resource with holes in it is a promise about deleting a fourth of the user's history.
   *
   * The three refusals below are the schema's rules restated in the layer that owns them, the same
   * way `readWindow` restates its two: a caller reaching this method from a script or a test has
   * passed through no schema at all.
   */
  async writeMany(userId: string, entries: readonly SleepBatchEntry[]): Promise<number> {
    // An empty batch is a client that has not decided what to send. Answering `200` with `written: 0`
    // would make that look like a successful sync of nothing, which is the failure this project's
    // absence rules exist to keep visible.
    if (entries.length === 0) {
      throw new SleepError("invalid_request", "rows must not be empty");
    }

    if (entries.length > MAX_BATCH_SLEEPS) {
      throw new SleepError(
        "invalid_request",
        `rows must hold at most ${MAX_BATCH_SLEEPS} days, got ${entries.length}`,
      );
    }

    // Two rows for one night in one request is a client that has computed its day set twice and
    // disagreed with itself. It would also be *silently* harmless — the second write wins, and the
    // row that ends up on disk is whichever the array happened to put last — which is precisely why
    // it is refused rather than allowed to be resolved by ordering. The stakes are the highest on
    // this resource of the three that share the rule: a night carries sixteen fields and two versions
    // of it could differ in *any* of them, so the day would end up holding a night assembled from one
    // array position and its boundary instants from another, with nothing anywhere reporting it.
    const days = new Set(entries.map((entry) => entry.date));
    if (days.size !== entries.length) {
      const repeated = entries.length - days.size;
      throw new SleepError(
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
