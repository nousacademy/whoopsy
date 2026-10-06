import { z } from "@hono/zod-openapi";
import { BIOMETRIC_SAMPLE_ID_PATTERN } from "../domain";
import {
  MAX_BATCH_BIOMETRIC_SAMPLES,
  MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS,
} from "../services";
import { InstantSchema } from "./shared";

/**
 * The wire shapes for `/v1/biometric-samples` — and, because the OpenAPI document is generated from
 * these declarations, the published contract itself.
 *
 * The three conventions this API fixes are `dto/recoveries.ts`'s and are restated in `dto/shared.ts`:
 * camelCase on the wire over snake_case columns, `.nullable()` and never `.optional()` for an
 * absence, and an instant checked by round trip through `parseInstant`.
 *
 * **This is the first resource in the Worker whose window is not a window of days, and every shape
 * below follows from that one fact.** The other six key a row on a day and count their windows in
 * days, because on all six a day is one row. Here a day is up to 86,400 rows, so the read takes two
 * instants, the cap is a chunk size rather than a day's worth, and there is no `days`/`endingOn` pair
 * anywhere in this file to mirror. `MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS` is the ceiling on one read
 * and it is a *span* rather than a count — which is what makes "give me everything" unaskable rather
 * than merely large.
 *
 * **Nine of the twelve fields are nullable, and the nullability is the resource rather than a
 * looseness.** A notification carries what the strap happened to measure: R-R intervals only when the
 * characteristic's R-R bit is set, skin temperature and SpO₂ only when the optical engine produced an
 * estimate, a sequence number only on a frame that came off the flash. `null` here is the strap's own
 * word for *I did not report this channel*, and every one of those fields is a channel the app stores
 * as absent rather than defaulting — a `0.0` accelerometer axis is free fall, which lands on the
 * *still* side of every movement threshold. `dto/recoveries.ts` carries the same rule for
 * `skinTemperature` and `spo2Percentage`.
 *
 * **`heartRate` is the one channel that is always present**, because a sample exists only when the
 * decoder had a pulse to report — and it is bounded `nonnegative` and not `positive`, because a
 * stored `0` is a reading the strap gave. That is `strains`' `averageHeartRate` call rather than
 * `recoveries`' `restingHeartRate` one, and the two siblings differ on exactly this reasoning.
 */

/**
 * A sample's identity.
 *
 * The pattern is `domain/biometricSample.ts`'s, and the reason it is a UUID at all is that the app's
 * `BiometricSample.id` is a `UUID`: an id this Worker accepted but the app cannot parse is a row that
 * is written, is returned by every read here, and reaches no screen — the same failure
 * `ReceptiveInactivityIdSchema` documents.
 *
 * **The derivation is the client's and this file has no opinion about it**, which is `PUT
 * /v1/workouts/{id}`'s position on a session id and is deliberate for the same reason: the id is a
 * string the producer mints, and the only property this contract requires of it is that it be
 * **deterministic**, so that re-sending a sample is an upsert rather than a second row. The app has
 * no identifier for a sample that could travel — its local key is an autoincrement assigned by that
 * device's own SQLite and read back by nothing — so a derived id is the only kind that works across
 * two devices in one partition.
 *
 * Any version and either case, because `UUID(uuidString:)` is.
 */
export const BiometricSampleIdSchema = z
  .string()
  .regex(BIOMETRIC_SAMPLE_ID_PATTERN, {
    message: "must be a UUID — the app reads every stored id through UUID(uuidString:)",
  })
  .openapi({
    description:
      "A UUID string. Any version and either case. **The derivation is the client's**, and the one property this API needs from it is determinism: the same sample must always derive the same id, so that a replayed chunk is an upsert rather than a second row. The app has no sample identifier of its own that could travel — its local key is an autoincrement in that device's SQLite — so two devices sharing a partition would otherwise overwrite each other.",
    example: "8f14e45f-ceea-467a-9c2b-1c3a5b7d0e11",
  });

/**
 * The stored fields, in one place.
 *
 * Composed into the response schema and both write bodies, so the three cannot drift: a field added
 * here appears in the contract's response *and* in its request bodies, and adding one to just one
 * side means writing it out separately — the mistake this shape exists to prevent.
 *
 * **Nothing is defaulted and every absence is `.nullable()`.** A client that omits `skinTemp` and one
 * that sends `skinTemp: null` are making the same claim — the strap did not report it — and this API
 * must not hold a third answer for either. On this resource a default would be worse than untidy
 * rather than merely untidy: `0.0` on an accelerometer axis is a *measurement* of free fall, and the
 * app's own sleep and stress models threshold that number.
 */
const biometricSampleFields = {
  timestamp: InstantSchema.openapi({
    description:
      "When the app heard the beats, in canonical UTC form. **An arrival instant and not a beat time**, which is the app's own documented caveat: the BLE layer stamps the clock when a notification is decoded, so this is when the beats were heard rather than when they happened. It is the lookup column — a window is a range over this field — and it is the natural input to the id derivation below, with the caveat that a derivation folding in nothing else makes two samples in one millisecond collide.",
    example: "2026-08-22T13:45:00.000Z",
  }),

  heartRate: z
    .number()
    .int()
    .nonnegative()
    .openapi({
      description:
        "The pulse at this notification, in beats per minute. **The one channel that is always present**, because a sample exists only when the decoder had a pulse to report — and it may legitimately be `0`, which is why the bound is `nonnegative` and not `positive`. Not rounded: what the strap reported is what is stored.",
      example: 62,
    }),

  rrIntervalsMs: z
    .array(z.number().finite().nonnegative())
    .min(1)
    .nullable()
    .openapi({
      description:
        "The beat-to-beat intervals **one notification** carried, in wire order, in milliseconds — or `null` when it carried none. A series rather than one figure, because that is what the characteristic sends: within a notification these are adjacent beats by definition, and across notifications they are not, so a consumer differencing them must not difference across a boundary. That is why the array is published whole rather than flattened into a single figure. **`null` is the one spelling of \"no intervals\"**: an empty array is refused, because the app's BLE layer already collapses that case on the way in and a stored `[]` would be a value no producer writes.",
      example: [958, 962, 955],
    }),

  accelX: z
    .number()
    .finite()
    .nullable()
    .openapi({
      description:
        "Acceleration along X in Gs, or `null` when the notification carried no motion. **The three axes are nullable independently and are not constrained to agree**: the strap sends the triplet as one record, so in practice all three arrive together or none does, but \"none\" is three `null`s rather than a fourth flag. The app has a defined reading for a partial triplet — its acceleration magnitude is `null` unless every axis is present — so a rule refusing it here would reject a row the storage holds. **A `0.0` would be the one value that must never be substituted**: free fall is physically unreachable on a body and lands on the *still* side of every movement threshold.",
      example: 0.98,
    }),

  accelY: z.number().finite().nullable().openapi({
    description: "Acceleration along Y in Gs, or `null`. Independently nullable — see `accelX`.",
    example: -0.12,
  }),

  accelZ: z.number().finite().nullable().openapi({
    description: "Acceleration along Z in Gs, or `null`. Independently nullable — see `accelX`.",
    example: 0.04,
  }),

  skinTemp: z
    .number()
    .finite()
    .nullable()
    .openapi({
      description:
        "Skin temperature in degrees Celsius, or `null` when the optical engine reported none. Unbounded on purpose: this Worker holds no physiological band for a temperature, and a range invented here would refuse a real reading rather than a fabricated one. `recoveries.skinTemperature` is the same quantity and is bounded the same way.",
      example: 33.6,
    }),

  spo2Percentage: z
    .number()
    .finite()
    .min(0)
    .max(100)
    .nullable()
    .openapi({
      description:
        "Blood-oxygen saturation as a percentage, or `null` when no estimate was produced. Bounded `0`…`100` because that is what a percentage is, which is the one bound here that is definitional rather than physiological — `recoveries.spo2Percentage` carries it too, so the same quantity is not bounded two ways.",
      example: 96.5,
    }),

  isOnBody: z
    .boolean()
    .nullable()
    .openapi({
      description:
        "Whether the strap was on a wrist, or `null` when it did not say. **The app's own mapper resolves this absence to `true` on read, and that default is deliberately not copied here.** `true` and `false` are opposite measurements of a question nobody answered, and a defaulted `true` would put \"worn\" on a row the strap never described.",
      example: true,
    }),

  isCharging: z
    .boolean()
    .nullable()
    .openapi({
      description:
        "Whether the strap was charging, or `null` when it did not say. Defaulting to `false` is the same fabrication as defaulting `isOnBody` to `true`, and is refused for the same reason.",
      example: false,
    }),

  rawSequenceNumber: z
    .number()
    .int()
    .nonnegative()
    .max(0xffffffff)
    .nullable()
    .openapi({
      description:
        "The frame's own sequence number, or `null` for a frame that did not carry one — which is every live notification, since only a banked record off the flash has a counter. Bounded because the app types it as a 32-bit unsigned integer, so a value outside that range is one no producer can emit.",
      example: 10342,
    }),
};

/**
 * One stored sample, as the API returns it.
 *
 * The response is the **row read back from the database**, not the request echoed — which is what
 * lets a client confirm the round trip. On this resource that assertion is worth more than it is on
 * any sibling: nine of these twelve fields are nullable, so a stray default anywhere in the binding
 * list would be invisible in the answer, and a `[]` folded into a `null` (or the reverse) would
 * silently disable an R-R consumer on a night that has beats in it.
 *
 * `userId` is deliberately **not** on the wire, for `RecoverySchema`'s reason: it is the caller's own
 * identity, already known from the request that asked, and publishing it invites a client to read an
 * owner out of a payload instead of out of the credential.
 *
 * The response schema carries **no refinement of any kind**, and here that is the resource rather than
 * an omission: a sample is one notification, so there is no second field for any of these to be
 * consistent with. The three accelerometer axes are the case that looks like it wants one and
 * deliberately does not have one — see `accelX`.
 */
export const BiometricSampleSchema = z
  .object({
    id: BiometricSampleIdSchema,
    ...biometricSampleFields,
  })
  .openapi("BiometricSample", {
    description:
      "One notification off the strap: when it arrived, what the pulse was, and whatever else it carried. Nine of the twelve fields are nullable, and a `null` on any of them is the strap's own word for a channel it did not report — never a zero-filled stand-in.",
  });

/**
 * The response type, inferred from the schema rather than written out beside it.
 *
 * `routes/biometricSamples.ts` declares its domain-to-wire mapper as returning this, which closes the
 * chain the same way `RecoveryWire` does: a field added to `biometricSampleFields` and forgotten in
 * the mapper is a compile error rather than a column that quietly never leaves the database.
 */
export type BiometricSampleWire = z.infer<typeof BiometricSampleSchema>;

/**
 * The `PUT /v1/biometric-samples/{id}` body: the stored fields, minus the identity.
 *
 * The `id` is in the path, so a body carrying one would be a second, disagreeable statement of the
 * same fact — the same rule as `WorkoutWriteSchema`'s missing `id` — and `.strict()` makes it a `400`
 * rather than a silent strip.
 *
 * **`timestamp` is in this body and is required**, which is the one place this resource's write
 * differs in kind from its siblings'. On `receptiveInactivities` the day is stated because nothing
 * else can derive it; here the instant is stated because the instant **is** the sample — it is the
 * lookup column, it is the read window's subject, and it is the natural input to the id the path
 * carries. A server deriving it from its own clock would stamp the moment the write arrived rather
 * than the moment the beats were heard, which is a different reading of a different thing.
 */
export const BiometricSampleWriteSchema = z
  .object(biometricSampleFields)
  .strict()
  .openapi("BiometricSampleWrite", {
    description:
      "The fields of a sample, less its identity — the id comes from the path. Every field is required **except** the ones that are `.nullable()`, where `null` is the strap's word for a channel it did not report and not an omission.",
  });

/**
 * One row of a bulk write: the same fields a `PUT` body carries, plus the identity the path would
 * have carried.
 *
 * `id` is back on the type, where `BiometricSampleWriteSchema` deliberately drops it, because a batch
 * has no path to put it in. That is the whole reason the two schemas are not one — the split
 * `services/biometricSampleService.ts` draws between `BiometricSampleInput` and
 * `BiometricSampleBatchEntry`.
 *
 * **`.strict()` first, then `.openapi()`.** `@asteasolutions/zod-to-openapi` patches `.refine()` to
 * carry a schema's `openapi` metadata through and does **not** patch `.strict()` — so a name attached
 * before the strictness is discarded and this lands in the document as an unnamed inline object. The
 * order is not cosmetic: a component with no name cannot be referred to by a client generator, and
 * `tests/openapi.spec.ts` asserts this one is named.
 *
 * There is no refine chained after the name on this one, which is the same shape
 * `ReceptiveInactivityBatchRowSchema` has: nothing on a sample is a fraction of anything else on it,
 * so there is no cross-field rule for a row to state.
 */
export const BiometricSampleBatchRowSchema = z
  .object({
    id: BiometricSampleIdSchema,
    ...biometricSampleFields,
  })
  .strict()
  .openapi("BiometricSampleBatchRow", {
    description:
      "One sample of a bulk write. The id is required and carried in the body, because a batch has no path to put it in.",
  });

/**
 * Whether any row's id is named twice in a batch.
 *
 * A predicate and not the offending id, because **a schema's refusal message is a constant**:
 * `@asteasolutions/zod-to-openapi` patches `.refine()` and does not patch `.superRefine()`, so a
 * dynamically composed message would cost this schema its name in the document. The count is stated
 * by `services/biometricSampleService.ts`, which is the layer that can phrase it and which a caller
 * arriving over HTTP never reaches — the schema refuses first, with this constant message.
 *
 * It is a per-resource function rather than one shared with `workouts` or `receptiveInactivities`,
 * for the reason the caps are per-resource constants: the files are the only callers, and a single
 * helper imported across resources would put a refactor of one resource's validation inside the
 * other's diff.
 *
 * **On this resource the collision is likelier than on any sibling**, and the reason is the id's
 * derivation rather than the client's care: an id folded from the arrival instant alone makes two
 * samples that landed in the same millisecond the same id, and a batch is exactly where a burst of
 * those arrives together. Refusing the batch is the honest answer — the alternative is that the
 * second write wins silently and the row left on disk is whichever the array happened to put last.
 */
function hasRepeatedId(rows: readonly { readonly id: string }[]): boolean {
  const seen = new Set<string>();
  for (const row of rows) {
    if (seen.has(row.id)) return true;
    seen.add(row.id);
  }
  return false;
}

/**
 * The `POST /v1/biometric-samples/batch` body: up to `MAX_BATCH_BIOMETRIC_SAMPLES` samples, each
 * named exactly once.
 *
 * **The cap is 200, inherited deliberately from the six siblings, and on this resource that number is
 * a chunk size rather than a day's worth.** A sample row is one statement exactly as a recovery row
 * is, so the cost per row is the same; what differs is the population. A day at 1 Hz is up to 86,400
 * samples, so a full day is roughly 432 chunks — and the honest consequence is that a client syncing
 * a long history sends many requests, which is why the *window* is a span and not a day count. The
 * number is **not raised** here, on the rule that `MAX_BATCH_*` is a published limit: a cap a client
 * has already read is not a value to move because a new resource would prefer a bigger one.
 *
 * **What this endpoint is not is as load-bearing as what it is.** It is not a `PUT` on the collection:
 * that would say "these are the samples", which obliges the server to remove the ones the caller left
 * out. This API has no delete path at all — the Worker's standing shape rather than an omission on
 * this resource — so a batch adds and replaces, and it never removes.
 *
 * **Idempotence is the property the client depends on**, and here it is what makes a chunk replayed
 * after a timeout safe: every sample lands on the same `(userId, id)` key the single-sample `PUT`
 * writes, and the id is the client's own derivation, so re-sending rewrites each row with the values
 * it already holds and the row count does not move.
 *
 * Two refusals are carried here and restated in `services/biometricSampleService.ts`, which owns
 * them — the schema is what publishes them where a client can read them, and the service is what
 * enforces them for a caller that arrived from a script or a test and passed through no schema at
 * all. There is no third: a sample has no children, so the row cap **is** the work cap.
 */
export const BiometricSampleBatchWriteSchema = z
  .object({
    rows: z
      .array(BiometricSampleBatchRowSchema)
      .min(1)
      .max(MAX_BATCH_BIOMETRIC_SAMPLES)
      .openapi({
        description: `The samples to write, at least one and at most ${MAX_BATCH_BIOMETRIC_SAMPLES}. Each id must appear exactly once. **A sample is one row and has no children, so this cap is the whole bound on a request's work** — and it is a chunk size rather than a day's worth: a day at 1 Hz is up to 86,400 samples, so a full day is many requests.`,
      }),
  })
  .strict()
  .openapi("BiometricSampleBatchWrite", {
    description:
      "A chunk of samples to insert or replace. Adds and overwrites; it never deletes, so a sample the caller leaves out is left alone rather than removed.",
  })
  .refine((body) => !hasRepeatedId(body.rows), {
    path: ["rows"],
    message: "names a sample id more than once; a batch must give each sample exactly one row",
  });

/**
 * What a batch answers with.
 *
 * `written` counts **samples**, and on this resource samples and rows are the same number — a fact
 * about the shape rather than a second convention, and the note is here so the next reader does not
 * go looking for children the count excludes. It is the database's own `changes` tally, **so a
 * replayed chunk reports the same count as the first send rather than zero**: SQLite counts a row
 * matched by `ON CONFLICT … DO UPDATE` as changed even when every value is byte-identical. A client
 * must not read `written: 0` as "there was nothing to do", and nothing here answers `0` for a
 * non-empty batch.
 *
 * It is deliberately **not** the samples read back. The client already holds every value it just sent,
 * so echoing them is a round trip it cannot act on; the property a read-back would prove — that a
 * `null` stayed `null` — is asserted by reading the window afterwards, which is where it belongs.
 */
export const BiometricSampleBatchResultSchema = z
  .object({
    written: z.number().int().nonnegative().openapi({
      description:
        "How many samples the database reported writing. A sample is one row and has no children, so this is also the row count. A replayed chunk reports the same number as the first send, not zero.",
      example: 200,
    }),
  })
  .openapi("BiometricSampleBatchResult", {
    description:
      "The outcome of a bulk write. It reports what the database did, not what was on disk afterwards.",
  });

/**
 * The window read's query: **two instants, both required**, and the only window in this API that is
 * not counted in days.
 *
 * **`from`/`to` rather than `days`/`endingOn`, and the app's own port is why.** Every other resource
 * here mirrors the app's history window so a client porting an existing call passes the same number
 * through; this resource's port is `getSamples(from:to:)`, which takes both bounds from the caller,
 * and mirroring *that* is the same rule applied to a different shape. The unit change is forced by
 * the data rather than chosen: a day of this table is up to 86,400 rows, so a day-counted window
 * would make "give me last month" a read no Worker should be asked for.
 *
 * **Both bounds are required, and that is a judgement rather than a consequence.** A defaulted `to`
 * would be an implicit server-clock bound — the caller's question answered with the Worker's own
 * idea of now — which is a different thing from `endingOn`'s defaulted `utcToday()`, where the
 * server can at least name a day. The app's port requires both, so the honest shape requires both.
 *
 * **The bounds are inclusive at both ends**, matching the app's own read and the adapter's
 * `timestamp >= ? AND timestamp <= ?`. An instant range has no natural half-open form the way a day
 * chunk does, and the cost is bounded: a chunked sync overlapping at one millisecond re-sends that
 * sample, which is an upsert of an identical row rather than a duplicate.
 *
 * **The two rules the fields state are enforced in the service, not here.** `from <= to` and the
 * `MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS` ceiling are both checks on the *relationship* between the two
 * values rather than on either one, and this file does **not** carry them as a `.refine()` on the
 * query object. That is the standing shape of this Worker rather than a preference: a `.refine()`
 * here appears only on *field* schemas (`DayKeySchema`, `InstantSchema`) and on *body* schemas (batch
 * writes, write bodies) — never on a query object. A caller arriving from a script or a test reaches
 * the service having passed through no schema at all, so the service is where a rule lives if it is
 * to hold for every caller; the field descriptions below are what publish it where a client can read
 * it.
 */
export const BiometricSampleWindowQuerySchema = z.object({
  from: InstantSchema.openapi({
    description:
      `The oldest instant in the window, **inclusive**. Together with \`to\` this must span no more than ${MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS} seconds — a week — which is the bound that makes "give me everything" unaskable rather than merely large. A client syncing a long history chunks it. \`from\` must not be later than \`to\`.`,
    example: "2026-08-21T00:00:00.000Z",
  }),

  to: InstantSchema.openapi({
    description:
      "The newest instant in the window, **inclusive**. Required, and not defaulted to the server's now: a defaulted upper bound would be the Worker's clock answering the caller's question, which is a different thing from a defaulted *day* the server can at least name. An empty window is a `200` holding an empty array — a stretch the strap did not cover is not an error.",
    example: "2026-08-22T00:00:00.000Z",
  }),
});
