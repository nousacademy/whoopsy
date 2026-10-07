import { SELF, env } from "cloudflare:test";
import { authHeaders } from "../Support/auth";
import { describe, expect, it } from "vitest";
import { USER_PROFILE_GENDERS } from "../../src/domain";
import { deriveUserId, MIN_KEY_LENGTH } from "../../src/utils/identity";

/**
 * The eighth resource, and the first that is a **singleton**: a partition holds one profile or none,
 * so this file's subject is a shape no sibling here has.
 *
 * `receptiveInactivities.spec.ts` is the template and this file keeps its two keys, its `partition`
 * and `rowCount` helpers and its fresh storage per test — but almost everything the sibling files have
 * is *subtracted* here, and the subtractions are the resource rather than a smaller version of one:
 *
 * - **No path parameter.** There is no `{id}` and no `{date}`, so a write and a read are both `/` under
 *   the mount and neither request names a member. The identity is the credential and nothing else.
 * - **No window and no batch.** A singleton has no range to ask for and nothing to chunk, so there is
 *   no `days`, no `endingOn`, no `POST /batch` and no duplicate-key rule — the three checks every
 *   sibling's service opens its batch with have no counterpart, which is why this resource adds no
 *   constant to either of `services/index.ts`'s two families.
 * - **No refusal type.** The one rule the resource publishes — `restingHeartRate` strictly below
 *   `maxHeartRate` — is a rule about a body, so it lives on the write schema and publishes itself in
 *   the contract. There is no `UserProfileError` because no code path could throw one, and this file
 *   asserts that rule *as a `400` from the boundary* rather than as a service refusal.
 * - **No delete**, and that is the standing convention rather than this resource's omission: nothing in
 *   this Worker deletes anything.
 *
 * **`the endpoints this shape does not have` is the block that matters most**, and it is the reason
 * the four subtractions above are guarantees rather than descriptions. A singleton is not enforced by
 * the absence of a route file section — it is enforced by `src/app.ts` answering `route_not_found` for
 * a `POST`, a `DELETE`, a `/batch` and a `/{date}` that were never registered. Each of those is
 * asserted against its own literal, because the tempting wrong shape for this resource is a member
 * address, and a member address that answered `200` would be invisible in every other test here.
 *
 * What the file is for is that the app's own rules survive the trip across a process boundary, where
 * the failures are quieter than they are on-device: a `weightKg` that came back as a `0`, an absence
 * that came back as `""`, a form's cleared field silently filled back in. None of those raise
 * anything, and each produces a response a client would happily draw.
 */

const BASE = "https://whoopsy.test";

/**
 * Two real keys, at the length the app sends: 32 random bytes, 43 base64url characters.
 *
 * They are *keys* and not user ids: what reaches `user_id` is `sha256` of one of these, so every
 * direct read against `env.DB` goes through `partition(_:)`.
 */
const ALICE = "K7fQ2mZx9pLr4Tn6WvB1yHs8JcE3uGa5DkRm0Xq4YAb";
const BOB = "Qw3RtYuIoPaSdFgHjKlZxCvBnM1234567890abcdefg";

/**
 * The partition a key's rows live under — computed the way the Worker computes it.
 *
 * **Deliberately not an independent implementation.** `tests/utils/identity.spec.ts` pins the digest
 * against a literal computed outside this codebase, which is the assertion that the derivation is what
 * it claims to be; what these tests need is a *handle* on the row a request just wrote, so that a
 * direct `SELECT` and the endpoint agree about which partition they are talking about. Binding the raw
 * key instead would silently assert that `user_id` holds the header, which is the one thing
 * `utils/identity.ts` exists to prevent.
 */
function partition(key: string): Promise<string> {
  return deriveUserId(key);
}

/**
 * How many rows exist in one partition. `null` when it is empty, so `?? 0` at the call site.
 *
 * The `table` parameter is kept from the sibling files so the call sites below read alike, even though
 * this resource has exactly one table to count.
 */
async function rowCount(key: string, table = "user_profiles"): Promise<number> {
  const counted = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`)
    .bind(await partition(key))
    .first<{ n: number }>();

  return counted?.n ?? 0;
}

/**
 * The wire shape, spelled out rather than inferred, so a renamed field fails here loudly.
 *
 * **There is no `id` and no `userId`, and their absence is the resource's sharpest deviation.** The
 * D1 table is `PRIMARY KEY (user_id)` alone — the partition is the whole identity — and the app's own
 * local row is keyed by the literal `"primary"`, which is a storage constant with no meaning on this
 * side and is deliberately not published. A reader arriving from `UserProfileRecord` will find its
 * `id` missing here and should not add it back.
 */
interface UserProfileWire {
  maxHeartRate: number;
  restingHeartRate: number;
  weightKg: number | null;
  name: string | null;
  birthDate: string | null;
  gender: string | null;
  heightCm: number | null;
}

interface ErrorWire {
  error: { code: string; message: string };
}

/**
 * A complete profile: both heart rates, and all five declared facts supplied.
 *
 * The two heart rates clear `restingHeartRate < maxHeartRate` with room to spare, so a fixture that
 * wants the refusal has to move one of them rather than stumble into it.
 */
function fullProfile(overrides: Partial<UserProfileWire> = {}): UserProfileWire {
  return {
    maxHeartRate: 190,
    restingHeartRate: 60,
    weightKg: 75,
    name: "Alex",
    birthDate: "1994-03-17",
    gender: "preferNotToSay",
    heightCm: 178,
    ...overrides,
  };
}

/**
 * The same profile with all five nullable columns absent — the fresh-install shape.
 *
 * **This is not the "empty" fixture of a sibling file; it is a state the app really reaches.** A user
 * who has filled in nothing but the two heart rates the zone table needs is every user on first
 * launch, and the whole of what a whole-row write over nullable columns has to get right is that a
 * `null` sent is the `null` stored. A `?? 0` in the mapper or the adapter would turn "the user has not
 * told us their weight" into a number the calorie estimate divides into, and a `?? ""` would give the
 * name column a second spelling of "nothing".
 */
function bareProfile(overrides: Partial<UserProfileWire> = {}): UserProfileWire {
  return fullProfile({
    weightKg: null,
    name: null,
    birthDate: null,
    gender: null,
    heightCm: null,
    ...overrides,
  });
}

/**
 * The seven keys of a written profile, read off the fixture rather than listed.
 *
 * Derived, so the "every field is required" sweep below covers exactly the fields `fullProfile`
 * declares: a field added to the fixture is swept with no edit here, and a field the fixture omits is
 * caught by the round-trip tests instead — where the write would `400` rather than silently pass.
 */
const FIELDS = Object.keys(fullProfile()) as (keyof UserProfileWire)[];

/** The body with one key removed, so an omission can be asserted rather than described. */
function without<K extends keyof UserProfileWire>(
  fields: UserProfileWire,
  key: K,
): Record<string, unknown> {
  const copy: Record<string, unknown> = { ...fields };
  delete copy[key];
  return copy;
}

/**
 * A `PUT` to the singleton. There is no id argument, which is the whole point of the resource.
 *
 * The body is typed `unknown` rather than `UserProfileWire` so that the malformed-body tests below
 * read as what they are. A fixture that had to be cast into shape to be refused would be asserting
 * less than it appears to.
 */
function put(body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/profile`, {
    method: "PUT",
    headers: { "content-type": "application/json", ...authHeaders(userId) },
    body: JSON.stringify(body),
  });
}

function read(path = "/v1/profile", userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}${path}`, { headers: { ...authHeaders(userId) } });
}

/** The profile, asserting the read succeeded — so a 404 cannot be mistaken for a payload. */
async function profile(userId = ALICE): Promise<UserProfileWire> {
  const response = await read("/v1/profile", userId);
  expect(response.status).toBe(200);
  return (await response.json()) as UserProfileWire;
}

describe("a profile written and read back", () => {
  it("returns the stored row rather than an echo of the request", async () => {
    const body = fullProfile();

    const written = await put(body);
    expect(written.status).toBe(200);

    const stored = (await written.json()) as UserProfileWire;
    expect(stored).toEqual(body);

    // The read is the assertion that the response was the database's answer rather than the request's:
    // the two agree here only because the write really happened — `upsert` re-reads the row rather than
    // returning `RETURNING`, so a mapper that dropped a column would fail here and nowhere else.
    expect(await profile()).toEqual(stored);
  });

  it("replaces the profile when the same partition is written twice", async () => {
    await put(fullProfile());
    await put(fullProfile({ name: "Sam", weightKg: 68 }));

    // `ON CONFLICT (user_id) DO UPDATE`, which is the same key the app's own `saveUserProfile` is
    // INSERT-or-UPDATE by — so a second save lands on the row rather than beside it. **The assertion is
    // the row count and not the read**, because on a singleton the tempting wrong shape is an `INSERT`
    // that appends: the read below would still return the newest row and every screen would look right
    // while the partition quietly accumulated a profile per save.
    expect(await rowCount(ALICE)).toBe(1);
    expect((await profile()).name).toBe("Sam");
  });

  it("returns every absence as null, on the shape a fresh install writes", async () => {
    const body = bareProfile();

    const written = await put(body);
    expect(written.status).toBe(200);

    const stored = (await written.json()) as UserProfileWire;

    // Present at all — a stripped key would be a third state that means nothing, which is why the
    // schema declares `.nullable()` and never `.optional()`.
    for (const key of ["weightKg", "name", "birthDate", "gender", "heightCm"] as const) {
      expect(Object.hasOwn(stored, key)).toBe(true);
      expect(stored[key]).toBeNull();
    }

    // **`null` in, `null` out**, and this is the round trip a screenshot cannot make: a `0` that came
    // back for a cleared weight would be a plausible body weight the calorie estimate divides into,
    // reported to the user as their own.
    expect(await profile()).toEqual(body);
  });

  it("keeps the two heart rates required while the other five may be absent", async () => {
    // The split is the app's own: these two are the inputs the Karvonen zone table cannot be built
    // without — `computeZones` reads both and has a 20 bpm floor on their reserve — while the other
    // five are *declared* facts the user supplies. A profile with no maximal rate is not a profile with
    // a missing reading, it is a zone table that cannot be computed at all.
    expect((await put(bareProfile())).status).toBe(200);
    expect((await put(fullProfile({ restingHeartRate: 0 }))).status).toBe(400);
  });
});

describe("the write shape", () => {
  it("requires every field, because this is a whole-row write", async () => {
    const body = fullProfile();

    for (const key of FIELDS) {
      const response = await put(without(body, key));

      // A `400` and never a silent default. **This is the resource's sharpest rule**: an omitted key
      // here has two plausible readings — "I did not mention it" and "there is none" — and a whole-row
      // write has to collapse them. It collapses them onto `null`, which is why that is what a client
      // sends instead of omitting. A schema that made a field optional would give the two absences
      // different spellings and the write path would have to pick one, silently.
      expect(response.status, `omitting ${key} was accepted`).toBe(400);
      expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    }
  });

  it("refuses a body naming its own identity", async () => {
    // The two keys the app's own local row carries. `id` is the phone's `"primary"` — a storage
    // constant with no meaning on this side — and `userId` is the credential's, already stated by the
    // request that carried it. `.strict()` **refuses** them rather than stripping them, which is the
    // stronger statement: a body that carried one would otherwise be a second statement of something
    // the request has already said, and the two could disagree with nothing to report it.
    for (const extra of [{ id: "primary" }, { userId: "someone-else" }, { date: "2026-08-22" }]) {
      const response = await put({ ...fullProfile(), ...extra });

      expect(response.status, `${Object.keys(extra)[0]} was accepted`).toBe(400);
      expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    }

    // And the identity really came from the credential: the refused writes left nothing behind.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a resting heart rate that is not strictly below the maximal one", async () => {
    // The one rule this resource publishes, and it is on the write body alone. It is a rule about a
    // *body* — a non-positive reserve is not a zone table but a division by nothing — which is where
    // this Worker puts those, exactly as `SleepWriteSchema`'s `endsAfterItStarts` is stated on its body
    // and forwarded by its service rather than restated.
    const reversed = await put(fullProfile({ maxHeartRate: 60, restingHeartRate: 190 }));

    expect(reversed.status).toBe(400);

    const body = (await reversed.json()) as ErrorWire;
    expect(body.error.code).toBe("invalid_request");

    // The message is pinned **by value**, because a `.refine()`'s metadata is what survives into the
    // published contract while a `.superRefine()`'s does not — so a rule rewritten as a superRefine
    // would keep refusing and silently stop explaining itself in the document. The path prefix is the
    // `validationHook`'s and says which field to fix.
    expect(body.error.message).toBe(
      "restingHeartRate: restingHeartRate must be strictly below maxHeartRate — " +
        "a non-positive reserve is not a heart-rate zone table",
    );

    // Equal is refused too, so the rule is a strict inequality rather than a `<=` that happens to pass
    // every other test in this file: a reserve of exactly zero is the same table it exists to prevent.
    expect((await put(fullProfile({ maxHeartRate: 190, restingHeartRate: 190 }))).status).toBe(400);
  });

  it("accepts a resting rate one below the maximal one", async () => {
    // The pair that makes the refusal above a *boundary* rather than a restatement of a check that any
    // nonsense would also fail.
    const response = await put(fullProfile({ maxHeartRate: 190, restingHeartRate: 189 }));

    expect(response.status).toBe(200);
    expect((await response.json() as UserProfileWire).restingHeartRate).toBe(189);
  });

  it("refuses a heart rate that is not a positive whole number", async () => {
    // Shape bounds and not the app's form bands. `100…250` and `30…120` are `ProfileDraft`
    // Presentation guards, changeable without a deploy; publishing them here would make this API
    // refuse a profile the app itself can hold. What is published is that these are integers and that
    // they are positive — and `190.5` is the case that matters, because a fractional bpm would be
    // stored and read back happily while the zone table it feeds is built from whole bands.
    for (const bad of [190.5, 0, -5]) {
      const response = await put(fullProfile({ maxHeartRate: bad }));

      expect(response.status, `maxHeartRate ${bad} was accepted`).toBe(400);
    }
  });

  it("refuses a cleared field spelled as an empty string", async () => {
    // `null` and `""` are different answers, and only one of them is an absence. A name column holding
    // `""` is a value nobody supplied — the state `receptiveInactivities` documents for `note`, reached
    // there by construction and refused here at the boundary.
    expect((await put(bareProfile({ name: "" }))).status).toBe(400);
  });

  it("refuses a birth date that is not a calendar day", async () => {
    // `DayKeySchema` round-trips the string through a parse, so `1994-3-17` and `1994-03-32` are both
    // refused rather than stored as text no reader can key on. The wire is a **day key** and not an
    // instant — the app's own column is a `.datetime`, which is the conversion the mapper that does not
    // exist yet will have to make.
    for (const bad of ["1994-3-17", "1994-02-30", "17/03/1994", "1994-03-17T00:00:00.000Z"]) {
      expect((await put(bareProfile({ birthDate: bad }))).status, bad).toBe(400);
    }

    // And the day key itself is stored verbatim — no time is attached on the way through, which is what
    // keeps a birthday from moving a day in a negative-offset zone.
    await put(bareProfile({ birthDate: "1994-03-17" }));
    expect((await profile()).birthDate).toBe("1994-03-17");
  });

  it("accepts every published gender and refuses any other word", async () => {
    // Swept off the domain's own tuple rather than typed here, so the schema and the vocabulary it
    // publishes are asserted to be the same list: a fifth word added to `USER_PROFILE_GENDERS` is
    // accepted by construction, and one removed stops being accepted.
    for (const gender of USER_PROFILE_GENDERS) {
      const response = await put(bareProfile({ gender }));

      expect(response.status, `${gender} was refused`).toBe(200);
      expect((await response.json() as UserProfileWire).gender).toBe(gender);
    }

    // The refusal half, with a word outside the set — the assertion that the column is a closed
    // vocabulary at the boundary rather than free text. There is deliberately **no `CHECK` constraint**
    // behind it on the table: a constraint would freeze a set expected to grow into a migration file
    // that is frozen once shipped, where the `z.enum` needs only a deploy.
    expect((await put(bareProfile({ gender: "male" }))).status).toBe(400);
  });
});

describe("a partition with no profile", () => {
  it("is a 404 naming the code, not a fabricated row", async () => {
    const response = await read("/v1/profile");

    expect(response.status).toBe(404);

    // `not_found` and **not** the day-keyed resources' `no_measurement_for_day`. That code names a day
    // that exists with nothing measured on it — the day is the subject and the measurement is missing —
    // and there is no day here and nothing to measure. The absence is the same shape `workouts`,
    // `receptiveInactivities` and `biometricSamples` answer for a row that is not there.
    expect(await response.json()).toEqual({
      error: { code: "not_found", message: "no profile is stored for this caller" },
    });
  });

  it("does not publish the app's cold-start heart rates", async () => {
    // **The decision this resource most easily gets wrong.** The app's own repository answers a
    // cold-start 190/60 when no row exists, and that pair is the *client's* tolerance for a zone table
    // it cannot build — applied at the moment it merges a remote absence with its local copy. A server
    // that published it would be inventing a measurement and calling it a row, which is the fabrication
    // every absence rule in this project forbids. So the absence is an absence, and the client's
    // fallback stays the client's.
    const response = await read("/v1/profile");
    const body = (await response.json()) as ErrorWire;

    expect(body.error.code).not.toBe("no_measurement_for_day");

    // Asserted from the storage side too, so a row written by a later path cannot make this a
    // statement about the status code alone.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("answers a profile to the same key only after one has been written", async () => {
    expect((await read("/v1/profile")).status).toBe(404);

    await put(fullProfile());

    // The pair that pins the 404 above as an absence rather than a broken read path: nothing else
    // changed between the two requests.
    expect((await read("/v1/profile")).status).toBe(200);
  });
});

describe("the partition", () => {
  it("keeps one user's profile invisible to another", async () => {
    await put(fullProfile({ name: "Alice" }), ALICE);

    expect((await profile(ALICE)).name).toBe("Alice");

    // Nothing verifies the header yet, so this is the `user_id` column doing real work: the row is
    // there, and a different owner cannot reach it.
    expect((await read("/v1/profile", BOB)).status).toBe(404);
  });

  it("lets two users hold their own profile under one primary key", async () => {
    await put(fullProfile({ name: "Alice", weightKg: 62 }), ALICE);
    await put(fullProfile({ name: "Bob", weightKg: 81 }), BOB);

    // **`PRIMARY KEY (user_id)` and not `(user_id, id)`**, which is the migration's decision seen from
    // the only side that can see it: two partitions each hold exactly one row, and the second user's
    // write did not replace the first's. On a collection the conflict target names a value being
    // written; here it names the ownership column alone, which is never updated because a write cannot
    // move a row between partitions.
    expect((await profile(ALICE)).name).toBe("Alice");
    expect((await profile(BOB)).name).toBe("Bob");
    expect((await profile(ALICE)).weightKg).toBe(62);
    expect(await rowCount(ALICE)).toBe(1);
    expect(await rowCount(BOB)).toBe(1);
  });

  it("files the row under the digest of the key, never under the key", async () => {
    await put(fullProfile());

    // The two reads are the assertion, and the second is the one that matters. The first says the row
    // is reachable at all; the second says the column holds something that is *not* the header, which
    // is the whole of what a D1 dump leaking no usable credentials means. A `user_id` equal to `ALICE`
    // would satisfy every other test in this file — the requests would still work, because the same
    // string would be hashed on the way in and matched on the way out — and would be a database of
    // working keys.
    expect(await rowCount(ALICE)).toBe(1);

    const keyed = await env.DB.prepare("SELECT COUNT(*) AS n FROM user_profiles WHERE user_id = ?")
      .bind(ALICE)
      .first<{ n: number }>();

    expect(keyed?.n).toBe(0);
  });

  it("never publishes the partition back to the client", async () => {
    const stored = await put(fullProfile()).then((response) => response.json());

    // The digest is an internal key. `toWire` withholds `userId` deliberately: a client that read its
    // owner out of a payload would be learning to trust the body over the credential, which is the
    // habit that breaks the day the header is verified rather than derived.
    expect(Object.hasOwn(stored as object, "userId")).toBe(false);
    expect(Object.hasOwn(stored as object, "user_id")).toBe(false);
  });
});

describe("identity", () => {
  it("refuses a request with no X-Whoopsy-User-Id", async () => {
    const response = await SELF.fetch(`${BASE}/v1/profile`, { headers: { ...authHeaders() } });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses an empty X-Whoopsy-User-Id", async () => {
    const response = await read("/v1/profile", "");

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a key one character below the floor", async () => {
    const short = "a".repeat(MIN_KEY_LENGTH - 1);

    // The boundary from the inside, because the guard is a length test and an off-by-one is its only
    // realistic defect: `>=` spelled `>` would admit exactly this string and pass every other test in
    // this file, including the empty-key one above — nothing else here is near the edge.
    expect((await read("/v1/profile", short)).status).toBe(400);

    // And one character above it is accepted, so the pair pins a boundary rather than restating a
    // refusal that a blank check would also produce. The answer is a `404` because no profile has been
    // written, which is the honest reading of a usable key on an empty partition.
    expect((await read("/v1/profile", "a".repeat(MIN_KEY_LENGTH))).status).toBe(404);
  });

  it("refuses a write with no credential as readily as a read", async () => {
    const response = await SELF.fetch(`${BASE}/v1/profile`, {
      method: "PUT",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify(fullProfile()),
    });

    // Both endpoints go through one `partitionFor`, and this is the half that would be easy to leave
    // out: a write path that hashed a missing header would file the row under the digest of `undefined`.
    expect(response.status).toBe(400);
  });
});

/**
 * The block that makes the singleton a guarantee rather than a description.
 *
 * Every other test in this file would pass unchanged on a resource with a `{id}`, a `/batch` and a
 * window — they simply never ask for one. What pins the shape is that the four addresses a *collection*
 * would have do not exist, and that is a fact about `routes/index.ts` and `src/app.ts` rather than
 * about this resource's own files: nothing was registered, so nothing answers.
 *
 * The message is asserted by value because it is the same sentence for all four — `src/app.ts` builds
 * it from the method and the path — so a reader can tell a wrong path from a wrong method, which is
 * exactly what a person checking this by hand gets wrong.
 */
describe("the endpoints this shape does not have", () => {
  it("has no second write verb, so there is no POST", async () => {
    const response = await SELF.fetch(`${BASE}/v1/profile`, {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders(ALICE) },
      body: JSON.stringify(fullProfile()),
    });

    // `PUT` alone, because the app's own save is a whole-row upsert and a `PUT` is the verb for exactly
    // that: the caller is stating the complete resource rather than proposing a new member of a
    // collection. A `POST` on a singleton would have to mean an insert that fails once the row exists,
    // or a second spelling of the same upsert — and the second is a second way to write one row.
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({
      error: { code: "route_not_found", message: "no route for POST /v1/profile" },
    });
  });

  it("has no DELETE, like every other resource here", async () => {
    await put(fullProfile());

    const response = await SELF.fetch(`${BASE}/v1/profile`, {
      method: "DELETE",
      headers: { ...authHeaders(ALICE) },
    });

    // The standing convention rather than this resource's omission — `WorkoutRepository.delete(_:)` and
    // `ReceptiveInactivityRepository.delete(_:)` both exist on the app's side with no counterpart here.
    // The row is asserted still present, because a `404` from a handler that *had* deleted and then
    // failed to report would be indistinguishable from this one.
    expect(response.status).toBe(404);
    expect((await response.json() as ErrorWire).error.message).toBe("no route for DELETE /v1/profile");
    expect(await rowCount(ALICE)).toBe(1);
  });

  it("has no batch, because a partition holds one profile", async () => {
    const response = await SELF.fetch(`${BASE}/v1/profile/batch`, {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders(ALICE) },
      body: JSON.stringify([fullProfile()]),
    });

    // There is nothing to chunk, so there is no empty-list refusal, no row cap and no repeated-key
    // check — the three things every sibling's service opens `writeBatch` with. That is the whole
    // reason this resource adds no constant to either family in `services/index.ts`, and a
    // `MAX_BATCH_USER_PROFILES` would be a published ceiling on an endpoint that does not exist.
    expect(response.status).toBe(404);
    expect((await response.json() as ErrorWire).error.message).toBe(
      "no route for POST /v1/profile/batch",
    );
  });

  it("has no addressable member, so neither a date nor an id is a path", async () => {
    // The tempting wrong shape for this resource, and the reason the mount is `/v1/profile` singular
    // rather than `/v1/user-profiles`. A plural collection path reads as "list them", and a member path
    // reads as "this one of them" — and there is no list and no member, so both would be addresses with
    // nothing behind them. A `GET` that answered `200` here would be the whole resource quietly
    // becoming a collection, which no other test in this file would notice.
    for (const path of ["/v1/profile/2026-08-22", "/v1/profile/primary"]) {
      const response = await read(path);

      expect(response.status, path).toBe(404);
      expect((await response.json() as ErrorWire).error.message).toBe(`no route for GET ${path}`);
    }
  });

  it("ignores a window, because the contract publishes no query for one", async () => {
    await put(fullProfile());

    const response = await read("/v1/profile?days=7&endingOn=2026-08-22");

    // Not a refusal and not a window: the route declares no query object, so there is nothing to
    // validate and nothing to honour, and the parameters are simply not read. Asserted rather than left
    // alone because it is a *behaviour* a client could come to depend on — a caller that sent `days`
    // is told nothing about it having meant nothing — and because it fails loudly the day someone gives
    // this route a `WindowQuerySchema` for consistency with its seven siblings, which is the shape
    // change this resource exists to not have.
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(fullProfile());
  });
});
