import type { Strain, StrainRepository } from "../domain";
import { addDays } from "../utils/days";
import { ApiRefusal, type ApiErrorCode } from "../utils/errors";

/**
 * Policy for `strains` — what is neither HTTP nor SQL.
 *
 * Three things live here and nothing else does: **the window arithmetic**, which is the only place a
 * `days` number becomes a pair of day keys; **the absence decision**, which is that a day with no row
 * is `null` and the caller turns that into a 404; and **passing `hasMeasurement` through untouched**,
 * never normalized and never inferred from a figure, because a value this layer computed would be a
 * claim about whether a reading was taken — which is the one thing the score cannot tell it.
 *
 * There is deliberately no `D1Database`, no `Request`/`Response`, no status code and no Zod import in
 * this file. That is what makes it exercisable against a fake port with no Worker and no database,
 * and it is the rule `services/index.ts` states.
 */

/**
 * The widest window this endpoint will answer.
 *
 * `4000` is not invented: it is the value the iOS app's own suite passes to `getStrainHistory(days:)`
 * when it wants "everything that is there". The cap exists so that a typo'd `days` cannot ask a
 * database for a hundred thousand days of range scan, and it is set above any real history rather
 * than below it so that the legitimate call is never the one refused.
 *
 * **Deliberately not `MAX_WINDOW_DAYS`**, even though the two are equal today. `services/index.ts`
 * gives the rule for the batch pair and it applies here unchanged: the day one is retuned for cost,
 * a shared constant would move the other's published limit with it and nothing would say so. Two
 * resources whose windows happen to match are still two published limits.
 */
export const MAX_STRAIN_WINDOW_DAYS = 4000;

/**
 * The most rows one `POST /v1/strains/batch` may carry.
 *
 * **Measured rather than guessed, and the measurement is what it is a cap on.** The app's real corpus
 * is the bundled WHOOP export: 931 strains rows over 931 distinct days, which is the largest push
 * this endpoint will ever see from the device it was written for. At 200 rows a request that is five
 * round trips, which a phone does on a coffee break and a chunk of 931 in one request is not
 * obviously safe to send — D1 documents limits on a request's size and on the work one invocation
 * does, and a body carrying nine hundred rows is where those start to matter.
 *
 * **Deliberately not `MAX_BATCH_ROWS`**, which is the same `200` and the same reasoning, for the
 * reason spelled out on that constant in `services/index.ts`: a recovery is one statement and a
 * strain is one statement, and the two limits are still two constants because retuning the day one
 * for cost would otherwise move the strain one's published limit with it and nothing would say so.
 *
 * The cap is stated here, in the layer that owns the number, and imported by the schema that
 * publishes it — the same arrangement `MAX_STRAIN_WINDOW_DAYS` has, and for the same reason: a client
 * should be able to read the limit out of the OpenAPI document rather than discover it, and there
 * must be one place to change it rather than two that agree today.
 */
export const MAX_BATCH_STRAINS = 200;

/**
 * One day-range write's payload: the stored fields, less the two the request already determines.
 *
 * Derived from `Strain` rather than written out, so a column added to the domain type is a compile
 * error here until it is accepted or explicitly excluded — the alternative is a new field that
 * silently never leaves the request body. That derivation is also what carries `hasMeasurement` onto
 * the wire without a line of code naming it: it is a stored field like any other, and nothing in this
 * layer is entitled to decide whether it may be omitted.
 */
export type StrainInput = Omit<Strain, "userId" | "date">;

/**
 * One row of a bulk write: the same stored fields, plus the day each row is filed under.
 *
 * `date` is back on the type, where `StrainInput` deliberately drops it, because a batch has no path
 * to carry it. That is the whole reason the two types are not one: on a `PUT` the day is in the URL
 * and a body holding one is a `400`, while in a batch every row must name its own day or the request
 * means nothing.
 */
export type StrainBatchEntry = StrainInput & { readonly date: string };

/**
 * A refusal this layer made, carrying the code the API publishes for it.
 *
 * The *code* is HTTP vocabulary and the *message* is this layer's — the service knows why a range was
 * refused and the route knows what status that becomes, so the two halves stay where the knowledge
 * is. The route maps the code to a status and does not restate the reason.
 *
 * The shared half — the code field and the `body` builder — lives on `ApiRefusal`, which is what
 * `routes/errors.ts` catches. This class exists for its *name*: the log line says `StrainError`
 * rather than `ApiRefusal`, so a stack names the resource that refused. `errorHandler` tests the base
 * class deliberately, so a new resource's refusal needs no edit there.
 */
export class StrainError extends ApiRefusal {
  constructor(code: ApiErrorCode, message: string) {
    super(code, message);
    this.name = "StrainError";
  }
}

export class StrainService {
  constructor(private readonly repository: StrainRepository) {}

  /**
   * One day's row, or `null` when that day has no row.
   *
   * `null` rather than a zero-filled record, and rather than a throw: whether an absent day is a 404
   * or a 200 with a body is an HTTP question and belongs to the route. This method answers the only
   * question it can — is there a row?
   *
   * **It answers a row and not a measurement**, and that distinction is this resource's alone. The
   * adapter returns an unmeasured row it finds, because the row exists and withholding it would be a
   * decision; this method forwards it; and the route puts `hasMeasurement: false` on the wire rather
   * than a 404. That is the whole reason the flag travels: the client already stores it, and a server
   * that turned a placeholder into an absence would be answering a different question from the one
   * `findByDay` was asked.
   *
   * `date` is trusted to be a day key. It has already round-tripped through `parseDayKey` at the
   * route's param schema, and re-deriving it here would be a second statement of the day-key rule
   * with its own chance of disagreeing.
   */
  async readDay(userId: string, date: string): Promise<Strain | null> {
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
   * The read is `[from, to]` and not a count, so a day inside the window with no row is simply absent
   * from the answer. There is no padding and no placeholder.
   */
  async readWindow(userId: string, days: number, endingOn: string): Promise<Strain[]> {
    // Both bounds are also stated in the query schema, which is what publishes them in the OpenAPI
    // document — a client should be able to read the limit rather than discover it. They are
    // repeated here because this is the layer that owns them: `MAX_STRAIN_WINDOW_DAYS` is defined
    // here and imported by the schema, not the other way round, and a caller arriving at this method
    // from the generator script or a test has passed through no schema at all.
    if (days > MAX_STRAIN_WINDOW_DAYS) {
      throw new StrainError(
        "invalid_request",
        `days must be at most ${MAX_STRAIN_WINDOW_DAYS}, got ${days}`,
      );
    }

    if (days < 0) {
      throw new StrainError(
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
   * An upsert rather than an insert, because that is what the app's `saveStrain` is: GRDB's `save` is
   * INSERT-or-UPDATE by primary key, so a `PUT` to a day that already has a row replaces it. The
   * `date` is taken from the path and the body carries none, so the two can never disagree.
   *
   * Every field is passed through as it arrived. There is no `?? 0`, no `?? false` and no default of
   * any kind: a `source` of `null` stays `null`, and a `hasMeasurement` of `false` stays `false`.
   * That last one is the load this method carries on this resource — a layer that helpfully inferred
   * the flag from a non-zero heart rate would rewrite the app's own record of whether a reading was
   * taken, and would do it invisibly, since the round trip would still look like a strain.
   */
  async writeDay(userId: string, date: string, input: StrainInput): Promise<Strain> {
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
   * is `POST /batch` rather than a `PUT` on the collection — a `PUT` on `/v1/strains` would say
   * "these are the days", and a sync that says that has to delete the ones it left out, which is a
   * promise about deletion this API does not make.
   *
   * The three refusals below are the schema's rules restated in the layer that owns them, the same
   * way `readWindow` restates its two: a caller reaching this method from a script or a test has
   * passed through no schema at all.
   */
  async writeMany(userId: string, entries: readonly StrainBatchEntry[]): Promise<number> {
    // An empty batch is a client that has not decided what to send. Answering `200` with `written: 0`
    // would make that look like a successful sync of nothing, which is the failure this project's
    // absence rules exist to keep visible.
    if (entries.length === 0) {
      throw new StrainError("invalid_request", "rows must not be empty");
    }

    if (entries.length > MAX_BATCH_STRAINS) {
      throw new StrainError(
        "invalid_request",
        `rows must hold at most ${MAX_BATCH_STRAINS} days, got ${entries.length}`,
      );
    }

    // Two rows for one day in one request is a client that has computed its day set twice and
    // disagreed with itself. It would also be *silently* harmless — the second write wins, and the
    // row that ends up on disk is whichever the array happened to put last — which is precisely why
    // it is refused rather than allowed to be resolved by ordering. The stakes are higher here than
    // on `recoveries` only in appearance: the two rows could carry different `hasMeasurement` flags,
    // and the day would end up claiming whichever one the array put last.
    const days = new Set(entries.map((entry) => entry.date));
    if (days.size !== entries.length) {
      const repeated = entries.length - days.size;
      throw new StrainError(
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
