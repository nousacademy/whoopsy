import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import type { Sleep } from "../domain";
import {
  SleepBatchResultSchema,
  SleepBatchWriteSchema,
  SleepSchema,
  type SleepWire,
  SleepWriteSchema,
  WindowQuerySchema,
} from "../dto/sleeps";
import { DayKeySchema, UserHeaderSchema } from "../dto/shared";
import type { Env } from "../env";
import { D1SleepRepository } from "../repositories";
import { SleepService } from "../services";
import { utcToday } from "../utils/days";
import { apiError } from "../utils/errors";
import { deriveUserId } from "../utils/identity";
import { errorResponse, validationHook } from "./errors";

/**
 * The four `sleeps` endpoints, and nothing else.
 *
 * A handler here validates, calls the service and shapes the response. It contains **no SQL and no
 * policy**: the window arithmetic is `SleepService`'s, the table is `D1SleepRepository`'s, and what
 * remains is the two things only this layer can know — how a day key becomes a URL, and which status
 * code an answer deserves. The one decision taken here rather than in the service is that a day with
 * no row is a `404` rather than a `200` with a `null`, because that is a fact about HTTP.
 *
 * **This resource's absence rule is `recoveries`', not `strains`', and the three-line handler below is
 * where that shows.** `strains` has a second case to reason about — a row that exists carrying
 * `hasMeasurement: false` — and its route carries a paragraph explaining why that is a `200`. This
 * table has no such column, so a row that exists is a night that was measured and the only absence is
 * `null`. Nothing here needs a paragraph, and that absence of one is the difference.
 *
 * It is also the only layer that sees `Env` at all. `serviceFor` below is the composition root for
 * this resource — one line, in one place, so the repository is chosen once and no service or
 * repository file ever holds a binding it could reach past its own port with.
 *
 * Paths are declared relative to the resource, and `routes/index.ts` mounts the lot under
 * `/v1/sleeps`. The OpenAPI document is generated from the mounted app, so the prefix appears in the
 * published paths by construction rather than by a second string agreeing with this one.
 */

/** Paths are declared relative to `/v1/sleeps`; this is the route's own path-parameter schema. */
const DateParamSchema = z.object({ date: DayKeySchema });

/**
 * The composition root for this resource.
 *
 * `D1SleepRepository.from(c.env)` rather than a module-level singleton: an isolate is reused across
 * requests, so a repository captured at module scope would hold the first request's bindings for the
 * life of the isolate. The wrapper is a thin object over `env.DB` — there is nothing here worth
 * caching, and caching it would be the bug.
 */
function serviceFor(env: Env): SleepService {
  return new SleepService(D1SleepRepository.from(env));
}

/**
 * The caller's partition: the header value, hashed, and never the header itself.
 *
 * **Every handler goes through this, and the reason is a failure that would be near-invisible.** If
 * one route read the raw header while the others hashed it, that caller's rows would be filed under
 * two different `user_id`s — the digest for the routes that hashed and the literal key for the one
 * that did not — and nothing would report it. The symptom is a night that a batch answered `200` for
 * and a `GET` then calls absent, which reads as a sync bug rather than as a routing one. One call
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
 * Spelled out rather than spread-and-strip (`const { userId, ...rest } = sleep`), because the return
 * type is `SleepWire` and that is what makes the schema and this mapper agree: `userId` is
 * deliberately absent from the contract, and a field added to `sleepFields` without being added here
 * fails to compile. On a sixteen-field row that is not a formality — destructuring would make
 * `userId` the only thing held back by hand and every future column opt-out by default, and a column
 * that quietly never leaves the database is exactly what a sync cannot afford.
 *
 * **The six nullable fields are copied like any other field, and that is the whole of this mapper's
 * job.** There is no `?? 0` and no `?? null` here — the second being the subtler mistake, since it
 * would look defensive while silently erasing a `source` of `""` or a `sleepStages` the client
 * deliberately sent. What a client PUTs is what a client GETs, and the three computed fields among
 * those six are the ones a device would most regret seeing a plausible number come back for.
 *
 * `userId` is withheld because it is the caller's own identity, already known from the request that
 * asked for it. Publishing it would invite a client to read an owner out of a payload instead of out
 * of the credential, which is the habit that breaks the day the placeholder header is replaced.
 */
function toWire(sleep: Sleep): SleepWire {
  return {
    date: sleep.date,
    startTime: sleep.startTime,
    endTime: sleep.endTime,
    sleepPerformance: sleep.sleepPerformance,
    totalSleepNeeded: sleep.totalSleepNeeded,
    lightSleep: sleep.lightSleep,
    deepSleep: sleep.deepSleep,
    remSleep: sleep.remSleep,
    awakeTime: sleep.awakeTime,
    respiratoryRate: sleep.respiratoryRate,
    disturbanceCount: sleep.disturbanceCount,
    sleepConsistency: sleep.sleepConsistency,
    sleepDebt: sleep.sleepDebt,
    sleepStages: sleep.sleepStages,
    source: sleep.source,
  };
}

const listSleeps = createRoute({
  method: "get",
  path: "/",
  summary: "Read a window of nights",
  description:
    "Every night holding a row in an inclusive window ending on `endingOn`. Days with no row are **omitted** rather than returned as zero-filled records — an empty array is a real answer and means nothing in the window has a row. On a partially-worn history that is the ordinary case rather than an edge: a night the user did not wear the strap is a hole in the middle of the range, not a missing tail. The window is inclusive at both ends, so `days=14` spans 15 calendar days.",
  request: {
    query: WindowQuerySchema,
    headers: UserHeaderSchema,
  },
  responses: {
    200: {
      description: "The nights holding a row in the window, oldest first.",
      content: { "application/json": { schema: z.array(SleepSchema) } },
    },
    400: errorResponse("A query parameter failed validation."),
  },
});

const readSleep = createRoute({
  method: "get",
  path: "/{date}",
  summary: "Read one night",
  description:
    "One night's row, or `404 no_measurement_for_day` if that day has no row at all. **There is no second kind of row here**: a night the classifier could not read is never written, so unlike `strains` there is no unmeasured-row state to tell a reading apart from. The `date` is the night's **wake** day, not the day it began on.",
  request: {
    params: DateParamSchema,
    headers: UserHeaderSchema,
  },
  responses: {
    200: {
      description: "The night's row.",
      content: { "application/json": { schema: SleepSchema } },
    },
    400: errorResponse("`date` is not a calendar day in `YYYY-MM-DD` form."),
    404: errorResponse("That day has no row."),
  },
});

const writeSleep = createRoute({
  method: "put",
  path: "/{date}",
  summary: "Write one night",
  description:
    "Insert or replace the day's row — the day-keyed upsert the app's own `saveSleep` is. Answers with the row **read back from the database**, not with the request echoed, so a caller can see that a `null` stayed `null` rather than arriving back as the `0` a default somewhere in the write path might have folded it into. That assertion is the whole of what this resource's write path has to get right: three of its nullable fields are values a model on the device computes, and the device is the only party that knows whether one exists.",
  request: {
    params: DateParamSchema,
    headers: UserHeaderSchema,
    body: {
      required: true,
      content: { "application/json": { schema: SleepWriteSchema } },
    },
  },
  responses: {
    200: {
      description: "The stored row, as the database holds it.",
      content: { "application/json": { schema: SleepSchema } },
    },
    400: errorResponse(
      "The day, the header or the body failed validation — including a body carrying its own `date` and one whose `endTime` does not follow its `startTime`.",
    ),
  },
});

const writeSleepBatch = createRoute({
  method: "post",
  path: "/batch",
  summary: "Write a chunk of nights",
  description:
    "Insert or replace up to `MAX_BATCH_SLEEPS` nights in one request — the shape the app's first sync needs, where a nine-hundred-day history is five of these instead of nine hundred round trips. Every row is keyed on the same `(userId, date)` pair the single-day `PUT` writes, so a chunk replayed after a timeout is safe: **it rewrites each row with the values it already holds and the row count does not move.** The chunk is one transaction, so a failure writes nothing and the same body can be sent again. **It never deletes** — a day the caller leaves out is left alone, which is why this is a `POST` on `/batch` and not a `PUT` on the collection: on a nine-hundred-day history with holes in it, a verb that said `these are the nights` would oblige the server to remove a fourth of the user's sleep history on the first sync of a partially-worn range.",
  request: {
    headers: UserHeaderSchema,
    body: {
      required: true,
      content: { "application/json": { schema: SleepBatchWriteSchema } },
    },
  },
  responses: {
    200: {
      description: "How many rows the database reported writing.",
      content: { "application/json": { schema: SleepBatchResultSchema } },
    },
    400: errorResponse(
      "The header or the body failed validation — including a chunk larger than the cap, a night carried twice, and a row whose `endTime` does not follow its `startTime`.",
    ),
  },
});

export const sleepRoutes = new OpenAPIHono<{ Bindings: Env }>({
  defaultHook: validationHook,
})
  .openapi(listSleeps, async (c) => {
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
  .openapi(readSleep, async (c) => {
    const { date } = c.req.valid("param");
    const userId = await partitionFor(c.req.valid("header"));

    const sleep = await serviceFor(c.env).readDay(userId, date);

    // `null` from the repository means the day has no row, and the status is the route's decision:
    // the storage layer reports an absence and this layer says what an absence *is* over HTTP. A
    // `200` with a `null` body would be indistinguishable from a measured night to a client that only
    // checked the status, and a zero-filled `200` is the fabrication this project's absence rule
    // forbids everywhere else.
    //
    // **The check is `=== null` and there is nothing else it could be.** `strainRoutes` warns against
    // testing `hasMeasurement` at this line, because a strain row can exist carrying `false`; this
    // table has no such column, so a row that exists here is a night that was measured. That is the
    // same absence `recoveries` answers with the same code, for the same reason — and it is why the
    // two share a word while `strains` shares it with a different behaviour behind it.
    if (sleep === null) {
      return c.json(apiError("no_measurement_for_day", `no sleep measured on ${date}`), 404);
    }

    return c.json(toWire(sleep), 200);
  })
  .openapi(writeSleep, async (c) => {
    const { date } = c.req.valid("param");
    const userId = await partitionFor(c.req.valid("header"));
    const body = c.req.valid("json");

    // `date` comes from the path and never from the body — the write schema has no `date` field, and
    // `.strict()` makes a body carrying one a `400` rather than a silent strip. On this resource that
    // matters more than on either sibling, because the day is the *wake* day: a client with its own
    // opinion about which night it is writing is a whole day out, silently, on a row that looks
    // correct.
    const stored = await serviceFor(c.env).writeDay(userId, date, body);

    return c.json(toWire(stored), 200);
  })
  .openapi(writeSleepBatch, async (c) => {
    const userId = await partitionFor(c.req.valid("header"));
    const { rows } = c.req.valid("json");

    // The day is in each row and not in the path, which is the one structural difference from
    // `writeSleep` above — and the schemas enforce both halves, so a batch row that forgot its day
    // and a single-day body that carried one are each a `400` rather than a guess.
    //
    // The answer is the database's tally, not an echo: see `SleepBatchResultSchema` for why a
    // replayed chunk reports the same number rather than zero.
    const written = await serviceFor(c.env).writeMany(userId, rows);

    return c.json({ written }, 200);
  });
