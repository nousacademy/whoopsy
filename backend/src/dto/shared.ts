import { z } from "@hono/zod-openapi";
import { parseDayKey } from "../utils/days";
import { MAX_KEY_LENGTH, MIN_KEY_LENGTH } from "../utils/identity";
import { parseInstant } from "../utils/instants";

/**
 * The vocabulary every resource's schema is written in.
 *
 * A day key, an instant and the caller's header are not `recoveries`' words or `workouts`' words —
 * they are the words this API has, and a second resource needing one of them is a second resource
 * needing it. They lived in `dto/recoveries.ts` while it was the only resource; they moved here
 * when the second one arrived, because the alternative is a `workouts` schema importing its header
 * schema out of a file named after another resource, which is a dependency that reads as a mistake
 * and would be copied by the third resource.
 *
 * What belongs here is a **format**: a shape whose rule is about how a value is spelled rather than
 * about what it means to a resource. What does not belong here is anything that names a table, a
 * column or a field of a particular payload — those live in that resource's own schema file, next to
 * the document they publish.
 *
 * Every schema below is attached inline by the resources that use it rather than registered as a
 * named component. That is deliberate: `components.schemas` is the list of *things a client takes
 * apart*, and a bare `string` with a refinement is not one of them. Naming them would put "Instant"
 * beside "Workout" in the document as though the two were the same kind of object.
 */

/**
 * A calendar day, `YYYY-MM-DD`.
 *
 * Validated by `parseDayKey` rather than by a regex, and the difference is the whole point: a regex
 * accepts `2026-02-31`, and `Date.UTC` *rolls it forward* to March 3 rather than refusing it. So the
 * regex-only version would accept a `PUT` to `/v1/recoveries/2026-02-31`, file it under a day nobody
 * named, and then answer the client's follow-up `GET` on the same impossible string — consistently,
 * so nothing anywhere would look wrong. Requiring the constructed instant to re-read as the same
 * year, month and day is what makes "this is a day" a fact.
 *
 * A day carrying a time component (`2026-08-22T13:45:00Z`) is refused rather than snapped. The app's
 * writers snap silently because they hold a real `Date` and the snap is the only sensible reading;
 * here the string *is* the payload, so a time component is a client that has misunderstood the
 * field — and refusing is louder than quietly reproducing the app's own
 * written-at-a-raw-timestamp-inserted-never-updated failure somewhere the app cannot see it.
 */
export const DayKeySchema = z
  .string()
  .refine((value) => parseDayKey(value) !== null, {
    message: "must be a calendar day in YYYY-MM-DD form",
  })
  .openapi({
    description:
      "A calendar day, `YYYY-MM-DD`. Not an instant: a value carrying a time component is refused rather than snapped, because the day is `startOfDay` in the *device's* calendar and this server cannot re-derive the device's midnight.",
    example: "2026-08-22",
  });

/**
 * An instant, in the one spelling this API accepts.
 *
 * **ISO-8601, canonical UTC, exactly three fractional digits** — `2026-08-22T13:45:00.000Z` and
 * nothing else. `…:00Z`, `…:00.0Z`, `…:00.000+00:00` and `…:00.000000Z` all name the same moment and
 * are all refused.
 *
 * One spelling rather than several, because a format with more than one is a format whose
 * comparisons are somebody's guess about which spelling the other side used. The concrete
 * consequence here is `ORDER BY`: `workouts.started_at` is TEXT and the window read sorts a day's
 * sessions by it, so a fixed-width UTC spelling makes that a chronological order rather than a
 * lexicographic accident — `…T09:00` sorts before `…T13:45` because `0` precedes `1`, and would not
 * if one row carried an offset or a variable number of fractional digits.
 *
 * Normalising on write was the other way to get that and is worse: the column stores the string it
 * is handed, so pinning the format means a client's own spelling round-trips, which is the property
 * a sync exists for. See `utils/instants.ts`, which owns the rule and is where the parse lives.
 */
export const InstantSchema = z
  .string()
  .refine((value) => parseInstant(value) !== null, {
    message: "must be an instant in canonical UTC form, like 2026-08-22T13:45:00.000Z",
  })
  .openapi({
    description:
      "An instant in canonical UTC form: ISO-8601, exactly three fractional digits, `Z` offset — `2026-08-22T13:45:00.000Z`. Other spellings of the same moment are refused, so that the stored text sorts chronologically.",
    example: "2026-08-22T13:45:00.000Z",
  });

/**
 * The deployment's shared secret, as a header.
 *
 * **Required, and it is checked before anything else in the request is looked at.** The header is
 * published per operation rather than declared once as a `securitySchemes` block, so that every byte
 * of the contract stays generated from the route definitions — see `routes/errors.ts`'s
 * `unauthorizedResponse`, which is the 401 that goes with it.
 *
 * What it buys and what it does not is argued in `utils/tokens.ts`, and the short version is worth
 * having in the published document too, because this is where a client's author will read it: it
 * keeps scanners and drive-by requests off a discoverable `workers.dev` hostname, and it is **not**
 * an identity. Every install of one deployment sends the same string.
 */
export const TokenHeaderSchema = z.object({
  authorization: z.string().openapi({
    description:
      "The deployment's shared secret, as `Bearer <token>`. The scheme is case-insensitive; the space is exactly one. **This is not a per-install identity** — every client of one deployment sends the same value, so it decides whether a request is served at all and not whose rows it reaches. A missing or wrong credential is a `401`; a deployment with no secret configured answers `500`, because that is the operator's problem rather than the caller's.",
    example: "Bearer 3Yk8QvN2mR7xLpZ4tWbJ6hFcS9dG1aE5uK0oI8yT2nM",
  }),
});

/**
 * The caller's key, as a header — and the two things it is not.
 *
 * **It is not an account.** There is no accounts table and no registration: the app mints 32 random
 * bytes on first use and keeps them in its own Keychain, so the same install is the same partition
 * forever and a second install is a second partition. Nothing needs to be created on this side.
 *
 * **It is not verified, and it *is* a bearer credential.** Anyone who holds a key reads and writes
 * that key's rows; there is no signature, no expiry and no revocation. What the length floor below
 * buys is that the key must be too long to guess — 32 random bytes encode to at least 43 characters
 * — and what it cannot buy is anything more, because this Worker has no way to tell a key it issued
 * from a key somebody made up.
 *
 * **The shared token gate does not change any of that**, and the two must not be read as one thing.
 * `TokenHeaderSchema` above decides whether a request is served; this decides *which partition* it is
 * served from, and it verifies nothing about the caller. A deployment is now safe to expose because
 * a credential is required, not because this header became an identity.
 *
 * **The value here is never stored.** Each resource's route hashes it with `deriveUserId` and the
 * `user_id` column holds the digest, so a dump of the database is not a list of usable keys. The
 * bound is stated in terms of `utils/identity.ts`'s constants rather than as literals, so the schema,
 * the database and the hash cannot come to disagree about what a key is.
 */
export const UserHeaderSchema = z.object({
  "x-whoopsy-user-id": z
    .string()
    .min(MIN_KEY_LENGTH, {
      message: `must be at least ${MIN_KEY_LENGTH} characters — the app sends 32 random bytes, which is 43 base64url characters`,
    })
    .max(MAX_KEY_LENGTH)
    .openapi({
      description:
        `The install's key: 32 random bytes, base64url or hex encoded, generated on the device and kept in its Keychain. **It selects a partition and verifies nothing** — anyone holding it reads and writes its rows, and it is not an identity this API checks. The request that carried it was already admitted by the \`Authorization\` header above. **It is hashed on arrival and never stored**: the \`user_id\` column holds \`sha256\` of it. At least ${MIN_KEY_LENGTH} characters, at most ${MAX_KEY_LENGTH}.`,
      example: "K7fQ2mZx9pLr4Tn6WvB1yHs8JcE3uGa5DkRm0Xq4Y",
    }),
});

/**
 * The two headers every `/v1` operation takes, in the order they are checked.
 *
 * **`merge` rather than a `z.object` listing both fields**, so the two halves stay declared once and a
 * change to either reaches every operation. **Token first, deliberately**: `merge` appends the second
 * object's keys after the first's, so the published parameter list reads gate-then-identity, which is
 * also the order the Worker evaluates them in at runtime. A client reading the document top to bottom
 * therefore sees them in the order they will actually matter.
 *
 * That order is deterministic — `merge` preserves declaration order and Zod does not reorder — which
 * matters more than it sounds: `shared/openapi.json` is a committed file that `make backend-check`
 * diffs, so an unstable parameter order would show up as a spurious change on every regeneration.
 */
export const RequestHeaderSchema = TokenHeaderSchema.merge(UserHeaderSchema);
