import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import type { Recovery } from "../domain";
import {
  RecoveryBatchResultSchema,
  RecoveryBatchWriteSchema,
  RecoverySchema,
  type RecoveryWire,
  RecoveryWriteSchema,
  WindowQuerySchema,
} from "../dto/recoveries";
import { DayKeySchema, UserHeaderSchema } from "../dto/shared";
import type { Env } from "../env";
import { D1RecoveryRepository } from "../repositories";
import { RecoveryService } from "../services";
import { utcToday } from "../utils/days";
import { apiError } from "../utils/errors";
import { deriveUserId } from "../utils/identity";
import { errorResponse, validationHook } from "./errors";

/**
 * The four `recoveries` endpoints, and nothing else.
 *
 * A handler here validates, calls the service and shapes the response. It contains **no SQL and no
 * policy**: the window arithmetic is `RecoveryService`'s, the table is `D1RecoveryRepository`'s, and
 * what remains is the two things only this layer can know — how a day key becomes a URL, and which
 * status code an answer deserves. The one decision taken here rather than in the service is that a
 * missing day is a `404` rather than a `200` with a `null`, because that is a fact about HTTP.
 *
 * It is also the only layer that sees `Env` at all. `serviceFor` below is the composition root for
 * this resource — one line, in one place, so the repository is chosen once and no service or
 * repository file ever holds a binding it could reach past its own port with.
 *
 * Paths are declared relative to the resource, and `routes/index.ts` mounts the lot under
 * `/v1/recoveries`. The OpenAPI document is generated from the mounted app, so the prefix appears in
 * the published paths by construction rather than by a second string agreeing with this one.
 */

/** Paths are declared relative to `/v1/recoveries`; this is the route's own path-parameter schema. */
const DateParamSchema = z.object({ date: DayKeySchema });

/**
 * The composition root for this resource.
 *
 * `D1RecoveryRepository.from(c.env)` rather than a module-level singleton: an isolate is reused across
 * requests, so a repository captured at module scope would hold the first request's bindings for the
 * life of the isolate. The wrapper is a thin object over `env.DB` — there is nothing here worth
 * caching, and caching it would be the bug.
 */
function serviceFor(env: Env): RecoveryService {
  return new RecoveryService(D1RecoveryRepository.from(env));
}

/**
 * The caller's partition: the header value, hashed, and never the header itself.
 *
 * **Every handler goes through this, and the reason is a failure that would be near-invisible.** If
 * one route read the raw header while the others hashed it, that caller's rows would be filed under
 * two different `user_id`s — the digest for the routes that hashed and the literal key for the one
 * that did not — and nothing would report it. The symptom is a day that a batch answered `200` for and
 * a `GET` then calls unmeasured, which reads as a sync bug rather than as a routing one. One call
 * site per handler, going through one function, is what makes that unrepresentable.
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
 * Spelled out rather than spread-and-strip (`const { userId, ...rest } = recovery`), because the
 * return type is `RecoveryWire` and that is what makes the schema and this mapper agree: `userId` is
 * deliberately absent from the contract, and a field added to `recoveryFields` without being added
 * here fails to compile. Destructuring would make `userId` the only thing held back by hand and every
 * future column opt-out by default.
 *
 * `userId` is withheld because it is the caller's own identity, already known from the request that
 * asked for it. Publishing it would invite a client to read an owner out of a payload instead of out
 * of the credential, which is the habit that breaks the day the placeholder header is replaced.
 */
function toWire(recovery: Recovery): RecoveryWire {
  return {
    date: recovery.date,
    recoveryScore: recovery.recoveryScore,
    restingHeartRate: recovery.restingHeartRate,
    hrvValueMs: recovery.hrvValueMs,
    hrvMetric: recovery.hrvMetric,
    skinTemperature: recovery.skinTemperature,
    spo2Percentage: recovery.spo2Percentage,
    respiratoryRate: recovery.respiratoryRate,
    source: recovery.source,
  };
}

const listRecoveries = createRoute({
  method: "get",
  path: "/",
  summary: "Read a window of days",
  description:
    "Every measured day in an inclusive window ending on `endingOn`. Days with no measurement are **omitted** rather than returned as zero-filled records — an empty array is a real answer and means nothing in the window was measured.",
  request: {
    query: WindowQuerySchema,
    headers: UserHeaderSchema,
  },
  responses: {
    200: {
      description: "The measured days in the window, oldest first.",
      content: { "application/json": { schema: z.array(RecoverySchema) } },
    },
    400: errorResponse("A query parameter failed validation."),
  },
});

const readRecovery = createRoute({
  method: "get",
  path: "/{date}",
  summary: "Read one day",
  description: "One day's reading, or `404 no_measurement_for_day` if that day has no row.",
  request: {
    params: DateParamSchema,
    headers: UserHeaderSchema,
  },
  responses: {
    200: {
      description: "The day's reading.",
      content: { "application/json": { schema: RecoverySchema } },
    },
    400: errorResponse("`date` is not a calendar day in `YYYY-MM-DD` form."),
    404: errorResponse("That day has no measurement."),
  },
});

const writeRecovery = createRoute({
  method: "put",
  path: "/{date}",
  summary: "Write one day",
  description:
    "Insert or replace the day's reading — the day-keyed upsert the app's own `saveRecovery` is. Answers with the row **read back from the database**, not with the request echoed, so a caller can see that a `null` stayed `null`.",
  request: {
    params: DateParamSchema,
    headers: UserHeaderSchema,
    body: {
      required: true,
      content: { "application/json": { schema: RecoveryWriteSchema } },
    },
  },
  responses: {
    200: {
      description: "The stored row, as the database holds it.",
      content: { "application/json": { schema: RecoverySchema } },
    },
    400: errorResponse("The day, the header or the body failed validation."),
  },
});

const writeRecoveryBatch = createRoute({
  method: "post",
  path: "/batch",
  summary: "Write a chunk of days",
  description:
    "Insert or replace up to `MAX_BATCH_ROWS` days in one request — the shape the app's first sync needs, where a nine-hundred-day history is five of these instead of nine hundred round trips. Every row is keyed on the same `(userId, date)` pair the single-day `PUT` writes, so a chunk replayed after a timeout is safe: **it rewrites each row with the values it already holds and the row count does not move.** The chunk is one transaction, so a failure writes nothing and the same body can be sent again. **It never deletes** — a day the caller leaves out is left alone, which is why this is a `POST` on `/batch` and not a `PUT` on the collection.",
  request: {
    headers: UserHeaderSchema,
    body: {
      required: true,
      content: { "application/json": { schema: RecoveryBatchWriteSchema } },
    },
  },
  responses: {
    200: {
      description: "How many rows the database reported writing.",
      content: { "application/json": { schema: RecoveryBatchResultSchema } },
    },
    400: errorResponse(
      "The header or the body failed validation — including a chunk larger than the cap and a day carried twice.",
    ),
  },
});

export const recoveryRoutes = new OpenAPIHono<{ Bindings: Env }>({
  defaultHook: validationHook,
})
  .openapi(listRecoveries, async (c) => {
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
  .openapi(readRecovery, async (c) => {
    const { date } = c.req.valid("param");
    const userId = await partitionFor(c.req.valid("header"));

    const recovery = await serviceFor(c.env).readDay(userId, date);

    // `null` from the repository means the day has no row, and the status is the route's decision:
    // the storage layer reports an absence and this layer says what an absence *is* over HTTP. A
    // `200` with a `null` body would be indistinguishable from a measured day to a client that only
    // checked the status, and a zero-filled `200` is the fabrication this project's absence rule
    // forbids everywhere else.
    if (recovery === null) {
      return c.json(apiError("no_measurement_for_day", `no recovery measured on ${date}`), 404);
    }

    return c.json(toWire(recovery), 200);
  })
  .openapi(writeRecovery, async (c) => {
    const { date } = c.req.valid("param");
    const userId = await partitionFor(c.req.valid("header"));
    const body = c.req.valid("json");

    // `date` comes from the path and never from the body — the write schema has no `date` field, and
    // `.strict()` makes a body carrying one a `400` rather than a silent strip. A body that
    // disagreed with its own URL would otherwise be a write to one day reported as a write to
    // another.
    const stored = await serviceFor(c.env).writeDay(userId, date, body);

    return c.json(toWire(stored), 200);
  })
  .openapi(writeRecoveryBatch, async (c) => {
    const userId = await partitionFor(c.req.valid("header"));
    const { rows } = c.req.valid("json");

    // The day is in each row and not in the path, which is the one structural difference from
    // `writeRecovery` above — and the schemas enforce both halves, so a batch row that forgot its day
    // and a single-day body that carried one are each a `400` rather than a guess.
    //
    // The answer is the database's tally, not an echo: see `RecoveryBatchResultSchema` for why a
    // replayed chunk reports the same number rather than zero.
    const written = await serviceFor(c.env).writeMany(userId, rows);

    return c.json({ written }, 200);
  });
