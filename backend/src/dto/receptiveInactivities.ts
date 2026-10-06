import { z } from "@hono/zod-openapi";
import { RECEPTIVE_INACTIVITY_ID_PATTERN } from "../domain";
import { MAX_BATCH_RECEPTIVE_INACTIVITIES, MAX_WINDOW_DAYS } from "../services";
import { DayKeySchema, InstantSchema } from "./shared";

/**
 * The wire shapes for `/v1/receptive-inactivities` — and, because the OpenAPI document is generated
 * from these declarations, the published contract itself.
 *
 * The three conventions this API fixes are `dto/recoveries.ts`'s and are restated in `dto/shared.ts`:
 * camelCase on the wire over snake_case columns, `.nullable()` and never `.optional()` for an
 * absence, and a day key checked by round trip.
 *
 * **The shape is `workouts`', and every place it is not is a field this resource does not have.**
 * An entry is addressed by `id` and carries its day in the body, because a day holds several —
 * two dreams on one night is an ordinary night, and a `date` primary key would make the second
 * overwrite the first. What is *absent* is what the shape is really about: no `endedAt`, so no
 * duration and no cross-field boundary refine; no children, so no aggregate cap and no `seq`; and no
 * measured field of any kind, so nothing here carries an optional number with a reserved zero to
 * distinguish from an absence.
 *
 * **Two fields are nullable and the nullability is the point, not a looseness.** `startedAt` is the
 * first nullable *instant* in this Worker: `workouts.startedAt` is required because a session has a
 * beginning by definition, while an entry in a notes log routinely has no recorded time — all 62 rows
 * of the app's bundled file are untimed — so a required field there would demand a fabricated clock
 * time, which is the fabrication every absence rule in this project forbids. `note` is the same
 * argument for prose, with the extra rule that `""` is refused: the column being nullable is what
 * gives "nothing was written" a spelling, and an empty string is a value nobody supplied.
 */

/**
 * An entry's identity.
 *
 * The pattern is `domain/receptiveInactivity.ts`'s, and the reason it is a UUID at all is that
 * `GRDBReceptiveInactivityRepository` builds a `UUID` from each stored id and **silently drops the
 * row** when that fails. An id this Worker accepted but the app cannot parse is a row that is
 * written, is returned by every read here, and appears on no screen — an import that reports success
 * and delivers nothing, which is the exact failure the app's own docs record against string ids.
 *
 * Any version and either case, because `UUID(uuidString:)` accepts both: the app mints **v4** ids for
 * a hand-entered row and derives **v5** ids for an import, and neither carries a version nibble
 * anything here has an opinion about.
 */
export const ReceptiveInactivityIdSchema = z
  .string()
  .regex(RECEPTIVE_INACTIVITY_ID_PATTERN, {
    message: "must be a UUID — the app reads every stored id through UUID(uuidString:)",
  })
  .openapi({
    description:
      "A UUID string. Any version and either case, because `UUID(uuidString:)` accepts both — the app mints v4 ids for a hand-entered entry and derives v5 ids from an entry's date, type and text for an import. Not decoration: the app **drops a row whose id will not parse**, so an id refused here is a row that would otherwise be stored and never shown.",
    example: "7805a9df-1064-5201-9c99-378fd38d1ed6",
  });

/**
 * The stored fields, in one place.
 *
 * Composed into the response schema and both write bodies, so the three cannot drift: a field added
 * here appears in the contract's response *and* in its request bodies, and adding one to just one side
 * means writing it out separately — the mistake this shape exists to prevent.
 *
 * **No field is defaulted, and every absence is `.nullable()`.** A client that omits `note` and one
 * that sends `note: null` are making the same claim — nothing was written — and this API must not hold
 * a third answer for either. A defaulted `startedAt` would be worse than untidy: midnight is a real
 * clock time, so a fabricated one would sort and print as a time the user gave.
 */
const receptiveInactivityFields = {
  date: DayKeySchema,

  name: z
    .string()
    .min(1)
    .openapi({
      description:
        "What the entry was — `Dream`, `Meditation`, and whatever a future producer names. **A label and not a measurement**, which is why it is a string: the app resolves it through its own vocabulary table rather than requiring one of a closed set, so a new producer can join this path without a schema change. Never empty: a nameless entry is not a shape the producer can make.",
      example: "Dream",
    }),

  note: z
    .string()
    .min(1)
    .nullable()
    .openapi({
      description:
        "The entry's own prose, or `null` when nothing was written. **`null` is not `\"\"`** — the column being nullable is what gives absence a spelling, and an empty string is a value nobody supplied. The text is both a value and, on the app's side, an input to the row's derived id, so a re-worded entry leaves its predecessor beside it rather than overwriting it.",
      example: "Standing in a house that was not mine.",
    }),

  startedAt: InstantSchema.nullable().openapi({
    description:
      "A time-of-day on `date`, or `null` for an untimed entry — which is the ordinary case rather than the exception, and every one of the app's 62 bundled rows is untimed. **The first nullable instant in this API**: a session has a beginning by definition, while a note routinely has no recorded time at all, and defaulting one to midnight would sort and print as a time nobody gave. The client rebuilds the hour and minute onto `date`'s own year, month and day, so a non-null value is always on the day beside it.",
    example: "2026-08-22T03:40:00.000Z",
  }),
};

/**
 * One stored entry, as the API returns it.
 *
 * The response is the **row read back from the database**, not the request echoed — which is what lets
 * a client confirm the round trip, and in particular that a `null` sent as `null` is still `null` and
 * was not folded into `""` or a midnight anywhere in the write path. That is the assertion a
 * screenshot cannot make, and on this resource it is the one that matters most: an untimed entry is
 * the *majority* case, so a default that quietly made it midnight would rewrite every imported row
 * while every screen still looked plausible.
 *
 * `userId` is deliberately **not** on the wire, for `RecoverySchema`'s reason: it is the caller's own
 * identity, already known from the request that asked, and publishing it invites a client to read an
 * owner out of a payload instead of out of the credential.
 *
 * The response schema carries **no refinement of any kind**, and that is this resource's shape rather
 * than an omission: there is no second field for any of these to be consistent with — no end for a
 * start to precede, and no array for a share to be a fraction of.
 */
export const ReceptiveInactivitySchema = z
  .object({
    id: ReceptiveInactivityIdSchema,
    ...receptiveInactivityFields,
  })
  .openapi("ReceptiveInactivity", {
    description:
      "One entry in the receptive-inactivity log: what it was, which day it belongs to, and optionally when and what was written. Nothing on this row is measured — no strain, no heart rate, no steps — so an absent value is `null` and never a zero-filled stand-in.",
  });

/**
 * The response type, inferred from the schema rather than written out beside it.
 *
 * `routes/receptiveInactivities.ts` declares its domain-to-wire mapper as returning this, which
 * closes the chain the same way `RecoveryWire` does: a field added to `receptiveInactivityFields` and
 * forgotten in the mapper is a compile error rather than a column that quietly never leaves the
 * database.
 */
export type ReceptiveInactivityWire = z.infer<typeof ReceptiveInactivitySchema>;

/**
 * The `PUT /v1/receptive-inactivities/{id}` body: the stored fields, minus the identity.
 *
 * The `id` is in the path, so a body carrying one would be a second, disagreeable statement of the
 * same fact — the same rule as `WorkoutWriteSchema`'s missing `id`, and `.strict()` makes it a `400`
 * rather than a silent strip.
 *
 * **`date` *is* in this body, and here that is forced rather than chosen.** A session's day is at
 * least derivable in principle from its start instant; this entry has no `endedAt` and its
 * `startedAt` may be absent altogether, so when no time was given there is nothing to derive the day
 * *from*. It therefore comes from the client, which knows it for a certain reason: the day is the one
 * its screen was showing. See `migrations/0006_create_receptive_inactivities.sql`.
 *
 * **There is no cross-field refine here, and the absence is a fact about the resource.** `sleeps` and
 * `workouts` each carry a boundary-pair rule because each holds two instants; this shape holds one
 * optional instant and nothing for it to precede, so a refine would have no predicate to state.
 */
export const ReceptiveInactivityWriteSchema = z
  .object(receptiveInactivityFields)
  .strict()
  .openapi("ReceptiveInactivityWrite", {
    description:
      "The fields of an entry, less its identity — the id comes from the path. `date` **is** here: this row's start time is optional, so the day cannot be derived from it and must be stated.",
  });

/**
 * One entry of a bulk write: the same fields a `PUT` body carries, plus the identity the path would
 * have carried.
 *
 * `id` is back on the type, where `ReceptiveInactivityWriteSchema` deliberately drops it, because a
 * batch has no path to put it in. That is the whole reason the two schemas are not one — the split
 * `services/receptiveInactivityService.ts` draws between `ReceptiveInactivityInput` and
 * `ReceptiveInactivityBatchEntry`.
 *
 * **`.strict()` first, then `.openapi()`.** `@asteasolutions/zod-to-openapi` patches `.refine()` to
 * carry a schema's `openapi` metadata through and does **not** patch `.strict()` — so a name attached
 * before the strictness is discarded and this lands in the document as an unnamed inline object. The
 * order is not cosmetic: a component with no name cannot be referred to by a client generator, and
 * `tests/openapi.spec.ts` asserts this one is named.
 *
 * There is no refine chained after the name on this one, and on this resource that is the difference
 * worth noticing: its sibling `WorkoutBatchRow` has one, so this schema is the only batch row in the
 * API whose metadata order cannot be got wrong by putting `.openapi()` in the wrong place.
 */
export const ReceptiveInactivityBatchRowSchema = z
  .object({
    id: ReceptiveInactivityIdSchema,
    ...receptiveInactivityFields,
  })
  .strict()
  .openapi("ReceptiveInactivityBatchRow", {
    description:
      "One entry of a bulk write. The id is required and carried in the body, because a batch has no path to put it in.",
  });

/**
 * Whether any entry's id is named twice in a batch.
 *
 * A predicate and not the offending id, because **a schema's refusal message is a constant**:
 * `@asteasolutions/zod-to-openapi` patches `.refine()` and does not patch `.superRefine()`, so a
 * dynamically composed message would cost this schema its name in the document. The count is stated
 * by `services/receptiveInactivityService.ts`, which is the layer that can phrase it and which a
 * caller arriving over HTTP never reaches — the schema refuses first, with this constant message.
 *
 * It is a per-resource function rather than one shared with `workouts`, for the reason the caps are
 * per-resource constants: the two files are the only callers, and a single helper imported across
 * resources would put a refactor of one resource's validation inside the other's diff.
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
 * The `POST /v1/receptive-inactivities/batch` body: up to `MAX_BATCH_RECEPTIVE_INACTIVITIES` entries,
 * each named exactly once.
 *
 * **Uniqueness is on `id` here and on `date` in `recoveries`**, and the inversion is the resource's
 * whole shape: a day holds several entries, so two rows sharing a date are an ordinary night while
 * two sharing an id are a client that has minted one identity twice. That case is refused rather than
 * resolved by ordering, because the second write would win silently and the row left on disk would be
 * whichever the array happened to put last.
 *
 * **What this endpoint is not is as load-bearing as what it is.** It is not a `PUT` on the collection:
 * that would say "these are the entries", which obliges the server to remove the ones the caller left
 * out. This API has no delete path at all — which is the whole of the answer to "does a delete
 * propagate?", and on this resource it is also the answer to the app's own
 * `ReceptiveInactivityRepository.delete(_:)`, which has no counterpart here — so a batch adds and
 * replaces, and it never removes.
 *
 * **Idempotence is the property the client depends on**, and on this resource it is what makes the
 * import safe to press twice: every entry lands on the same `(userId, id)` key the single-entry `PUT`
 * writes, and the app derives that id from the entry's own date, type and text, so a replayed chunk
 * rewrites each entry with the values it already holds — no duplicates, no row count moved.
 *
 * Two refusals are carried here and restated in `services/receptiveInactivityService.ts`, which owns
 * them — the schema is what publishes them where a client can read them, and the service is what
 * enforces them for a caller that arrived from a script or a test and passed through no schema at
 * all. The third, the aggregate child cap, has no analogue here: an entry is one row and has no
 * children, so the row cap **is** the work cap.
 */
export const ReceptiveInactivityBatchWriteSchema = z
  .object({
    rows: z
      .array(ReceptiveInactivityBatchRowSchema)
      .min(1)
      .max(MAX_BATCH_RECEPTIVE_INACTIVITIES)
      .openapi({
        description: `The entries to write, at least one and at most ${MAX_BATCH_RECEPTIVE_INACTIVITIES}. Each id must appear exactly once. Unlike a session, an entry is one row and has no children, so this cap is the whole bound on a request's work.`,
      }),
  })
  .strict()
  .openapi("ReceptiveInactivityBatchWrite", {
    description:
      "A chunk of entries to insert or replace. Adds and overwrites; it never deletes, so an entry the caller leaves out is left alone rather than removed.",
  })
  .refine((body) => !hasRepeatedId(body.rows), {
    path: ["rows"],
    message: "names an entry id more than once; a batch must give each entry exactly one row",
  });

/**
 * What a batch answers with.
 *
 * `written` counts **entries**, and on this resource entries and rows are the same number — which is
 * a fact about the shape rather than a second convention, and the note is here so the next reader does
 * not go looking for the children the count excludes. It is the database's own `changes` tally, **so
 * a replayed chunk reports the same count as the first send rather than zero**: SQLite counts a row
 * matched by `ON CONFLICT … DO UPDATE` as changed even when every value is byte-identical. A client
 * must not read `written: 0` as "there was nothing to do", and nothing here answers `0` for a
 * non-empty batch.
 *
 * It is deliberately **not** the entries read back. The client already holds every value it just sent,
 * so echoing them is a round trip it cannot act on; the property a read-back would prove — that a
 * `null` stayed `null` — is asserted by reading the window afterwards, which is where it belongs.
 */
export const ReceptiveInactivityBatchResultSchema = z
  .object({
    written: z.number().int().nonnegative().openapi({
      description:
        "How many entries the database reported writing. On this resource an entry is one row and has no children, so this is also the row count. A replayed chunk reports the same number as the first send, not zero.",
      example: 62,
    }),
  })
  .openapi("ReceptiveInactivityBatchResult", {
    description:
      "The outcome of a bulk write. It reports what the database did, not what was on disk afterwards.",
  });

/**
 * The window read's query.
 *
 * **`days`/`endingOn`, not `from`/`to`**, for `WindowQuerySchema`'s reason: the endpoint mirrors the
 * app's own history window so a client porting an existing call passes the same number through. That
 * mirroring includes the app's off-by-one — the window is inclusive at both ends, so `days=14` spans
 * 15 calendar days — and it is `recoveries`' arithmetic verbatim, not a second derivation of it.
 *
 * **A single day is `days=0`, and there is no per-day endpoint to reach for instead.** That is the
 * difference from `workouts`, which has none either but where a day's sessions are more naturally
 * asked for as a window; here the day-shaped read is the *only* read the app performs, since its own
 * port has one method taking a date. `GET ?days=0&endingOn=<day>` is that call, and it is why the
 * resource is mounted at a collection with an `{id}` beside it rather than at a `{date}`.
 *
 * The answer is shaped like `workouts`': an **array** with no padding, because a day holds several
 * entries and a day inside the window holding none is simply not represented.
 *
 * `MAX_WINDOW_DAYS` is imported rather than redeclared, and the omission of a sixth window constant
 * is deliberate: this is the *app's* history window mirrored, exactly as `workouts` mirrors it, and a
 * second name for one published limit would be a second thing to move with nothing saying why.
 */
export const ReceptiveInactivityWindowQuerySchema = z.object({
  days: z.coerce
    .number()
    .int()
    .min(0)
    .max(MAX_WINDOW_DAYS)
    .openapi({
      description: `How many days back from \`endingOn\` to reach. **The window is inclusive at both ends, so \`days=14\` spans 15 calendar days** — this mirrors the app's own window exactly, deliberately, so a ported call returns identical rows. \`0\` means the single day \`endingOn\`, which is the app's ordinary per-day read.`,
      example: 0,
    }),

  endingOn: DayKeySchema.optional().openapi({
    description:
      "The newest day in the window, inclusive. Optional only because the server has no notion of the caller's local today — its own is UTC, and a device eight hours behind it is a day out. **Clients should always send this.**",
    example: "2026-08-22",
  }),
});
