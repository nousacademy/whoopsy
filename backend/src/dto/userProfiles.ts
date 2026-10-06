import { z } from "@hono/zod-openapi";
import { USER_PROFILE_GENDERS } from "../domain";
import { DayKeySchema } from "./shared";

/**
 * The wire shapes for `/v1/profile` — and, because the OpenAPI document is generated from these
 * declarations, the published contract itself.
 *
 * The three conventions this API fixes are `dto/recoveries.ts`'s and are restated in `dto/shared.ts`:
 * camelCase on the wire over snake_case columns, `.nullable()` and never `.optional()` for an
 * absence, and a day key checked by round trip.
 *
 * **This file is short because the resource is a singleton, and what is missing is the shape.** There
 * is no `UserProfileIdSchema`, no batch row, no `WindowQuerySchema` and no batch result — not one of
 * them omitted for brevity, each for a reason the field list makes plain: there is no id to publish,
 * a partition holds one profile so there is nothing to chunk, and a singleton has no window to ask
 * for. That is four schema-shaped absences, and it is why the resource's `POST`/`GET ?days=` surface
 * is missing too rather than being a smaller version of a sibling's.
 *
 * **What that leaves is a body and a response carrying the same seven fields**, which is the one
 * place this file has to be read carefully: the two are not the same schema, because the write body
 * carries a refinement the response deliberately does not. See both below.
 */

/**
 * The stored fields, in one place.
 *
 * Composed into the response schema and the write body, so the two cannot drift: a field added here
 * appears in the contract's response *and* in its request body, and adding one to just one side means
 * writing it out separately — the mistake this shape exists to prevent.
 *
 * **Only two fields are required, and the split is the app's own rather than this file's.** The two
 * heart rates are the inputs the Karvonen zone table cannot be built without — `computeZones` reads
 * both and has a 20 bpm floor on their reserve — so an absent one is not an absence a screen can
 * draw, it is a zone table that cannot be computed at all. The app's own repository answers a
 * cold-start 190/60 rather than a row with a hole in it, for exactly that reason. The other five are
 * *declared* facts: the user supplies them, the user is the sensor, and `null` is the honest value for
 * one nobody has supplied.
 *
 * **No field is optional, and that is a separate statement from nullable.** A client must send all
 * seven keys; omitting `weightKg` is a `400` while sending `weightKg: null` is the absence. That
 * matters more here than on a day-keyed sibling, because this body is a **whole-row** write: a body
 * that could leave a key out would give "I did not mention the weight" and "I am telling you there is
 * no weight" two different spellings, and the write path has to collapse them into one answer anyway.
 *
 * **No bounds are published beyond shape.** `maxHeartRate` is not `100…250` and `restingHeartRate` is
 * not `30…120`, though those are the bands the app's own form refuses outside of: they are
 * Presentation-layer guards in `ProfileDraft`, changeable without a deploy here, and publishing them
 * would make this API refuse a profile the app can hold. What is published is the shape — a positive
 * integer — and the one *relationship* between the two, which is on the write body below because it
 * is a rule about a body rather than about a field.
 */
const userProfileFields = {
  maxHeartRate: z
    .number()
    .int()
    .positive()
    .openapi({
      description:
        "The user's maximum heart rate, in bpm. Required: this is one of the two inputs the zone table is built from, so an absent one is not a missing reading, it is a table that cannot be computed. Must be **strictly greater** than `restingHeartRate` — see the write body. No upper bound, deliberately: the app's own form band is a Presentation-layer guard, and publishing it here would refuse a profile the app can hold.",
      example: 190,
    }),

  restingHeartRate: z
    .number()
    .int()
    .positive()
    .openapi({
      description:
        "The user's resting heart rate, in bpm. Required, for `maxHeartRate`'s reason. Positive: a rate of zero is not a measurement, it is an absent one, and an absent one has no row here.",
      example: 60,
    }),

  weightKg: z
    .number()
    .finite()
    .positive()
    .nullable()
    .openapi({
      description:
        "Body weight in kilograms, or `null` when the user has not said. **The one field here a model divides into**: the calorie estimate is scaled by it, so a fabricated value would scale a figure by a body nobody described, and a `0` would be a division with no answer. Positive, or absent — never `0`.",
      example: 75,
    }),

  name: z
    .string()
    .min(1)
    .nullable()
    .openapi({
      description:
        "The user's first name, or `null` when they have not given one. **`null` is not `\"\"`** — the column being nullable is what gives absence a spelling, and an empty string is a value nobody supplied. Nothing in the app reads this: it is a declared fact, saved and drawn back onto the form.",
      example: "Alex",
    }),

  birthDate: DayKeySchema.nullable().openapi({
    description:
      "The user's birthday as a calendar day, `YYYY-MM-DD`, or `null` when unset. **A day key and not an instant**: the user supplies a date, not a moment, and an instant would carry a time of day and a UTC offset they never gave. The app's own column is a `datetime`, so the client is the one that converts — and it converts on both sides, which is where a `startOfDay` snap can be got wrong.",
    example: "1994-03-17",
  }),

  gender: z
    .enum(USER_PROFILE_GENDERS)
    .nullable()
    .openapi({
      description:
        "One of the app's four words — `man`, `woman`, `nonBinary`, `preferNotToSay` — or `null` when the user has not said, which is a distinct answer from any of the four. Closed rather than a free string, because the app resolves an unrecognised word to `null` rather than guessing at it: an open field would accept values every reader silently drops.",
      example: "preferNotToSay",
    }),

  heightCm: z
    .number()
    .finite()
    .positive()
    .nullable()
    .openapi({
      description:
        "Height in centimetres, or `null` when the user has not said. Positive, for `weightKg`'s reason and with a weaker one behind it: nothing in the app divides by a height, but a height of zero is not a height, and the absence already has a spelling.",
      example: 178,
    }),
};

/**
 * One person's profile, as the API returns it.
 *
 * The response is the **row read back from the database**, not the request echoed — which is what lets
 * a client confirm the round trip, and in particular that a `weightKg` sent as `null` is still `null`
 * and was not folded into a `0` or a default anywhere in the write path. On this resource that
 * assertion is the whole of what the write path has to get right, so `PUT` answers from disk.
 *
 * **Neither `id` nor `userId` is on the wire, and the two absences are different.** `userId` is the
 * caller's own identity, already known from the request that asked, and publishing it would invite a
 * client to read an owner out of a payload instead of out of the credential. `id` is absent for a
 * reason no sibling shares: the app's own record keys this row with the literal `"primary"`, so
 * publishing it would put a field on the wire whose only legal value is that word — a constant
 * dressed as data, which a client would then have to be told not to vary. The partition is the
 * identity here, and it is in the header.
 *
 * **This schema carries no cross-field refinement**, deliberately, while the write body below does.
 * `SleepSchema` states the rule and it applies here verbatim: **a response schema that could reject
 * its own storage is a `500` waiting for a legacy row.** A reversed heart-rate pair is refused before
 * it can be written, so nothing this API produces can trip it — but the response's job is to report
 * what is on disk, not to hold an opinion about it.
 */
export const UserProfileSchema = z
  .object(userProfileFields)
  .openapi("UserProfile", {
    description:
      "One person's profile: the two heart rates the zone table is built from, and five declared facts about the body that no model here reads. A partition holding no profile is a `404` — this resource has no empty-row state, because the app's cold-start pair is the client's answer to an absence rather than a row this API would invent.",
  });

/**
 * The response type, inferred from the schema rather than written out beside it.
 *
 * `routes/userProfiles.ts` declares its domain-to-wire mapper as returning this, which closes the
 * chain the same way `RecoveryWire` does: a field added to `userProfileFields` and forgotten in the
 * mapper is a compile error rather than a column that quietly never leaves the database.
 */
export type UserProfileWire = z.infer<typeof UserProfileSchema>;

/**
 * Whether the resting rate is below the maximal one.
 *
 * A predicate and not the offending pair, because **a schema's refusal message is a constant**:
 * `@asteasolutions/zod-to-openapi` patches `.refine()` and does not patch `.superRefine()`, so a
 * dynamically composed message would cost this schema its name in the document.
 *
 * It is a per-resource function rather than a shared helper, on `hasRepeatedDay`'s rule — this file
 * is its only caller, and a shared helper would put a refactor of one resource's validation inside
 * another's diff.
 */
function restingRateBelowMax(profile: {
  readonly maxHeartRate: number;
  readonly restingHeartRate: number;
}): boolean {
  return profile.restingHeartRate < profile.maxHeartRate;
}

/**
 * The `PUT /v1/profile` body: the stored fields and nothing else.
 *
 * **There is no path identity to drop, so what `.strict()` refuses here is the identity itself** —
 * which is a different job from the one it does on every sibling. `SleepWriteSchema` refuses a body
 * that names its own `date` because the path already states the day; this route has no path
 * parameter at all, and the two keys a client might reasonably send anyway are the app's local
 * `id` (`"primary"`) and the `userId` the response does not publish. Both are a second statement of
 * something the request has already said — the credential says whose row it is — and `.strict()`
 * makes each a `400` rather than a silent strip, so a client learns its payload is wrong instead of
 * believing a field it sent was honoured.
 *
 * **This body is the whole row, and that is a property a client has to know rather than a detail.**
 * The app's own save is INSERT-or-UPDATE over the entire record, so a `PUT` carrying
 * `weightKg: null` *clears* the weight rather than leaving it alone. There is one write verb here and
 * no partial update; a client changing one field reads the row first, changes it, and sends the whole
 * thing back — which is what the app's own form does.
 *
 * **The heart-rate refinement is here and not on the response, and it is a rule the app already
 * enforces.** `ProfileViewModel` refuses a save whose resting rate is not strictly below the maximal
 * one, and it is the only production writer of the app's `user_profiles` table. `computeZones` cannot
 * build a table from a non-positive reserve, so a row with the pair reversed is not a profile with an
 * odd number in it — it is a group of zones that cannot be computed, and therefore every strain,
 * calorie and zone figure derived from it on the phone. Publishing the rule is what makes it hold for
 * a caller that is not that form.
 *
 * **`.strict()` first, then `.openapi()`, then the refinement.** `@asteasolutions/zod-to-openapi`
 * patches `.refine()` to carry a schema's `openapi` metadata through and does not patch `.strict()` —
 * so a name attached before the strictness is discarded and this lands in the document as an unnamed
 * inline object. The order is not cosmetic: a component with no name cannot be referred to by a
 * client generator, and `tests/openapi.spec.ts` asserts the names.
 */
export const UserProfileWriteSchema = z
  .object(userProfileFields)
  .strict()
  .openapi("UserProfileWrite", {
    description:
      "A whole profile. There is no path identity to omit — the caller's key says whose row this is — so the body carries every stored field and nothing else. This is a **whole-row** write: a field sent as `null` is cleared, not left alone.",
  })
  .refine(restingRateBelowMax, {
    path: ["restingHeartRate"],
    message:
      "restingHeartRate must be strictly below maxHeartRate — a non-positive reserve is not a heart-rate zone table",
  });
