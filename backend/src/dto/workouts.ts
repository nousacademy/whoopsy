import { z } from "@hono/zod-openapi";
import { WORKOUT_ID_PATTERN, ZONE_COUNT } from "../domain";
import {
  MAX_BATCH_ROUTE_POINTS,
  MAX_BATCH_SPLITS,
  MAX_BATCH_WORKOUTS,
  MAX_ROUTE_POINTS,
  MAX_SPLITS,
  MAX_WINDOW_DAYS,
} from "../services";
import { parseInstant } from "../utils/instants";
import { DayKeySchema, InstantSchema } from "./shared";

/**
 * The wire shapes for `/v1/workouts` — and, because the OpenAPI document is generated from these
 * declarations, the published contract itself.
 *
 * The three conventions this API fixes are `dto/recoveries.ts`'s and are restated in `dto/shared.ts`:
 * camelCase on the wire over snake_case columns, `.nullable()` and never `.optional()` for an
 * absence, and a day key checked by round trip. What is new here is what an **aggregate** adds to a
 * wire shape, and four things follow from it.
 *
 * **A session is addressed by `id`, not by its day.** `date` rides in the body — it is the device's
 * `startOfDay(startedAt)` and this Worker cannot derive it — but it is a field rather than the key,
 * because a day holds several sessions. So the `PUT` is `/{id}` and the body carries the day, which is
 * the exact inversion of `PUT /v1/recoveries/{date}` taking its day from the path and refusing one in
 * the body.
 *
 * **The children ride inside the session and are required.** `route` and `splits` are not `.optional()`
 * and have no default, because the write *replaces* them: a session with a stored route, written by a
 * body that omitted `route`, would have that route deleted and nothing would say so. `.strict()` turns
 * the omission into a `400` naming the missing field, which is the only failure mode a sync can act on.
 *
 * **A child's `id` is on the wire.** The app's `WorkoutRoutePoint` and `WorkoutSplit` each carry a
 * `UUID` that is their primary key locally, and a sync whose round trip re-minted a primary key could
 * restore a picture but not a database.
 *
 * **`hrZonePercents` is five whole percents summing to at most 100, and `null` is a different answer
 * from any array.** See `zoneBlock` below.
 */

/**
 * A session's identity, and its children's.
 *
 * One schema for all three because it is one rule and it comes from one place: `WORKOUT_ID_PATTERN`
 * is `repositories/workout.ts`'s, and the reason it is a UUID at all is that
 * `GRDBWorkoutRepository.makeSessions` builds a `UUID` from each stored id and **silently skips the
 * row** when that fails. An id this Worker accepted but the app cannot parse is a row that is written,
 * is returned by every read here, and appears on no screen — an import that reports success and
 * delivers nothing.
 *
 * The children are held to it for the same reason rather than by analogy: `WorkoutRoutePoint.id` and
 * `WorkoutSplit.id` are `UUID` on the app's own types, so a non-UUID here would be a value the app's
 * decoder has to refuse or crash on. Publishing the pattern is what lets a client generator produce a
 * type that cannot send one.
 */
export const WorkoutIdSchema = z
  .string()
  .regex(WORKOUT_ID_PATTERN, {
    message: "must be a UUID — the app reads every stored id through UUID(uuidString:)",
  })
  .openapi({
    description:
      "A UUID string. Any version and either case, because `UUID(uuidString:)` accepts both — the app mints v4 ids for a live session and derives ids from instants for an import, and neither carries a meaningful version nibble. Not decoration: the app **skips a row whose id will not parse**, so an id refused here is a row that would otherwise be stored and never shown.",
    example: "6f9619ff-8b86-d011-b42d-00c04fc964ff",
  });

/**
 * One GPS fix on a session's route.
 *
 * A named component rather than an inline object, because it is a thing a client takes apart: the app
 * decodes an array of these and a generated client should have a type for one of them.
 *
 * `heartRate` is required and not nullable, mirroring the app's `WorkoutRoutePoint`, whose route
 * points are only ever written from inside a session that is accumulating one — each fix is stamped
 * with the rate in force at that moment. A fix with no rate is therefore not a shape the producer can
 * make, and making it expressible here would invite a `null` the app's decoder cannot hold.
 */
export const WorkoutRoutePointSchema = z
  .object({
    id: WorkoutIdSchema,
    latitude: z.number().finite().min(-90).max(90).openapi({
      description: "Degrees, ±90. A value outside the range is not a place.",
      example: 40.7128,
    }),
    longitude: z.number().finite().min(-180).max(180).openapi({
      description: "Degrees, ±180.",
      example: -74.006,
    }),
    timestamp: InstantSchema,
    heartRate: z.number().int().positive().openapi({
      description:
        "The heart rate in force at this fix, in bpm. Required: the app stamps every point it records from the session's own accumulator, so there is no fix in this system that has no rate.",
      example: 148,
    }),
  })
  .openapi("WorkoutRoutePoint", {
    description: "One GPS fix. The array's order **is** the route's order — it is stored against its index and read back by it.",
  });

/**
 * One lap of a session.
 *
 * `workout_splits` has no producer in the app — there is no lap model — so this describes a shape
 * nothing writes yet rather than one in use. It is published anyway for the same reason the table
 * exists: the app's types carry it, the aggregate is written and read as a whole, and a session
 * carrying splits would otherwise have no way to sync them.
 *
 * `elapsed` is a `TimeInterval` in the app and a `REAL` column here, so it is a number and not an
 * integer: a lap's length in seconds is a measurement, not a count.
 */
export const WorkoutSplitSchema = z
  .object({
    id: WorkoutIdSchema,
    elapsed: z.number().finite().nonnegative().openapi({
      description: "Seconds into the session at which this lap closed. A `TimeInterval` in the app, so fractional.",
      example: 300.5,
    }),
    strain: z.number().finite().nonnegative().openapi({
      description: "The lap's own strain contribution. The app's `StrainScore` scale is 0–21, but this is a model output and is not bounded here — a bound that refused a row the app can compute would be worse than one that admits an overshoot.",
      example: 3.4,
    }),
  })
  .openapi("WorkoutSplit", {
    description: "One lap. Ordered by array index, exactly as `WorkoutRoutePoint` is. **No producer exists yet** — the app has no lap model.",
  });

/**
 * Whether a zone block is a shape this API will store.
 *
 * The length is a published bound (`.length(ZONE_COUNT)` on the array) and the sum is not expressible
 * as one, so it lives here: the five bands are shares of one session's span, and **time below zone 1
 * belongs to no band**, so the total is at most 100 and never exactly 100 by requirement. A block
 * summing to more would be shares of something other than the session, and the app derives a row's
 * duration from its share — so the figure on screen would exceed the session it sits inside.
 *
 * `null` passes: an absent block is not an invalid one, and the two are different claims.
 */
function isZoneBlock(value: readonly number[] | null): boolean {
  if (value === null) {
    return true;
  }

  const total = value.reduce((sum, share) => sum + share, 0);
  return total <= 100;
}

/**
 * Whether a session's end is strictly after its start.
 *
 * A shared predicate for the two write schemas, on `hasRepeatedDay`'s rule: the rule is stated once,
 * where it can be read, and each refine is one line that asks it.
 *
 * **Both instants are re-parsed rather than compared as strings**, even though the canonical form
 * sorts lexicographically and a string comparison would give the same answer on every well-formed
 * pair. A malformed one is the case that matters: `"zzz" > "aaa"` is true and says nothing, so a
 * string comparison would pass a body whose two fields the instant schema still has to refuse — and
 * it is the *schema's* refusal, with a field path, that a client can act on.
 *
 * Strictly after, not merely different: a session of zero length is not a duration the app can show,
 * and a reversed pair would make every derived figure — the zone span, a fast's elapsed seconds, a
 * split's position — negative while looking like a stored session.
 */
function endsAfterItStarts(session: {
  readonly startedAt: string;
  readonly endedAt: string;
}): boolean {
  const started = parseInstant(session.startedAt);
  const ended = parseInstant(session.endedAt);

  return started !== null && ended !== null && ended > started;
}

/**
 * The stored fields, in one place.
 *
 * Composed into the response schema and both write bodies, so the three cannot drift: a field added
 * here appears in the contract's response *and* in its request bodies, and adding one to just one side
 * means writing it out separately — the mistake this shape exists to prevent.
 *
 * **No field is defaulted, and every absence is `.nullable()`.** A client that omits `strain` and one
 * that sends `strain: null` are making the same claim — nothing was measured — and this API must not
 * hold a third answer for either. A defaulted `0` here would be the fabrication every absence rule in
 * this project forbids: `steps: 0` is a measured session that never moved, `strain: 0.0` is a session
 * that never left zone 1, and neither is what a missing key means.
 */
const workoutFields = {
  date: DayKeySchema,

  startedAt: InstantSchema,

  endedAt: InstantSchema,

  strain: z.number().finite().nonnegative().nullable().openapi({
    description:
      "The session's cardiovascular load on WHOOP's 0–21 scale, or `null` for a session nothing measured one on — a fast is the producer of that case. `null` and `0.0` are different answers: `0.0` is a measured session that never left zone 1.",
    example: 7.4,
  }),

  averageHeartRate: z.number().int().positive().nullable().openapi({
    description:
      "Average heart rate in bpm, or `null` when unmeasured. Positive and never zero: a rate of zero is not a measurement, it is an absent one, and an absent one has a spelling already.",
    example: 132,
  }),

  maxHeartRate: z.number().int().positive().nullable().openapi({
    description: "Peak heart rate in bpm, or `null` when unmeasured. Positive for `averageHeartRate`'s reason.",
    example: 171,
  }),

  source: z
    .string()
    .min(1)
    .nullable()
    .openapi({
      description:
        "Provenance — which producer wrote the row (`whoop_export`, `zero_fasting`, …). `null` means this app recorded it. An empty string is refused: it is a value nobody supplied, and the column being nullable is what gives absence a spelling.",
      example: "whoop_export",
    }),

  activityName: z
    .string()
    .min(1)
    .nullable()
    .openapi({
      description:
        "The activity's own label. **A label and not a measurement**, which is why it is a string rather than a number: WHOOP's classifier abstains rather than guessing and its export writes exactly the word `Activity` on the rows it could not categorise. `null` is a session with no name at all.",
      example: "Basketball",
    }),

  hrZonePercents: z
    .array(z.number().int().min(0).max(100))
    .length(ZONE_COUNT)
    .nullable()
    .refine(isZoneBlock, {
      message: `the ${ZONE_COUNT} shares must sum to at most 100 — time below zone 1 belongs to no band`,
    })
    .openapi({
      description:
        `The ${ZONE_COUNT} zone shares, zone 1 first, as whole percents summing to **at most** 100 — the remainder is time below zone 1, which belongs to no band, so the five do not cover the session. \`null\` is a session with no zone block, which is **not** \`[0,0,0,0,0]\`: that array is a real reading of a session that never reached zone 1. The app derives a row's duration from its own share, so the two figures on a row can never contradict each other, and a fractional share is a value from some other producer.`,
      example: [12, 40, 33, 10, 0],
    }),

  steps: z.number().int().nonnegative().nullable().openapi({
    description:
      "Steps counted during the session, or `null` when no motion was seen. **`null` is not a measured `0`** — a session that measured motion and counted no steps is a real zero, and one whose motion never arrived is an absence.",
    example: 693,
  }),

  offlineRegionID: z
    .string()
    .min(1)
    .nullable()
    .openapi({
      description:
        "The Mapbox tile region downloaded around this session, or `null` for every session recorded with `USE OFFLINE MAP` off — which is most of them. The device answers whether those tiles are still on disk; this column only records that a region was requested.",
      example: null,
    }),

  // Required, and never defaulted to `[]`. The write replaces the children, so a body that could omit
  // this would delete a stored route — and `.strict()` makes the omission a `400` naming the field
  // rather than a silent wipe.
  route: z.array(WorkoutRoutePointSchema).max(MAX_ROUTE_POINTS).openapi({
    description: `The session's GPS fixes in order. **Required and never defaulted**: a write replaces the route, so an omitted one would delete a stored path rather than leave it alone. Empty means the session has no route, which is an affirmative claim. At most ${MAX_ROUTE_POINTS}.`,
  }),

  splits: z.array(WorkoutSplitSchema).max(MAX_SPLITS).openapi({
    description: `The session's laps in order. Required, and required to be empty rather than absent, for \`route\`'s reason. At most ${MAX_SPLITS}.`,
  }),
};

/**
 * One stored session, as the API returns it.
 *
 * The response is the **row read back from the database**, not the request echoed — which is what lets
 * a client confirm the round trip, and in particular that a `null` sent as `null` is still `null` and
 * was not folded into `0` or `[]` anywhere in the write path. That is the assertion a screenshot
 * cannot make, and on this resource it is the one that matters most: `steps: null`, `strain: null` and
 * `hrZonePercents: null` are three absences a default would quietly erase.
 *
 * `userId` is deliberately **not** on the wire, for `RecoverySchema`'s reason: it is the caller's own
 * identity, already known from the request that asked, and publishing it invites a client to read an
 * owner out of a payload instead of out of the credential.
 *
 * The response schema carries **no cross-field refinement**, and the asymmetry with the write bodies is
 * deliberate: a row here came out of the database, which the write path already refused to fill with a
 * reversed pair. Validating it again would describe a state this API cannot produce, and a response
 * schema that could reject its own storage is a 500 waiting for a legacy row.
 */
export const WorkoutSchema = z
  .object({
    id: WorkoutIdSchema,
    ...workoutFields,
  })
  .openapi("Workout", {
    description:
      "One recorded session with its route and laps. A day holds several, so a session is addressed by `id` and `date` is an ordinary field. Unmeasured fields are `null`, never zero-filled.",
  });

/**
 * The response type, inferred from the schema rather than written out beside it.
 *
 * `workouts.ts` declares its domain-to-wire mapper as returning this, which closes the chain the same
 * way `RecoveryWire` does: a field added to `workoutFields` and forgotten in the mapper is a compile
 * error rather than a column that quietly never leaves the database.
 *
 * Note that it is the *mutable* shape — `z.infer` gives `number[]` where the domain type says
 * `readonly number[]` — which is why the mapper spreads the arrays rather than passing them through.
 */
export type WorkoutWire = z.infer<typeof WorkoutSchema>;

/** One GPS fix as the contract spells it. Exported so the mapper's return type can name it. */
export type WorkoutRoutePointWire = z.infer<typeof WorkoutRoutePointSchema>;

/** One lap as the contract spells it. */
export type WorkoutSplitWire = z.infer<typeof WorkoutSplitSchema>;

/**
 * The `PUT /v1/workouts/{id}` body: the stored fields, minus the identity.
 *
 * The `id` is in the path, so a body carrying one would be a second, disagreeable statement of the same
 * fact — the same rule as `RecoveryWriteSchema`'s missing `date`, moved from the day to the session.
 * `.strict()` makes either a `400` rather than a silent strip.
 *
 * **`date` *is* in this body**, and that is not an inconsistency with the sentence above: a session's
 * day is not derivable from its id, and it is not derivable here from `startedAt` either. It is
 * `startOfDay(startedAt)` in the *client's* calendar, which a Worker in UTC cannot reconstruct — a
 * 22:40 session is the 22nd to a caller in New York and the 23rd to one in Berlin, and both are right.
 * So it is carried rather than computed, and nothing here cross-checks it against `startedAt`.
 */
export const WorkoutWriteSchema = z
  .object(workoutFields)
  .strict()
  .openapi("WorkoutWrite", {
    description:
      "The fields of a session, less its identity — the id comes from the path. `date` **is** here, unlike a recovery's: a session's day is the device's `startOfDay(startedAt)` and this Worker cannot derive it.",
  })
  .refine(endsAfterItStarts, {
    path: ["endedAt"],
    message: "endedAt must be strictly after startedAt — a session of zero length is not a duration",
  });

/**
 * One session of a bulk write: the same fields a `PUT` body carries, plus the identity the path would
 * have carried.
 *
 * `id` is back on the type, where `WorkoutWriteSchema` deliberately drops it, because a batch has no
 * path to put it in. That is the whole reason the two schemas are not one — the split
 * `services/workoutService.ts` draws between `WorkoutInput` and `WorkoutBatchEntry`.
 *
 * **`.strict()` first, then `.openapi()`, then the refinement.** `@asteasolutions/zod-to-openapi`
 * patches `.refine()` to carry a schema's `openapi` metadata through and does **not** patch `.strict()`
 * — so a name attached before the strictness is discarded and this lands in the document as an unnamed
 * inline object. The order is not cosmetic: a component with no name cannot be referred to by a client
 * generator, and `tests/openapi.spec.ts` asserts this one is named.
 */
export const WorkoutBatchRowSchema = z
  .object({
    id: WorkoutIdSchema,
    ...workoutFields,
  })
  .strict()
  .openapi("WorkoutBatchRow", {
    description:
      "One session of a bulk write. The id is required and carried in the body, because a batch has no path to put it in.",
  })
  .refine(endsAfterItStarts, {
    path: ["endedAt"],
    message: "endedAt must be strictly after startedAt — a session of zero length is not a duration",
  });

/**
 * Whether any session's id is named twice in a batch.
 *
 * A predicate and not the offending id, because **a schema's refusal message is a constant**:
 * `@asteasolutions/zod-to-openapi` patches `.refine()` and does not patch `.superRefine()`, so a
 * dynamically composed message would cost this schema its name in the document. The count is stated by
 * `services/workoutService.ts`, which is the layer that can phrase it and which a caller arriving over
 * HTTP never reaches — the schema refuses first, with this constant message.
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
 * Whether a batch's children exceed what one request may carry.
 *
 * **This is the rule that actually bounds the work a request does**, and it is why it is published
 * rather than left to the service. A session costs at least three statements before its children, so
 * `MAX_ROUTE_POINTS × MAX_BATCH_WORKOUTS` would be 400,000 statements in one batch; the aggregate caps
 * hold the whole request to roughly `MAX_BATCH_WORKOUTS × 3 + MAX_BATCH_ROUTE_POINTS + MAX_BATCH_SPLITS`
 * — about 2,800 at the limits, and about 600 for the ordinary case of two hundred sessions with no
 * children at all. A batch of many short routes and a batch of one long one are both fine; a batch of
 * two hundred long ones is not.
 *
 * The per-session caps are separate and are published as field bounds (`.max()` on each array), which
 * is why only the totals need a predicate.
 */
function exceedsBatchChildCaps(rows: readonly { readonly route: readonly unknown[]; readonly splits: readonly unknown[] }[]): boolean {
  let routePoints = 0;
  let splits = 0;

  for (const row of rows) {
    routePoints += row.route.length;
    splits += row.splits.length;
  }

  return routePoints > MAX_BATCH_ROUTE_POINTS || splits > MAX_BATCH_SPLITS;
}

/**
 * The `POST /v1/workouts/batch` body: up to `MAX_BATCH_WORKOUTS` sessions, each named exactly once.
 *
 * **Uniqueness is on `id` here and on `date` in `recoveries`**, and the inversion is the resource's
 * whole shape: a day holds several sessions, so two rows sharing a date are an ordinary Tuesday while
 * two sharing an id are a client that has minted one identity twice. That case is refused rather than
 * resolved by ordering, because the second write would win silently and the row left on disk would be
 * whichever the array happened to put last.
 *
 * **What this endpoint is not is as load-bearing as what it is.** It is not a `PUT` on the collection:
 * that would say "these are the sessions", which obliges the server to remove the ones the caller left
 * out. This API has no delete path at all — which is the whole of the answer to "does a delete
 * propagate?" — so a batch adds and replaces, and it never removes.
 *
 * **Idempotence is the property the client depends on.** Every session lands on the same `(userId, id)`
 * key the single-session `PUT` writes, so a chunk replayed after a timeout the client never saw the
 * answer to rewrites each session with the values it already holds: no duplicates, no row count moved.
 *
 * Three refusals are carried here and restated in `services/workoutService.ts`, which owns them — the
 * schema is what publishes them where a client can read them, and the service is what enforces them
 * for a caller that arrived from a script or a test and passed through no schema at all.
 */
export const WorkoutBatchWriteSchema = z
  .object({
    rows: z
      .array(WorkoutBatchRowSchema)
      .min(1)
      .max(MAX_BATCH_WORKOUTS)
      .openapi({
        description: `The sessions to write, at least one and at most ${MAX_BATCH_WORKOUTS}. Each id must appear exactly once, and the batch's routes and splits are capped in total at ${MAX_BATCH_ROUTE_POINTS} and ${MAX_BATCH_SPLITS} — the cap that actually bounds a request's work, since a session costs three statements before its children. A chunk of the app's full history is four of these.`,
      }),
  })
  .strict()
  .openapi("WorkoutBatchWrite", {
    description:
      "A chunk of sessions to insert or replace. Adds and overwrites; it never deletes, so a session the caller leaves out is left alone rather than removed.",
  })
  .refine((body) => !hasRepeatedId(body.rows), {
    path: ["rows"],
    message: "names a session id more than once; a batch must give each session exactly one row",
  })
  .refine((body) => !exceedsBatchChildCaps(body.rows), {
    path: ["rows"],
    message: "carries more route points or splits in total than one request may hold",
  });

/**
 * What a batch answers with, and the one thing about the number that would mislead.
 *
 * `written` counts **sessions, not rows**, and that is a different claim from
 * `RecoveryBatchResultSchema`'s even though the field is spelled the same — which is why this is its
 * own component rather than a shared one. A session with a 2,000-point route touches 2,003 rows in the
 * batch, so a total counted in rows would be a function of how much GPS a run collected rather than of
 * what was sent. The adapter sums the parent upserts alone.
 *
 * Like its sibling it is the database's own `changes` tally, **so a replayed chunk reports the same
 * count as the first send rather than zero** — SQLite counts a row matched by `ON CONFLICT … DO UPDATE`
 * as changed even when every value is byte-identical. A client must not read `written: 0` as "there was
 * nothing to do", and nothing here answers `0` for a non-empty batch.
 *
 * It is deliberately **not** the sessions read back. The client already holds every value it just sent,
 * so echoing two hundred of them is a second round trip it cannot act on; the property a read-back
 * would prove — that a `null` stayed `null` — is asserted by reading the window afterwards, which is
 * where it belongs.
 */
export const WorkoutBatchResultSchema = z
  .object({
    written: z.number().int().nonnegative().openapi({
      description:
        "How many **sessions** the database reported writing — not rows, and not children: a session with a 2,000-point route is one. A replayed chunk reports the same number as the first send, not zero.",
      example: 200,
    }),
  })
  .openapi("WorkoutBatchResult", {
    description:
      "The outcome of a bulk write, counted in sessions rather than rows. It reports what the database did, not what was on disk afterwards.",
  });

/**
 * The window read's query.
 *
 * **`days`/`endingOn`, not `from`/`to`**, for `WindowQuerySchema`'s reason: the endpoint mirrors the
 * app's own history window so a client porting an existing call passes the same number through. That
 * mirroring includes the app's off-by-one — the window is inclusive at both ends, so `days=14` spans
 * 15 calendar days — and it is `recoveries`' arithmetic verbatim, not a second derivation of it.
 *
 * The answer is shaped differently, though: an **array** of sessions with no padding, because a day
 * holds several and a day inside the window with none is simply not represented.
 */
export const WorkoutWindowQuerySchema = z.object({
  days: z.coerce
    .number()
    .int()
    .min(0)
    .max(MAX_WINDOW_DAYS)
    .openapi({
      description: `How many days back from \`endingOn\` to reach. **The window is inclusive at both ends, so \`days=14\` spans 15 calendar days** — this mirrors the app's own window exactly, deliberately, so a ported call returns identical rows. \`0\` means the single day \`endingOn\`.`,
      example: 14,
    }),

  endingOn: DayKeySchema.optional().openapi({
    description:
      "The newest day in the window, inclusive. Optional only because the server has no notion of the caller's local today — its own is UTC, and a device eight hours behind it is a day out. **Clients should always send this.**",
    example: "2026-08-22",
  }),
});
