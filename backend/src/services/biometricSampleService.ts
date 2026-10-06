import type { BiometricSample, BiometricSampleRepository } from "../domain";
import { ApiRefusal, type ApiErrorCode } from "../utils/errors";
import { parseInstant } from "../utils/instants";

/**
 * Policy for `biometric_samples` — what is neither HTTP nor SQL.
 *
 * **The window is the whole of what this service adds to a sibling's policy, and the file is short
 * because there is nothing else for policy to be about.** Every other service here counts its window in
 * days and derives a lower bound from an upper one; this one is handed both bounds and checks that the
 * span between them is one a read may ask for. Everything else a sibling covers is absent for a reason
 * that is the resource's shape rather than an omission:
 *
 * - No **`days`/`endingOn` pair and no `addDays`**, so no off-by-one to inherit and no defaulted upper
 *   bound to choose. A day of this table is up to 86,400 rows, so a day-counted window would be a read
 *   nothing should ask for — see the cap below.
 * - No **`hasMeasurement` rule**, because there is no second kind of row: a sample exists only when the
 *   decoder had a pulse to report, so every stored row is a measurement and there is no reserved zero
 *   to guard.
 * - No **share that must sum to at most 100** and no aggregate caps, because a sample is one
 *   notification with no children. That is what makes the row cap the work cap here, where a workout's
 *   is not.
 *
 * What is left is the four refusals below, and the two structural ones are stated in the query schema
 * as well as here for the reason `readWindow` gives: **a caller arriving from a script or a test has
 * passed through no schema at all**, so the layer that owns a rule is the layer that enforces it. That
 * is why the `from <= to` rule and the span ceiling live here and **not** as a `.refine()` on the query
 * object — this Worker's `.refine()`s appear only on *field* schemas and *body* schemas, and a rule on
 * a query object would hold for HTTP callers alone.
 *
 * There is deliberately no `D1Database`, no `Request`/`Response`, no status code and no Zod import in
 * this file. See `services/index.ts`.
 */

/**
 * The most samples one `POST /v1/biometric-samples/batch` may carry.
 *
 * `200` like every other batch cap in this Worker, and separate from them for the reason those six
 * names already carry — but **the argument here is different in kind from theirs, and it is the first
 * resource where the inherited number is far below the population it is a cap on.** A sample row is one
 * statement exactly as a recovery row is, so the cost per row separates nothing; what separates this
 * resource is that a day at 1 Hz is up to 86,400 samples, which makes 200 roughly **a three-minute
 * chunk** and a full day about 432 requests. That is a real consequence and it is not hidden: it is why
 * the window below is a span rather than a day count, and it is why a client syncing a long history is
 * expected to chunk rather than to send.
 *
 * **It is not raised here.** The rule the six siblings state is that `MAX_BATCH_*` is a *published*
 * limit — a client reads it out of the document and sizes its own buffers against it — so a new
 * resource does not get to move a number its clients have already been told. A bigger cap would also be
 * a bigger single transaction, and one all-or-nothing request of ten thousand rows is a request that
 * fails as a unit when one row is wrong.
 */
export const MAX_BATCH_BIOMETRIC_SAMPLES = 200;

/**
 * The widest instant range one `GET /v1/biometric-samples` may ask for, in seconds.
 *
 * **A week, and the number is deliberately in this resource's own unit.** The four day-keyed windows
 * publish `4000` because on those resources a day is *one row*; here a day is up to 86,400 rows, so
 * reusing `MAX_WINDOW_DAYS` would either be a unit error or a ceiling that permits ten million
 * samples. `604_800` is seven days exactly, written in seconds because that is what this window is
 * measured in.
 *
 * **What this ceiling is not is a response-size limit.** 604,800 samples is far more than any response
 * should carry, and it is not the bound that keeps a response small. What it is is the bound that makes
 * **"give me everything" unaskable** rather than merely large: without it, a client that has never
 * synced can ask for its whole history in one request and there is no number in the contract that says
 * why that is a bad idea. With it, the widest honest question is a week and a long sync is a walk —
 * which is the shape the app's own `getSamples(from:to:)` port already has, since it takes both bounds
 * from the caller and nothing in it invites an unbounded read.
 *
 * A week was chosen rather than a day because a day is the unit a *client* thinks in for a sync and a
 * day is ~86,400 rows — asking a client to chunk a day into three-hour pieces would be a limit that
 * makes an ordinary sync awkward to no one's benefit. It is not `MetricWeek`'s seven days derived from
 * the app (that is a chart width); it is the same number arrived at from the other side, as the widest
 * span whose row count is still a number a Worker can be asked for.
 */
export const MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS = 604_800;

/**
 * A sample's stored fields, less the two the request determines.
 *
 * Derived from `BiometricSample` rather than written out, so a field added to the domain type is a
 * compile error here until it is accepted or explicitly excluded. `id` is dropped because it is in the
 * path of the `PUT` this type belongs to; `userId` because it comes from the header, and a body
 * carrying one would be a second opinion about whose row this is.
 *
 * **`timestamp` is on this type and is required**, which is the one place this resource's write differs
 * in kind from its siblings'. On `receptiveInactivities` the day is in the body because nothing can
 * derive it; here the instant is in the body because the instant **is** the sample — it is the lookup
 * column, the read window's subject, and the natural input to the id the path carries. Deriving it from
 * the server's clock would stamp the moment the write arrived rather than the moment the beats were
 * heard, which is a different reading of a different thing.
 */
export type BiometricSampleInput = Omit<BiometricSample, "userId" | "id">;

/**
 * One sample of a bulk write: the same stored fields, plus the identity the path would have carried.
 *
 * `id` is back on the type, where `BiometricSampleInput` deliberately drops it, because a batch has no
 * path to put it in. The same split `RecoveryInput`/`RecoveryBatchEntry` and
 * `WorkoutInput`/`WorkoutBatchEntry` draw.
 */
export type BiometricSampleBatchEntry = Omit<BiometricSample, "userId">;

/**
 * A refusal this layer made, carrying the code the API publishes for it.
 *
 * Its own name so a log line says `BiometricSampleError` rather than `ApiRefusal` and a stack names the
 * resource that refused; the code field and the `body` builder are `ApiRefusal`'s, which is what the
 * route's single catch arm tests.
 */
export class BiometricSampleError extends ApiRefusal {
  constructor(code: ApiErrorCode, message: string) {
    super(code, message);
    this.name = "BiometricSampleError";
  }
}

export class BiometricSampleService {
  constructor(private readonly repository: BiometricSampleRepository) {}

  /**
   * One sample, or `null` when this partition holds no such id.
   *
   * `null` rather than a throw, and rather than a record of nulls: whether an absent id is a `404` or a
   * `200` is an HTTP question and belongs to the route. This answers the only question it can — is there
   * a row?
   *
   * **This read has no counterpart in the app's own port, and it is carried anyway.** The app's
   * `BiometricRepository` declares `getSamples(from:to:)` and no `findById`, because nothing on a phone
   * needs to fetch one sample by identity — a sample is only ever read as part of a night's series. The
   * endpoint exists because every id-keyed resource in this API is addressed at its own URL, and a
   * client that has just written one id and wants to confirm it landed should not have to ask for a
   * window around it. That is a judgement rather than a consequence of the storage, and it is recorded
   * here rather than left for a reader to infer from the app.
   *
   * `id` is trusted to be a UUID string. It has already round-tripped through
   * `BIOMETRIC_SAMPLE_ID_PATTERN` at the route's param schema, and re-testing it here would be a second
   * statement of that rule with its own chance of disagreeing.
   */
  async readOne(userId: string, id: string): Promise<BiometricSample | null> {
    return this.repository.findById(userId, id);
  }

  /**
   * Every sample whose arrival instant falls in `from`…`to`, **inclusive at both ends**, oldest first.
   *
   * **Both bounds are required and neither is defaulted, and that is a judgement.** A defaulted `to`
   * would be the Worker's own clock answering the caller's question, which is a different thing from a
   * defaulted upper bound expressed as a *day* the server can at least name — and this resource has no
   * `utcToday()` to reach for in any case, since there is no day in this read at all. The app's port
   * requires both, so the honest shape requires both.
   *
   * **The two refusals below are the rules the query schema publishes and this layer owns.** They are
   * not restatements for their own sake: a caller arriving here from a test or a script has passed
   * through no schema, and a rule that holds for HTTP callers alone is a rule about HTTP rather than
   * about this resource. The instant strings themselves are *not* re-validated — they round-tripped
   * through `InstantSchema` at the route — but they are parsed, because the two rules below are
   * comparisons between the values and a comparison needs the numbers.
   */
  async readWindow(userId: string, from: string, to: string): Promise<BiometricSample[]> {
    const fromInstant = parseInstant(from);
    const toInstant = parseInstant(to);

    // Unreachable through the route, since `InstantSchema` refuses a non-canonical instant before a
    // handler runs. It is here because this method is callable without a route, and because a silent
    // `NaN` comparison below would pass a reversed or absurd window through as if it were fine.
    if (fromInstant === null) {
      throw new BiometricSampleError("invalid_request", `from must be a canonical UTC instant, got ${from}`);
    }

    if (toInstant === null) {
      throw new BiometricSampleError("invalid_request", `to must be a canonical UTC instant, got ${to}`);
    }

    // A reversed window is refused rather than answered with an empty array. It is not "a range with
    // nothing in it" — it is a client whose two bounds have been swapped, and the empty array would
    // come back indistinguishable from a week the strap did not cover, which is the one distinction
    // this resource's client most needs to keep.
    if (fromInstant > toInstant) {
      throw new BiometricSampleError(
        "invalid_request",
        `from must not be later than to, got ${from} and ${to}`,
      );
    }

    // Phrased in seconds because that is the unit the cap is published in, so the message and the
    // document name the same number and a client can read one against the other. The comparison is
    // made in milliseconds because that is what `parseInstant` answers with.
    const spanSeconds = (toInstant - fromInstant) / 1000;
    if (spanSeconds > MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS) {
      throw new BiometricSampleError(
        "invalid_request",
        `the window must span at most ${MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS} seconds, got ${spanSeconds}`,
      );
    }

    return this.repository.listWindow(userId, from, to);
  }

  /**
   * Write one sample, addressed by its id, and answer with it as it is on disk.
   *
   * An upsert, because that is what the app's own storage is: GRDB's `save` is INSERT-or-UPDATE by
   * primary key, so a `PUT` to an id that already has a row replaces it and keeps its identity. The `id`
   * comes from the path and the body carries none, so the two can never disagree.
   *
   * **`id` is not derived here, and that is the resource's sharpest decision.** The app has no sample
   * identifier that could travel — its local key is an autoincrement assigned by that device's own
   * SQLite and read back by nothing — so a derived id is the only kind that works across two devices in
   * one partition, and the derivation is the client's. This Worker validates the *shape* and documents
   * the requirement — it must be deterministic, so that a replay is an upsert rather than a second row —
   * and deliberately does not reproduce a recipe, because a server that derived an id would be a second
   * implementation of the client's identity that could disagree with it.
   *
   * **All nine nullable fields cross this method exactly as they arrived.** No `?? 0`, no `?? null`, no
   * normalisation: the column being nullable *is* the absence, and `null` is the strap's own word for a
   * channel it did not report. A substituted `0.0` on an accelerometer axis would be free fall, which
   * lands on the *still* side of every movement threshold; a substituted `false` on `isOnBody` would be
   * an answer to a question nobody answered. The schema refuses the third spellings (an empty R-R
   * array) rather than this layer normalising them, on `""`'s rule in `receptiveInactivityService.ts`.
   */
  async writeOne(userId: string, id: string, input: BiometricSampleInput): Promise<BiometricSample> {
    return this.repository.upsert({ userId, id, ...input });
  }

  /**
   * Write a chunk of samples as one unit, answering how many **samples** the database wrote.
   *
   * Samples and rows are the same number on this resource — a sample has no children — and the port
   * still says *samples* rather than rows, because that is the quantity `POST /batch` publishes and a
   * caller should not have to know that this resource's arithmetic happens to be the identity.
   *
   * **Idempotent by the same key `writeOne` is, and here that is the property the whole endpoint exists
   * for.** Every sample lands on the same `(userId, id)` pair, and the id is the client's own
   * deterministic derivation, so a chunk replayed after a timeout rewrites each row with the values it
   * already holds — no duplicates, and no need for the client to know whether the first attempt landed.
   * That is what makes this `POST /batch` and not a `PUT` on the collection: a `PUT` on
   * `/v1/biometric-samples` would say "these are the samples", and a sync that says that has to delete
   * the ones it left out. This API has no delete path anywhere — the Worker's standing shape rather than
   * an omission on this resource — so a batch adds and replaces and never removes.
   *
   * The four refusals below are the schema's rules restated in the layer that owns them.
   */
  async writeMany(
    userId: string,
    samples: readonly BiometricSampleBatchEntry[],
  ): Promise<number> {
    // An empty batch is a client that has not decided what to send. Answering `200` with `written: 0`
    // would make that look like a successful sync of nothing, which is the failure this project's
    // absence rules exist to keep visible.
    if (samples.length === 0) {
      throw new BiometricSampleError("invalid_request", "rows must not be empty");
    }

    // The cap is far below one day's data, and the message says the number rather than apologising for
    // it: a client that hits this is a client that has not chunked, and the count it is told is the
    // count it must chunk by.
    if (samples.length > MAX_BATCH_BIOMETRIC_SAMPLES) {
      throw new BiometricSampleError(
        "invalid_request",
        `rows must hold at most ${MAX_BATCH_BIOMETRIC_SAMPLES} samples, got ${samples.length}`,
      );
    }

    // Uniqueness is on `id`, as it is on `receptiveInactivities` and on `workouts`, and the case for it
    // is stronger here than on either. Two rows sharing an id are a client that has minted one identity
    // twice — and on this resource that is the *likely* failure rather than the careless one, because
    // an id folded from the arrival instant alone makes two samples in one millisecond the same id, and
    // a batch is exactly where a burst of those arrives together. Refused rather than resolved by
    // ordering: the second write would win silently and the row left on disk would be whichever the
    // array happened to put last.
    const ids = new Set(samples.map((sample) => sample.id));
    if (ids.size !== samples.length) {
      const repeated = samples.length - ids.size;
      throw new BiometricSampleError(
        "invalid_request",
        `rows carry ${repeated} repeated ${repeated === 1 ? "id" : "ids"}; a batch must name each sample once`,
      );
    }

    return this.repository.upsertMany(samples.map((sample) => ({ userId, ...sample })));
  }
}
