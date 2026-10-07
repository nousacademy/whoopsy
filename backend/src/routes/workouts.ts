import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import type { Workout } from "../domain";
import { RequestHeaderSchema } from "../dto/shared";
import {
  WorkoutBatchResultSchema,
  WorkoutBatchWriteSchema,
  WorkoutIdSchema,
  WorkoutSchema,
  type WorkoutWire,
  WorkoutWindowQuerySchema,
  WorkoutWriteSchema,
} from "../dto/workouts";
import type { Env } from "../env";
import { D1WorkoutRepository } from "../repositories";
import { WorkoutService } from "../services";
import { utcToday } from "../utils/days";
import { apiError } from "../utils/errors";
import { deriveUserId } from "../utils/identity";
import { errorResponse, unauthorizedResponse, validationHook } from "./errors";

/**
 * The four `workouts` endpoints, and nothing else.
 *
 * This file is `recoveries.ts` with the resource swapped, and the places where it deliberately is not
 * are the places the two resources genuinely differ. Three of them are worth naming before the code,
 * because each looks like an inconsistency until you follow it back to the table:
 *
 * **A session is addressed by `{id}` and carries its day in the body.** `recoveries` is `/{date}` and
 * refuses a `date` in the body, because the path states it and a second statement of one fact can
 * only disagree with the first. Here a day holds several sessions, so the id is the address — and
 * `date` has to come from the body, because it is the client's `startOfDay(startedAt)` in its own
 * calendar and a UTC Worker cannot derive it. The `PUT` therefore inverts its sibling exactly:
 * identity in the path, day in the body.
 *
 * **There is a fifth schema, and it is the aggregate's.** `route` and `splits` ride inside a session
 * and the write *replaces* them, so they are required rather than defaulted — see
 * `dto/workouts.ts`. The consequence reaches this layer as a wire shape that is deeper than a
 * recovery's, which is the whole reason `toWire` below maps three levels rather than one.
 *
 * **The 404 says `not_found`, not `no_measurement_for_day`.** The sibling's code names a *day* that
 * has no reading, which is a statement about a calendar; `not_found` names an id the partition does
 * not hold, which is a statement about a row. A client switching on the code must be able to tell a
 * day it has not synced from a session it has lost, and only the second is a reason to re-read
 * anything.
 *
 * As in the sibling, a handler validates, calls the service and shapes a response: no SQL, no policy,
 * no `Env` outside `serviceFor`, and the one HTTP decision taken here rather than in the service —
 * that an absent row is a `404` rather than a `200` holding `null`.
 */

/** Paths are declared relative to `/v1/workouts`; this is the route's own path-parameter schema. */
const IdParamSchema = z.object({ id: WorkoutIdSchema });

/**
 * The composition root for this resource.
 *
 * `D1WorkoutRepository.from(c.env)` rather than a module-level singleton, for `recoveries`' reason: an
 * isolate is reused across requests, so a repository captured at module scope would hold the first
 * request's bindings for the life of the isolate.
 */
function serviceFor(env: Env): WorkoutService {
  return new WorkoutService(D1WorkoutRepository.from(env));
}

/**
 * The caller's partition: the header value, hashed, and never the header itself.
 *
 * Every handler goes through this, and the failure it prevents is the same one `recoveries.ts`
 * describes — a caller's rows filed under two different `user_id`s, one hashed and one literal,
 * with a batch answering `200` for rows a `GET` then calls missing. That failure is worse here and
 * not better: a session's children are keyed on `(user_id, id)` in their own tables, so a second
 * partition would not merely hide a session, it would store its route against one owner and its
 * parent row against another.
 */
function partitionFor(headers: { readonly "x-whoopsy-user-id": string }): Promise<string> {
  return deriveUserId(headers["x-whoopsy-user-id"]);
}

/**
 * Domain to wire, spelled out field by field.
 *
 * Spelled out rather than spread-and-strip, for `recoveries`' reason and one more: the return type is
 * `WorkoutWire`, so a field added to `workoutFields` and forgotten here is a compile error rather
 * than a column that quietly never leaves the database. With three nested shapes rather than one flat
 * record, that check is doing real work — `hrZonePercents` and `route` are both arrays, and a mapper
 * that returned the wrong one in the wrong slot would satisfy a spread-and-strip and fail this.
 *
 * **The arrays are spread, and the spread is load-bearing rather than defensive.** The domain type
 * says `readonly number[]` and `readonly WorkoutRoutePoint[]` — the repository hands back what it
 * read and no caller may mutate it — while `z.infer` gives the mutable `number[]` and an array of
 * mutable objects. Those are different types and TypeScript will not bridge them implicitly, which is
 * exactly the right outcome: the copy is where the mutation boundary is, and a wire shape handed the
 * repository's own array would be a response body sharing storage with the read that produced it.
 *
 * `userId` is withheld for `recoveries`' reason: it is the caller's own identity, already known from
 * the request that asked, and publishing it invites a client to read an owner out of a payload
 * instead of out of the credential.
 */
function toWire(workout: Workout): WorkoutWire {
  return {
    id: workout.id,
    date: workout.date,
    startedAt: workout.startedAt,
    endedAt: workout.endedAt,
    strain: workout.strain,
    averageHeartRate: workout.averageHeartRate,
    maxHeartRate: workout.maxHeartRate,
    source: workout.source,
    activityName: workout.activityName,
    hrZonePercents: workout.hrZonePercents === null ? null : [...workout.hrZonePercents],
    steps: workout.steps,
    offlineRegionID: workout.offlineRegionID,
    route: workout.route.map((point) => ({
      id: point.id,
      latitude: point.latitude,
      longitude: point.longitude,
      timestamp: point.timestamp,
      heartRate: point.heartRate,
    })),
    splits: workout.splits.map((split) => ({
      id: split.id,
      elapsed: split.elapsed,
      strain: split.strain,
    })),
  };
}

const listWorkouts = createRoute({
  method: "get",
  path: "/",
  summary: "Read a window of sessions",
  description:
    "Every session filed on a day in an inclusive window ending on `endingOn`, oldest first. The answer is a bare array with **no padding**: a day inside the window holding no session is simply absent, and an empty array means nothing in the window was recorded. A day holds several sessions, so there is no per-day slot for one to occupy.",
  request: {
    query: WorkoutWindowQuerySchema,
    headers: RequestHeaderSchema,
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The sessions in the window, oldest first, each with its route and splits.",
      content: { "application/json": { schema: z.array(WorkoutSchema) } },
    },
    400: errorResponse("A query parameter failed validation."),
  },
});

const readWorkout = createRoute({
  method: "get",
  path: "/{id}",
  summary: "Read one session",
  description:
    "One session and everything filed under it, or `404 not_found` if this partition holds no such id. The children come back with it — a caller never fetches a route separately, because a route has no identity outside the session that owns it.",
  request: {
    params: IdParamSchema,
    headers: RequestHeaderSchema,
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The session, with its route and splits in order.",
      content: { "application/json": { schema: WorkoutSchema } },
    },
    400: errorResponse("`id` is not a UUID."),
    404: errorResponse("No session with that id in this partition."),
  },
});

const writeWorkout = createRoute({
  method: "put",
  path: "/{id}",
  summary: "Write one session",
  description:
    "Insert or replace the session and its children — the upsert the app's own `saveWorkout` is. **A write replaces the route and the splits**, so a body must carry them: an omitted `route` is a `400`, not a silent deletion of a stored path. Answers with the row **read back from the database**, so a caller can see that a `null` stayed `null` rather than being folded into a `0` or an empty array.",
  request: {
    params: IdParamSchema,
    headers: RequestHeaderSchema,
    body: {
      required: true,
      content: { "application/json": { schema: WorkoutWriteSchema } },
    },
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The stored session, as the database holds it.",
      content: { "application/json": { schema: WorkoutSchema } },
    },
    400: errorResponse("The id, the header or the body failed validation."),
  },
});

const writeWorkoutBatch = createRoute({
  method: "post",
  path: "/batch",
  summary: "Write a chunk of sessions",
  description:
    "Insert or replace up to `MAX_BATCH_WORKOUTS` sessions in one request — the shape the app's first sync needs, where a six-hundred-and-seventy-three-session history is four of these instead of six hundred and seventy-three round trips. Every session is keyed on the same `(userId, id)` pair the single-session `PUT` writes, so a chunk replayed after a timeout is safe: **it rewrites each session with the values it already holds and the row count does not move.** The whole chunk is one transaction, so a failure writes nothing and the same body can be sent again. **It never deletes** — a session the caller leaves out is left alone, which is why this is a `POST` on `/batch` and not a `PUT` on the collection. `written` counts sessions and not rows.",
  request: {
    headers: RequestHeaderSchema,
    body: {
      required: true,
      content: { "application/json": { schema: WorkoutBatchWriteSchema } },
    },
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "How many sessions the database reported writing.",
      content: { "application/json": { schema: WorkoutBatchResultSchema } },
    },
    400: errorResponse(
      "The header or the body failed validation — including a chunk larger than the cap, an id carried twice, and a chunk whose routes or splits exceed what one request may hold.",
    ),
  },
});

export const workoutRoutes = new OpenAPIHono<{ Bindings: Env }>({
  defaultHook: validationHook,
})
  .openapi(listWorkouts, async (c) => {
    const { days, endingOn } = c.req.valid("query");
    const userId = await partitionFor(c.req.valid("header"));

    // Defaulted **here** and not in the schema, for `recoveries`' reason: a Zod `.default(utcToday())`
    // is evaluated once, when the module is first loaded, so a long-lived isolate would answer every
    // request for the rest of its life with the day it cold-started on. The default is a poor one
    // anyway — UTC is not the caller's today — and it exists only so the endpoint is usable from a
    // browser address bar.
    const through = endingOn ?? utcToday();

    const sessions = await serviceFor(c.env).readWindow(userId, days, through);

    return c.json(sessions.map(toWire), 200);
  })
  .openapi(readWorkout, async (c) => {
    const { id } = c.req.valid("param");
    const userId = await partitionFor(c.req.valid("header"));

    const workout = await serviceFor(c.env).readOne(userId, id);

    // `null` from the repository means this partition holds no such id, and the status is the route's
    // decision. `not_found` rather than the sibling's `no_measurement_for_day`: that code names a day
    // that has no reading, and this one names a session that is not here. A client syncing a history
    // treats them differently — one is a day it never recorded, the other is a session it believes it
    // has and does not — and collapsing them would take away the only signal that separates a gap
    // from a loss.
    if (workout === null) {
      return c.json(apiError("not_found", `no session with id ${id} in this partition`), 404);
    }

    return c.json(toWire(workout), 200);
  })
  .openapi(writeWorkout, async (c) => {
    const { id } = c.req.valid("param");
    const userId = await partitionFor(c.req.valid("header"));
    const body = c.req.valid("json");

    // `id` comes from the path and never from the body — the write schema has no `id` field, and
    // `.strict()` makes a body carrying one a `400` rather than a silent strip. `date`, by contrast,
    // is *required* in the body and nowhere else, because it is the device's day and this Worker
    // cannot derive it from `startedAt`. That split is the inversion this resource makes against
    // `recoveries`, and it is the same rule either way: a fact is stated once, in the one place that
    // can state it.
    const stored = await serviceFor(c.env).writeWorkout(userId, id, body);

    return c.json(toWire(stored), 200);
  })
  .openapi(writeWorkoutBatch, async (c) => {
    const userId = await partitionFor(c.req.valid("header"));
    const { rows } = c.req.valid("json");

    // The id is in each row and not in the path, for `recoveries`' reason moved from the day to the
    // session: a batch has no path to put it in. Both halves are enforced by the schemas, so a batch
    // row that forgot its id and a single-session body that carried one are each a `400`.
    //
    // The answer is the database's tally of **sessions**, not of rows and not an echo: see
    // `WorkoutBatchResultSchema` for why a replayed chunk reports the same number rather than zero.
    const written = await serviceFor(c.env).writeMany(userId, rows);

    return c.json({ written }, 200);
  });
