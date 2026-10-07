import { createRoute, OpenAPIHono, z } from "@hono/zod-openapi";
import type { BiometricSample } from "../domain";
import {
  BiometricSampleBatchResultSchema,
  BiometricSampleBatchWriteSchema,
  BiometricSampleIdSchema,
  BiometricSampleSchema,
  type BiometricSampleWire,
  BiometricSampleWindowQuerySchema,
  BiometricSampleWriteSchema,
} from "../dto/biometricSamples";
import { RequestHeaderSchema } from "../dto/shared";
import type { Env } from "../env";
import { D1BiometricSampleRepository } from "../repositories";
import { BiometricSampleService } from "../services";
import { apiError } from "../utils/errors";
import { deriveUserId } from "../utils/identity";
import { errorResponse, unauthorizedResponse, validationHook } from "./errors";

/**
 * The four `/v1/biometric-samples` endpoints, and nothing else.
 *
 * **This file is `receptiveInactivities.ts` with the day taken out, and the removal reaches further
 * than the query schema.** That file reads a window ending on a day and defaults the day at the
 * handler; this one is handed both bounds and has nothing to default, so the `endingOn ?? utcToday()`
 * block is gone along with its `../utils/days` import — there is no calendar in this resource at all.
 * Everything else a handler here does is the family's ordinary job, which is the point: the endpoints
 * differ from the six siblings' in the *shape of one query*, not in how a request is handled.
 *
 * **The instantaneous window is the app's own port rather than an invention.** `BiometricRepository`
 * declares `getSamples(from:to:)`, so a client porting an existing call passes the same two bounds
 * through, exactly as the day-keyed resources mirror `getRecoveryHistory(days:endingOn:)`. The unit
 * change is forced by the data: a day of this table is up to 86,400 rows, so a day-counted window
 * would make "give me last month" a read no Worker should be asked for.
 *
 * **The 404 says `not_found`**, for `receptiveInactivities`' reason: `no_measurement_for_day` names a
 * *day* with no reading, which is a statement about a calendar, while this names an id the partition
 * does not hold. A sample is one notification and is never "unmeasured" — it exists only when the
 * decoder had a pulse to report — so the sibling's code would be not merely imprecise here but false.
 *
 * As in every sibling, a handler validates, calls the service and shapes a response: no SQL, no
 * policy, no `Env` outside `serviceFor`, and the one HTTP decision taken here rather than in the
 * service — that an absent row is a `404` rather than a `200` holding `null`.
 */

/** Paths are declared relative to `/v1/biometric-samples`; this is the route's param schema. */
const IdParamSchema = z.object({ id: BiometricSampleIdSchema });

/**
 * The composition root for this resource.
 *
 * `D1BiometricSampleRepository.from(c.env)` rather than a module-level singleton, for the siblings'
 * reason: an isolate is reused across requests, so a repository captured at module scope would hold
 * the first request's bindings for the life of the isolate.
 */
function serviceFor(env: Env): BiometricSampleService {
  return new BiometricSampleService(D1BiometricSampleRepository.from(env));
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
 * `BiometricSampleWire`, so a field added to `biometricSampleFields` and forgotten here is a compile
 * error rather than a column that quietly never leaves the database. **That check is worth more on
 * this resource than on any of the six**, because nine of these twelve fields are nullable and a
 * dropped one would come back as `undefined` — which a client merging two sources reads as "not
 * reported", the same word the strap uses, so a mapper that forgot `skinTemp` would be
 * indistinguishable from a strap whose optical engine said nothing.
 *
 * **`rrIntervalsMs` is copied with a spread rather than passed through, and that copy is about the
 * type and not about the value.** The entity declares it `readonly number[] | null` and the wire
 * declares it `number[] | null`, so handing the array over is a compile error; `[...series]` is the
 * conversion. **`null` passes through as `null` and never becomes `[]`**, which is the whole reason
 * the ternary is written out: an empty array is the second spelling of "no intervals" that the DTO
 * refuses on the way in and the adapter refuses on the way out, and a mapper that normalised it here
 * would put that second spelling on the wire from the one file between them.
 *
 * The other eleven fields are straight copies, and there is **no `??` in this function**: `null` on
 * any of them is the strap's own word for a channel it did not report, so a `?? 0` on an accelerometer
 * axis would be free fall and a `?? false` on `isCharging` an answer nobody gave.
 *
 * `userId` is withheld for the siblings' reason: it is the caller's own identity, already known from
 * the request that asked, and publishing it invites a client to read an owner out of a payload
 * instead of out of the credential.
 */
function toWire(sample: BiometricSample): BiometricSampleWire {
  return {
    id: sample.id,
    timestamp: sample.timestamp,
    heartRate: sample.heartRate,
    rrIntervalsMs: sample.rrIntervalsMs === null ? null : [...sample.rrIntervalsMs],
    accelX: sample.accelX,
    accelY: sample.accelY,
    accelZ: sample.accelZ,
    skinTemp: sample.skinTemp,
    spo2Percentage: sample.spo2Percentage,
    isOnBody: sample.isOnBody,
    isCharging: sample.isCharging,
    rawSequenceNumber: sample.rawSequenceNumber,
  };
}

const listBiometricSamples = createRoute({
  method: "get",
  path: "/",
  summary: "Read a window of samples",
  description:
    "Every sample whose arrival instant falls in `from`…`to`, **inclusive at both ends**, oldest first. The answer is a bare array with **no padding**: an empty array means nothing was recorded in the window, which is the ordinary answer for a stretch the strap did not cover rather than an error. **Both bounds are required** — `to` is not defaulted to the server's now, because that would be the Worker's clock answering the caller's question. The window may span at most a week; a client syncing a longer history chunks it. Samples sharing a millisecond are ordered by id, which is arbitrary rather than chronological: the app's own tiebreak *is* arrival order, and this resource's id is content-derived, so that clause is a stable order and not a recovered one.",
  request: {
    query: BiometricSampleWindowQuerySchema,
    headers: RequestHeaderSchema,
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The samples in the window, oldest first.",
      content: { "application/json": { schema: z.array(BiometricSampleSchema) } },
    },
    400: errorResponse(
      "A query parameter failed validation, or the window is reversed or wider than a week.",
    ),
  },
});

const readBiometricSample = createRoute({
  method: "get",
  path: "/{id}",
  summary: "Read one sample",
  description:
    "One sample, or `404 not_found` if this partition holds no such id. A sample has nothing filed under it — its R-R series is a column rather than rows of its own — so this is the whole of the row. It is addressed by id because every id-keyed resource in this API is, which is worth saying here: **the app's own port has no such read** (`getSamples(from:to:)` is the whole of it), so this endpoint exists so that a client which has just written an id can confirm it landed without asking for a window around it.",
  request: {
    params: IdParamSchema,
    headers: RequestHeaderSchema,
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The sample, as the database holds it.",
      content: { "application/json": { schema: BiometricSampleSchema } },
    },
    400: errorResponse("`id` is not a UUID."),
    404: errorResponse("No sample with that id in this partition."),
  },
});

const writeBiometricSample = createRoute({
  method: "put",
  path: "/{id}",
  summary: "Write one sample",
  description:
    "Insert or replace the sample — the upsert the app's own `save` is, which is INSERT-or-UPDATE by primary key. Answers with the row **read back from the database**, which on this resource is the assertion that matters: nine of these twelve fields are nullable, so a stray default anywhere in the write path would be invisible in an echo of the request. **The id is the client's own derivation and must be deterministic**, so that re-sending the same sample replaces a row rather than adding one; the Worker validates the shape and takes no view of how it was derived. **`timestamp` is required and travels in the body**, because the instant *is* the sample — it is the lookup column and the read window's subject — and deriving it from the server's clock would stamp when the write arrived rather than when the beats were heard.",
  request: {
    params: IdParamSchema,
    headers: RequestHeaderSchema,
    body: {
      required: true,
      content: { "application/json": { schema: BiometricSampleWriteSchema } },
    },
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The stored sample, as the database holds it.",
      content: { "application/json": { schema: BiometricSampleSchema } },
    },
    400: errorResponse("The id, the header or the body failed validation."),
  },
});

const writeBiometricSampleBatch = createRoute({
  method: "post",
  path: "/batch",
  summary: "Write a chunk of samples",
  description:
    "Insert or replace up to `MAX_BATCH_BIOMETRIC_SAMPLES` samples in one request — the shape a sync needs, where a burst of notifications is one request instead of one per sample. **On this resource that cap is a chunk size rather than a day's worth**: a sample is one row and has no children, so the row cap *is* the whole bound on the request's work, and a day at 1 Hz is roughly 432 chunks. Every sample is keyed on the same `(userId, id)` pair the single-sample `PUT` writes, so a chunk replayed after a timeout is safe: **it rewrites each sample with the values it already holds and the row count does not move.** The whole chunk is one transaction, so a failure writes nothing and the same body can be sent again. **It never deletes** — a sample the caller leaves out is left alone, which is why this is a `POST` on `/batch` and not a `PUT` on the collection. `written` counts samples, and a replay reports the same number as the first send rather than zero.",
  request: {
    headers: RequestHeaderSchema,
    body: {
      required: true,
      content: { "application/json": { schema: BiometricSampleBatchWriteSchema } },
    },
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "How many samples the database reported writing.",
      content: { "application/json": { schema: BiometricSampleBatchResultSchema } },
    },
    400: errorResponse(
      "The header or the body failed validation — including a chunk larger than the cap and an id carried twice.",
    ),
  },
});

export const biometricSampleRoutes = new OpenAPIHono<{ Bindings: Env }>({
  defaultHook: validationHook,
})
  .openapi(listBiometricSamples, async (c) => {
    const { from, to } = c.req.valid("query");
    const userId = await partitionFor(c.req.valid("header"));

    // Nothing is defaulted here, and that is the one structural difference from every sibling's
    // handler: they derive a lower bound from a counted window and an anchor, or default the anchor,
    // while this read is handed both of its bounds. The two rules about their *relationship* — that
    // `from` is not later than `to`, and that the span is at most a week — live in the service rather
    // than in a `.refine()` on the query object, because a caller arriving from a script or a test has
    // passed through no schema at all. See `BiometricSampleWindowQuerySchema`.
    const samples = await serviceFor(c.env).readWindow(userId, from, to);

    return c.json(samples.map(toWire), 200);
  })
  .openapi(readBiometricSample, async (c) => {
    const { id } = c.req.valid("param");
    const userId = await partitionFor(c.req.valid("header"));

    const sample = await serviceFor(c.env).readOne(userId, id);

    // `null` from the repository means this partition holds no such id, and the status is the route's
    // decision. `not_found` and not the day-keyed resources' `no_measurement_for_day`: that code names
    // a day with no reading, and a sample is one notification rather than a day's measurement.
    if (sample === null) {
      return c.json(
        apiError("not_found", `no biometric sample with id ${id} in this partition`),
        404,
      );
    }

    return c.json(toWire(sample), 200);
  })
  .openapi(writeBiometricSample, async (c) => {
    const { id } = c.req.valid("param");
    const userId = await partitionFor(c.req.valid("header"));
    const body = c.req.valid("json");

    // `id` comes from the path and never from the body — the write schema has no `id` field, and
    // `.strict()` makes a body carrying one a `400` rather than a silent strip.
    //
    // The id is **not** derived here. A server that minted one would be a second implementation of the
    // client's identity, free to disagree with the id the client will ask for on its next read — and
    // the app has no sample identifier that could travel in the first place, its local key being an
    // autoincrement in that device's own SQLite. The contract requires determinism and nothing else;
    // see `BiometricSampleIdSchema`.
    const stored = await serviceFor(c.env).writeOne(userId, id, body);

    return c.json(toWire(stored), 200);
  })
  .openapi(writeBiometricSampleBatch, async (c) => {
    const userId = await partitionFor(c.req.valid("header"));
    const { rows } = c.req.valid("json");

    // The id is in each row and not in the path, for the siblings' reason: a batch has no path to put
    // it in. Both halves are enforced by the schemas, so a batch row that forgot its id and a
    // single-sample body that carried one are each a `400`.
    //
    // The duplicate check is on `id` here as it is on `workouts` and `receptiveInactivities`, and on
    // this resource it is the check most likely to fire rather than the least: an id folded from the
    // arrival instant alone makes two samples in one millisecond the same id, and a batch is exactly
    // where a burst of those arrives together.
    //
    // The answer is the database's tally of **samples**, not an echo: see
    // `BiometricSampleBatchResultSchema` for why a replayed chunk reports the same number rather than
    // zero. On this resource the count and the row count coincide, because a sample has no children.
    const written = await serviceFor(c.env).writeMany(userId, rows);

    return c.json({ written }, 200);
  });
