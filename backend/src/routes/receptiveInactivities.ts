import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import type { ReceptiveInactivity } from "../domain";
import {
  ReceptiveInactivityBatchResultSchema,
  ReceptiveInactivityBatchWriteSchema,
  ReceptiveInactivityIdSchema,
  ReceptiveInactivitySchema,
  type ReceptiveInactivityWire,
  ReceptiveInactivityWindowQuerySchema,
  ReceptiveInactivityWriteSchema,
} from "../dto/receptiveInactivities";
import { RequestHeaderSchema } from "../dto/shared";
import type { Env } from "../env";
import { D1ReceptiveInactivityRepository } from "../repositories";
import { ReceptiveInactivityService } from "../services";
import { utcToday } from "../utils/days";
import { apiError } from "../utils/errors";
import { deriveUserId } from "../utils/identity";
import { errorResponse, unauthorizedResponse, validationHook } from "./errors";

/**
 * The four `/v1/receptive-inactivities` endpoints, and nothing else.
 *
 * This file is `workouts.ts` with the aggregate removed, and the removals are the whole of what is
 * interesting about it. There is no fifth schema, because there are no children: a session's `route`
 * and `splits` ride inside it and make `toWire` a three-level map, while an entry is six flat fields
 * and maps in one. There is no boundary rule, so no write is rejected for the *relationship* between
 * two of its fields — only for their shapes, plus the two cross-row rules a batch owns. And the
 * `PUT`'s body is not the inversion a session's is: `date` is required here, exactly as it is there,
 * for a reason that survives the difference — `startedAt` is optional on this row, so when no time
 * was given there is nothing for a UTC Worker to derive the day *from*.
 *
 * **A day holds several entries, so the resource is addressed at a collection.** `/{id}` is the
 * identity and `days=0&endingOn=<day>` is the day-shaped read, which is the app's ordinary call
 * rather than a degenerate window — see `ReceptiveInactivityService.readWindow`. A `/{date}` mount
 * would be a second way to ask a question that query already answers, and this API does not carry
 * `/v1/receptive-inactivities/{date}` at all; `tests/openapi.spec.ts` asserts its absence, which is
 * the mirror of the four `{id}`-absent assertions the day-keyed resources carry.
 *
 * **The 404 says `not_found`**, for `workouts`' reason: `no_measurement_for_day` names a *day* with
 * no reading, which is a statement about a calendar, while this names an id the partition does not
 * hold. An entry is never "unmeasured" — nothing on the row is a measurement — so the sibling's code
 * would be not merely imprecise here but false.
 *
 * As in both siblings, a handler validates, calls the service and shapes a response: no SQL, no
 * policy, no `Env` outside `serviceFor`, and the one HTTP decision taken here rather than in the
 * service — that an absent row is a `404` rather than a `200` holding `null`.
 */

/** Paths are declared relative to `/v1/receptive-inactivities`; this is the route's param schema. */
const IdParamSchema = z.object({ id: ReceptiveInactivityIdSchema });

/**
 * The composition root for this resource.
 *
 * `D1ReceptiveInactivityRepository.from(c.env)` rather than a module-level singleton, for the
 * siblings' reason: an isolate is reused across requests, so a repository captured at module scope
 * would hold the first request's bindings for the life of the isolate.
 */
function serviceFor(env: Env): ReceptiveInactivityService {
  return new ReceptiveInactivityService(D1ReceptiveInactivityRepository.from(env));
}

/**
 * The caller's partition: the header value, hashed, and never the header itself.
 *
 * Every handler goes through this, and the failure it prevents is the same one `recoveries.ts`
 * describes — a caller's rows filed under two different `user_id`s, one hashed and one literal, with
 * a batch answering `200` for rows a `GET` then calls missing.
 */
function partitionFor(headers: { readonly "x-whoopsy-user-id": string }): Promise<string> {
  return deriveUserId(headers["x-whoopsy-user-id"]);
}

/**
 * Domain to wire, spelled out field by field.
 *
 * Spelled out rather than spread-and-strip, for the siblings' reason: the return type is
 * `ReceptiveInactivityWire`, so a field added to `receptiveInactivityFields` and forgotten here is a
 * compile error rather than a column that quietly never leaves the database. On a flat six-field row
 * the spread would satisfy the compiler today, which is exactly why the check is worth keeping in
 * place before a seventh field exists to be dropped.
 *
 * **The two nullable fields are copied, not normalised**, and this is the one mapper in the Worker
 * where that sentence is load-bearing twice over: `note: null` and `startedAt: null` are the
 * ordinary case on this resource rather than the exception, so a `?? ""` or a `?? "00:00:00"` here
 * would rewrite every imported row into a fabricated value while every screen still looked
 * plausible. There is no `??` in this function and there must not be one.
 *
 * `userId` is withheld for the siblings' reason: it is the caller's own identity, already known from
 * the request that asked, and publishing it invites a client to read an owner out of a payload
 * instead of out of the credential.
 */
function toWire(activity: ReceptiveInactivity): ReceptiveInactivityWire {
  return {
    id: activity.id,
    date: activity.date,
    name: activity.name,
    note: activity.note,
    startedAt: activity.startedAt,
  };
}

const listReceptiveInactivities = createRoute({
  method: "get",
  path: "/",
  summary: "Read a window of entries",
  description:
    "Every entry filed on a day in an inclusive window ending on `endingOn`, ordered by day, then by start time with untimed entries last, then by name. The answer is a bare array with **no padding**: a day inside the window holding no entry is simply absent, and an empty array means nothing in the window was recorded. **`days=0` is the ordinary per-day read** — a day holds several entries, so there is no per-day slot for one to occupy and no `/{date}` endpoint to reach for instead.",
  request: {
    query: ReceptiveInactivityWindowQuerySchema,
    headers: RequestHeaderSchema,
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The entries in the window, oldest first.",
      content: { "application/json": { schema: z.array(ReceptiveInactivitySchema) } },
    },
    400: errorResponse("A query parameter failed validation."),
  },
});

const readReceptiveInactivity = createRoute({
  method: "get",
  path: "/{id}",
  summary: "Read one entry",
  description:
    "One entry, or `404 not_found` if this partition holds no such id. An entry has nothing filed under it — no route, no splits, no children of any kind — so this is the whole of the row and there is nothing a second request could fetch.",
  request: {
    params: IdParamSchema,
    headers: RequestHeaderSchema,
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The entry, as the database holds it.",
      content: { "application/json": { schema: ReceptiveInactivitySchema } },
    },
    400: errorResponse("`id` is not a UUID."),
    404: errorResponse("No entry with that id in this partition."),
  },
});

const writeReceptiveInactivity = createRoute({
  method: "put",
  path: "/{id}",
  summary: "Write one entry",
  description:
    "Insert or replace the entry — the upsert the app's own `save` is, which is INSERT-or-UPDATE by primary key. Answers with the row **read back from the database**, so a caller can confirm that a `null` stayed `null` rather than being folded into an empty string or a midnight. There are no children to replace, so unlike a session's `PUT` an omitted field cannot silently delete a stored child — the entire row is these six fields.",
  request: {
    params: IdParamSchema,
    headers: RequestHeaderSchema,
    body: {
      required: true,
      content: { "application/json": { schema: ReceptiveInactivityWriteSchema } },
    },
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The stored entry, as the database holds it.",
      content: { "application/json": { schema: ReceptiveInactivitySchema } },
    },
    400: errorResponse("The id, the header or the body failed validation."),
  },
});

const writeReceptiveInactivityBatch = createRoute({
  method: "post",
  path: "/batch",
  summary: "Write a chunk of entries",
  description:
    "Insert or replace up to `MAX_BATCH_RECEPTIVE_INACTIVITIES` entries in one request — the shape the app's import needs, where a sixty-entry notes log is one of these instead of sixty round trips. Every entry is keyed on the same `(userId, id)` pair the single-entry `PUT` writes, and the app derives that id from the entry's own date, type and text, so a chunk replayed after a timeout is safe: **it rewrites each entry with the values it already holds and the row count does not move.** The whole chunk is one transaction, so a failure writes nothing and the same body can be sent again. **It never deletes** — an entry the caller leaves out is left alone, which is why this is a `POST` on `/batch` and not a `PUT` on the collection. `written` counts entries.",
  request: {
    headers: RequestHeaderSchema,
    body: {
      required: true,
      content: { "application/json": { schema: ReceptiveInactivityBatchWriteSchema } },
    },
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "How many entries the database reported writing.",
      content: { "application/json": { schema: ReceptiveInactivityBatchResultSchema } },
    },
    400: errorResponse(
      "The header or the body failed validation — including a chunk larger than the cap and an id carried twice.",
    ),
  },
});

export const receptiveInactivityRoutes = new OpenAPIHono<{ Bindings: Env }>({
  defaultHook: validationHook,
})
  .openapi(listReceptiveInactivities, async (c) => {
    const { days, endingOn } = c.req.valid("query");
    const userId = await partitionFor(c.req.valid("header"));

    // Defaulted **here** and not in the schema, for `recoveries`' reason: a Zod `.default(utcToday())`
    // is evaluated once, when the module is first loaded, so a long-lived isolate would answer every
    // request for the rest of its life with the day it cold-started on. The default is a poor one
    // anyway — UTC is not the caller's today — and it exists only so the endpoint is usable from a
    // browser address bar.
    const through = endingOn ?? utcToday();

    const entries = await serviceFor(c.env).readWindow(userId, days, through);

    return c.json(entries.map(toWire), 200);
  })
  .openapi(readReceptiveInactivity, async (c) => {
    const { id } = c.req.valid("param");
    const userId = await partitionFor(c.req.valid("header"));

    const activity = await serviceFor(c.env).readOne(userId, id);

    // `null` from the repository means this partition holds no such id, and the status is the route's
    // decision. `not_found` and not the day-keyed resources' `no_measurement_for_day`: that code names
    // a day with no reading, and this resource has no reading to be missing — every row here is a
    // note that either exists or does not.
    if (activity === null) {
      return c.json(
        apiError("not_found", `no receptive inactivity with id ${id} in this partition`),
        404,
      );
    }

    return c.json(toWire(activity), 200);
  })
  .openapi(writeReceptiveInactivity, async (c) => {
    const { id } = c.req.valid("param");
    const userId = await partitionFor(c.req.valid("header"));
    const body = c.req.valid("json");

    // `id` comes from the path and never from the body — the write schema has no `id` field, and
    // `.strict()` makes a body carrying one a `400` rather than a silent strip. `date` is required in
    // the body and nowhere else, for `workouts`' reason carried one field further: this row's
    // `startedAt` is optional, so when it is absent the day is not derivable from anything and only
    // the client — which knows the day its screen was showing — can state it. A fact is stated once,
    // in the one place that can state it.
    const stored = await serviceFor(c.env).writeOne(userId, id, body);

    return c.json(toWire(stored), 200);
  })
  .openapi(writeReceptiveInactivityBatch, async (c) => {
    const userId = await partitionFor(c.req.valid("header"));
    const { rows } = c.req.valid("json");

    // The id is in each row and not in the path, for the siblings' reason: a batch has no path to put
    // it in. Both halves are enforced by the schemas, so a batch row that forgot its id and a
    // single-entry body that carried one are each a `400`.
    //
    // The answer is the database's tally of **entries**, not an echo: see
    // `ReceptiveInactivityBatchResultSchema` for why a replayed chunk reports the same number rather
    // than zero. On this resource the count and the row count coincide, because an entry has no
    // children — the one place in this Worker where that arithmetic is the identity.
    const written = await serviceFor(c.env).writeMany(userId, rows);

    return c.json({ written }, 200);
  });
