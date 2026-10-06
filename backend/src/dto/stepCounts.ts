import { z } from "@hono/zod-openapi";
import { MAX_BATCH_STEP_COUNTS, MAX_STEP_COUNT_WINDOW_DAYS } from "../services";
import { DayKeySchema } from "./shared";

/**
 * The wire shapes for `/v1/step-counts` — and, because the OpenAPI document is generated from these
 * declarations, the published contract itself.
 *
 * Three conventions are fixed here and each has a reason.
 *
 * **camelCase on the wire, snake_case in the database.** The D1 columns are this Worker's own spelling
 * (`step_count`, `measured_seconds`); the JSON uses the app's *property* names (`stepCount`,
 * `measuredSeconds`), which are the names a Swift client already has. That holds even though the app's
 * local `stepCounts` table is one of the two tables whose columns are camelCase (`StepCountRecord`
 * declares no `CodingKeys`) — the wire is the app's property names either way, and the mapping between
 * the two namings lives in exactly one file, `d1StepCountRepository.ts`.
 *
 * **Every field is required and non-nullable, and there is no `hasMeasurement`.** Where `strains`
 * carries a stored flag and a nullable `source`, this resource carries neither: the absence rule here
 * is a *row's* existence, so there is no second kind of row for a flag to describe, and steps have one
 * producer, so there is no provenance to record. A client derives `hasMeasurement` as
 * `measuredSeconds > 0` from a field the wire already publishes; see the note on that field below.
 *
 * **A day is `YYYY-MM-DD`, and it is checked by round trip.** That rule is `dto/shared.ts`'s, and so
 * is the caller's header: both are the vocabulary this API has rather than words belonging to
 * `stepCounts`. Note what is *not* imported from there — `InstantSchema`, and `parseInstant` with it,
 * because neither field on this resource is an instant. That absence is why this file is about a third
 * the length of `dto/sleeps.ts`: no boundary pair, no ordering refinement, no blob to bound, and no
 * nullable column to round-trip.
 */

/**
 * The stored fields, in one place.
 *
 * Both the response schema and the write bodies are composed from this object, so they cannot drift: a
 * field added here appears in the contract's response *and* in its request bodies, and the only way to
 * add one to just one side is to write it out separately — which is the mistake this shape exists to
 * prevent.
 */
const stepCountFields = {
  stepCount: z.number().int().nonnegative().openapi({
    description:
      "Steps the strap's pedometer counted that day. A whole number of steps, and **`0` is a measurement**: a day of no walking that the strap did wear is a real zero, distinguished from a day nothing measured by `measuredSeconds` below and never by this field. There is no fraction to round — the app stores an `Int` and the accumulator adds whole peaks — so a fractional value is refused rather than truncated, on the rule that this API does not edit a client's figure.",
    example: 8432,
  }),

  measuredSeconds: z.number().finite().nonnegative().openapi({
    description:
      "Seconds of motion the count above came from, as the app's accumulator summed them — `Σ min(5.0, Δt)` over the batches it was handed, so a fractional value is ordinary rather than an error. **This is the field that separates a measured day from a day nothing measured**: the app's `StepCount.hasMeasurement` is exactly `measuredSeconds > 0`, so a client derives that flag from this number rather than receiving it. `0` is accepted and stored rather than refused — a row holding it is one no current writer produces but that the app can still hold, and an API that refused it would be deciding a row the client has does not exist. It is never a default: this API applies none to any field, because a `0` filled in here would publish a day nothing measured as a day that was.",
    example: 41_760,
  }),
};

/**
 * One stored day, as the API returns it.
 *
 * The response is the **row read back from the database**, not the request echoed. That is what lets a
 * client confirm the round trip — that a `0` was stored as a `0` and that nothing in the write path
 * defaulted `measuredSeconds` — and it is the assertion a screenshot cannot make.
 *
 * **A day with no row is a `404`, and there is nothing else to test beside it.** That is
 * `recoveries`' absence rule rather than `strains`': the app stores no `hasMeasurement` column here,
 * its flag is computed, and no writer produces a row that claims nothing was measured — so unlike
 * `strains`, where an unmeasured row is a legitimate `200`, there is no second kind of row this
 * resource could return. Answering a zero-filled record for an absent day would be the fabrication the
 * absence rule exists to prevent, and a client syncing it up would store a count nobody took.
 *
 * `userId` is deliberately **not** on the wire. It is the caller's own identity, already known from
 * the request that asked, and publishing it would invite a client to start reading an owner out of a
 * payload instead of out of the credential — which is the habit that breaks the day the placeholder
 * header is replaced by a real one.
 */
export const StepCountSchema = z
  .object({
    date: DayKeySchema,
    ...stepCountFields,
  })
  .openapi("StepCount", {
    description:
      "One day's step count. A day the strap did not measure has no row and is a 404; a measured day of no walking is a `200` carrying `stepCount: 0` and a positive `measuredSeconds`.",
  });

/**
 * The response type, inferred from the schema rather than written out beside it.
 *
 * `routes/stepCounts.ts` declares its domain-to-wire mapper as returning this, which is what closes
 * the last gap in the chain: the schema is shared between the response and the write bodies, the write
 * bodies are typechecked against `StepCountInput` by `StepCountService`'s parameters, and the response
 * is typechecked against this. A field added to `stepCountFields` and forgotten in the mapper is a
 * compile error rather than a column that quietly never leaves the database.
 */
export type StepCountWire = z.infer<typeof StepCountSchema>;

/**
 * The `PUT` body: the stored fields, minus the day.
 *
 * The day is in the path, so a body carrying one would be a second, disagreeable statement of the same
 * fact. `.strict()` makes that a `400` rather than a silent strip.
 *
 * **There is no `.refine` on this schema, where `SleepWriteSchema` has one.** `sleeps` refines
 * `endTime > startTime` because a night whose end precedes its start is not a night; neither field
 * here is an instant, and no ordering between a count and a span exists to state. A refinement written
 * anyway — a `measuredSeconds > 0` rule, say — would be this API refusing a row the app can hold, and
 * it would put the resource's absence rule on the wire where `measured_seconds`'s own description
 * already states it.
 *
 * `.strict()` matters here for the same reason it does on `strains`: every field is required and
 * non-nullable, so a *misspelling* is already refused by the missing-field check and no default can
 * absorb it. Strictness is catching the **extra** key, and the extra key that matters is `date` — a
 * `PUT` whose body names its own day is a client with two opinions about which day it is writing, and
 * the path wins every time in a way the client cannot see.
 *
 * No field is defaulted, on `measuredSeconds`' own argument above.
 */
export const StepCountWriteSchema = z
  .object(stepCountFields)
  .strict()
  .openapi("StepCountWrite", {
    description: "The fields of a step count, less its day — the day comes from the path.",
  });

/**
 * One row of a bulk write: the same fields a `PUT` body carries, plus the day it is filed under.
 *
 * **The day is in the body here, and that is the one structural difference from `StepCountWriteSchema`.**
 * There a body carrying `date` is a `400`, because the path already states the day and a second
 * statement of one fact can only disagree with the first. A batch has no path, so every row must name
 * its own day or the request does not mean anything — which is the whole reason
 * `services/stepCountService.ts` has two input types rather than one.
 *
 * `.strict()` matters more here than it does on the single-day body and for a reason that is about
 * volume: a batch is assembled by a client out of its own database, and a misspelled field in one row
 * of two hundred is exactly the failure a silent strip would turn into one day's reading written with
 * a defaulted field and a `200` beside it.
 *
 * **`.strict()` first, then `.openapi()`.** `@asteasolutions/zod-to-openapi` patches `.refine()` to
 * carry a schema's `openapi` metadata through, and it does not patch `.strict()` — so a name attached
 * before the strictness is discarded and this schema lands in the document as an unnamed inline
 * object. The order is the fix and it is not cosmetic: the document is the contract, and a component
 * with no name cannot be referred to by a client generator.
 */
export const StepCountBatchRowSchema = z
  .object({
    date: DayKeySchema,
    ...stepCountFields,
  })
  .strict()
  .openapi("StepCountBatchRow", {
    description:
      "One day of a bulk write. The day is required and carried in the body, because a batch has no path to put it in.",
  });

/**
 * Whether any day is named twice in a batch.
 *
 * A predicate and not the offending day, because **a schema's refusal message is a constant**.
 * `@asteasolutions/zod-to-openapi` patches `.refine()` to carry `openapi` metadata through and does
 * not patch `.superRefine()` — the two lists are in its own `index.cjs` — so a dynamically composed
 * message here would cost this schema its name in the document, which is a worse trade than a refusal
 * that says *what* is wrong without saying *where*. The count is stated by
 * `services/stepCountService.ts`, which is the layer that can phrase it and which a caller arriving
 * through HTTP never reaches: the schema refuses first, with this constant message.
 *
 * **Restated here rather than shared with `dto/strains.ts` or `dto/sleeps.ts`, and the rule that
 * decides it is `dto/shared.ts`'s own boundary.** That file is where a thing goes when a second
 * resource needs it — it is how `DayKeySchema` and `UserHeaderSchema` got there — but its doc draws
 * the line at a **format**: a shape whose rule is about how a value is spelled rather than about what
 * it means to a resource. A predicate over `{ date }` rows names a field of a particular payload, so
 * it is on the wrong side of that line and `dto/shared.ts` is not available as a home for it. The
 * alternatives were a fourth file holding one eight-line function, or this resource's schema importing
 * out of a file named after another resource — the dependency `dto/shared.ts`'s own doc calls "a
 * dependency that reads as a mistake and would be copied by the third resource". So the rule is
 * stated once per resource, which is what it means — and this is the fourth copy of it, which is the
 * arrangement working rather than a sign the line was drawn wrong.
 */
function hasRepeatedDay(rows: readonly { readonly date: string }[]): boolean {
  const seen = new Set<string>();
  for (const row of rows) {
    if (seen.has(row.date)) return true;
    seen.add(row.date);
  }
  return false;
}

/**
 * The `POST /v1/step-counts/batch` body: up to `MAX_BATCH_STEP_COUNTS` days, each named exactly once.
 *
 * **What this endpoint is not is as load-bearing as what it is.** It is not a `PUT` on the collection,
 * and the difference is a promise about deletion: a `PUT` on `/v1/step-counts` would say "these are
 * the days", which obliges the server to remove the ones the caller left out. This API has no delete
 * path at all — which is the whole of the answer to "do deletes propagate?" — so a verb that implied
 * one would be a promise the Worker cannot keep. A batch adds and replaces, and it never removes.
 *
 * **That promise is worth more on this resource than on any of its siblings**, because the days a
 * caller leaves out are not an oversight here: the strap is worn intermittently, so a step history is
 * mostly holes, and "these are the days" would be a request to delete most of the user's record every
 * time it was sent.
 *
 * **Idempotence is the property the client actually depends on.** Every row lands on the same
 * `(userId, date)` key the single-day `PUT` writes, so a chunk replayed after a timeout the client
 * never saw the answer to rewrites each row with the values it already holds. That is what makes a
 * retry safe without the client having to know whether the first attempt landed.
 *
 * The three rules below — at least one row, at most `MAX_BATCH_STEP_COUNTS`, each day once — are also
 * stated in `services/stepCountService.ts`, which is the layer that owns them. They are restated
 * rather than delegated for `readWindow`'s reason: the schema is what publishes them where a client
 * can read them, and the service is what enforces them for a caller that arrived from a script or a
 * test and passed through no schema at all. `MAX_BATCH_STEP_COUNTS` is imported from the service
 * rather than repeated, so the published limit and the enforced limit are one number.
 *
 * The distinct-day rule is the one worth arguing for, because allowing it would be *nearly* harmless:
 * the second write of a day wins and the row that ends up on disk is whichever the array happened to
 * put last. That is precisely the problem — a client that computed its day set twice and disagreed
 * with itself would get a `200` and a silently order-dependent result, instead of a `400` it can act
 * on. The stakes are lower here than on a night, which carries sixteen fields; a step row carries two,
 * so a disagreement could only be about a count or a span. It is refused anyway, because the rule is
 * the family's and a resource that made an exception for being narrow would be the one a reader has
 * to remember.
 */
export const StepCountBatchWriteSchema = z
  .object({
    rows: z
      .array(StepCountBatchRowSchema)
      .min(1)
      .max(MAX_BATCH_STEP_COUNTS)
      .openapi({
        description: `The days to write, at least one and at most ${MAX_BATCH_STEP_COUNTS}. Each day must appear exactly once. A chunk of the app's full history is five of these.`,
      }),
  })
  .strict()
  .openapi("StepCountBatchWrite", {
    description:
      "A chunk of days to insert or replace. Adds and overwrites; it never deletes, so a day the caller leaves out is left alone rather than removed.",
  })
  .refine((body) => !hasRepeatedDay(body.rows), {
    path: ["rows"],
    message: "names a day more than once; a batch must give each day exactly one row",
  });

/**
 * What a batch answers with, and the one thing about the number that would otherwise mislead.
 *
 * `written` is the database's own `changes` tally summed over the chunk, **so a replayed chunk reports
 * the same count as the first send rather than zero**. SQLite counts a row matched by
 * `ON CONFLICT … DO UPDATE` as changed even when every value is byte-identical, which is the honest
 * answer — the statement did write that row — but it means a client must not read `written: 0` as
 * "there was nothing to do". Nothing in this API answers `0` for a non-empty batch.
 *
 * It is deliberately **not** the rows read back. The client is a sync that already holds every value
 * it just sent, so echoing two hundred rows is a second round trip it cannot act on; the property a
 * read-back would prove — that a `0` stayed a `0` — is asserted by reading the range afterwards, which
 * is where it belongs.
 */
export const StepCountBatchResultSchema = z
  .object({
    written: z.number().int().nonnegative().openapi({
      description:
        "How many rows the database reported writing. A replayed chunk reports the same number as the first send, not zero — `INSERT … ON CONFLICT DO UPDATE` counts a matched row as changed.",
      example: 200,
    }),
  })
  .openapi("StepCountBatchResult", {
    description: "The outcome of a bulk write. It reports what the database did, not what was on disk afterwards.",
  });

/**
 * The range read's query.
 *
 * **`days`/`endingOn`, not `from`/`to`**, because the endpoint mirrors
 * `StepRepository.getStepHistory(days:endingOn:)` and a client porting an existing call should pass
 * the same number through rather than compute a second pair of dates. That mirroring includes the
 * app's own off-by-one, which is documented on `days` below and pinned by a test.
 *
 * **Declared here rather than imported from `dto/strains.ts` or `dto/sleeps.ts`, where a schema of
 * this name lives.** The name is the same because the shape is the same shape every windowed read in
 * this API has; the *schema* is this resource's, on `dto/shared.ts`'s boundary rule — it names `days`
 * and `endingOn`, which are fields of this payload, and a `step-counts` route importing them out of a
 * file named after another resource is the dependency that rule exists to prevent. Neither is
 * registered as a named component, so the copies do not collide in the document; each is inlined into
 * its own operation. Four copies of nine lines is the price, and `stepCountService.ts`'s two caps are
 * the reason it is the right price: this copy imports *this* resource's ceiling, so retuning one
 * resource's window cannot move another's published limit.
 *
 * `days` is required and undefaulted. A default here would be an invented number of days assembled
 * from nothing — this API has no opinion about how much history a caller wants, and `0` is a
 * perfectly good answer meaning "just the one day".
 */
export const WindowQuerySchema = z.object({
  days: z.coerce
    .number()
    .int()
    .min(0)
    .max(MAX_STEP_COUNT_WINDOW_DAYS)
    .openapi({
      description:
        `How many days back from \`endingOn\` to reach. **The window is inclusive at both ends, so \`days=14\` spans 15 calendar days** — this mirrors the app's own \`historyWindow(days:endingOn:)\` exactly, deliberately, so a ported call returns identical rows. \`0\` means the single day \`endingOn\`.`,
      example: 14,
    }),

  endingOn: DayKeySchema.optional().openapi({
    description:
      "The newest day in the window, inclusive. Optional only because the server has no notion of the caller's local today — its own is UTC, and a device eight hours behind it is a day out. **Clients should always send this.**",
    example: "2026-08-22",
  }),
});
