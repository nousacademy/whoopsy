import { z } from "@hono/zod-openapi";
import { MAX_BATCH_SLEEPS, MAX_SLEEP_WINDOW_DAYS } from "../services";
import { parseInstant } from "../utils/instants";
import { DayKeySchema, InstantSchema } from "./shared";

/**
 * The wire shapes for `/v1/sleeps` — and, because the OpenAPI document is generated from these
 * declarations, the published contract itself.
 *
 * Three conventions are fixed here and each has a reason.
 *
 * **camelCase on the wire, snake_case in the database.** The D1 columns are this Worker's own spelling
 * (`sleep_performance`, `total_sleep_needed`); the JSON uses the app's *property* names
 * (`sleepPerformance`, `totalSleepNeeded`), which are the names a Swift client already has. That holds
 * even though the app's local `SleepRecord` maps its own camelCase properties onto those same
 * snake_case names with an explicit `CodingKeys` — the wire is the app's property names either way, and
 * the mapping between the two namings lives in exactly one file, `d1SleepRepository.ts`.
 *
 * **A nullable field is `.nullable()` and never `.optional()`.** An absent key and a key holding `null`
 * are different claims, and on this resource the distinction carries more weight than it does on either
 * sibling: six fields are nullable, three of them are *values a model on the client computes*, and the
 * app's own readers tell "the estimator declined" from "the estimator answered" by exactly that `null`.
 * A default here would put a number on the wire that no client produced. No field on this schema is
 * defaulted anywhere.
 *
 * **A day is `YYYY-MM-DD`, and it is checked by round trip.** That rule is `dto/shared.ts`'s, and so is the
 * caller's header and the instant spelling: all three are the vocabulary this API has rather than words
 * belonging to `sleeps`.
 */

/**
 * The longest `sleepStages` blob this API will carry, in bytes of JSON text.
 *
 * **Measured rather than guessed, and the measurement is the app's own read window.** The blob is one
 * segment per epoch the strap staged, and the app reads 9 PM → 10 AM — thirteen hours, which at a
 * 30-second epoch is 1560 segments. Each segment's JSON runs about 121 characters: a 36-character UUID,
 * two 13-digit unix-millisecond instants, and a stage raw value up to `"Deep / SWS"`. That is ≈188,760
 * bytes for the widest night the app can produce, so `262_144` (256 KiB) leaves roughly 1.4× headroom —
 * enough for a night read at a coarser epoch spacing or with a longer stage name, and still far below
 * anything that would trouble a request body or a D1 cell.
 *
 * **A payload-shape bound, and that classification is what decides where it lives.** It is `source`'s
 * `.min(1)` rather than `MAX_BATCH_SLEEPS`: a rule about what a well-formed field looks like, with no
 * policy behind it and therefore no counterpart in `SleepService`. The service states the caps it
 * *enforces* — how many rows, how far back — and this states the one shape the schema refuses on its
 * own, which is why the constant is here and not in `services/sleepService.ts`.
 *
 * It is a **byte ceiling on a string**, not a segment count, because counting segments would mean
 * parsing the blob — the one thing no file in this Worker is allowed to do. See the field's own doc.
 */
export const MAX_SLEEP_STAGES_LENGTH = 262_144;

/**
 * Whether the night ends after it starts.
 *
 * A shared predicate for the two write schemas, on `hasRepeatedDay`'s rule: the rule is stated once,
 * where it can be read, and each refine is one line that asks it.
 *
 * **Both instants are re-parsed rather than compared as strings**, even though the canonical form sorts
 * lexicographically and a string comparison would give the same answer on every well-formed pair. A
 * malformed one is the case that matters: `"zzz" > "aaa"` is true and says nothing, so a string
 * comparison would pass a body whose two fields the instant schema still has to refuse — and it is the
 * *schema's* refusal, with a field path, that a client can act on.
 *
 * Strictly after, not merely different: a night of zero length is not a night, and the app's own
 * arithmetic on the pair — the sleep period, the stage totals' span, the efficiency denominator — would
 * all divide by it while the row looked stored and plausible.
 *
 * **This refines the two write bodies and deliberately not `SleepSchema`**, which is `WorkoutSchema`'s
 * rule applied to this resource: a response schema that could reject its own storage is a `500` waiting
 * for a legacy row. Nothing in this API can produce a reversed pair — the bodies below refuse it before
 * it reaches the table — but the response's job is to report what is on disk rather than to hold an
 * opinion about it.
 */
function endsAfterItStarts(night: {
  readonly startTime: string;
  readonly endTime: string;
}): boolean {
  const started = parseInstant(night.startTime);
  const ended = parseInstant(night.endTime);

  return started !== null && ended !== null && ended > started;
}

/**
 * The stored fields, in one place.
 *
 * Both the response schema and the two write bodies are composed from this object, so the three cannot
 * drift: a field added here appears in the contract's response *and* in its request bodies, and the
 * only way to add one to just one side is to write it out separately — which is the mistake this shape
 * exists to prevent. On a fourteen-field object that is not hypothetical.
 */
const sleepFields = {
  startTime: InstantSchema.openapi({
    description:
      "When the night began, as an instant in canonical UTC form. **The day this night is filed under is not derived from this field** — it is the *wake* day, and it comes from the path or from the row's own `date`.",
    example: "2026-08-21T23:12:00.000Z",
  }),

  endTime: InstantSchema.openapi({
    description:
      "When it ended. Refused by both write bodies unless it is strictly later than `startTime` — a night of zero length is not a night. The response carries no such refinement, deliberately.",
    example: "2026-08-22T07:04:00.000Z",
  }),

  sleepPerformance: z.number().finite().min(0).max(100).openapi({
    description:
      "Sleep performance as a whole-scale percentage. **This is the app's own figure and not WHOOP's column**: every stored row holds `clamp(asleep ÷ need × 100, 0, 100)` computed on the device, so one formula covers all 910 imported nights and every night after. The export's own `Sleep performance %` is parsed by the app and read by nothing. The bounds are the scale's definition, and the clamp is applied before the value is stored — a client sending a figure outside them is describing a different quantity.",
    example: 81.3,
  }),

  totalSleepNeeded: z.number().finite().nonnegative().openapi({
    description:
      "The night's requirement, in **seconds** — not minutes, which is the unit WHOOP's own `Sleep need (min)` column uses and which the importer converts. **A value below the eight-hour baseline is real and correct**: 53 of the bundled export's nights carry one, and the app's own formula cannot produce it, because a strap night's need is a computed baseline plus a fitted strain term while an imported night's is WHOOP's own. Nothing distinguishes the two producers here except `source`.",
    example: 33420,
  }),

  lightSleep: z.number().finite().nonnegative().openapi({
    description:
      "Light sleep, in seconds. One of the three stages whose sum is the asleep total `sleepPerformance` divides.",
    example: 18720,
  }),

  deepSleep: z.number().finite().nonnegative().openapi({
    description:
      "Deep (slow-wave) sleep, in seconds. **Zero is legal and is a measurement**: the export holds a night of 15h40m of light sleep with no deep and no REM at all, and a bar chart draws that as a labelled column carrying no bar.",
    example: 5400,
  }),

  remSleep: z.number().finite().nonnegative().openapi({
    description: "REM sleep, in seconds. Zero is legal and is a measurement, for the reason above.",
    example: 3060,
  }),

  awakeTime: z.number().finite().nonnegative().openapi({
    description:
      "Wakefulness within the night's own span, in seconds — the fourth stage total and not a fifth row. It is what makes `asleep + awake == duration` an identity a reader can check against the night's two boundary instants: the three stages above plus this one span the whole night.",
    example: 1620,
  }),

  respiratoryRate: z.number().finite().nonnegative().nullable().openapi({
    description:
      "Breaths per minute, **derived from the R-R series rather than read off a sensor** — the strap has no respiratory sensor. `null` on every night that series cannot support, which includes every imported night, since the export carries no R-R series at all. **`null` and `0` are different answers**: the estimator declining and the estimator returning a figure are different facts, and a server that filled one in would be publishing a reading no device took. Non-negative rather than positive because the optional already carries the absence — this bound only refuses a negative breathing rate.",
    example: 14.4,
  }),

  disturbanceCount: z.number().int().nonnegative().nullable().openapi({
    description:
      "How many times the night's sleep was disturbed. `null` on every imported night — the export has no such column — and on any night the actigraphy classifier could not read. A `0` is a measured night nobody stirred, which is a different claim from a night nobody scored.",
    example: 7,
  }),

  sleepConsistency: z.number().int().min(0).max(100).nullable().openapi({
    description:
      "WHOOP's own Sleep Consistency for the night, as a whole percent. Nullable for two separate reasons and both are real states: a night with fewer than four priors has none, and a row written before the app's `v9` migration has none either. **`null` is 'not scored', which is not a score of zero** — a `0` here would claim a night maximally inconsistent with its own history.",
    example: 88,
  }),

  sleepDebt: z.number().finite().nonnegative().nullable().openapi({
    description:
      "The accumulated deficit, in **seconds** — WHOOP's `Sleep debt (min)` converted, whose 910 non-empty export values run 0 to 127 minutes. **The two producers are different quantities and only one of them is a term of the need above it**: WHOOP's need is a total that contains `need_from_sleep_debt`, while the app's own `SleepNeedMath` deliberately omits any debt term — so `need − debt` is WHOOP's base-plus-strain on an imported night and a base requirement short by the whole deficit on a strap night. Nothing but `source` distinguishes them, which is why the app's breakdown card gates on provenance rather than on this field being non-null.",
    example: 6240,
  }),

  sleepStages: z
    .string()
    .min(1)
    .max(MAX_SLEEP_STAGES_LENGTH)
    .nullable()
    .openapi({
      description:
        "The night's stage timeline, as **opaque JSON text**, stored and handed back unchanged. On the phone this field is an array of typed segments; on this side of the boundary it is the string the column holds, and **nothing in this Worker parses it, validates its interior or re-serialises it**. That is a decision rather than a shortcut, and it has three parts. The server never reads into the blob and takes no opinion about it, so there is no second decoder here that has to agree with the app's `Codable` one forever. The instants inside it are **unix milliseconds** — a third convention that this API's own `InstantSchema` exists to keep out of the published contract, so a structured wire form would either impose a conversion on the client with a silent-corruption failure mode or put a second instant spelling in this document. And the failure mode of a string is bounded and honest: a client that PUTs garbage gets the same garbage back, which is the property a sync exists for. An empty string is refused — a night with no stages and a night that was never staged are the same thing, and `null` is that thing's only representation; an empty array is never stored. `null` on every imported night permanently, because the export reports stage *totals* and no timeline.",
      example:
        '[{"id":"8B1F0C24-3E5A-4D77-9C21-6F0B7A2E4D18","start":1787372263000,"end":1787372293000,"stage":"Light"}]',
    }),

  source: z
    .string()
    .min(1)
    .nullable()
    .openapi({
      description:
        "Provenance — which producer wrote the row (`whoop_export`, …). `null` means this app measured it, or that the row predates the column. An empty string is refused: it is a value nobody supplied, and the whole point of the column being nullable is that absence has a spelling already. **It carries more weight on this resource than on any other in this API**, because it is the only marker separating two producers of `sleepPerformance`, `sleepConsistency`, `sleepDebt` and `respiratoryRate` — four fields the app computes for a strap night and stores verbatim for an imported one.",
      example: "whoop_export",
    }),
};

/**
 * One stored night, as the API returns it.
 *
 * The response is the **row read back from the database**, not the request echoed. That is what lets a
 * client confirm the round trip — that a `respiratoryRate` sent as `null` is still `null` rather than
 * the `0` a default somewhere in the write path might have folded it into — and on this resource that
 * assertion is the whole of what the write path has to get right, so `PUT` answers from disk.
 *
 * **A night with no row is a `404 no_measurement_for_day`, and there is no second kind of row**, which
 * is where this resource takes `recoveries`' shape rather than `strains`'. The app's local `sleeps`
 * table carries no `hasMeasurement` column: a night the classifier could not read is never written —
 * `AnalyzeSleepUseCase` returns an optional and writes nothing — so a row that exists is a night that
 * was measured. There is nothing here for a flag to discriminate and no placeholder to forward, and the
 * route therefore checks `=== null` and nothing else.
 *
 * **This schema carries no cross-field refinement**, deliberately, while both write bodies below do.
 * `WorkoutSchema` states the rule and it applies here verbatim: a response schema that could reject its
 * own storage is a `500` waiting for a legacy row. The reversed `endTime` is refused before it can be
 * written, so nothing this API produces can trip it — but the response's job is to report what is on
 * disk, not to hold an opinion about it.
 *
 * `userId` is deliberately **not** on the wire. It is the caller's own identity, already known from the
 * request that asked, and publishing it would invite a client to start reading an owner out of a
 * payload instead of out of the credential — which is the habit that breaks the day the placeholder
 * header is replaced by a real one.
 */
export const SleepSchema = z
  .object({
    date: DayKeySchema,
    ...sleepFields,
  })
  .openapi("Sleep", {
    description:
      "One night's sleep, filed under the day it **woke** on. A day with no row is a 404 — this resource has no unmeasured-row state, because a night the classifier could not read is never written at all.",
  });

/**
 * The response type, inferred from the schema rather than written out beside it.
 *
 * `sleeps.ts` declares its domain-to-wire mapper as returning this, which is what closes the last gap
 * in the chain: the schema is shared between the response and the write bodies, the write bodies are
 * typechecked against `SleepInput` by `SleepService.writeDay`'s parameter, and the response is
 * typechecked against this. A field added to `sleepFields` and forgotten in the mapper is a compile
 * error rather than a column that quietly never leaves the database.
 */
export type SleepWire = z.infer<typeof SleepSchema>;

/**
 * The `PUT` body: the stored fields, minus the day.
 *
 * The day is in the path, so a body carrying one would be a second, disagreeable statement of the same
 * fact. `.strict()` makes that a `400` rather than a silent strip.
 *
 * **Strictness matters more here than on `recoveries` and about as much as it does on `strains`.** Four
 * of this body's fields are nullable, so a client that *misspells* one of those is not caught by the
 * missing-field check in the way a required field would be — except that none of them is optional, so a
 * misspelling is still a missing key and still a `400`. What strictness adds is the **extra** key, and
 * the extra key that matters is `date`: a `PUT` whose body names its own day is a client with two
 * opinions about which night it is writing, and the path wins every time in a way the client cannot
 * see. On a night whose day is its *wake* day that is a whole-day error waiting to happen.
 *
 * The `endTime`-after-`startTime` refinement is attached **after** `.openapi()`, and the order is not
 * cosmetic — see `SleepBatchRowSchema` below for the full argument.
 *
 * No field is defaulted. A client that omits `source` and a client that sends `source: null` are making
 * the same claim, and this API must not hold a third answer for either.
 */
export const SleepWriteSchema = z
  .object(sleepFields)
  .strict()
  .openapi("SleepWrite", {
    description: "The fields of a night's sleep, less its day — the day comes from the path.",
  })
  .refine(endsAfterItStarts, {
    path: ["endTime"],
    message: "endTime must be strictly after startTime — a night of zero length is not a night",
  });

/**
 * One row of a bulk write: the same fields a `PUT` body carries, plus the day it is filed under.
 *
 * **The day is in the body here, and that is the one structural difference from `SleepWriteSchema`.**
 * There a body carrying `date` is a `400`, because the path already states the day and a second
 * statement of one fact can only disagree with the first. A batch has no path, so every row must name
 * its own day or the request does not mean anything — which is the whole reason
 * `services/sleepService.ts` has two input types rather than one.
 *
 * `.strict()` matters more here than it does on the single-day body and for a reason that is about
 * volume: a batch is assembled by a client out of its own database, and a misspelled field in one row
 * of two hundred is exactly the failure a silent strip would turn into one night written with a
 * defaulted field and a `200` beside it.
 *
 * **`.strict()` first, then `.openapi()`, then the refinement.** `@asteasolutions/zod-to-openapi`
 * patches `.refine()` to carry a schema's `openapi` metadata through, and it does not patch
 * `.strict()` — so a name attached before the strictness is discarded and this schema lands in the
 * document as an unnamed inline object. The order is the fix and it is not cosmetic: the document is
 * the contract, and a component with no name cannot be referred to by a client generator.
 *
 * The refinement is restated rather than shared with the body above, on `hasRepeatedDay`'s rule: the
 * *predicate* is shared and each refine is one line that asks it. Sharing the composed schema instead
 * would mean one of the two bodies being built from the other, and the two differ by exactly the field
 * a shared base would have to hold back.
 */
export const SleepBatchRowSchema = z
  .object({
    date: DayKeySchema,
    ...sleepFields,
  })
  .strict()
  .openapi("SleepBatchRow", {
    description:
      "One night of a bulk write. The day is required and carried in the body, because a batch has no path to put it in. It is the night's **wake** day.",
  })
  .refine(endsAfterItStarts, {
    path: ["endTime"],
    message: "endTime must be strictly after startTime — a night of zero length is not a night",
  });

/**
 * Whether any day is named twice in a batch.
 *
 * A predicate and not the offending day, because **a schema's refusal message is a constant**.
 * `@asteasolutions/zod-to-openapi` patches `.refine()` to carry `openapi` metadata through and does
 * not patch `.superRefine()` — the two lists are in its own `index.cjs` — so a dynamically composed
 * message here would cost this schema its name in the document, which is a worse trade than a refusal
 * that says *what* is wrong without saying *where*. The count is stated by
 * `services/sleepService.ts`, which is the layer that can phrase it and which a caller arriving
 * through HTTP never reaches: the schema refuses first, with this constant message.
 *
 * **Restated here rather than shared with `dto/strains.ts`, and the rule that decides it is
 * `dto/shared.ts`'s own boundary.** That file is where a thing goes when a second resource needs it, but its
 * doc draws the line at a **format**: a shape whose rule is about how a value is spelled rather than
 * about what it means to a resource. A predicate over `{ date }` rows names a field of a particular
 * payload, so it is on the wrong side of that line, and a `sleeps` schema importing out of a file named
 * after another resource is the dependency `dto/shared.ts` calls "a dependency that reads as a mistake and
 * would be copied by the third resource" — which is now the fourth.
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
 * The `POST /v1/sleeps/batch` body: up to `MAX_BATCH_SLEEPS` days, each named exactly once.
 *
 * **What this endpoint is not is as load-bearing as what it is.** It is not a `PUT` on the collection,
 * and the difference is a promise about deletion: a `PUT` on `/v1/sleeps` would say "these are the
 * nights", which obliges the server to remove the ones the caller left out. This API has no delete path
 * at all — which is the whole of the answer to "do deletes propagate?" — so a verb that implied one
 * would be a promise the Worker cannot keep. A batch adds and replaces, and it never removes.
 *
 * **The stakes on that are the highest of the four resources.** A night's history has holes in it by
 * construction — a night the user did not wear the strap is a gap in the middle of a nine-hundred-day
 * range rather than a missing tail — so a collection-wide `PUT` would oblige this API to delete roughly
 * a fourth of the user's sleep history on the first sync of a partially-worn range. Here the same
 * property that makes the endpoint honest (`null` is a value, and a missing day is a day nobody
 * measured) is the one that makes a delete verb unrepresentable rather than merely wrong.
 *
 * **Idempotence is the property the client actually depends on.** Every row lands on the same
 * `(userId, date)` key the single-day `PUT` writes, so a chunk replayed after a timeout the client
 * never saw the answer to rewrites each row with the values it already holds. That is what makes a
 * retry safe without the client having to know whether the first attempt landed.
 *
 * The three rules below — at least one row, at most `MAX_BATCH_SLEEPS`, each day once — are also stated
 * in `services/sleepService.ts`, which is the layer that owns them. They are restated rather than
 * delegated for `readWindow`'s reason: the schema is what publishes them where a client can read them,
 * and the service is what enforces them for a caller that arrived from a script or a test and passed
 * through no schema at all. `MAX_BATCH_SLEEPS` is imported from the service rather than repeated, so
 * the published limit and the enforced limit are one number.
 *
 * The distinct-day rule is the one worth arguing for, and it is the strongest case of the four
 * resources that share it: a night carries fourteen fields and two versions of one could differ in
 * *any* of them, so the day would end up holding a night assembled from one array position and its two
 * boundary instants from another — with a `200` beside it and nothing anywhere reporting it.
 */
export const SleepBatchWriteSchema = z
  .object({
    rows: z
      .array(SleepBatchRowSchema)
      .min(1)
      .max(MAX_BATCH_SLEEPS)
      .openapi({
        description: `The nights to write, at least one and at most ${MAX_BATCH_SLEEPS}. Each day must appear exactly once. A chunk of the app's full history is five of these.`,
      }),
  })
  .strict()
  .openapi("SleepBatchWrite", {
    description:
      "A chunk of nights to insert or replace. Adds and overwrites; it never deletes, so a day the caller leaves out is left alone rather than removed.",
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
 * It is deliberately **not** the rows read back. The client is a sync that already holds every value it
 * just sent, so echoing two hundred sixteen-column nights is a second round trip it cannot act on; the
 * property a read-back would prove — that six `null`s stayed `null` — is asserted by reading the range
 * afterwards, which is where it belongs, and by the single-day `PUT`, which does read back.
 */
export const SleepBatchResultSchema = z
  .object({
    written: z.number().int().nonnegative().openapi({
      description:
        "How many rows the database reported writing. A replayed chunk reports the same number as the first send, not zero — `INSERT … ON CONFLICT DO UPDATE` counts a matched row as changed.",
      example: 200,
    }),
  })
  .openapi("SleepBatchResult", {
    description:
      "The outcome of a bulk write. It reports what the database did, not what was on disk afterwards.",
  });

/**
 * The range read's query.
 *
 * **`days`/`endingOn`, not `from`/`to`**, because the endpoint mirrors
 * `SleepRepository.getSleepHistory(days:endingOn:)` and a client porting an existing call should pass
 * the same number through rather than compute a second pair of dates. That mirroring includes the
 * app's own off-by-one, which is documented on `days` below and pinned by a test.
 *
 * **Declared here rather than imported from `dto/strains.ts`, where a schema of this name lives.**
 * The name is the same because the shape is the same shape every windowed read in this API has; the
 * *schema* is this resource's, on `dto/shared.ts`'s boundary rule — it names `days` and `endingOn`, which are
 * fields of this payload, and a `sleeps` route importing them out of a file named after another
 * resource is the dependency that rule exists to prevent. Neither is registered as a named component,
 * so the two do not collide in the document; each is inlined into its own operation.
 *
 * `days` is required and undefaulted. A default here would be an invented number of days assembled from
 * nothing — this API has no opinion about how much history a caller wants, and `0` is a perfectly good
 * answer meaning "just the one day".
 */
export const WindowQuerySchema = z.object({
  days: z.coerce
    .number()
    .int()
    .min(0)
    .max(MAX_SLEEP_WINDOW_DAYS)
    .openapi({
      description:
        `How many days back from \`endingOn\` to reach. **The window is inclusive at both ends, so \`days=14\` spans 15 calendar days** — this mirrors the app's own \`historyWindow(days:endingOn:)\` exactly, deliberately, so a ported call returns identical rows. \`0\` means the single day \`endingOn\`. Days inside the window with no row are omitted rather than padded, which on a partially-worn history is the ordinary case.`,
      example: 14,
    }),

  endingOn: DayKeySchema.optional().openapi({
    description:
      "The newest day in the window, inclusive. Optional only because the server has no notion of the caller's local today — its own is UTC, and a device eight hours behind it is a day out. **Clients should always send this.**",
    example: "2026-08-22",
  }),
});
