import { createRoute, OpenAPIHono } from "@hono/zod-openapi";
import type { UserProfile } from "../domain";
import { UserProfileSchema, type UserProfileWire, UserProfileWriteSchema } from "../dto/userProfiles";
import { RequestHeaderSchema } from "../dto/shared";
import type { Env } from "../env";
import { D1UserProfileRepository } from "../repositories";
import { UserProfileService } from "../services";
import { apiError } from "../utils/errors";
import { deriveUserId } from "../utils/identity";
import { errorResponse, unauthorizedResponse, validationHook } from "./errors";

/**
 * The two `user_profiles` endpoints, and nothing else.
 *
 * **This is the first resource here whose route file has no path parameter, and every absence in it
 * follows from that one fact.** A profile is a singleton: the partition holds one row or none, so
 * there is no `{date}` to read a day with, no `{id}` to address a member with, no `/batch` to chunk a
 * history into, and no `?days=` window to ask for. What is left is `GET /v1/profile` and
 * `PUT /v1/profile` — a read and a whole-row write of the one row the caller owns.
 *
 * **The path is the resource's own name and the mount is where it is decided.** `routes/index.ts`
 * mounts this file at `/v1/profile`, singular, and the argument for that spelling is there rather than
 * here: a plural *collection* path for a resource that can never hold more than one row reads as "list
 * them", and there is no list. Paths below are declared relative to that mount, which is why both are
 * `/` and why the published document says `/v1/profile` rather than a second string agreeing with the
 * first.
 *
 * **`PUT` and not `POST`, because the app's own save is a whole-row upsert** and a `PUT` is the verb
 * for exactly that: the caller is stating the complete resource, not proposing a new member of a
 * collection. There is deliberately no `POST` beside it. A `POST` on a singleton would have to mean
 * one of two things and neither is honest — an insert that fails once the row exists, or a second
 * spelling of the same upsert, which is a second way to write one row.
 *
 * What remains here is the two things only this layer can know: how the caller's credential becomes a
 * partition, and which status code an absence deserves. The one decision taken here rather than in the
 * service is that a partition holding no profile is a `404` rather than a `200` with a `null` — a fact
 * about HTTP, and the same split `StrainService.readDay` and `strainRoutes`' handler already make.
 */

/**
 * The composition root for this resource.
 *
 * `D1UserProfileRepository.from(c.env)` rather than a module-level singleton: an isolate is reused
 * across requests, so a repository captured at module scope would hold the first request's bindings
 * for the life of the isolate. The wrapper is a thin object over `env.DB` — there is nothing here
 * worth caching, and caching it would be the bug.
 */
function serviceFor(env: Env): UserProfileService {
  return new UserProfileService(D1UserProfileRepository.from(env));
}

/**
 * The caller's partition: the header value, hashed, and never the header itself.
 *
 * **Every handler goes through this, and the reason is a failure that would be near-invisible.** If
 * one route read the raw header while the others hashed it, that caller's rows would be filed under
 * two different `user_id`s — the digest for the routes that hashed and the literal key for the one
 * that did not — and nothing would report it. Here the symptom would be a `PUT` that answered `200`
 * and a `GET` that then called the profile absent, which reads as a sync bug rather than as a routing
 * one. One call site per handler, going through one function, is what makes that unrepresentable.
 *
 * The alternative — hashing inside the repository or the service — is worse in the other direction:
 * the digest is a fact about *arriving at this Worker*, and a layer that took a key and hashed it
 * would be a layer that could be handed a key it was never meant to see.
 *
 * `deriveUserId` is async because `crypto.subtle.digest` is, and the header is already known to be a
 * usable key: `UserHeaderSchema` refused anything too short or too long before this ran.
 */
function partitionFor(headers: { readonly "x-whoopsy-user-id": string }): Promise<string> {
  return deriveUserId(headers["x-whoopsy-user-id"]);
}

/**
 * Domain to wire.
 *
 * Spelled out rather than spread-and-strip (`const { userId, ...rest } = profile`), because the return
 * type is `UserProfileWire` and that is what makes the schema and this mapper agree: `userId` is
 * deliberately absent from the contract, and a field added to `userProfileFields` without being added
 * here fails to compile. Destructuring would make `userId` the only thing held back by hand and every
 * future field opt-out by default — and on a resource whose whole contract is seven fields, a field
 * that silently stopped leaving the database would be most of the resource.
 *
 * `userId` is withheld because it is the caller's own identity, already known from the request that
 * asked for it. Publishing it would invite a client to read an owner out of a payload instead of out
 * of the credential, which is the habit that breaks the day the placeholder header is replaced.
 *
 * Every nullable field is copied through as it stands — no `?? null`, no `?? 0` — which is the whole
 * of what this resource's write path has to get right: a `weightKg` that came back as a `0` would mean
 * a form's cleared field had been silently filled in with a number the calorie estimate divides into.
 */
function toWire(profile: UserProfile): UserProfileWire {
  return {
    maxHeartRate: profile.maxHeartRate,
    restingHeartRate: profile.restingHeartRate,
    weightKg: profile.weightKg,
    name: profile.name,
    birthDate: profile.birthDate,
    gender: profile.gender,
    heightCm: profile.heightCm,
  };
}

const readProfile = createRoute({
  method: "get",
  path: "/",
  summary: "Read the caller's profile",
  description:
    "The one profile this caller owns, or `404 not_found` if the partition holds none. **There is no empty-row state here and no window and no list**: a profile is a singleton, so this endpoint answers the whole of what the resource is, and a client that gets a `404` has a user who has not filled the form in rather than a user whose profile is blank. The app's own cold-start 190/60 pair is applied by the *client* when it merges that absence with its local copy — this API does not publish it, because a server that did would be inventing a zone table and calling it a row.",
  request: { headers: RequestHeaderSchema },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The caller's profile.",
      content: { "application/json": { schema: UserProfileSchema } },
    },
    400: errorResponse("The header failed validation."),
    404: errorResponse("This partition holds no profile."),
  },
});

const writeProfile = createRoute({
  method: "put",
  path: "/",
  summary: "Write the caller's profile",
  description:
    "Insert or replace the caller's profile — the whole-row upsert the app's own `saveUserProfile` is. Answers with the row **read back from the database**, not with the request echoed, so a caller can see that a `weightKg` sent as `null` is still `null` rather than a `0` some layer defaulted. **Every field must be sent**: this is a whole-row write, so a field sent as `null` is cleared and a field omitted is a `400` — there is no partial update on this resource and a client changing one field reads the row, changes it and sends the whole thing back.",
  request: {
    headers: RequestHeaderSchema,
    body: {
      required: true,
      content: { "application/json": { schema: UserProfileWriteSchema } },
    },
  },
  responses: {
    401: unauthorizedResponse,
    200: {
      description: "The stored profile, as the database holds it.",
      content: { "application/json": { schema: UserProfileSchema } },
    },
    400: errorResponse(
      "The header or the body failed validation — including a body naming its own identity, and a resting heart rate not strictly below the maximal one.",
    ),
  },
});

export const userProfileRoutes = new OpenAPIHono<{ Bindings: Env }>({
  defaultHook: validationHook,
})
  .openapi(readProfile, async (c) => {
    const userId = await partitionFor(c.req.valid("header"));

    const profile = await serviceFor(c.env).read(userId);

    // `null` from the repository means the partition has no row, and the status is the route's
    // decision: the storage layer reports an absence and this layer says what an absence *is* over
    // HTTP. A `200` with a `null` body would be indistinguishable from a profile to a client that only
    // checked the status, and a fabricated pair is the invention this project's absence rule forbids
    // everywhere else.
    //
    // The code is `not_found` and **not** `no_measurement_for_day`, and the difference is the shape of
    // the absence rather than a preference. `no_measurement_for_day` names a day that exists with
    // nothing measured on it — the day is the subject and the measurement is missing — which is why
    // the four day-keyed resources all answer with it. Here there is no day and nothing to measure: a
    // partition either holds a profile or does not, which is the same absence `workouts`,
    // `receptiveInactivities` and `biometricSamples` answer for a row that is not there.
    if (profile === null) {
      return c.json(apiError("not_found", "no profile is stored for this caller"), 404);
    }

    return c.json(toWire(profile), 200);
  })
  .openapi(writeProfile, async (c) => {
    const userId = await partitionFor(c.req.valid("header"));
    const body = c.req.valid("json");

    // The identity comes from the credential and never from the body, and on this resource that is a
    // stronger statement than a sibling's: there is no path parameter to disagree with, so the two
    // keys a client might send anyway — the app's local `id` and a `userId` — are refused outright by
    // `UserProfileWriteSchema`'s `.strict()` rather than being stripped. A body that carried one would
    // otherwise be a second statement of something the request has already said.
    //
    // The answer is the row read back from disk rather than the body echoed, which is `toWire`'s
    // argument above: on a whole-row write over five nullable columns, "the `null` I sent is the
    // `null` stored" is the entire contract, and an echo could not demonstrate it.
    const stored = await serviceFor(c.env).write(userId, body);

    return c.json(toWire(stored), 200);
  });
