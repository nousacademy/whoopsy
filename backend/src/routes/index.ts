import { OpenAPIHono } from "@hono/zod-openapi";
import type { Env } from "../env";
import { biometricSampleRoutes } from "./biometricSamples";
import { validationHook } from "./errors";
import { healthRoutes } from "./health";
import { receptiveInactivityRoutes } from "./receptiveInactivities";
import { recoveryRoutes } from "./recoveries";
import { sleepRoutes } from "./sleeps";
import { stepCountRoutes } from "./stepCounts";
import { strainRoutes } from "./strains";
import { userProfileRoutes } from "./userProfiles";
import { workoutRoutes } from "./workouts";

/**
 * HTTP controllers — the Worker's edge, and the table of contents for it.
 *
 * A route below parses a request, calls a service, and shapes a response; it holds no SQL and no
 * policy, so that the question "what does this endpoint do" is answered by reading one file rather
 * than by following a query into a table.
 *
 * The OpenAPI document in `shared/openapi.json` is generated from these, which is why the schemas are
 * declared as `@hono/zod-openapi` route definitions rather than as hand-written JSON.
 *
 * **This file is the mount table, and the prefix lives here rather than in the route.** Each resource
 * declares its paths relative to itself, and the version segment appears exactly once, below. That is
 * what keeps `/v1` from being spelled into five paths that could drift apart — and because
 * `getOpenAPI31Document` reads the mounted app, the prefix is in the published paths by construction
 * rather than by a second string agreeing with the first.
 *
 * **One app, not one per resource.** A sub-app carries its own `defaultHook`, so nesting them would
 * mean remembering to install the hook on each new one; mounting everything onto a single app means a
 * route added tomorrow is covered by the hook that is already there. This is why the resources export
 * routers to be mounted rather than registering themselves.
 */
export const routes = new OpenAPIHono<{ Bindings: Env }>({
  defaultHook: validationHook,
})
  .route("/", healthRoutes)
  // Mounted first of the eight because `biometric-samples` sorts before every sibling, and it is the
  // entry the rule below is easiest to get wrong on: a new resource is conventionally appended, which
  // here would put it last in a list whose order is the document's own path order.
  //
  // The `b` in the path is also the one letter that distinguishes this mount from a plausible wrong
  // one. The resource's own type is `BiometricSample`, singular, so `/v1/biometric-sample` reads as
  // correctly as `/v1/biometric-samples` does and names a mount that does not exist — the trap
  // `step-counts` and `receptive-inactivities` already document from the other side, where the
  // resource is plural and the path is not.
  .route("/v1/biometric-samples", biometricSampleRoutes)
  // **Mounted second, between `biometric-samples` and `receptive-inactivities`, because `p` sorts
  // between `b` and `r`** — and this is the mount that shows why the two orders are different rather
  // than merely worth keeping aligned. Appending this file's router conventionally would have put it
  // last, after `workouts`, which is where its *identifier* belongs in an import block
  // (`./userProfiles` sits between `./strains` and `./workouts` above) and precisely where its *path*
  // does not belong here. The list is the document's own path order, so an entry out of place is the
  // one thing a reader diffing two mount tables cannot see.
  //
  // **`/v1/profile`, singular, and this is the only mount here whose segment is not the resource's
  // plural table name.** The other seven name collections — `/v1/strains` is every day's strain —
  // while a partition holds exactly one profile, so a plural path would read as "list them" for a
  // resource with no list and no `{id}` to address a member with. The file, the type and the table all
  // keep the resource's own name (`userProfiles.ts`, `UserProfile`, `user_profiles`); only the URL
  // deviates, which makes this pair the sharpest instance of the mismatch `step-counts` and
  // `biometric-samples` already document from the other side.
  .route("/v1/profile", userProfileRoutes)
  // Mounted here rather than after `recoveries` because `receptive-inactivities` sorts before it: the
  // list below is the document's own path order, and an entry out of place is the one thing a reader
  // diffing two mount tables cannot see.
  .route("/v1/receptive-inactivities", receptiveInactivityRoutes)
  .route("/v1/recoveries", recoveryRoutes)
  .route("/v1/sleeps", sleepRoutes)
  .route("/v1/step-counts", stepCountRoutes)
  .route("/v1/strains", strainRoutes)
  .route("/v1/workouts", workoutRoutes);
