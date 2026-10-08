import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { openApiConfig, serialiseOpenApiDocument } from "../src/openapi";
import { bearerToken } from "../src/utils/tokens";

/**
 * The served contract, checked against the config it was generated from.
 *
 * This file covers the half of "one source, two readings" that a Worker can check. The other half —
 * that `shared/openapi.json` is byte-identical to what the Worker serves — cannot live here: the
 * runtime has no filesystem, so that comparison is a shell step against a running `wrangler dev`,
 * and it is in the README's backend section rather than in this suite.
 *
 * **What is worth asserting is the shape a client depends on**, not the whole document: the paths
 * that exist, the methods on each, and the fields that are prose rather than generated — the
 * description and the servers block, which `OpenApiGeneratorV31` merges its own output over rather
 * than replacing. Those are the parts a regeneration cannot derive, so they are the parts a
 * regeneration could silently lose.
 *
 * The servers block's **url** is a third kind, and the odd one out: it is derived per request rather
 * than configured, so what is asserted of it is that it follows the request — a property no
 * hardcoded origin can have, which is exactly why the assertion reads it off two different hosts.
 */

interface ServedDocument {
  openapi: string;
  info: { title: string; version: string; description?: string };
  servers?: { url: string; description?: string }[];
  paths: Record<string, Record<string, unknown>>;
  components?: { schemas?: Record<string, unknown> };
}

/**
 * The origin every fetch below is made on, and the value `servers[0].url` is asserted to equal.
 *
 * A `let`-free constant rather than a literal at each call site, because the whole point of the
 * origin assertion is that it is the *request's* origin: a spec that fetched one host and asserted
 * another would be asserting nothing.
 */
const SERVED_ORIGIN = "https://whoopsy.test";

async function served(origin: string = SERVED_ORIGIN): Promise<ServedDocument> {
  const response = await SELF.fetch(`${origin}/openapi.json`);

  expect(response.status).toBe(200);
  expect(response.headers.get("content-type")).toContain("application/json");

  return (await response.json()) as ServedDocument;
}

describe("GET /openapi.json", () => {
  it("serves a document a client can parse, with a path per route", async () => {
    const document = await served();

    expect(document.openapi).toBe("3.1.0");

    // Twenty-three paths, and the exact list is the assertion: a resource mounted under the wrong prefix —
    // `/v1/workout` for `/v1/workouts` — publishes a contract a client will code against and get a
    // 404 from, and the mount table in `routes/index.ts` is the only place that string appears. That
    // is why the list is written out rather than derived from the mount table: deriving it would make
    // the assertion agree with whatever the table happens to say, including `/v1/strain`.
    //
    // **`/v1/biometric-samples` is the seventh resource, the third id-keyed one, and the third
    // kebab-case prefix — and it is the only entry here that sorts ahead of every `/v1/recoveries`
    // path.** Two facts about it are the reason it leads rather than being appended beside the
    // resources it resembles. Its segment is kebab-case where the resource's own type is
    // `BiometricSample` and its table is `biometric_samples`, so `/v1/biometricSamples` and
    // `/v1/biometric_samples` are both plausible readings of one URL and neither is mounted; and `b`
    // sorts before `r`, so a reader who finds this resource at the *bottom* of a mount table and this
    // list at the top is looking at the one place where the two orders are allowed to disagree — the
    // mount table's order is the identifier's, and this list's is the path string's.
    //
    // **`/v1/profile` is the eighth resource and the one entry here that is a whole resource's entire
    // surface.** Every other line in this list is one of the two or three belonging to a resource, so a
    // mistyped path costs the document a read or a batch; this one has no `/batch` and no `{…}` beside
    // it — a profile is a singleton, so a partition holds one row or none — and a missing entry here
    // would leave a client with no address for the resource at all. It is also the only segment in this
    // document that is **singular**, the other seven naming collections (`/v1/strains` is every day's
    // strain), which makes `/v1/user-profiles` the plausible wrong spelling a reader arriving from the
    // resource's own type and table would reach for. The list catches it by being written out; nothing
    // about either string's shape would.
    //
    // **`/v1/receptive-inactivities` is the sixth resource, the second id-keyed one, and the second
    // kebab-case prefix here.** Three of those four facts are checkable against the resource itself and
    // the fourth is not, which is why the entry is worth its three lines: `receptive-inactivities` is
    // the only path in this document whose segment count is three, so it is the only one that sorts
    // *above* `/v1/recoveries` rather than among the resources it resembles. A reader diffing this list
    // against the mount table reads position as meaning, and an entry appended at the end would look
    // like a resource added last rather than one that sorts first.
    //
    // **`/v1/sleeps` is the fourth resource and the third day-keyed one**, and it is here rather than
    // absent because the list is exhaustive: a mount that was never added would leave the three sleep
    // paths out and every other assertion in this file green, since `/v1/sleeps` is a prefix nothing
    // else in the document mentions.
    //
    // **`/v1/step-counts` is the fifth and the fourth day-keyed one, and it is the first prefix here
    // that is two words.** That is what makes it worth mounting in front of a reader rather than
    // adding quietly beside its siblings: `step-counts` is kebab-case where the resource's own type is
    // `StepCount` and its table is `step_counts`, so the path is the one spelling of the three that
    // nothing else in this Worker repeats. A route that published `/v1/stepCounts` or `/v1/step_counts`
    // would be describing a URL no mount answers, and a client would build it from this document.
    expect(Object.keys(document.paths).sort()).toEqual([
      "/health",
      "/v1/biometric-samples",
      "/v1/biometric-samples/batch",
      "/v1/biometric-samples/{id}",
      "/v1/profile",
      "/v1/receptive-inactivities",
      "/v1/receptive-inactivities/batch",
      "/v1/receptive-inactivities/{id}",
      "/v1/recoveries",
      "/v1/recoveries/batch",
      "/v1/recoveries/{date}",
      "/v1/sleeps",
      "/v1/sleeps/batch",
      "/v1/sleeps/{date}",
      "/v1/step-counts",
      "/v1/step-counts/batch",
      "/v1/step-counts/{date}",
      "/v1/strains",
      "/v1/strains/batch",
      "/v1/strains/{date}",
      "/v1/workouts",
      "/v1/workouts/batch",
      "/v1/workouts/{id}",
    ]);
  });

  it("does not list itself among the paths", async () => {
    const document = await served();

    // The endpoint is registered with a plain `get` rather than an `openapi()` route precisely so
    // that it stays out of the document it serves — a contract listing an endpoint the contract
    // does not describe is describing itself. This assertion is what fails if anyone "tidies" it
    // into the route registry.
    expect(document.paths["/openapi.json"]).toBeUndefined();
  });

  it("gives each addressed path both a read and a write, and each window path only a read", async () => {
    const document = await served();

    // The biometric-samples trio leads because its path sorts first, and it is **third** resource here
    // addressed by an id — `receptiveInactivities`' shape a second time, with none of the aggregate and
    // a window measured in instants rather than days. The `{id}` parameter is the half a copy of the
    // day-keyed shape gets wrong, and on this resource that mistake is worse than it is on either
    // sibling: `biometric_samples` is keyed on `(user_id, id)` precisely because a day is up to 86,400
    // rows, so a route lifted from `sleeps` would address a sample by a day no column here holds and
    // the document would describe it perfectly well. The absent-parameter assertion is the half the
    // three verb reads cannot see: it is what fails when the *template* reverts while the verbs do not.
    expect(Object.keys(document.paths["/v1/biometric-samples/{id}"]!).sort()).toEqual(["get", "put"]);
    expect(Object.keys(document.paths["/v1/biometric-samples"]!).sort()).toEqual(["get"]);
    expect(Object.keys(document.paths["/v1/biometric-samples/batch"]!).sort()).toEqual(["post"]);
    expect(
      Object.keys(document.paths).some((path) => path.includes("/v1/biometric-samples/{date}")),
    ).toBe(false);

    // And the profile's one path, which is the **whole** of that resource rather than a third of it.
    // The two verbs are read off a single entry where every block below spans two or three, and the
    // absent-path assertion is a single test for all three addresses a collection would have —
    // `/v1/profile/batch`, `/v1/profile/{id}` and `/v1/profile/{date}` — because a singleton has one
    // URL and the prefix holding nothing else is exactly that guarantee. Both are what fail if a later
    // pass gives this resource an addressable member for consistency with its seven siblings, which is
    // the shape change `routes/userProfiles.ts` exists to not have.
    //
    // The `PUT`-and-not-`POST` half is the one a copy of a sibling would get wrong, and it fails
    // nowhere else: `POST /v1/profile` reads as "create the profile" and would be a second spelling of
    // the same upsert — the second way to write one row that `dto/userProfiles.ts` argues against —
    // while a document describing it would validate perfectly well.
    expect(Object.keys(document.paths["/v1/profile"]!).sort()).toEqual(["get", "put"]);
    expect(Object.keys(document.paths).some((path) => path.includes("/v1/profile/"))).toBe(false);

    // The receptive-inactivities trio follows because it sorts second, and it is the **second**
    // resource here addressed by an id, and the pair of parameters is the
    // whole of what a copy of the day-keyed shape gets wrong. `{id}` and `{date}` are not
    // interchangeable — a route lifted from `sleeps` would address an entry by a day this table holds
    // as an ordinary column, so two entries on one night would overwrite each other and the document
    // would describe it perfectly well. The absent-parameter assertion is the half the three verb reads
    // above cannot see: it is what fails when the *template* reverts while the verbs do not.
    expect(Object.keys(document.paths["/v1/receptive-inactivities/{id}"]!).sort()).toEqual(["get", "put"]);
    expect(Object.keys(document.paths["/v1/receptive-inactivities"]!).sort()).toEqual(["get"]);
    expect(Object.keys(document.paths["/v1/receptive-inactivities/batch"]!).sort()).toEqual(["post"]);
    expect(
      Object.keys(document.paths).some((path) => path.includes("/v1/receptive-inactivities/{date}")),
    ).toBe(false);

    expect(Object.keys(document.paths["/v1/recoveries/{date}"]!).sort()).toEqual(["get", "put"]);
    expect(Object.keys(document.paths["/v1/recoveries"]!).sort()).toEqual(["get"]);
    expect(Object.keys(document.paths["/health"]!).sort()).toEqual(["get"]);

    // The batch path is a `POST` and nothing else — and that is the assertion worth making, because
    // the tempting shape is a `PUT` on `/v1/recoveries` meaning "these are the days". A `PUT` there
    // would oblige the server to delete the days the caller left out, and this API has no delete path
    // at all; the verb is the promise, and a client reading its own name for it would find the wrong
    // one. `dto/recoveries.ts` carries the argument in full.
    expect(Object.keys(document.paths["/v1/recoveries/batch"]!).sort()).toEqual(["post"]);

    // The sleeps table is `recoveries`' shape one address over — the same three paths, the same two
    // verbs on the addressed one, the same `POST`-only batch — and the parameter is asserted beside it
    // for the same reason the strains block below asserts its own. **This is the pair most tempting to
    // leave out**, because the two resources' paths differ only by a word and a copy of the block
    // above with `/recoveries` swapped for `/v1/sleeps` would pass whether or not the route was ever
    // mounted: the assertions read `document.paths[...]` through a non-null `!`, so a missing key
    // throws rather than answering `[]`, and the *path list* above is the one that catches a mount
    // that never happened.
    expect(Object.keys(document.paths["/v1/sleeps/{date}"]!).sort()).toEqual(["get", "put"]);
    expect(Object.keys(document.paths["/v1/sleeps"]!).sort()).toEqual(["get"]);
    expect(Object.keys(document.paths["/v1/sleeps/batch"]!).sort()).toEqual(["post"]);
    // The day-keyed addressing is the half a copy of the aggregate gets wrong: a sleeps route lifted
    // from `workouts` would address a night by an id no column of this table holds, and the document
    // would describe it perfectly well.
    expect(Object.keys(document.paths).some((path) => path.includes("/v1/sleeps/{id}"))).toBe(false);

    // The step-counts table is the same shape a third address over, and its own half is the **prefix**:
    // every argument above is about a single-word segment, while this resource's path is two words and
    // kebab-cased, so `step-counts` is the one string here that a reader cannot check against the
    // type's own spelling. `StepCount` and `step_counts` are both plausible renderings of this URL and
    // neither is it. These three reads are what fail if the mount, the route or the document ever
    // disagrees about which — and they fail loudly rather than answering `[]`, since a missing key
    // throws through the non-null assertion.
    expect(Object.keys(document.paths["/v1/step-counts/{date}"]!).sort()).toEqual(["get", "put"]);
    expect(Object.keys(document.paths["/v1/step-counts"]!).sort()).toEqual(["get"]);
    expect(Object.keys(document.paths["/v1/step-counts/batch"]!).sort()).toEqual(["post"]);
    // The day-keyed half again, and worth restating on a resource whose absence is a bare `404`: it is
    // the shape that *looks* like it could be addressed either way — a step count is one number per
    // day, and a client could reasonably expect to fetch it by an id — while no column of this table
    // holds one.
    expect(Object.keys(document.paths).some((path) => path.includes("/v1/step-counts/{id}"))).toBe(false);

    // The strains table is the same shape a second address over — the same three paths, the same two
    // verbs on the addressed one, the same `POST`-only batch — and the parameter is asserted beside it
    // because that is the half a copy of the *other* resource gets wrong. `{date}` and `{id}` are not
    // interchangeable: a strains route lifted from `workouts` would address a day by an id this table
    // has no column for, and the document would describe it perfectly.
    expect(Object.keys(document.paths["/v1/strains/{date}"]!).sort()).toEqual(["get", "put"]);
    expect(Object.keys(document.paths["/v1/strains"]!).sort()).toEqual(["get"]);
    expect(Object.keys(document.paths["/v1/strains/batch"]!).sort()).toEqual(["post"]);
    expect(Object.keys(document.paths).some((path) => path.includes("/v1/strains/{id}"))).toBe(false);

    // The workouts pair is the same table one address over, and the parameter is the point of it: a
    // session is addressed by `{id}`, not by `{date}`, because a day holds several. Asserting the
    // verbs without asserting the parameter name would pass a document that had quietly reverted to
    // the day-keyed shape — and a client following it would overwrite the first session of the day
    // with the second, which is the exact defect `workouts`' id-keying exists to prevent. The
    // parameter is read out of the path template rather than off the operation because that is where
    // a client derives its own variable name from.
    expect(Object.keys(document.paths["/v1/workouts/{id}"]!).sort()).toEqual(["get", "put"]);
    expect(Object.keys(document.paths["/v1/workouts"]!).sort()).toEqual(["get"]);
    expect(Object.keys(document.paths["/v1/workouts/batch"]!).sort()).toEqual(["post"]);
    expect(Object.keys(document.paths).some((path) => path.includes("/v1/workouts/{date}"))).toBe(false);
  });

  it("carries the config's prose through generation untouched", async () => {
    const document = await served();

    const config = openApiConfig(SERVED_ORIGIN);

    // These two come from `openApiConfig` rather than from the routes, which is exactly why they are
    // asserted against it: a generator that replaced the config wholesale would leave a document
    // that still validates and has simply lost its description and its server. The config is called
    // on the origin this fetch used, so the two sides are the same reading of one source — the
    // *origin* half of the block has its own test below, where it is checked against the request.
    expect(document.info.description).toBe(config.info.description);
    expect(document.servers?.[0]?.description).toBe(config.servers?.[0]?.description);
  });

  it("names the origin it was fetched on, so a deployment describes itself unconfigured", async () => {
    const document = await served();
    const url = document.servers?.[0]?.url ?? "";

    // **The request's own origin, rather than a shape.** This began by asserting the placeholder
    // string, because nothing had been deployed and a guessed subdomain would have looked
    // deployable; it became a pattern (`^https://whoopsy-sync\.[a-z0-9-]+\.workers\.dev$`) so that a
    // fork's *correct* document was not a failing test. Deriving the origin from the request retires
    // what the pattern was working around: **no stored string can satisfy this**, because the second
    // fetch below asks from a different host and reads a different answer back.
    expect(url).toBe(SERVED_ORIGIN);

    const elsewhere = await served("https://whoopsy-sync.example.workers.dev");
    expect(elsewhere.servers?.[0]?.url).toBe("https://whoopsy-sync.example.workers.dev");

    // **An origin, not an address.** No trailing slash and no path, because a client concatenating
    // `/v1/...` onto this is doing so blindly and would produce a double slash on one and a correct
    // URL on the other — a difference that shows up as a 404 on one route and not its sibling.
    expect(url.endsWith("/")).toBe(false);
    expect(new URL(url).pathname).toBe("/");

    // And the description is the one place the document states the gate, which is what a client's
    // author reads before writing an integration against it.
    expect(document.servers?.[0]?.description).toContain("Authorization");
  });

  it("publishes the schemas the routes were declared with", async () => {
    const document = await served();
    const schemas = document.components?.schemas ?? {};

    for (const name of [
      "Health",
      // The two the eighth resource added, and it is the **fewest any resource here contributes**: a
      // singleton has no batch schema, no batch row and no batch result, which is five names fewer than
      // the four day-keyed resources and three fewer than the two id-keyed ones. So this pair is the
      // block where an omission is most likely to be mistaken for the resource being small rather than
      // broken — and what makes it worth naming is that `UserProfile` and `UserProfileWrite` are the
      // only two schemas in this document built from **one shared field object**, so they cannot drift
      // apart field by field. `UserProfileWrite` is the one that carries the pair's single `.refine()`
      // and therefore the one whose call order matters: a `.openapi()` moved below the `.refine()`
      // drops the name and lands the schema in the document as an unnamed inline object, which
      // validates the right bytes and leaves a client generator nothing to refer to — the same silent
      // failure `RecoveryBatchWrite`'s comment describes, on a body rather than a batch.
      "UserProfile",
      "UserProfileWrite",
      // The five the seventh resource added, and the first of them is the one to read: `BiometricSample`
      // is the only read schema in this document whose **`rrIntervalsMs` is an array of numbers**, where
      // every other collection-shaped field here is a list of `$ref`s to child objects. It is published
      // as a plain array because an R-R interval has no identity to address — the app's own `v8` stores
      // one the same way, as a JSON text column — so a generator that inlined it would still produce a
      // document that validates, while a client's model for a series of intervals would come back as an
      // untyped list. Nine of this schema's twelve fields are nullable as well, which is the most of any
      // resource here, and none of them carries a default: an absent channel is `null` on this wire
      // rather than a substituted number, so a client that filled one in would be inventing a reading.
      "BiometricSample",
      "BiometricSampleWrite",
      "BiometricSampleBatchRow",
      "BiometricSampleBatchWrite",
      "BiometricSampleBatchResult",
      // The five the second id-keyed resource added, and the block that reads them sits here rather
      // than appended below for the reason the schema names are: `ReceptiveInactivityWrite` is the
      // only write schema in this document whose body carries a **nullable** field at all, so it is
      // the one whose `.strict()`-before-`.openapi()` ordering has a second modifier to sit beside.
      // A `.strict()` moved after the `.openapi()` on *this* schema still publishes the name and still
      // refuses the extra key — the failure the recovery half's comment describes bites a `.refine()`
      // — but it is the schema most likely to be edited by someone reaching for `.nullable()` and
      // reordering by reflex, which is why it is called out here rather than left to the loop.
      "ReceptiveInactivity",
      "ReceptiveInactivityWrite",
      "ReceptiveInactivityBatchRow",
      "ReceptiveInactivityBatchWrite",
      "ReceptiveInactivityBatchResult",
      "Recovery",
      "RecoveryWrite",
      "Error",
      // The three the batch route added. `RecoveryBatchWrite` is the one that would go missing
      // quietly: it is the only schema here carrying a `.refine()`, and `@asteasolutions/zod-to-openapi`
      // patches exactly five modifiers to carry `openapi` metadata through — `optional`, `nullable`,
      // `default`, `transform` and `refine` — so the refine is safe only while it stays a `refine`. A
      // `.superRefine()` (which a dynamically composed refusal message would want) drops the name and
      // lands the schema in the document as an unnamed inline object, where a client generator cannot
      // refer to it. This loop is what fails if that swap is ever made.
      "RecoveryBatchRow",
      "RecoveryBatchWrite",
      "RecoveryBatchResult",
      // The five the first day-keyed sibling added. They are named on the resource rather than shared
      // with `recoveries`' — `StrainWrite` is not `RecoveryWrite` — because the two bodies carry
      // different fields, and a generator handed one schema under the other's name would produce a
      // client that typechecks and sends the wrong shape. `StrainBatchWrite` carries the same
      // `.refine()` and so has the same silent failure mode the recovery half's comment describes.
      //
      // **The sleep half is the same five a third time, and on this resource the refine is the one
      // that matters most.** A night's `endTime` must follow its `startTime`, so `SleepWrite` and
      // `SleepBatchRow` each carry a `.refine()` of their own *and* `SleepBatchWrite` carries the
      // duplicate-day one — three refined schemas where `recoveries` has one. Each is a place the
      // `.openapi()`-before-`.refine()` ordering has to hold, and a swap there drops the name and
      // lands the schema in the document as an unnamed inline object, which validates and describes
      // the right bytes while leaving a client generator nothing to refer to.
      "Sleep",
      "SleepWrite",
      "SleepBatchRow",
      "SleepBatchWrite",
      "SleepBatchResult",
      // And the same five a fourth time, on the resource whose schemas are the **least** refined here:
      // neither field of a step count is an instant, so `StepCountWrite` and `StepCountBatchRow` carry
      // no `.refine()` at all and `StepCountBatchWrite`'s duplicate-day check is the only one among
      // the five. That is the opposite of the sleep half above and it is why this block is not a
      // copy: a reader who has just read three boundary-pair refines will assume a fourth, and the
      // absence of one is a fact about this resource rather than an oversight in its DTO.
      "StepCount",
      "StepCountWrite",
      "StepCountBatchRow",
      "StepCountBatchWrite",
      "StepCountBatchResult",
      "Strain",
      "StrainWrite",
      "StrainBatchRow",
      "StrainBatchWrite",
      "StrainBatchResult",
      // The seven the aggregate added. `WorkoutRoutePoint` and `WorkoutSplit` are here for a reason
      // the flat resource has no instance of: they are reachable **only** as `$ref`s from inside
      // `Workout`, so a generator that inlined them would still publish a document that validates and
      // describes the right bytes — while a client's generated model for a route point would no
      // longer exist under the name the rest of the contract uses. Nothing else in this suite reads
      // them, so this loop is the whole of what keeps them named.
      "Workout",
      "WorkoutWrite",
      "WorkoutBatchRow",
      "WorkoutBatchWrite",
      "WorkoutBatchResult",
      "WorkoutRoutePoint",
      "WorkoutSplit",
    ]) {
      expect(Object.hasOwn(schemas, name)).toBe(true);
    }
  });

  it("keeps the batch schemas named through chained refinements", async () => {
    const document = await served();
    const batch = document.components?.schemas?.["WorkoutBatchWrite"] as
      | { properties?: Record<string, unknown>; additionalProperties?: unknown }
      | undefined;
    const strainBatch = document.components?.schemas?.["StrainBatchWrite"] as
      | { properties?: Record<string, unknown>; additionalProperties?: unknown }
      | undefined;
    const sleepBatch = document.components?.schemas?.["SleepBatchWrite"] as
      | { properties?: Record<string, unknown>; additionalProperties?: unknown }
      | undefined;
    const stepCountBatch = document.components?.schemas?.["StepCountBatchWrite"] as
      | { properties?: Record<string, unknown>; additionalProperties?: unknown }
      | undefined;
    const inactivityBatch = document.components?.schemas?.["ReceptiveInactivityBatchWrite"] as
      | { properties?: Record<string, unknown>; additionalProperties?: unknown }
      | undefined;
    const biometricBatch = document.components?.schemas?.["BiometricSampleBatchWrite"] as
      | { properties?: Record<string, unknown>; additionalProperties?: unknown }
      | undefined;

    // The recovery batch carries one `.refine()` and the workout batch carries two — a duplicate-id
    // check and an aggregate child-cap check — and two is a variation on the one pattern that was
    // proven when `recoveries` landed. `@asteasolutions/zod-to-openapi` patches `refine` to carry the
    // `.openapi()` metadata through, so chaining should be safe; this asserts that it *is*, because
    // the failure mode is silent — the schema lands in the document as an unnamed inline object and
    // the loop above is the only thing that would notice. The `additionalProperties: false` is read
    // beside it because `.strict()` is the one modifier the package does **not** patch, which is why
    // every schema here calls `.strict()` *before* `.openapi()` and never after.
    expect(batch?.additionalProperties).toBe(false);
    expect(Object.keys(batch?.properties ?? {})).toEqual(["rows"]);

    // The same pair read off the resource that copied the pattern rather than the one that invented
    // it, because the ordering is what the copy had to get right and a tidy that moved `.openapi()`
    // below the `.refine()` would leave *this* schema unnamed while the pair above stayed green.
    expect(strainBatch?.additionalProperties).toBe(false);
    expect(Object.keys(strainBatch?.properties ?? {})).toEqual(["rows"]);

    // And the same pair off the schema whose row is refined as well as its body — `SleepBatchWrite`
    // is the only batch here whose `rows` array holds elements carrying a `.refine()`. The metadata
    // on the *outer* schema is what this reads, so it stays green while the inner one could have gone
    // unnamed; the loop above is what covers `SleepBatchRow`, and the two together are why a change
    // to either schema's call order fails somewhere rather than nowhere.
    expect(sleepBatch?.additionalProperties).toBe(false);
    expect(Object.keys(sleepBatch?.properties ?? {})).toEqual(["rows"]);

    // And the plainest composition here, which is the reason to read it: `StepCountBatchWrite` is one
    // `.strict()`, one `.openapi()` and one `.refine()`, so the loop above already fails if those are
    // *misordered*. What the loop cannot see is a `.strict()` that was **dropped** — the schema keeps
    // its name, validates the right bytes, and silently accepts a body carrying a field the contract
    // has no column for, which is the extra key `stepCounts`' spec refuses from the batch and the
    // single-day write alike. `additionalProperties` is the only reading that separates the two.
    expect(stepCountBatch?.additionalProperties).toBe(false);
    expect(Object.keys(stepCountBatch?.properties ?? {})).toEqual(["rows"]);

    // And the same pair off the schema whose `.refine()` is the fourth instance of the duplicate-id
    // check and the first that reads a field which is **also nullable**: `hasRepeatedId` walks
    // `rows.map((row) => row.id)`, and moving that check onto the day — which is what the three
    // day-keyed resources do and is the obvious simplification for anyone who has just read them —
    // would leave every assertion above green, because the metadata this reads is on the outer schema
    // either way. What fails is not here: it is `receptiveInactivities.spec.ts`'s pair, which asserts
    // a repeated id refused *and* two rows sharing a day accepted. This reading is the one that says
    // the schema kept its name and its strictness through that change.
    expect(inactivityBatch?.additionalProperties).toBe(false);
    expect(Object.keys(inactivityBatch?.properties ?? {})).toEqual(["rows"]);

    // And the same pair off the fifth instance of the duplicate-id check, which is the one whose
    // `.refine()` has a **constant** message rather than a counted one. That is not a style choice: a
    // refine's message is composed by the schema, and `@asteasolutions/zod-to-openapi` carries the
    // schema's metadata through a `refine` but not a `superRefine` — so a refusal that interpolated the
    // repeated count would have to be a `superRefine` and would drop this name, landing the schema in
    // the document as an unnamed inline object that validates the right bytes and leaves a client
    // generator nothing to refer to. The count is stated a layer down instead, in
    // `biometricSampleService.ts`, where a caller that passed through no schema at all meets it. This
    // reading is what fails if that swap is ever made, and it is the only place the difference between
    // the two spellings is visible.
    expect(biometricBatch?.additionalProperties).toBe(false);
    expect(Object.keys(biometricBatch?.properties ?? {})).toEqual(["rows"]);
  });

  it("serves the same bytes on a second request", async () => {
    // The handler memoises the serialised string, and the two readings have to agree or the shell
    // gate compares a document the client would never have received.
    const first = await SELF.fetch("https://whoopsy.test/openapi.json");
    const second = await SELF.fetch("https://whoopsy.test/openapi.json");

    expect(await first.text()).toBe(await second.text());
  });
});

/**
 * The gate, as the contract describes it.
 *
 * **This is the loop that fails when a resource is mounted without the schema**, and it is the only
 * thing that does. `src/app.ts`'s gate covers `*`, so a new route is *protected* whether or not it
 * publishes a credential — the request is refused either way, because the middleware runs before the
 * router does. What a route that forgot `RequestHeaderSchema` loses is not the protection but the
 * *description* of it: the document would offer a client an operation with no credential parameter
 * and no possible `401`, and a generated client would have no way to send a token it is required to
 * send. Green suite, unusable contract. That is the shape of defect this block exists for.
 *
 * It reads the document rather than the route files, so it is also what catches the reverse: a route
 * that publishes the parameter while reaching a handler some other way.
 */
describe("every operation's credential, as published", () => {
  /** The parameters an operation declares, whether under `parameters` or on the path item. */
  function parametersOf(
    document: ServedDocument,
    path: string,
    method: string,
  ): { name?: string; in?: string; required?: boolean }[] {
    const item = document.paths[path] as Record<string, unknown>;
    const operation = item[method] as { parameters?: unknown[] } | undefined;

    return (operation?.parameters ?? []) as { name?: string; in?: string; required?: boolean }[];
  }

  it("requires an Authorization header on every /v1 operation, and offers a 401", async () => {
    const document = await served();
    const operations = Object.entries(document.paths)
      .filter(([path]) => path.startsWith("/v1/"))
      .flatMap(([path, item]) => Object.keys(item).map((method) => ({ path, method })));

    // Twenty-two paths carrying thirty operations. Asserted as a floor rather than an equality,
    // because the list of paths is pinned in the block above and a second assertion of the same
    // fact here would be a second thing to update.
    expect(operations.length).toBeGreaterThanOrEqual(30);

    for (const { path, method } of operations) {
      const authorization = parametersOf(document, path, method).find(
        (parameter) => parameter.name === "authorization" && parameter.in === "header",
      );

      expect(authorization, `${method.toUpperCase()} ${path} publishes no authorization header`).toBeDefined();
      expect(authorization?.required, `${method.toUpperCase()} ${path} has an optional credential`).toBe(true);

      // Read off the operation's own `responses`, not off the operation: `Object.hasOwn(op, "401")`
      // is `false` for every operation in this document, which is a green-looking assertion that
      // measures nothing.
      const item = document.paths[path] as Record<string, Record<string, unknown>>;
      const responses = (item[method] ?? {})["responses"] as Record<string, unknown> | undefined;

      expect(
        Object.hasOwn(responses ?? {}, "401"),
        `${method.toUpperCase()} ${path} publishes no 401`,
      ).toBe(true);
    }
  });

  it("leaves the two open paths without a credential of their own", async () => {
    const document = await served();

    // `/health` is a liveness probe and `/openapi.json` is the contract itself; neither is a `/v1`
    // operation and neither may claim a credential, or the document would describe a Worker a probe
    // could not reach. (`/openapi.json` is not in `document.paths` at all — asserted above — so the
    // second half of this is about `/health` alone.)
    expect(parametersOf(document, "/health", "get")).toEqual([]);

    const health = document.paths["/health"]!.get as { responses?: Record<string, unknown> };
    expect(Object.hasOwn(health.responses ?? {}, "401")).toBe(false);
  });

  it("names a credential the runtime would actually accept as well-formed", async () => {
    // The example is prose, and prose that cannot pass the gate is worse than none: a reader who
    // copies it into a curl and gets a 401 has been told something false by the contract. `bearerToken`
    // is the parser the Worker itself uses, so this is the same reading the gate takes.
    const document = await served();
    const authorization = parametersOf(document, "/v1/recoveries", "get").find(
      (parameter) => parameter.name === "authorization",
    ) as { schema?: { example?: string } } | undefined;

    // The example sits on the parameter's **schema**, not on the parameter — an `example` written one
    // level up is not published at all, which is the same silent drop the description would suffer.
    expect(bearerToken(authorization?.schema?.example)).not.toBeNull();
  });
});

describe("serialiseOpenApiDocument", () => {
  it("is the one serialiser, and it ends the file with a newline", async () => {
    const document = await served();
    const text = await SELF.fetch("https://whoopsy.test/openapi.json").then((r) => r.text());

    // Pretty-printed and newline-terminated, which is what makes `shared/openapi.json` a reviewable
    // file and keeps `git diff` from reporting a missing newline at EOF on every regeneration. The
    // served document and the committed one are therefore the same shape, not merely the same JSON.
    expect(text).toBe(`${JSON.stringify(document, null, 2)}\n`);
    expect(text.endsWith("\n")).toBe(true);
    expect(text.split("\n")[1]).toMatch(/^ {2}"openapi":/);
    expect(serialiseOpenApiDocument(document)).toBe(text);
  });
});
