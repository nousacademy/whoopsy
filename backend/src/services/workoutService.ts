import {
  ZONE_COUNT,
  type Workout,
  type WorkoutRepository,
  type WorkoutRoutePoint,
  type WorkoutSplit,
} from "../domain";
import { addDays } from "../utils/days";
import { ApiRefusal, type ApiErrorCode } from "../utils/errors";
import { parseInstant } from "../utils/instants";
import { MAX_WINDOW_DAYS } from "./recoveryService";

/**
 * Policy for `workouts` — what is neither HTTP nor SQL.
 *
 * The window arithmetic is `recoveries`' and is reused rather than restated: both resources answer
 * "the last N days ending on D", the app computes that window in one place, and a second copy here
 * would be a second answer to an off-by-one that is already written down once.
 *
 * What is new here is the **aggregate's shape**, which `recoveries` has no equivalent of: a session
 * carries an ordered route and an ordered split list, and the write replaces both. So this file owns
 * the caps that bound how much of one request can be a child list, the ordering rule that keeps
 * `elapsedSeconds` from being negative, and the duplicate check — which for this resource is on
 * **`id` and not on `date`**, because a day holds several sessions. That inversion is the one place
 * this resource's policy differs from its sibling's, and it is the whole reason these cannot share a
 * batch validator.
 *
 * There is deliberately no `D1Database`, no `Request`/`Response`, no status code and no Zod import in
 * this file. See `services/index.ts`.
 */

/**
 * The most sessions one `POST /v1/workouts/batch` may carry.
 *
 * Sized against the app's real corpus rather than guessed at: the bundled WHOOP export is 673
 * sessions over 445 distinct days, so a full first sync is four requests at this cap. It is lower
 * than `recoveries`' 200-per-request in name only — the number is the same, and the *cost* per row is
 * not: a recovery is one statement and a session is at least three, before its children. That is why
 * this file carries three more caps below it.
 */
export const MAX_BATCH_WORKOUTS = 200;

/**
 * The most GPS fixes one session may carry.
 *
 * `2000` is a 10 km run at the app's `CoreLocationTrackingService.distanceFilter`, which records a
 * few metres apart — so this is above any route the app can produce, and a body that exceeds it is a
 * client pushing something other than a recorded route. The cap exists because a route is stored as
 * one INSERT per point inside a single batch, and an unbounded array would let one request become
 * tens of thousands of statements.
 */
export const MAX_ROUTE_POINTS = 2000;

/**
 * The most splits one session may carry.
 *
 * The app has no lap model at all — `workout_splits` has no producer — so this is a bound on a shape
 * nothing writes yet rather than on a real payload. It is set where a manual lap model would plausibly
 * land (a lap a kilometre for a marathon is 42) with generous headroom, and it exists so that the
 * schema can refuse an unbounded array rather than store one.
 */
export const MAX_SPLITS = 200;

/**
 * The most route points one *batch* may carry, across all of its sessions.
 *
 * This is the number that actually bounds a request's work, and it is deliberately separate from the
 * per-session cap above: `MAX_ROUTE_POINTS × MAX_BATCH_WORKOUTS` would be 400,000 statements, while
 * this caps the whole request at roughly `MAX_BATCH_WORKOUTS × 3 + MAX_BATCH_ROUTE_POINTS +
 * MAX_BATCH_SPLITS` — about 2,800 at the limits, and about 600 for the ordinary case of 200 sessions
 * with no children at all. A batch of many short routes and a batch of one long one are both fine;
 * a batch of two hundred long ones is not, and this is the number that says so.
 */
export const MAX_BATCH_ROUTE_POINTS = 2000;

/** The most splits one batch may carry. See `MAX_BATCH_ROUTE_POINTS` for why this is not per session. */
export const MAX_BATCH_SPLITS = 200;

/**
 * A session's stored fields, less the two the request determines.
 *
 * Derived from `Workout` rather than written out, so a field added to the domain type is a compile
 * error here until it is accepted or explicitly excluded. `id` is dropped because it is in the path
 * of the `PUT` this type belongs to; `userId` because it comes from the header and a body carrying
 * one would be a second opinion about whose row this is.
 */
export type WorkoutInput = Omit<Workout, "userId" | "id">;

/**
 * One session of a bulk write: the same stored fields, plus the identity the path would have carried.
 *
 * `id` is back on the type, where `WorkoutInput` deliberately drops it, because a batch has no path
 * to carry it. That is the whole reason the two types are not one — the same split `recoveries` draws
 * between `RecoveryInput` and `RecoveryBatchEntry`, moved from `date` to `id`.
 */
export type WorkoutBatchEntry = Omit<Workout, "userId">;

/**
 * A refusal this layer made, carrying the code the API publishes for it.
 *
 * Its own name so a log line says `WorkoutError`; the code field and the `body` builder are
 * `ApiRefusal`'s, which is what the route's single catch arm tests.
 */
export class WorkoutError extends ApiRefusal {
  constructor(code: ApiErrorCode, message: string) {
    super(code, message);
    this.name = "WorkoutError";
  }
}

/**
 * Refuse a session whose shape this layer will not store, naming it as `where` says.
 *
 * One function for the four rules rather than four checks at each of the two write paths, because
 * `writeWorkout` and `writeMany` must refuse the same bodies — a batch that accepted what a `PUT`
 * rejected would make the two endpoints disagree about what a session is, and the disagreement would
 * only show up as a row one of them wrote.
 *
 * Each rule is stated in this layer as well as in the schema, following `readWindow`'s precedent: a
 * caller arriving from a script or a test has passed through no schema at all.
 */
function checkSession(
  session: Pick<Workout, "id" | "startedAt" | "endedAt" | "hrZonePercents" | "route" | "splits">,
  where: string,
): void {
  const started = parseInstant(session.startedAt);
  if (started === null) {
    throw new WorkoutError("invalid_request", `${where}: startedAt is not a canonical instant`);
  }

  const ended = parseInstant(session.endedAt);
  if (ended === null) {
    throw new WorkoutError("invalid_request", `${where}: endedAt is not a canonical instant`);
  }

  // Strictly after, not merely different: a session of zero length is not a duration the app can
  // show, and a reversed pair would make every derived figure — the zone span, a fast's elapsed
  // seconds, a split's position — negative while looking like a stored session.
  if (ended <= started) {
    throw new WorkoutError("invalid_request", `${where}: endedAt must be after startedAt`);
  }

  if (session.route.length > MAX_ROUTE_POINTS) {
    throw new WorkoutError(
      "invalid_request",
      `${where}: route holds ${session.route.length} points, and ${MAX_ROUTE_POINTS} is the most a session may carry`,
    );
  }

  if (session.splits.length > MAX_SPLITS) {
    throw new WorkoutError(
      "invalid_request",
      `${where}: splits holds ${session.splits.length}, and ${MAX_SPLITS} is the most a session may carry`,
    );
  }

  const zones = session.hrZonePercents;
  if (zones !== null) {
    if (zones.length !== ZONE_COUNT) {
      throw new WorkoutError(
        "invalid_request",
        `${where}: hrZonePercents must hold ${ZONE_COUNT} shares, got ${zones.length}`,
      );
    }

    const whole = zones.every((share) => Number.isInteger(share) && share >= 0 && share <= 100);
    if (!whole) {
      throw new WorkoutError(
        "invalid_request",
        `${where}: hrZonePercents must be whole percents between 0 and 100`,
      );
    }

    // At most 100, never exactly 100: the five bands do not cover the session, and the time below
    // zone 1 belongs to no band. A block summing to more than 100 would be shares of something other
    // than the session's span, and the app derives a row's duration from its share — so the figure on
    // screen would exceed the session it sits inside.
    const total = zones.reduce((sum, share) => sum + share, 0);
    if (total > 100) {
      throw new WorkoutError(
        "invalid_request",
        `${where}: hrZonePercents sum to ${total}, and the five bands cannot cover more than the session`,
      );
    }
  }
}

export class WorkoutService {
  constructor(private readonly repository: WorkoutRepository) {}

  /**
   * One session with its children, or `null` when this partition holds no such id.
   *
   * `null` rather than a throw, and rather than a session of nulls: whether an absent id is a 404 or
   * a 200 is an HTTP question and belongs to the route. This answers the only question it can — is
   * there a row?
   *
   * `id` is trusted to be a UUID string. It has already round-tripped through `WORKOUT_ID_PATTERN` at
   * the route's param schema, and re-testing it here would be a second statement of that rule.
   */
  async readOne(userId: string, id: string): Promise<Workout | null> {
    return this.repository.findById(userId, id);
  }

  /**
   * The window `days` back from `endingOn`, **inclusive at both ends**, oldest session first.
   *
   * The off-by-one is `recoveries`' and is inherited rather than re-derived — see
   * `RecoveryService.readWindow`, which carries the argument in full. What is this resource's own is
   * the shape of the answer: an **array**, because a day holds several sessions, and no padding for a
   * day that has none. A day inside the window with no session is simply not represented.
   */
  async readWindow(userId: string, days: number, endingOn: string): Promise<Workout[]> {
    if (days > MAX_WINDOW_DAYS) {
      throw new WorkoutError(
        "invalid_request",
        `days must be at most ${MAX_WINDOW_DAYS}, got ${days}`,
      );
    }

    if (days < 0) {
      throw new WorkoutError("invalid_request", `days must not be negative, got ${days}`);
    }

    return this.repository.listWindow(userId, addDays(endingOn, -days), endingOn);
  }

  /**
   * Write one session, addressed by its id, and answer with it as it is on disk.
   *
   * An upsert, because that is what the app's `saveWorkout` is: GRDB's `save` is INSERT-or-UPDATE by
   * primary key, so a `PUT` to an id that already has a row replaces it and keeps its identity. The
   * `id` comes from the path and the body carries none, so the two cannot disagree.
   *
   * **`date` comes from the body and not from the path**, which is this resource's structural
   * difference from `recoveries`: the day is the client's `startOfDay(startedAt)` in the device's own
   * calendar, and a UTC Worker cannot derive it. A body that omits it is a `400` rather than a
   * server-computed guess.
   *
   * Every nullable field is passed through as it arrived; `?? null` and defaults of any kind appear
   * nowhere. A client that omits `strain` and one that sends `strain: null` mean the same thing — no
   * measurement — and this layer must not invent a third answer. `route` and `splits` are required by
   * the schema rather than defaulted to `[]`, because the write *replaces* the children: a body that
   * could leave `route` out would silently delete a stored route.
   */
  async writeWorkout(userId: string, id: string, input: WorkoutInput): Promise<Workout> {
    checkSession({ id, ...input }, id);

    return this.repository.upsert({ userId, id, ...input });
  }

  /**
   * Write a batch of sessions as one unit, answering how many **sessions** the database wrote.
   *
   * Sessions and not rows, deliberately: a session with a 2,000-point route touches 2,003 rows, so a
   * total counted in rows would be a function of how much GPS a run collected rather than of what was
   * sent. The adapter sums the parent upserts alone; this layer's job is to not promise otherwise.
   *
   * Idempotent by the same key `writeWorkout` is — every session is upserted on `(userId, id)`, so a
   * chunk replayed after a timeout the client never saw the answer to rewrites each session with the
   * values it already holds. That is why this is `POST /batch` and not a `PUT` on the collection: a
   * `PUT` on `/v1/workouts` would say "these are the sessions", and a sync that says that has to
   * delete the ones it left out — a promise about deletion this API does not make anywhere.
   *
   * The refusals below are the schema's rules restated in the layer that owns them.
   */
  async writeMany(userId: string, entries: readonly WorkoutBatchEntry[]): Promise<number> {
    // An empty batch is a client that has not decided what to send. Answering `200` with `written: 0`
    // would make that look like a successful sync of nothing.
    if (entries.length === 0) {
      throw new WorkoutError("invalid_request", "rows must not be empty");
    }

    if (entries.length > MAX_BATCH_WORKOUTS) {
      throw new WorkoutError(
        "invalid_request",
        `rows must hold at most ${MAX_BATCH_WORKOUTS} sessions, got ${entries.length}`,
      );
    }

    // Uniqueness is on `id` here and on `date` in `recoveries`, and the inversion is the resource's
    // whole shape: a day holds several sessions, so two rows sharing a date are an ordinary Tuesday
    // while two sharing an id are a client that has minted one identity twice. That case is refused
    // rather than resolved by ordering, because the second write would win silently and the row on
    // disk would be whichever the array happened to put last.
    const ids = new Set(entries.map((entry) => entry.id));
    if (ids.size !== entries.length) {
      const repeated = entries.length - ids.size;
      throw new WorkoutError(
        "invalid_request",
        `rows carry ${repeated} repeated ${repeated === 1 ? "id" : "ids"}; a batch must name each session once`,
      );
    }

    let routePoints = 0;
    let splits = 0;

    for (const entry of entries) {
      checkSession(entry, entry.id);
      routePoints += entry.route.length;
      splits += entry.splits.length;
    }

    // The aggregate caps are checked after the per-session ones, so a single oversized route is
    // reported as that rather than as the batch total it also happens to exceed — the more specific
    // refusal is the one that says what to change.
    if (routePoints > MAX_BATCH_ROUTE_POINTS) {
      throw new WorkoutError(
        "invalid_request",
        `rows carry ${routePoints} route points in total, and one request may carry ${MAX_BATCH_ROUTE_POINTS}`,
      );
    }

    if (splits > MAX_BATCH_SPLITS) {
      throw new WorkoutError(
        "invalid_request",
        `rows carry ${splits} splits in total, and one request may carry ${MAX_BATCH_SPLITS}`,
      );
    }

    return this.repository.upsertMany(entries.map((entry) => ({ userId, ...entry })));
  }
}

/**
 * The children types are re-exported from here for the route's schema, which describes them as
 * request bodies and should not have to reach into the repository layer to name them.
 */
export type { WorkoutRoutePoint, WorkoutSplit };
