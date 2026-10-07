import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import type { StepCount } from "../domain";
import {
  StepCountBatchResultSchema,
  StepCountBatchWriteSchema,
  StepCountSchema,
  type StepCountWire,
  StepCountWriteSchema,
  WindowQuerySchema,
} from "../dto/stepCounts";
import { DayKeySchema, RequestHeaderSchema } from "../dto/shared";
import type { Env } from "../env";
import { D1StepCountRepository } from "../repositories";
import { StepCountService } from "../services";
import { utcToday } from "../utils/days";
import { apiError } from "../utils/errors";
import { deriveUserId } from "../utils/identity";
import { errorResponse, unauthorizedResponse, validationHook } from "./errors";

/**
 * The four `step-counts` endpoints, and nothing else.
 *
 * A handler here validates, calls the service and shapes the response. It contains **no SQL and no
 * policy**: the window arithmetic is `StepCountService`'s, the table is `D1StepCountRepository`'s, and
 * what remains is the two things only this layer can know — how a day key becomes a URL, and which
 * status code an answer deserves. The one decision taken here rather than in the service is that a day
 * with no row is a `404` rather than a `200` with a `null`, because that is a fact about HTTP.
 *
 * **This resource's absence rule is `recoveries`', not `strains`', and the three-line handler below is
 * where that shows.** `strains` has a second case to reason about — a row that exists carrying
 * `hasMeasurement: false` — and its route carries a paragraph explaining why that is a `200`. This
 * table has no such column, so a row that exists is a day the strap was worn and the only absence is
 * `null`. Nothing here needs a paragraph, and that absence of one is the difference.
 *
 * It is also the only layer that sees `Env` at all. `serviceFor` below is the composition root for
 * this resource — one line, in one place, so the repository is chosen once and no service or
 * repository file ever holds a binding it could reach past its own port with.
 *
 * Paths are declared relative to the resource, and `routes/index.ts` mounts the lot under
 * `/v1/step-counts`. The OpenAPI document is generated from the mounted app, so the prefix appears in
 * the published paths by construction rather than by a second string agreeing with this one.
 */

/** Paths are declared relative to `/v1/step-counts`; this is the route's own path-parameter schema. */
const DateParamSchema = z.object({ date: DayKeySchema });

/**
 * The composition root for this resource.
 *
 * `D1StepCountRepository.from(c.env)` rather than a module-level singleton: an isolate is reused across
 * requests, so a repository captured at module scope would hold the first request's bindings for the
 * life of the isolate. The wrapper is a thin object over `env.DB` — there is nothing here worth
 * caching, and caching it would be the bug.
 */
function serviceFor(env: Env): StepCountService {
  return new StepCountService(D1StepCountRepository.from(env));
}

/**
 * The caller's partition: the header value, hashed, and never the header itself.
 *
 * **Every handler goes through this, and the reason is a failure that would be near-invisible.** If
 * one route read the raw header while the others hashed it, that caller's rows would be filed under
 * two different `user_id`s — the digest for the routes that hashed and the literal key for the one
 * that did not — and nothing would report it. The symptom is a day that a batch answered `200` for and
 * a `GET` then calls absent, which reads as a sync bug rather than as a routing one. One call site per
 * handler, going through one function, is what makes that unrepresentable.
 *
 * The alternative — hashing inside the repository or the service — is worse in the other direction:
 * the digest is a fact about *arriving at this Worker*, and a layer that took a key and hashed it
 * would be a layer that could be handed a key it was never meant to see.
 *
 * `deriveUserId` is async because `crypto.subtle.digest` is, and the header is already known to be a
 * usable key: `UserHeaderSchema` refused anything too short or too long before this ran.
 */
function partitionFor(headers: { readonly "x-whoopsy-user-id": string }): Promise<string> {
  return deriveUserId(headers["x-whoopsy-user-id"]);
}

/**
 * Domain to wire.
 *
 * Spelled out rather than spread-and-strip (`const { userId, ...rest } = stepCount`), because the
 * return type is `StepCountWire` and that is what makes the schema and this mapper agree: `userId` is
 * deliberately absent from the contract, and a field added to `stepCountFields` without being added
 * here fails to compile.
 *
 * **`hasMeasurement` is not published here, and a reader arriving from `strains` will look for it.**
 * On the phone it is a *computed* property — `measuredSeconds > 0` — so there is nothing for this
 * Worker to carry: `measuredSeconds` is already on the wire two lines below, and the client derives
 * the flag from it. A field here holding what a client can compute would be a second answer to a
 * question that already has one, free to disagree with the number printed beside it.
 *
 * **Both fields are copied straight across, and on `measuredSeconds` that is the whole rule.** There is
 * no `?? 0` and no `?? null` — the second being the subtler mistake, since it would look defensive
 * while silently erasing a `0` a client deliberately sent. A `0` here is a real value: a day the strap
 * was worn and walked nowhere. A default would turn that into a day nothing measured, which on this
 * resource is not a row at all, and nothing downstream could tell the two apart.
 *
 * `userId` is withheld because it is the caller's own identity, already known from the request that
 * asked for it. Publishing it would invite a client to read an owner out of a payload instead of out
 * of the credential, which is the habit that breaks the day the placeholder header is replaced.
 */
function toWire(stepCount: StepCount): StepCountWire {
  return {
    date: stepCount.date,
    stepCount: stepCount.stepCount,
    measuredSeconds: stepCount.measuredSeconds,
  };
}

const listStepCounts = createRoute({
  method: "get",
  path: "/",
  summary: "Read a window of days",
  description:
    "Every day holding a row in an inclusive window ending on `endingOn`. Days with no row are **omitted** rather than returned as zero-filled records — an empty array is a real answer, and on a step history it is a common one: the strap is worn intermittently, so the gaps are inside the range rather than only at its ends. The window is inclusive at both ends, so `days=14` spans 15 calendar days.",
  request: {
    query: WindowQuerySchema,
    headers: RequestHeaderSchema,
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The days holding a row in the window, oldest first.",
      content: { "application/json": { schema: z.array(StepCountSchema) } },
    },
    400: errorResponse("A query parameter failed validation."),
  },
});

const readStepCount = createRoute({
  method: "get",
  path: "/{date}",
  summary: "Read one day",
  description:
    "One day's row, or `404 no_measurement_for_day` if that day has no row at all. **There is no second kind of row here**: a day the strap did not measure is never written, so unlike `strains` there is no unmeasured-row state to tell a reading apart from. A measured day of no walking is a `200` carrying `stepCount: 0`, which is a real reading rather than an absence.",
  request: {
    params: DateParamSchema,
    headers: RequestHeaderSchema,
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The day's row.",
      content: { "application/json": { schema: StepCountSchema } },
    },
    400: errorResponse("`date` is not a calendar day in `YYYY-MM-DD` form."),
    404: errorResponse("That day has no row."),
  },
});

const writeStepCount = createRoute({
  method: "put",
  path: "/{date}",
  summary: "Write one day",
  description:
    "Insert or replace the day's row — the day-keyed upsert the app's own step-row write is. Answers with the row **read back from the database**, not with the request echoed, so a caller can see that a `0` was stored as a `0` rather than arriving back as some default the write path might have folded it into. On this resource that assertion has a sharp edge: `measuredSeconds` is the field that separates a measured day of no walking from a day nothing measured, so a default on it would publish the second state as the first.",
  request: {
    params: DateParamSchema,
    headers: RequestHeaderSchema,
    body: {
      required: true,
      content: { "application/json": { schema: StepCountWriteSchema } },
    },
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The stored row, as the database holds it.",
      content: { "application/json": { schema: StepCountSchema } },
    },
    400: errorResponse(
      "The day, the header or the body failed validation — including a body carrying its own `date`, a fractional `stepCount` and a `measuredSeconds` that is not a number.",
    ),
  },
});

const writeStepCountBatch = createRoute({
  method: "post",
  path: "/batch",
  summary: "Write a chunk of days",
  description:
    "Insert or replace up to `MAX_BATCH_STEP_COUNTS` days in one request — the shape a first sync needs, where a long worn history is a handful of these rather than one round trip per day. Every row is keyed on the same `(userId, date)` pair the single-day `PUT` writes, so a chunk replayed after a timeout is safe: **it rewrites each row with the values it already holds and the row count does not move.** The chunk is one transaction, so a failure writes nothing and the same body can be sent again. **It never deletes** — a day the caller leaves out is left alone, which is why this is a `POST` on `/batch` and not a `PUT` on the collection. That promise is worth more here than on any sibling: a step history is mostly days the strap was not worn, so a verb that said `these are the days` would be a request to delete most of the user's record every time it was sent.",
  request: {
    headers: RequestHeaderSchema,
    body: {
      required: true,
      content: { "application/json": { schema: StepCountBatchWriteSchema } },
    },
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "How many rows the database reported writing.",
      content: { "application/json": { schema: StepCountBatchResultSchema } },
    },
    400: errorResponse(
      "The header or the body failed validation — including a chunk larger than the cap, a day carried twice, and a row carrying a field the contract does not have.",
    ),
  },
});

export const stepCountRoutes = new OpenAPIHono<{ Bindings: Env }>({
  defaultHook: validationHook,
})
  .openapi(listStepCounts, async (c) => {
    const { days, endingOn } = c.req.valid("query");
    const userId = await partitionFor(c.req.valid("header"));

    // `endingOn` is defaulted **here** and not in the schema, and the difference is not stylistic: a
    // Zod `.default(utcToday())` is evaluated once, when the module is first loaded, so a long-lived
    // isolate would answer every request for the rest of its life with the day it cold-started on.
    // The default is a poor one anyway — UTC is not the caller's today — and it exists only so the
    // endpoint is usable from a browser address bar.
    const through = endingOn ?? utcToday();

    const rows = await serviceFor(c.env).readWindow(userId, days, through);

    return c.json(rows.map(toWire), 200);
  })
  .openapi(readStepCount, async (c) => {
    const { date } = c.req.valid("param");
    const userId = await partitionFor(c.req.valid("header"));

    const stepCount = await serviceFor(c.env).readDay(userId, date);

    // `null` from the repository means the day has no row, and the status is the route's decision:
    // the storage layer reports an absence and this layer says what an absence *is* over HTTP. A
    // `200` with a `null` body would be indistinguishable from a measured day to a client that only
    // checked the status, and a zero-filled `200` is the fabrication this project's absence rule
    // forbids everywhere else.
    //
    // **The check is `=== null` and there is nothing else it could be.** `strainRoutes` warns against
    // testing `hasMeasurement` at this line, because a strain row can exist carrying `false`; this
    // table has no such column and this resource's flag is computed by the client, so a row that
    // exists here is a day that was measured. That is the same absence `recoveries` answers with the
    // same code, for the same reason — and it is why the two share a word while `strains` shares it
    // with a different behaviour behind it.
    //
    // The word itself is `stepCountService.readDay`'s doc comment one layer down, which is where a
    // reader looking for "why is there no `hasMeasurement` test here" should end up.
    if (stepCount === null) {
      return c.json(apiError("no_measurement_for_day", `no step count measured on ${date}`), 404);
    }

    return c.json(toWire(stepCount), 200);
  })
  .openapi(writeStepCount, async (c) => {
    const { date } = c.req.valid("param");
    const userId = await partitionFor(c.req.valid("header"));
    const body = c.req.valid("json");

    // `date` comes from the path and never from the body — the write schema has no `date` field, and
    // `.strict()` makes a body carrying one a `400` rather than a silent strip. The day is the whole
    // of what this route contributes to the write: the two stored fields arrive in the body and the
    // service passes them through untouched, which is where `measuredSeconds`' no-default rule lives.
    const stored = await serviceFor(c.env).writeDay(userId, date, body);

    return c.json(toWire(stored), 200);
  })
  .openapi(writeStepCountBatch, async (c) => {
    const userId = await partitionFor(c.req.valid("header"));
    const { rows } = c.req.valid("json");

    // The day is in each row and not in the path, which is the one structural difference from
    // `writeStepCount` above — and the schemas enforce both halves, so a batch row that forgot its day
    // and a single-day body that carried one are each a `400` rather than a guess.
    //
    // The answer is the database's tally, not an echo: see `StepCountBatchResultSchema` for why a
    // replayed chunk reports the same number rather than zero.
    const written = await serviceFor(c.env).writeMany(userId, rows);

    return c.json({ written }, 200);
  });
