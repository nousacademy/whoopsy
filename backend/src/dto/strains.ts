import { z } from "@hono/zod-openapi";
import { MAX_BATCH_STRAINS, MAX_STRAIN_WINDOW_DAYS } from "../services";
import { DayKeySchema } from "./shared";

/**
 * The wire shapes for `/v1/strains` — and, because the OpenAPI document is generated from these
 * declarations, the published contract itself.
 *
 * Three conventions are fixed here and each has a reason.
 *
 * **camelCase on the wire, snake_case in the database.** The D1 columns are this Worker's own
 * spelling (`strain_score`, `has_measurement`); the JSON uses the app's *property* names
 * (`strainScore`, `hasMeasurement`), which are the names a Swift client already has. That holds even
 * though the app's local `strains` table is the one table in the app whose columns are camelCase
 * (`StrainRecord` declares no `CodingKeys`) — the wire is the app's property names either way, and
 * the mapping between the two namings lives in exactly one file, `d1StrainRepository.ts`.
 *
 * **A nullable field is `.nullable()` and never `.optional()`.** An absent key and a key holding
 * `null` are different claims. Here that applies to `source` alone: every other field on a strain is
 * a stored non-null column, and the one field that could look optional — `hasMeasurement` — is
 * deliberately required, because a client that omitted it would be handing this API the decision the
 * flag exists to record.
 *
 * **A day is `YYYY-MM-DD`, and it is checked by round trip.** That rule is `dto/shared.ts`'s, and so is the
 * caller's header: both are the vocabulary this API has rather than words belonging to `strains`.
 */

/**
 * The stored fields, in one place.
 *
 * Both the response schema and the write body are composed from this object, so the two cannot drift:
 * a field added here appears in the contract's response *and* in its request body, and the only way
 * to add one to just one side is to write it out separately — which is the mistake this shape exists
 * to prevent.
 */
const strainFields = {
  strainScore: z.number().finite().min(0).max(21).openapi({
    description:
      "Strain, on WHOOP's 0–21 scale. The bounds are the scale's definition. The app rounds to one decimal (`(score * 10).rounded() / 10`) and that is not enforced here: a `multipleOf(0.1)` refinement on a binary float refuses values the app really holds, since `4.1 % 0.1` is not zero in IEEE-754. The figure a client sends is the figure that is stored.",
    example: 4.1,
  }),

  kilojoules: z.number().finite().nonnegative().openapi({
    description:
      "Energy expenditure in **kilojoules**, not kilocalories — the stored unit, converted through 4.184 on the app's side. **Zero is legal and is a measurement**: it is what a scored day with no weight on file produces, since the calorie estimate returns nothing without one. It is never an absence, and `hasMeasurement` below is what separates a measured zero from an unmeasured row.",
    example: 1046,
  }),

  averageHeartRate: z.number().int().nonnegative().openapi({
    description:
      "Average heart rate in bpm. **Non-negative rather than positive, unlike `recoveries.restingHeartRate`**: an unmeasured row carries `0` here and is legitimately on this wire, distinguished by `hasMeasurement` rather than by its rate. A `positive()` bound would refuse a row the app really holds.",
    example: 68,
  }),

  maxHeartRate: z.number().int().nonnegative().openapi({
    description: "Maximum heart rate in bpm. Non-negative for the same reason as the average.",
    example: 151,
  }),

  hasMeasurement: z.boolean().openapi({
    description:
      "**Whether the two rates and the score are readings, and the one thing `strainScore` cannot tell you.** A genuine rest day is a real `0.0` — WHOOP's own export scores exactly `0.0` on two days — and a row left behind by a build before the app's `v7` migration holds `0.0` too, so the score cannot distinguish them and neither can any other figure. Required, and never inferred by this API: it is a stored column on the app's side, it round-trips unchanged, and a server that derived it from a non-zero heart rate would rewrite the app's own record of whether anyone took a reading. The rate bounds above are non-negative precisely so that this flag, rather than a rate, is the discriminator.",
    example: true,
  }),

  source: z
    .string()
    .min(1)
    .nullable()
    .openapi({
      description:
        "Provenance — which producer wrote the row (`whoop_export`, …). `null` means this app measured it, or that the row predates the column. An empty string is refused: it is a value nobody supplied, and the whole point of the column being nullable is that absence has a spelling already. Every strain row the bundled WHOOP export produces carries `whoop_export`; the column matters more here than it does on `recoveries`, because an imported strain is WHOOP's own figure rather than this app's.",
      example: "whoop_export",
    }),
};

/**
 * One stored day, as the API returns it.
 *
 * The response is the **row read back from the database**, not the request echoed. That is what lets
 * a client confirm the round trip — that a `source` sent as `null` is still `null`, and that a
 * `hasMeasurement` sent as `false` came back `false` rather than as the `1` the column stores — and
 * it is the assertion a screenshot cannot make.
 *
 * **An unmeasured row is a `200` with `hasMeasurement: false`, not a 404**, which is where this
 * resource differs from `recoveries` in more than its fields. The app stores such a row, `findByDay`
 * finds it, and `StrainScore.hasMeasurement` is how every reader in the app already tells it apart
 * from a reading. Answering `404 no_measurement_for_day` here would be this API deciding that a row
 * the client holds does not exist — and a client syncing it up would then be told its own local row
 * was never measured, which is the one claim the flag is there to make honestly. The 404 is for a day
 * with **no row at all**, which is the same absence `recoveries` answers.
 *
 * `userId` is deliberately **not** on the wire. It is the caller's own identity, already known from
 * the request that asked, and publishing it would invite a client to start reading an owner out of a
 * payload instead of out of the credential — which is the habit that breaks the day the placeholder
 * header is replaced by a real one.
 */
export const StrainSchema = z
  .object({
    date: DayKeySchema,
    ...strainFields,
  })
  .openapi("Strain", {
    description:
      "One day's strain. A day with no row at all is a 404; a row that exists but carries `hasMeasurement: false` is a `200`, because that row is real and the flag is how it is told apart from a reading.",
  });

/**
 * The response type, inferred from the schema rather than written out beside it.
 *
 * `strains.ts` declares its domain-to-wire mapper as returning this, which is what closes the last
 * gap in the chain: the schema is shared between the response and the write body, the write body is
 * typechecked against `StrainInput` by `StrainService.writeDay`'s parameter, and the response is
 * typechecked against this. A field added to `strainFields` and forgotten in the mapper is a compile
 * error rather than a column that quietly never leaves the database.
 */
export type StrainWire = z.infer<typeof StrainSchema>;

/**
 * The `PUT` body: the stored fields, minus the day.
 *
 * The day is in the path, so a body carrying one would be a second, disagreeable statement of the
 * same fact. `.strict()` makes that a `400` rather than a silent strip.
 *
 * **What strictness buys here is narrower than on `recoveries`, and the difference is worth stating.**
 * Every field on this body is required and non-nullable, so a client that *misspells* one — or leaves
 * `hasMeasurement` out — is already refused by the missing-field check, and no default can absorb it.
 * Strictness is therefore catching the **extra** key rather than the wrong one, and on this body the
 * extra key that matters is `date`: a `PUT` whose body names its own day is a client that has two
 * opinions about which day it is writing, and the path wins every time in a way the client cannot see.
 *
 * No field is defaulted. A client that omits `source` and a client that sends `source: null` are
 * making the same claim, and this API must not hold a third answer for either.
 */
export const StrainWriteSchema = z
  .object(strainFields)
  .strict()
  .openapi("StrainWrite", {
    description: "The fields of a strain reading, less its day — the day comes from the path.",
  });

/**
 * One row of a bulk write: the same fields a `PUT` body carries, plus the day it is filed under.
 *
 * **The day is in the body here, and that is the one structural difference from `StrainWriteSchema`.**
 * There a body carrying `date` is a `400`, because the path already states the day and a second
 * statement of one fact can only disagree with the first. A batch has no path, so every row must name
 * its own day or the request does not mean anything — which is the whole reason
 * `services/strainService.ts` has two input types rather than one.
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
export const StrainBatchRowSchema = z
  .object({
    date: DayKeySchema,
    ...strainFields,
  })
  .strict()
  .openapi("StrainBatchRow", {
    description:
      "One day of a bulk write. The day is required and carried in the body, because a batch has no path to put it in.",
  });

/**
 * Whether any day is named twice in a batch.
 *
 * A predicate and not the offending day, because **a schema's refusal message is a constant**.
 * `@asteasolutions/zod-to-openapi` patches `.refine()` to carry `openapi` metadata through and does
 * not patch `.superRefine()` — the two lists are in its own `index.cjs` — so a dynamically composed
 * message here would cost this schema its name in the document, which is a worse trade than a
 * refusal that says *what* is wrong without saying *where*. The count is stated by
 * `services/strainService.ts`, which is the layer that can phrase it and which a caller arriving
 * through HTTP never reaches: the schema refuses first, with this constant message.
 *
 * **Restated here rather than shared with `dto/recoveries.ts`, and the rule that decides it is
 * `dto/shared.ts`'s own boundary.** That file is where a thing goes when a second resource needs it — it is
 * how `DayKeySchema` and `UserHeaderSchema` got there — but its doc draws the line at a **format**: a
 * shape whose rule is about how a value is spelled rather than about what it means to a resource. A
 * predicate over `{ date }` rows names a field of a particular payload, so it is on the wrong side of
 * that line and `dto/shared.ts` is not available as a home for it. The alternatives were a third file
 * holding one eight-line function, or this resource's schema importing out of a file named after
 * another resource — the dependency `dto/shared.ts`'s own doc calls "a dependency that reads as a mistake
 * and would be copied by the third resource". So the rule is stated once per resource, which is what
 * it means.
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
 * The `POST /v1/strains/batch` body: up to `MAX_BATCH_STRAINS` days, each named exactly once.
 *
 * **What this endpoint is not is as load-bearing as what it is.** It is not a `PUT` on the collection,
 * and the difference is a promise about deletion: a `PUT` on `/v1/strains` would say "these are the
 * days", which obliges the server to remove the ones the caller left out. This API has no delete path
 * at all — which is the whole of the answer to "do deletes propagate?" — so a verb that implied one
 * would be a promise the Worker cannot keep. A batch adds and replaces, and it never removes.
 *
 * **Idempotence is the property the client actually depends on.** Every row lands on the same
 * `(userId, date)` key the single-day `PUT` writes, so a chunk replayed after a timeout the client
 * never saw the answer to rewrites each row with the values it already holds. That is what makes a
 * retry safe without the client having to know whether the first attempt landed.
 *
 * The three rules below — at least one row, at most `MAX_BATCH_STRAINS`, each day once — are also
 * stated in `services/strainService.ts`, which is the layer that owns them. They are restated rather
 * than delegated for `readWindow`'s reason: the schema is what publishes them where a client can read
 * them, and the service is what enforces them for a caller that arrived from a script or a test and
 * passed through no schema at all. `MAX_BATCH_STRAINS` is imported from the service rather than
 * repeated, so the published limit and the enforced limit are one number.
 *
 * The distinct-day rule is the one worth arguing for, because allowing it would be *nearly*
 * harmless: the second write of a day wins and the row that ends up on disk is whichever the array
 * happened to put last. That is precisely the problem — a client that computed its day set twice and
 * disagreed with itself would get a `200` and a silently order-dependent result, instead of a `400`
 * it can act on. On this resource the two rows could also disagree about `hasMeasurement`, which
 * would leave the day claiming whichever of the two the array happened to put last.
 */
export const StrainBatchWriteSchema = z
  .object({
    rows: z
      .array(StrainBatchRowSchema)
      .min(1)
      .max(MAX_BATCH_STRAINS)
      .openapi({
        description: `The days to write, at least one and at most ${MAX_BATCH_STRAINS}. Each day must appear exactly once. A chunk of the app's full history is five of these.`,
      }),
  })
  .strict()
  .openapi("StrainBatchWrite", {
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
 * read-back would prove — that a `false` stayed `false` — is asserted by reading the range
 * afterwards, which is where it belongs.
 */
export const StrainBatchResultSchema = z
  .object({
    written: z.number().int().nonnegative().openapi({
      description:
        "How many rows the database reported writing. A replayed chunk reports the same number as the first send, not zero — `INSERT … ON CONFLICT DO UPDATE` counts a matched row as changed.",
      example: 200,
    }),
  })
  .openapi("StrainBatchResult", {
    description: "The outcome of a bulk write. It reports what the database did, not what was on disk afterwards.",
  });

/**
 * The range read's query.
 *
 * **`days`/`endingOn`, not `from`/`to`**, because the endpoint mirrors
 * `StrainRepository.getStrainHistory(days:endingOn:)` and a client porting an existing call should
 * pass the same number through rather than compute a second pair of dates. That mirroring includes
 * the app's own off-by-one, which is documented on `days` below and pinned by a test.
 *
 * **Declared here rather than imported from `dto/recoveries.ts`, where a schema of this name
 * lives.** The name is the same because the shape is the same shape every windowed read in this API
 * has; the *schema* is this resource's, on `dto/shared.ts`'s boundary rule — it names `days` and `endingOn`,
 * which are fields of this payload, and a `strains` route importing them out of a file named after
 * another resource is the dependency that rule exists to prevent. Neither is registered as a named
 * component, so the two do not collide in the document; each is inlined into its own operation.
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
    .max(MAX_STRAIN_WINDOW_DAYS)
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
