import { z } from "@hono/zod-openapi";
import { HRV_METRICS } from "../domain";
import { MAX_BATCH_ROWS, MAX_WINDOW_DAYS } from "../services";
import { DayKeySchema } from "./shared";

/**
 * The wire shapes for `/v1/recoveries` — and, because the OpenAPI document is generated from these
 * declarations, the published contract itself.
 *
 * Three conventions are fixed here and each has a reason.
 *
 * **camelCase on the wire, snake_case in the database.** The D1 columns mirror the app's local
 * columns exactly (`skin_temperature`, `spo2_percentage`) because that is what "the local schema is
 * the starting point" means; the JSON uses the app's own *property* names (`skinTemperature`,
 * `spo2Percentage`), which are the names a Swift client already has. The mapping between the two
 * lives in exactly one file, `d1RecoveryRepository.ts`.
 *
 * **A nullable field is `.nullable()` and never `.optional()`.** An absent key and a key holding
 * `null` are different claims, and only one of them means "measured, and there was nothing there".
 * `.optional()` would make both spellings legal and would make a stripped key indistinguishable from
 * an honest null.
 *
 * **A day is `YYYY-MM-DD`, and it is checked by round trip.** That rule is `dto/shared.ts`'s, and so is the
 * caller's header: both are the vocabulary this API has rather than words belonging to `recoveries`,
 * and they moved there when `workouts` became the second resource to need them.
 */

/**
 * The stored fields, in one place.
 *
 * Both the response schema and the write body are composed from this object, so the two cannot drift:
 * a field added here appears in the contract's response *and* in its request body, and the only way
 * to add one to just one side is to write it out separately — which is the mistake this shape exists
 * to prevent.
 */
const recoveryFields = {
  recoveryScore: z.number().int().min(0).max(100).openapi({
    description: "Recovery score, 0–100. A percentage, so the bounds are its definition.",
    example: 68,
  }),

  restingHeartRate: z.number().int().positive().openapi({
    description:
      "Resting heart rate in bpm. Positive: a rate of zero is not a measurement, it is an absent one, and an absent one has no row here.",
    example: 52,
  }),

  hrvValueMs: z.number().finite().nonnegative().openapi({
    description:
      "Heart-rate variability in milliseconds, in the quantity `hrvMetric` names. Zero is legal and means what the app means by it — no measurable variability — because the app itself writes `0.0` on that path and a schema that refused it could not represent a row the app can create.",
    example: 71.4,
  }),

  hrvMetric: z.enum(HRV_METRICS).openapi({
    description:
      "Which quantity `hrvValueMs` is. RMSSD and SDNN are different distributions on different scales and never share a baseline, which is why this is required rather than defaulted.",
    example: "rmssd",
  }),

  skinTemperature: z.number().finite().nullable().openapi({
    description:
      "Skin temperature. `null` when the strap did not report one — which is not `0`, and the difference is preserved all the way to the database.",
    example: null,
  }),

  spo2Percentage: z.number().finite().min(0).max(100).nullable().openapi({
    description: "Blood-oxygen saturation, 0–100. `null` when unmeasured.",
    example: null,
  }),

  respiratoryRate: z.number().finite().nonnegative().nullable().openapi({
    description: "Respiratory rate in breaths per minute. `null` when unmeasured.",
    example: null,
  }),

  source: z
    .string()
    .min(1)
    .nullable()
    .openapi({
      description:
        "Provenance — which producer wrote the row (`whoop_export`, …). `null` means this app measured it, or that the row predates the column. An empty string is refused: it is a value nobody supplied, and the whole point of the column being nullable is that absence has a spelling already.",
      example: null,
    }),
};

/**
 * One stored day, as the API returns it.
 *
 * The response is the **row read back from the database**, not the request echoed. That is what lets
 * a client confirm the round trip — that a `source` sent as `null` is still `null` and was not
 * folded into `""` or `0` by a default somewhere in the write path — and it is the assertion a
 * screenshot cannot make.
 *
 * `userId` is deliberately **not** on the wire. It is the caller's own identity, already known from
 * the request that asked, and publishing it would invite a client to start reading an owner out of a
 * payload instead of out of the credential — which is the habit that breaks the day the placeholder
 * header is replaced by a real one.
 */
export const RecoverySchema = z
  .object({
    date: DayKeySchema,
    ...recoveryFields,
  })
  .openapi("Recovery", {
    description: "One day's recovery reading. An unmeasured day has no row and is a 404, never a zero-filled record.",
  });

/**
 * The response type, inferred from the schema rather than written out beside it.
 *
 * `recoveries.ts` declares its domain-to-wire mapper as returning this, which is what closes the last
 * gap in the chain: the schema is shared between the response and the write body, the write body is
 * typechecked against `RecoveryInput` by `RecoveryService.writeDay`'s parameter, and the response is
 * typechecked against this. A field added to `recoveryFields` and forgotten in the mapper is a
 * compile error rather than a column that quietly never leaves the database.
 */
export type RecoveryWire = z.infer<typeof RecoverySchema>;

/**
 * The `PUT` body: the stored fields, minus the day.
 *
 * The day is in the path, so a body carrying one would be a second, disagreeable statement of the
 * same fact. `.strict()` makes that a `400` rather than a silent strip — and strictness is the right
 * default here for the general reason too: a client that misspells `respiratoryRate` should be told,
 * not quietly have a `null` written where it meant to send a reading.
 *
 * No field is defaulted. A client that omits `source` and a client that sends `source: null` are
 * making the same claim, and this API must not hold a third answer for either.
 */
export const RecoveryWriteSchema = z
  .object(recoveryFields)
  .strict()
  .openapi("RecoveryWrite", {
    description: "The fields of a recovery reading, less its day — the day comes from the path.",
  });

/**
 * One row of a bulk write: the same fields a `PUT` body carries, plus the day it is filed under.
 *
 * **The day is in the body here, and that is the one structural difference from `RecoveryWriteSchema`.**
 * There a body carrying `date` is a `400`, because the path already states the day and a second
 * statement of one fact can only disagree with the first. A batch has no path, so every row must name
 * its own day or the request does not mean anything — which is the whole reason
 * `services/recoveryService.ts` has two input types rather than one.
 *
 * `.strict()` matters more here than it does on the single-day body and for a reason that is about
 * volume: a batch is assembled by a client out of its own database, and a misspelled field in one row
 * of two hundred is exactly the failure a silent strip would turn into one day's reading written as
 * `null` with a `200` beside it.
 *
 * **`.strict()` first, then `.openapi()`.** `@asteasolutions/zod-to-openapi` patches `.refine()` to
 * carry a schema's `openapi` metadata through, and it does not patch `.strict()` — so a name attached
 * before the strictness is discarded and this schema lands in the document as an unnamed inline
 * object. The order is the fix and it is not cosmetic: the document is the contract, and a component
 * with no name cannot be referred to by a client generator.
 */
export const RecoveryBatchRowSchema = z
  .object({
    date: DayKeySchema,
    ...recoveryFields,
  })
  .strict()
  .openapi("RecoveryBatchRow", {
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
 * `services/recoveryService.ts`, which is the layer that can phrase it and which a caller arriving
 * through HTTP never reaches: the schema refuses first, with this constant message.
 *
 * A plain function rather than a `Set` built inside the predicate, on `readWindow`'s rule — the rule
 * is stated once, where it can be read, and the refine is one line that asks it.
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
 * The `POST /v1/recoveries/batch` body: up to `MAX_BATCH_ROWS` days, each named exactly once.
 *
 * **What this endpoint is not is as load-bearing as what it is.** It is not a `PUT` on the collection,
 * and the difference is a promise about deletion: a `PUT` on `/v1/recoveries` would say "these are the
 * days", which obliges the server to remove the ones the caller left out. This API has no delete path
 * at all — which is the whole of the answer to "do deletes propagate?" — so a verb that implied one
 * would be a promise the Worker cannot keep. A batch adds and replaces, and it never removes.
 *
 * **Idempotence is the property the client actually depends on.** Every row lands on the same
 * `(userId, date)` key the single-day `PUT` writes, so a chunk replayed after a timeout the client
 * never saw the answer to rewrites each row with the values it already holds. That is what makes a
 * retry safe without the client having to know whether the first attempt landed.
 *
 * The three rules below — at least one row, at most `MAX_BATCH_ROWS`, each day once — are also stated
 * in `services/recoveryService.ts`, which is the layer that owns them. They are restated rather than
 * delegated for `readWindow`'s reason: the schema is what publishes them where a client can read them,
 * and the service is what enforces them for a caller that arrived from a script or a test and passed
 * through no schema at all. `MAX_BATCH_ROWS` is imported from the service rather than repeated, so the
 * published limit and the enforced limit are one number.
 *
 * The distinct-day rule is the one worth arguing for, because allowing it would be *nearly*
 * harmless: the second write of a day wins and the row that ends up on disk is whichever the array
 * happened to put last. That is precisely the problem — a client that computed its day set twice and
 * disagreed with itself would get a `200` and a silently order-dependent result, instead of a `400`
 * it can act on.
 */
export const RecoveryBatchWriteSchema = z
  .object({
    rows: z
      .array(RecoveryBatchRowSchema)
      .min(1)
      .max(MAX_BATCH_ROWS)
      .openapi({
        description: `The days to write, at least one and at most ${MAX_BATCH_ROWS}. Each day must appear exactly once. A chunk of the app's full history is five of these.`,
      }),
  })
  .strict()
  .openapi("RecoveryBatchWrite", {
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
 * read-back would prove — that a `null` stayed `null` — is asserted by reading the range afterwards,
 * which is where it belongs.
 */
export const RecoveryBatchResultSchema = z
  .object({
    written: z.number().int().nonnegative().openapi({
      description:
        "How many rows the database reported writing. A replayed chunk reports the same number as the first send, not zero — `INSERT … ON CONFLICT DO UPDATE` counts a matched row as changed.",
      example: 200,
    }),
  })
  .openapi("RecoveryBatchResult", {
    description: "The outcome of a bulk write. It reports what the database did, not what was on disk afterwards.",
  });

/**
 * The range read's query.
 *
 * **`days`/`endingOn`, not `from`/`to`**, because the endpoint mirrors
 * `RecoveryRepository.getRecoveryHistory(days:endingOn:)` and a client porting an existing call
 * should pass the same number through rather than compute a second pair of dates. That mirroring
 * includes the app's own off-by-one, which is documented on `days` below and pinned by a test.
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
    .max(MAX_WINDOW_DAYS)
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
