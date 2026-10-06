import { SELF, env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { ZONE_COUNT } from "../../src/domain";
import {
  MAX_BATCH_ROUTE_POINTS,
  MAX_BATCH_SPLITS,
  MAX_BATCH_WORKOUTS,
  MAX_ROUTE_POINTS,
  MAX_SPLITS,
  MAX_WINDOW_DAYS,
} from "../../src/services";
import { deriveUserId, MIN_KEY_LENGTH } from "../../src/utils/identity";

/**
 * The second resource, and the first that is an aggregate: one session written and read as a thing
 * with its own route and its own splits.
 *
 * The sibling file is the template and this one deliberately keeps its shape — the same two keys, the
 * same `partition`/`rowCount`/`put`/`read`/`postBatch` helpers, the same fresh storage per test — so
 * that the differences between the two resources are the *only* thing a reader has to hold. There are
 * four, and each is a rule rather than a variation:
 *
 * - **A session is addressed by `{id}` and carries its day in the body**, where a recovery is
 *   addressed by `{date}`. A day holds several sessions, so a day-keyed address would overwrite the
 *   first with the second — the defect `workouts`' id-keying exists to prevent.
 * - **A session is three tables**, so the same id written twice has to replace its children as well as
 *   its row, and an omitted route cannot be read as an empty one: that would delete a stored route on
 *   a client's partial body.
 * - **`written` counts sessions, not rows**, and the two figures differ by more than an order of
 *   magnitude on any real chunk.
 * - **A 404 here says `not_found`**, because nothing in this resource is addressed by a day and the
 *   sibling's `no_measurement_for_day` would name a key this API does not take.
 *
 * Every assertion below maps to a rule this repo has already paid for once in the app, and the app's
 * own docs record what each cost. What the file is for is that those rules survive the trip across a
 * process boundary, where the failures they prevent are quieter than they are on-device: a `NULL` that
 * came back as `0`, a zone block that summed to 101, a route read back in a different order from the
 * one it was sent in — none of those raise anything, and each produces a response a client would
 * happily draw.
 */

const BASE = "https://whoopsy.test";

/**
 * Two real keys, at the length the app sends: 32 random bytes, 43 base64url characters.
 *
 * The sibling file carries the argument in full — briefly, they were `"alice"` and `"bob"` until the
 * header guard made them invalid, and shortening the guard to suit the fixtures would be the first
 * caller the rule broke. They are *keys* and not user ids: what reaches `user_id` is `sha256` of one
 * of these, so every direct read against `env.DB` goes through `partition(_:)`.
 */
const ALICE = "K7fQ2mZx9pLr4Tn6WvB1yHs8JcE3uGa5DkRm0Xq4YAb";
const BOB = "Qw3RtYuIoPaSdFgHjKlZxCvBnM1234567890abcdefg";

/** Session ids. Well-formed UUIDs because a non-UUID one is refused at the boundary — deliberately. */
const SESSION = "6f9619ff-8b86-d011-b42d-00c04fc964ff";
const OTHER = "7a2c1d40-5e83-4b16-9f27-3c8a6d5b0e91";

/** Child ids. Distinct per child, because the child tables are keyed `(user_id, id)`. */
const POINT_A = "0d1f2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5b";
const POINT_B = "1e2f3a4b-5c6d-4e7f-9a0b-1c2d3e4f5a6b";
const POINT_C = "2f3a4b5c-6d7e-4f80-9b1c-2d3e4f5a6b7c";
const SPLIT_A = "3a4b5c6d-7e8f-4a91-8c2d-3e4f5a6b7c8d";
const SPLIT_B = "4b5c6d7e-8f90-4a12-9d3e-4f5a6b7c8d9e";

/**
 * A well-formed UUID per index, so a fixture that needs two hundred ids does not list them.
 *
 * The version and variant nibbles are the ones a v4 has, which is what the app mints for a live
 * session — `WORKOUT_ID_PATTERN` deliberately accepts any version, but a fixture that used one the
 * pattern accepted and `UUID(uuidString:)` did not would be testing a string no client can send.
 */
function uuid(n: number): string {
  return `00000000-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;
}

/**
 * The partition a key's rows live under — computed the way the Worker computes it.
 *
 * **Deliberately not an independent implementation.** `tests/utils/identity.spec.ts` pins the digest
 * against a literal computed outside this codebase, which is the assertion that the derivation is
 * what it claims to be; what these tests need is a *handle* on the row a request just wrote, so that
 * a direct `SELECT` and the endpoint agree about which partition they are talking about. Binding the
 * raw key instead would silently assert that `user_id` holds the header, which is the one thing
 * `utils/identity.ts` exists to prevent.
 */
function partition(key: string): Promise<string> {
  return deriveUserId(key);
}

/**
 * How many rows exist in one partition of one table. `null` when the table is empty, so `?? 0` at the
 * call site — and the `table` parameter is the whole reason this is a parameter rather than three
 * near-identical helpers: an aggregate's children are where "the write landed" and "the write landed
 * once" part company, and both counts have to be against the same partition.
 */
async function rowCount(key: string, table = "workouts"): Promise<number> {
  const counted = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`,
  )
    .bind(await partition(key))
    .first<{ n: number }>();

  return counted?.n ?? 0;
}

interface RoutePointWire {
  id: string;
  latitude: number;
  longitude: number;
  timestamp: string;
  heartRate: number;
}

interface SplitWire {
  id: string;
  elapsed: number;
  strain: number;
}

/** The wire shape, spelled out rather than inferred, so a renamed field fails here loudly. */
interface WorkoutWire {
  id: string;
  date: string;
  startedAt: string;
  endedAt: string;
  strain: number | null;
  averageHeartRate: number | null;
  maxHeartRate: number | null;
  source: string | null;
  activityName: string | null;
  hrZonePercents: number[] | null;
  steps: number | null;
  offlineRegionID: string | null;
  route: RoutePointWire[];
  splits: SplitWire[];
}

/** What a `PUT` body carries: the session, without its id, which is in the path. */
type WorkoutFields = Omit<WorkoutWire, "id">;

interface ErrorWire {
  error: { code: string; message: string };
}

const POINT_A_WIRE: RoutePointWire = {
  id: POINT_A,
  latitude: 51.5074,
  longitude: -0.1278,
  timestamp: "2026-08-22T07:15:30.000Z",
  heartRate: 118,
};

const POINT_B_WIRE: RoutePointWire = {
  id: POINT_B,
  latitude: 51.5081,
  longitude: -0.1246,
  timestamp: "2026-08-22T07:40:00.000Z",
  heartRate: 131,
};

const POINT_C_WIRE: RoutePointWire = {
  id: POINT_C,
  latitude: 51.5096,
  longitude: -0.1201,
  timestamp: "2026-08-22T08:02:00.000Z",
  heartRate: 126,
};

const SPLIT_A_WIRE: SplitWire = { id: SPLIT_A, elapsed: 300, strain: 3.2 };
const SPLIT_B_WIRE: SplitWire = { id: SPLIT_B, elapsed: 120, strain: 1.4 };

/**
 * A measured session, carrying a route and a split rather than empty ones.
 *
 * The children are populated on purpose: the round trip in the first block is the only place the
 * aggregate is asserted as a whole, and a fixture with an empty route would let a read that never
 * joined the child tables pass it. `absentSession` below is the one that empties them.
 */
function measuredSession(overrides: Partial<WorkoutFields> = {}): WorkoutFields {
  return {
    date: "2026-08-22",
    startedAt: "2026-08-22T07:15:00.000Z",
    endedAt: "2026-08-22T08:15:00.000Z",
    strain: 7.4,
    averageHeartRate: 132,
    maxHeartRate: 171,
    source: "whoop_export",
    activityName: "Basketball",
    hrZonePercents: [12, 40, 33, 10, 0],
    steps: 693,
    offlineRegionID: null,
    route: [POINT_A_WIRE, POINT_B_WIRE],
    splits: [SPLIT_A_WIRE],
    ...overrides,
  };
}

/**
 * A route and a split that belong to one session, minted from that session's position in a partition.
 *
 * **`measuredSession`'s own children are shared identity, and two sessions in one partition must not
 * be.** Both child tables are keyed `(user_id, id)` and the write is a plain `INSERT`, so two sessions
 * written with the defaults above are two sessions claiming the *same* two route points and the *same*
 * split — which D1 refuses with `UNIQUE constraint failed: workout_route_points.user_id,
 * workout_route_points.id`. That refusal is correct and the fixture's fault: a client mints a fresh
 * `UUID` per fix, and a route is a property of one recording rather than of a shape two recordings
 * share. `measuredSession` keeps its children because the first block's round trip is the only place
 * the aggregate is asserted as a whole, and that block writes one session.
 *
 * `row` is the thing that has to differ, and **the index is unique within the partition rather than
 * within the test** — a `beforeEach` that writes six sessions has spent rows 0…5 before any `it`
 * runs, so a test adding to that partition continues from there. `the window` is both halves of that:
 * its hook claims six rows for six days, and its ordering test reads the next two off `DAYS.length`.
 * The ids come from the same `uuid` generator the cap fixtures use and sit clear of their 1000/2000
 * ranges. The children are otherwise the defaults, so a multi-session fixture still carries the
 * two-point route and the one split the single-session round trip pins.
 *
 * **The failure it prevents is loud, which is why this is a call-site rule and not a counter inside
 * `measuredSession`.** Forgetting it 500s the request rather than handing two sessions one route in
 * silence; an incrementing default would instead make every fixture's ids depend on the order the
 * tests ran in, which is the kind of thing that holds until someone runs one file alone.
 */
function ownChildren(row: number): Pick<WorkoutFields, "route" | "splits"> {
  const base = 9000 + row * 10;

  return {
    route: [
      { ...POINT_A_WIRE, id: uuid(base) },
      { ...POINT_B_WIRE, id: uuid(base + 1) },
    ],
    splits: [{ ...SPLIT_A_WIRE, id: uuid(base + 2) }],
  };
}

/**
 * The same session with every nullable column absent — the state most of the `NULL is not 0` block is
 * about, and one a fixture that filled them would leave untested.
 */
function absentSession(overrides: Partial<WorkoutFields> = {}): WorkoutFields {
  return measuredSession({
    strain: null,
    averageHeartRate: null,
    maxHeartRate: null,
    source: null,
    activityName: null,
    hrZonePercents: null,
    steps: null,
    offlineRegionID: null,
    ...overrides,
  });
}

/** One batch row, shaped the way a client assembles it: the session's own id, then its fields. */
function sessionRow(id: string, overrides: Partial<WorkoutFields> = {}): WorkoutWire {
  return { id, ...measuredSession(overrides) };
}

/** A session filed on a given day, with its own instants inside that day. */
function sessionOn(date: string, overrides: Partial<WorkoutFields> = {}): Partial<WorkoutFields> {
  return {
    date,
    startedAt: `${date}T07:15:00.000Z`,
    endedAt: `${date}T08:15:00.000Z`,
    ...overrides,
  };
}

/** The body with one key removed, so an omission can be asserted rather than described. */
function without<K extends keyof WorkoutFields>(
  fields: WorkoutFields,
  key: K,
): Record<string, unknown> {
  const copy: Record<string, unknown> = { ...fields };
  delete copy[key];
  return copy;
}

function put(id: string, body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/workouts/${id}`, {
    method: "PUT",
    headers: { "content-type": "application/json", "x-whoopsy-user-id": userId },
    body: JSON.stringify(body),
  });
}

function read(path: string, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}${path}`, { headers: { "x-whoopsy-user-id": userId } });
}

function postBatch(body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/workouts/batch`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-whoopsy-user-id": userId },
    body: JSON.stringify(body),
  });
}

async function session(userId: string, id: string): Promise<WorkoutWire> {
  const response = await read(`/v1/workouts/${id}`, userId);
  expect(response.status).toBe(200);
  return (await response.json()) as WorkoutWire;
}

async function window(query: string, userId = ALICE): Promise<WorkoutWire[]> {
  const response = await read(`/v1/workouts?${query}`, userId);
  expect(response.status).toBe(200);
  return (await response.json()) as WorkoutWire[];
}

describe("a session written and read back", () => {
  it("returns the stored row, children and all, rather than an echo of the request", async () => {
    const body = measuredSession();

    const written = await put(SESSION, body);
    expect(written.status).toBe(200);

    const stored = (await written.json()) as WorkoutWire;
    expect(stored).toEqual({ id: SESSION, ...body });

    // The read is the assertion that the response was the database's answer rather than the request's:
    // the two agree here only because the write really happened, which for an aggregate means three
    // tables agreed rather than one.
    expect(await session(ALICE, SESSION)).toEqual(stored);
  });

  it("replaces a session when the same id is written twice, its children included", async () => {
    await put(SESSION, measuredSession({ strain: 7.4 }));
    await put(SESSION, measuredSession({ strain: 12.1 }));

    // `UPSERT … ON CONFLICT (user_id, id) DO UPDATE` over the parent, and a delete-then-insert over
    // both children, so the second write must leave one session and not two.
    expect(await rowCount(ALICE)).toBe(1);
    expect((await session(ALICE, SESSION)).strain).toBe(12.1);

    // **The children count is the assertion the parent's cannot make.** An upsert that appended to
    // the child tables instead of replacing them would answer `1` above and `4` here, and a route
    // with every fix twice in it draws a plausible line back over itself.
    expect(await rowCount(ALICE, "workout_route_points")).toBe(2);
    expect(await rowCount(ALICE, "workout_splits")).toBe(1);
  });

  it("files two sessions on one day as two rows", async () => {
    await put(SESSION, measuredSession({ ...sessionOn("2026-08-22"), ...ownChildren(0) }));
    await put(
      OTHER,
      measuredSession({
        date: "2026-08-22",
        startedAt: "2026-08-22T18:00:00.000Z",
        endedAt: "2026-08-22T18:45:00.000Z",
        ...ownChildren(1),
      }),
    );

    // The resource's whole shape, and the assertion a day-keyed table fails: `recoveries` would hold
    // one row here, with the second write having overwritten the first and reported success.
    expect(await rowCount(ALICE)).toBe(2);

    const rows = await window("days=0&endingOn=2026-08-22");
    expect(rows.map((row) => row.id)).toEqual([SESSION, OTHER]);
  });
});

describe("the children", () => {
  it("keeps the route in the order the array carried, not in time order", async () => {
    // Deliberately out of chronological order, which a route's fixes can be — a corrected fix, a
    // device that stamps late. `SELECT_ROUTE_POINTS_FOR_WORKOUT` reads `ORDER BY seq ASC` and `seq`
    // is bound from the array's own index, so what a client PUTs is what a client GETs byte for byte.
    // A read that re-derived the order from `timestamp` would answer A, B, C below — a route drawn
    // through its own fixes in a different sequence, with no error anywhere.
    const scrambled = [POINT_C_WIRE, POINT_A_WIRE, POINT_B_WIRE];

    await put(SESSION, measuredSession({ route: scrambled }));

    const stored = await session(ALICE, SESSION);
    expect(stored.route.map((point) => point.id)).toEqual([POINT_C, POINT_A, POINT_B]);
    expect(stored.route).toEqual(scrambled);
  });

  it("keeps the splits in the order the array carried", async () => {
    // The same rule on the sibling table, with a fixture whose array order disagrees with its own
    // `elapsed` — so a read that sorted by anything but `seq` is visible.
    await put(SESSION, measuredSession({ splits: [SPLIT_B_WIRE, SPLIT_A_WIRE] }));

    expect((await session(ALICE, SESSION)).splits.map((split) => split.id)).toEqual([
      SPLIT_B,
      SPLIT_A,
    ]);
  });

  it("files each session's children under that session alone", async () => {
    await put(SESSION, measuredSession({ route: [POINT_A_WIRE], splits: [SPLIT_A_WIRE] }));
    await put(OTHER, measuredSession({ route: [POINT_B_WIRE], splits: [SPLIT_B_WIRE] }));

    // Read through the window rather than the single-session read, because the window's child query
    // is a different statement — it joins `workouts` on `(user_id, workout_id)` — and it is the one
    // whose `workout_id` predicate could go missing. Without it both sessions come back carrying both
    // routes, which is four fixes where there are two and a line drawn between two separate runs.
    const rows = await window("days=0&endingOn=2026-08-22");
    const first = rows.find((row) => row.id === SESSION);
    const second = rows.find((row) => row.id === OTHER);

    expect(first?.route.map((point) => point.id)).toEqual([POINT_A]);
    expect(first?.splits.map((split) => split.id)).toEqual([SPLIT_A]);
    expect(second?.route.map((point) => point.id)).toEqual([POINT_B]);
    expect(second?.splits.map((split) => split.id)).toEqual([SPLIT_B]);

    expect(await rowCount(ALICE, "workout_route_points")).toBe(2);
  });

  it("takes an empty route as an affirmative claim, and replaces a stored one with it", async () => {
    await put(SESSION, measuredSession({ route: [POINT_A_WIRE, POINT_B_WIRE] }));
    expect(await rowCount(ALICE, "workout_route_points")).toBe(2);

    // The pair to the refusal in `the write shape` below, and the two have to be read together: an
    // *omitted* route is a 400 because a partial body must not delete a stored one, while an empty
    // array is a client stating this session has no route — which for a session recorded with the
    // toggle off is the ordinary case and not an error.
    await put(SESSION, measuredSession({ route: [] }));

    expect(await rowCount(ALICE, "workout_route_points")).toBe(0);
    expect((await session(ALICE, SESSION)).route).toEqual([]);
  });

  it("refuses a child id that is not a UUID", async () => {
    // Both children are held to the session's own pattern, because the app reads every stored id
    // through `UUID(uuidString:)` and *skips* what will not round-trip — so a point stored under
    // `"point-one"` is a row the app writes, cannot see, and reports no error about.
    const point = await put(SESSION, measuredSession({ route: [{ ...POINT_A_WIRE, id: "point-one" }] }));
    const split = await put(SESSION, measuredSession({ splits: [{ ...SPLIT_A_WIRE, id: "split-one" }] }));

    expect(point.status).toBe(400);
    expect((await point.json() as ErrorWire).error.message).toContain("route.0.id");
    expect(split.status).toBe(400);
    expect((await split.json() as ErrorWire).error.message).toContain("splits.0.id");

    expect(await rowCount(ALICE)).toBe(0);
  });
});

describe("NULL is not 0", () => {
  let absent: WorkoutWire;
  let zero: WorkoutWire;

  beforeEach(async () => {
    // The two rows differ in their *columns* — one carries nothing, one carries measured zeroes —
    // and the children are `ownChildren`'s rule rather than part of that contrast: `absentSession`
    // forwards to `measuredSession`, so both would otherwise claim the same two route points and the
    // same split in this one partition.
    await put(SESSION, absentSession(ownChildren(0)));
    await put(
      OTHER,
      absentSession({
        strain: 0,
        steps: 0,
        hrZonePercents: new Array<number>(ZONE_COUNT).fill(0),
        ...ownChildren(1),
      }),
    );

    absent = await session(ALICE, SESSION);
    zero = await session(ALICE, OTHER);
  });

  it("carries every nullable column back as a key that is present and null", async () => {
    for (const key of [
      "strain",
      "averageHeartRate",
      "maxHeartRate",
      "source",
      "activityName",
      "hrZonePercents",
      "steps",
      "offlineRegionID",
    ] as const) {
      // Present at all — a stripped key would be a third state that means nothing, which is why the
      // schema declares `.nullable()` and never `.optional()`.
      expect(Object.hasOwn(absent, key)).toBe(true);
      expect(absent[key]).toBeNull();
    }

    // The three columns `v18` made nullable in the app, and the reason it exists: a Zero fast
    // measures none of them, and a `0` in any of the three reads as a measurement.
    expect([absent.strain, absent.averageHeartRate, absent.maxHeartRate]).toEqual([
      null,
      null,
      null,
    ]);
  });

  it("keeps a measured zero as a zero, so the near miss is asserted rather than assumed", async () => {
    // The other half of the pair, and the half a `?? 0` in the adapter would destroy: it would make
    // every absence above indistinguishable from these. `steps` is the sharpest of the three because
    // the app's own reader gates on `measuredSeconds > 0` — a session that saw no motion is an
    // absence, a session that measured motion and counted nothing is a real zero.
    expect(zero.strain).toBe(0);
    expect(zero.steps).toBe(0);
    expect(zero.hrZonePercents).toEqual([0, 0, 0, 0, 0]);

    // And the block is the one place the two states are a *pair* rather than a value: a measured
    // `[0, 0, 0, 0, 0]` is a session that reached no band, which is 45 of the app's 673 imported rows;
    // `null` is a session with no zone block at all. `?? [0, ...]` would collapse them.
    expect(absent.hrZonePercents).toBeNull();
  });

  it("leaves the nullable columns alone when the session carries no measurement at all", async () => {
    // A session with no strain and no heart rate is a fast, and the four columns that are ordinary
    // strings are absent on it too rather than defaulted to a plausible label — `source` in
    // particular, because a `"whoop_export"` written on a row nothing imported is a false claim
    // about a producer.
    expect(absent.source).toBeNull();
    expect(absent.activityName).toBeNull();
    expect(absent.offlineRegionID).toBeNull();
  });
});

describe("the zone block", () => {
  it("refuses a block whose shares sum to more than 100", async () => {
    // 101. The rule is a ceiling rather than an equality because time below zone 1 belongs to no
    // band, so the five shares legitimately sum to less than the session — which is why a
    // `sum === 100` test would refuse 45 of the app's own 673 imported rows.
    const response = await put(SESSION, measuredSession({ hrZonePercents: [12, 40, 33, 10, 6] }));

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("sum to at most 100");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("accepts a block summing to exactly 100, because the ceiling is inclusive", async () => {
    // The boundary from the inside: a `< 100` spelled for a `<= 100` would refuse this and pass every
    // other test in this block, since nothing else here is at the edge.
    const response = await put(SESSION, measuredSession({ hrZonePercents: [12, 40, 33, 10, 5] }));

    expect(response.status).toBe(200);
    expect((await session(ALICE, SESSION)).hrZonePercents).toEqual([12, 40, 33, 10, 5]);
  });

  it("refuses a block that is not five shares long, in either direction", async () => {
    // Four and six. A length rule rather than a `<=`, because the app draws one row per band: a
    // stored block of four would draw a short column with zone 5 missing, and a stored block of six
    // has a share nothing on any screen reads.
    const short = await put(SESSION, measuredSession({ hrZonePercents: [12, 40, 33, 10] }));
    const long = await put(SESSION, measuredSession({ hrZonePercents: [12, 40, 33, 10, 5, 0] }));

    expect(short.status).toBe(400);
    expect(long.status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a fractional share even when the block would otherwise pass", async () => {
    // 99.5, so the sum rule is satisfied and the integer rule is the only thing that can refuse it.
    // Every one of the app's 3,365 exported shares is a whole number, and a percent is what the app
    // divides by a duration to print a row's seconds — so a fraction is a value from some other
    // producer, and rounding it would invent a reading rather than lose one.
    const response = await put(SESSION, measuredSession({ hrZonePercents: [12.5, 40, 33, 10, 4] }));

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    expect(await rowCount(ALICE)).toBe(0);
  });
});

describe("the write shape", () => {
  it("refuses a body that carries an id of its own rather than stripping it", async () => {
    const response = await put(SESSION, { ...measuredSession(), id: OTHER });

    // `.strict()`, and the failure it prevents is the quietest in this file: a client posting to one
    // id and believing another was written. A silent strip answers `200` and the session is not where
    // the client will look for it.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a body that omits its route rather than reading the omission as an empty one", async () => {
    await put(SESSION, measuredSession({ route: [POINT_A_WIRE, POINT_B_WIRE] }));

    const response = await put(SESSION, without(measuredSession(), "route"));

    // **This is the assertion the aggregate most needs**, and it is a pair with the empty-array test
    // in `the children`. Every column on this schema is required — no `.optional()` anywhere — because
    // an omitted one would have to be read as some value, and for `route` the only candidate is the
    // empty one, which is a claim that this session has no route. A client assembling a partial body
    // would therefore delete a stored route and be told the write succeeded.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("route");

    // And the refusal is the only thing standing between that body and the deletion, so the stored
    // route is asserted still to be there rather than merely asserted un-refused.
    expect((await session(ALICE, SESSION)).route.map((point) => point.id)).toEqual([
      POINT_A,
      POINT_B,
    ]);
  });

  it("refuses a body missing its day", async () => {
    const response = await put(SESSION, without(measuredSession(), "date"));

    // The day is in the body here and in the path on the sibling resource, so this is the half that
    // has no other spelling. It is **not** derived from `startedAt`: it is the client's own
    // `startOfDay` in the device's calendar, and a Worker in UTC cannot know which zone filed a 22:40
    // session on the day it started or the day it ended — see the migration's own note.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("date");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a session that ends before it starts, or at the same instant", async () => {
    for (const endedAt of ["2026-08-22T07:00:00.000Z", "2026-08-22T07:15:00.000Z"]) {
      const response = await put(SESSION, measuredSession({ endedAt }));

      // The second is `endedAt === startedAt`, and it is refused rather than accepted: a session of
      // zero length is not a duration, and every figure downstream divides by one — the app's own
      // zone rows scale a share by the session's span, so a zero span is a division by zero behind a
      // `200`.
      expect(response.status).toBe(400);
      expect((await response.json() as ErrorWire).error.message).toContain("endedAt");
    }

    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses an instant that is not the canonical form", async () => {
    const response = await put(SESSION, measuredSession({ startedAt: "2026-08-22 07:15:00" }));

    // The export writes `2026-08-22 00:17:13`, so this is the shape a parser built on
    // `ISO8601DateFormatter` would hand over having read nothing. Storing it would make a session's
    // instants sort as text in a column the window read orders by, and `started_at`'s ordering is
    // what puts a day's sessions in sequence.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("startedAt");
    expect(await rowCount(ALICE)).toBe(0);
  });
});

describe("a session with no row", () => {
  it("is a 404 naming the code, not a zero-filled row", async () => {
    await put(OTHER, measuredSession());

    const response = await read(`/v1/workouts/${SESSION}`);

    expect(response.status).toBe(404);
    // `not_found` and **not** the sibling's `no_measurement_for_day`. That code names a day, and
    // nothing in this resource is addressed by one — a client switching on the sibling's code here
    // would match an arm this API can never send, which is why the two are separate members of the
    // one enum rather than one member reused.
    expect(await response.json()).toEqual({
      error: { code: "not_found", message: `no session with id ${SESSION} in this partition` },
    });
  });

  it("refuses a path parameter that could not name a session at all", async () => {
    const response = await read("/v1/workouts/this-morning");

    // A 400 and not a 404, because the two say different things: this string cannot be an id, so the
    // request never asked about a row. Answering 404 would tell a client its well-formed request
    // found nothing, and the client would go on sending the string.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("is omitted from a window rather than zero-filled", async () => {
    await put(SESSION, measuredSession({ ...sessionOn("2026-08-20"), ...ownChildren(0) }));
    await put(OTHER, measuredSession({ ...sessionOn("2026-08-22"), ...ownChildren(1) }));

    const rows = await window("days=4&endingOn=2026-08-22");

    // 08-21 is inside the window and absent from the answer. An empty array would be a real answer
    // too — "nothing in this window was measured" — which is why the omission, not the count, is the
    // assertion.
    expect(rows.map((row) => row.id)).toEqual([SESSION, OTHER]);
  });
});

describe("the window", () => {
  const DAYS = [
    "2026-08-18",
    "2026-08-19",
    "2026-08-20",
    "2026-08-21",
    "2026-08-22",
    "2026-08-23",
  ];

  beforeEach(async () => {
    // Six sessions, six days, and six sets of children: the days are what this block is about, and
    // the children are `ownChildren`'s rule — a partition is a partition whether the sessions arrive
    // one request at a time or six rows at once, so the defaults would collide here exactly as they
    // would inside a chunk.
    for (const [i, date] of DAYS.entries()) {
      await put(uuid(i), measuredSession({ ...sessionOn(date), ...ownChildren(i) }));
    }
  });

  it("returns days + 1 calendar days, oldest first", async () => {
    const rows = await window("days=2&endingOn=2026-08-22");

    // The app's own arithmetic, mirrored rather than corrected: `from = endingOn - days`, inclusive
    // at both ends, so `days: 14` is fifteen days. A ported call returns what it returned on-device,
    // and the off-by-one is a written-down fact instead of a surprise found later.
    expect(rows.map((row) => row.date)).toEqual(["2026-08-20", "2026-08-21", "2026-08-22"]);
  });

  it("takes days = 0 to mean the ending day alone", async () => {
    const rows = await window("days=0&endingOn=2026-08-22");

    expect(rows.map((row) => row.date)).toEqual(["2026-08-22"]);
  });

  it("returns an empty array for a window nothing covers", async () => {
    const response = await read("/v1/workouts?days=0&endingOn=2026-08-22");
    const rows = (await response.json()) as WorkoutWire[];

    // Non-empty here, deliberately, so the assertion below is about a *different* window.
    expect(rows).toHaveLength(1);

    // "Nothing was measured in this window" is a real answer and the honest one — the alternative,
    // padding the window with a row per day, is the reserved-zero placeholder this repo's absence
    // rule exists to forbid.
    expect(await window("days=0&endingOn=2020-01-01")).toEqual([]);
  });

  it("refuses a window wider than the service's ceiling", async () => {
    const response = await read(`/v1/workouts?days=${MAX_WINDOW_DAYS + 1}&endingOn=2026-08-22`);

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a non-numeric days rather than coercing it to a window", async () => {
    const response = await read("/v1/workouts?days=week&endingOn=2026-08-22");

    // `z.coerce.number()` turns this into `NaN`, and a handler that read `NaN` as "no bound" would
    // answer the caller's typo with the whole table.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("returns a day's sessions in the order they started", async () => {
    // A day holds several sessions — two runs and a ride is an ordinary Tuesday — so the day alone is
    // not an order. `SELECT_WINDOW` ties on `date`, then `started_at`, then `id`, and the first of
    // those tie-breaks is the one being asserted: written latest-first, read oldest-first.
    //
    // **The two rows here are `DAYS.length` on, because this describe's `beforeEach` has already
    // claimed rows 0…5.** That is `ownChildren`'s rule read rather than restated: a row index is
    // unique within a *partition*, and both sessions this test adds land in ALICE beside the six the
    // hook wrote — so reusing row 0 here is a constraint violation on the child table rather than a
    // second session with a second route. Spelled off `DAYS` rather than as `6`/`7` so that adding a
    // seventh day to the hook moves this with it.
    await put(SESSION, measuredSession({
      date: "2026-08-24",
      startedAt: "2026-08-24T18:00:00.000Z",
      endedAt: "2026-08-24T18:45:00.000Z",
      ...ownChildren(DAYS.length),
    }));
    await put(OTHER, measuredSession({ ...sessionOn("2026-08-24"), ...ownChildren(DAYS.length + 1) }));

    const rows = await window("days=0&endingOn=2026-08-24");

    expect(rows.map((row) => row.id)).toEqual([OTHER, SESSION]);
  });
});

describe("the partition", () => {
  it("keeps one user's session invisible to another", async () => {
    await put(SESSION, measuredSession(), ALICE);

    expect((await read(`/v1/workouts/${SESSION}`, ALICE)).status).toBe(200);
    // Nothing verifies the header yet, so this is the `user_id` column doing real work: the row is
    // there, and a different owner cannot reach it.
    expect((await read(`/v1/workouts/${SESSION}`, BOB)).status).toBe(404);
    expect(await window("days=2&endingOn=2026-08-22", BOB)).toEqual([]);
  });

  it("lets two users hold the same session id without colliding, children and all", async () => {
    await put(SESSION, measuredSession({ strain: 7.4, route: [POINT_A_WIRE] }), ALICE);
    await put(SESSION, measuredSession({ strain: 12.1, route: [POINT_B_WIRE] }), BOB);

    expect((await session(ALICE, SESSION)).strain).toBe(7.4);
    expect((await session(BOB, SESSION)).strain).toBe(12.1);

    // **The children are the half this table's keying makes non-obvious.** Both child tables carry
    // `user_id` and are keyed `(user_id, id)`, so the same session id under two partitions is two
    // disjoint sets of children rather than a collision — and the read is scoped by `user_id` too, so
    // neither caller can see the other's fixes. A child table keyed on `workout_id` alone would have
    // the second write's route appear under the first caller's session.
    expect((await session(ALICE, SESSION)).route.map((point) => point.id)).toEqual([POINT_A]);
    expect((await session(BOB, SESSION)).route.map((point) => point.id)).toEqual([POINT_B]);
    expect(await rowCount(ALICE, "workout_route_points")).toBe(1);
    expect(await rowCount(BOB, "workout_route_points")).toBe(1);
  });

  it("files the row under the digest of the key, never under the key", async () => {
    await put(SESSION, measuredSession());

    // The two reads are the assertion, and the second is the one that matters. The first says the row
    // is reachable at all; the second says the column holds something that is *not* the header, which
    // is the whole of what a D1 dump leaking no usable credentials means. A `user_id` equal to `ALICE`
    // would satisfy every other test in this file — the requests would still work, because the same
    // string would be hashed on the way in and matched on the way out — and would be a database of
    // working keys.
    expect(await rowCount(ALICE)).toBe(1);

    const keyed = await env.DB.prepare("SELECT COUNT(*) AS n FROM workouts WHERE user_id = ?")
      .bind(ALICE)
      .first<{ n: number }>();

    expect(keyed?.n).toBe(0);
  });
});

describe("identity", () => {
  it("refuses a request with no X-Whoopsy-User-Id", async () => {
    const response = await SELF.fetch(`${BASE}/v1/workouts?days=2&endingOn=2026-08-22`);

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses an empty X-Whoopsy-User-Id", async () => {
    const response = await read(`/v1/workouts/${SESSION}`, "");

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a key one character below the floor", async () => {
    const short = "a".repeat(MIN_KEY_LENGTH - 1);

    // The boundary from the inside, because the guard is a length test and an off-by-one is its only
    // realistic defect: `>=` spelled `>` would admit exactly this string and pass every other test in
    // this file, including the empty-key one above — nothing else here is near the edge.
    expect((await read(`/v1/workouts/${SESSION}`, short)).status).toBe(400);

    // And one character above it is accepted, so the pair pins a boundary rather than restating a
    // refusal that a blank check would also produce.
    expect((await read(`/v1/workouts/${SESSION}`, "a".repeat(MIN_KEY_LENGTH))).status).toBe(404);
  });
});

describe("a chunk of sessions", () => {
  it("answers with a tally of sessions, not of the rows they are made of", async () => {
    const rows = [
      sessionRow(SESSION, {
        route: [POINT_A_WIRE, POINT_B_WIRE, POINT_C_WIRE],
        splits: [SPLIT_A_WIRE, SPLIT_B_WIRE],
      }),
      sessionRow(OTHER, { route: [], splits: [] }),
    ];

    const response = await postBatch({ rows });
    expect(response.status).toBe(200);
    // **Two.** The aggregate's signature figure, and the one a reader will get wrong: ten statements
    // reached the database for it — two parent upserts, four child deletes, three route inserts and
    // two split inserts — and seven of them report a changed row. `upsertMany` sums
    // `result.meta.changes` at the parent indices only, because the tally's meaning is "how many
    // sessions did the server take", and a client comparing it against its own array length is the
    // caller this exists for.
    expect(await response.json()).toEqual({ written: 2 });

    // The reads are the assertion that the tally was about real rows: a `written` counted from the
    // request's own array would be the same number here, and would disagree with the tables the
    // moment an upsert stopped landing.
    expect(await rowCount(ALICE)).toBe(2);
    expect(await rowCount(ALICE, "workout_route_points")).toBe(3);
    expect(await rowCount(ALICE, "workout_splits")).toBe(2);

    const rowsBack = await window("days=0&endingOn=2026-08-22");
    expect(rowsBack.find((row) => row.id === SESSION)?.route.map((point) => point.id)).toEqual([
      POINT_A,
      POINT_B,
      POINT_C,
    ]);
  });

  it("answers the same number for a replayed chunk and moves no row", async () => {
    const rows = [sessionRow(SESSION, ownChildren(0)), sessionRow(OTHER, ownChildren(1))];

    const first = await postBatch({ rows });
    const second = await postBatch({ rows });

    expect(await first.json()).toEqual({ written: 2 });
    // **Not zero.** `INSERT … ON CONFLICT DO UPDATE` counts a row it matched as changed even when
    // every value is byte-identical, so a replayed chunk reports the same figure as the first send.
    // That is the honest answer — the statement did write that row — and it is why `written: 0` must
    // never be read as "there was nothing to do": nothing in this API answers `0` for a non-empty
    // batch. A client that treated 0 as a completion signal would hang on a retry that succeeded.
    expect(await second.json()).toEqual({ written: 2 });

    // And idempotence is a claim about the tables, not about the number — including the children,
    // which are deleted and re-inserted rather than upserted, so a second write that appended them
    // would answer `2` above and `4` here.
    expect(await rowCount(ALICE)).toBe(2);
    expect(await rowCount(ALICE, "workout_route_points")).toBe(4);
    expect(await rowCount(ALICE, "workout_splits")).toBe(2);
  });

  it("writes a full chunk of the cap in one request", async () => {
    const rows = Array.from({ length: MAX_BATCH_WORKOUTS }, (_, i) =>
      sessionRow(uuid(i), { route: [], splits: [] }),
    );

    const response = await postBatch({ rows });

    expect(response.status).toBe(200);
    // The cap is the app's whole history in four requests, so this is the real corpus's chunk size
    // rather than a round number — and `written` is the assertion that would catch a `NaN` from a
    // `meta.changes` this runtime did not report. `@cloudflare/workers-types` declares it
    // non-optional, so a sum that came back `NaN` would be a fact about miniflare rather than about
    // the types, and this is the only assertion in the suite that would see it.
    expect(await response.json()).toEqual({ written: MAX_BATCH_WORKOUTS });
    expect(await rowCount(ALICE)).toBe(MAX_BATCH_WORKOUTS);
  });

  it("refuses a chunk one session past the cap, and writes nothing", async () => {
    const rows = Array.from({ length: MAX_BATCH_WORKOUTS + 1 }, (_, i) =>
      sessionRow(uuid(i), { route: [], splits: [] }),
    );

    const response = await postBatch({ rows });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    // Nothing, not "the first two hundred". The cap is a refusal rather than a truncation because a
    // client whose chunk was silently trimmed would believe the whole range had been uploaded.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a session id carried twice, and writes nothing", async () => {
    const rows = [sessionRow(SESSION), sessionRow(OTHER)];
    const response = await postBatch({ rows: [...rows, rows[1]!] });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    // The alternative is *nearly* harmless — the second write wins and the session on disk is
    // whichever the array put last — which is exactly the failure: a `200` whose result depends on
    // the order of an array the client built, reported as success.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("accepts two rows sharing a day, which is the rule the sibling resource inverts", async () => {
    const rows = [
      sessionRow(SESSION, { ...sessionOn("2026-08-22"), ...ownChildren(0) }),
      sessionRow(
        OTHER,
        {
          ...sessionOn("2026-08-22", {
            startedAt: "2026-08-22T18:00:00.000Z",
            endedAt: "2026-08-22T18:45:00.000Z",
          }),
          ...ownChildren(1),
        },
      ),
    ];

    const response = await postBatch({ rows });

    // **Read beside the duplicate-id refusal above, not on its own.** `recoveries` refuses a date
    // carried twice because its primary key is the day; here two rows on one day are the ordinary
    // case and the uniqueness check is on `id`. The pair of assertions is what pins which key the
    // check is on, and neither alone can tell the right rule from the wrong one: a check written
    // against `date` passes the refusal above and fails this.
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ written: 2 });
    expect(await rowCount(ALICE)).toBe(2);
  });

  it("refuses an empty chunk", async () => {
    const response = await postBatch({ rows: [] });

    // A `200` with `written: 0` would render as "a successful sync of nothing", indistinguishable
    // from a chunk that worked.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a row that carries no id of its own", async () => {
    const response = await postBatch({ rows: [measuredSession()] });

    // The id is in the path on the `PUT` and in the body here, so this is the half that has no other
    // spelling: a row without one would have to be keyed on something, and the day is the one
    // candidate that must not be used — it is what makes the second session overwrite the first.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("rows.0.id");
  });

  it("refuses a row carrying a field the contract does not have", async () => {
    const rows = [sessionRow(SESSION), sessionRow(OTHER)];
    const response = await postBatch({
      rows: [rows[0], { ...rows[1], strainScore: 12.1 }],
    });

    // `.strict()`, and it matters more at this volume than on the single-session body: a batch is
    // assembled by a client out of its own database, and a misspelled field in one row of two
    // hundred is exactly the failure a silent strip turns into one session written with a `null` in
    // it and a `200` beside it. The path names the row, which is what makes it findable among 200.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("rows.1");
  });

  it("refuses a chunk within its session cap but over the aggregate's route cap", async () => {
    // Two rows, each carrying half the aggregate ceiling plus one point: 2,002 in total against a
    // ceiling of 2,000, while each row is comfortably inside the per-session cap of 2,000.
    //
    // **The two ids ranges are disjoint on purpose.** `workout_route_points` is keyed
    // `(user_id, id)` and the insert is a plain `INSERT`, so the same point id under two sessions in
    // one batch is a constraint violation rather than a duplicate — a different test, and one this
    // fixture must not accidentally become.
    const perRow = Math.ceil(MAX_BATCH_ROUTE_POINTS / 2) + 1;
    const points = (offset: number) =>
      Array.from({ length: perRow }, (_, i) => ({
        id: uuid(offset + i),
        latitude: 51.5,
        longitude: -0.12,
        timestamp: "2026-08-22T07:15:30.000Z",
        heartRate: 120,
      }));

    const response = await postBatch({
      rows: [
        sessionRow(SESSION, { route: points(1000), splits: [] }),
        sessionRow(OTHER, { route: points(2000), splits: [] }),
      ],
    });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("route points or splits");

    // Nothing, even though each row alone would have been accepted. This is the ceiling that exists
    // because the chunk is one transaction: 200 sessions of 2,000 points each is 400,000 statements
    // in a single `batch()`, and the refusal is what keeps the request from being one D1 will not
    // take.
    expect(await rowCount(ALICE)).toBe(0);
    expect(await rowCount(ALICE, "workout_route_points")).toBe(0);
  });

  it("accepts a chunk at exactly the aggregate's route cap", async () => {
    // The boundary from the inside, and the assertion that separates the aggregate ceiling from the
    // per-session one: `MAX_BATCH_ROUTE_POINTS` is 2,000 and `MAX_ROUTE_POINTS` is also 2,000, so a
    // rule written against either constant passes the refusal above — 2,002 is over both. Split
    // across two rows at 1,000 each, only the aggregate rule permits it, and this is the request that
    // proves which rule is in force.
    const perRow = MAX_BATCH_ROUTE_POINTS / 2;
    const points = (offset: number) =>
      Array.from({ length: perRow }, (_, i) => ({
        id: uuid(offset + i),
        latitude: 51.5,
        longitude: -0.12,
        timestamp: "2026-08-22T07:15:30.000Z",
        heartRate: 120,
      }));

    const response = await postBatch({
      rows: [
        sessionRow(SESSION, { route: points(1000), splits: [] }),
        sessionRow(OTHER, { route: points(2000), splits: [] }),
      ],
    });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ written: 2 });
    expect(await rowCount(ALICE, "workout_route_points")).toBe(MAX_BATCH_ROUTE_POINTS);
  });

  it("refuses a chunk over the aggregate's split cap", async () => {
    // The same rule on the sibling child, with a fixture that is cheap to build and still past the
    // edge: 101 splits a row against a per-session cap of 200, so 202 in total is the aggregate's
    // ceiling and nothing else's.
    const perRow = Math.ceil(MAX_BATCH_SPLITS / 2) + 1;
    const splits = (offset: number) =>
      Array.from({ length: perRow }, (_, i) => ({
        id: uuid(offset + i),
        elapsed: 300,
        strain: 3.2,
      }));

    const response = await postBatch({
      rows: [
        sessionRow(SESSION, { route: [], splits: splits(1000) }),
        sessionRow(OTHER, { route: [], splits: splits(2000) }),
      ],
    });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("route points or splits");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("never deletes a session the caller leaves out", async () => {
    const rows = [
      sessionRow(SESSION, { ...sessionOn("2026-08-20"), ...ownChildren(0) }),
      sessionRow(OTHER, { ...sessionOn("2026-08-21"), ...ownChildren(1) }),
    ];
    await postBatch({ rows });

    // One session of the two, alone in the chunk.
    await postBatch({ rows: [rows[1]!] });

    // Both are still there, and the one the second chunk carried is still there *once*. This is why
    // the endpoint is a `POST` on `/batch` and not a `PUT` on the collection: "these are the
    // sessions" obliges the server to remove the ones left out, and a client whose retry sent a
    // partial chunk — the rest of it lost to a timeout — would erase its own history while being
    // told the request succeeded.
    const rowsBack = await window("days=3&endingOn=2026-08-22");
    expect(rowsBack.map((row) => row.id)).toEqual([SESSION, OTHER]);
    expect(await rowCount(ALICE)).toBe(2);
  });

  it("keeps one caller's chunk out of another's partition", async () => {
    await postBatch({ rows: [sessionRow(SESSION, ownChildren(0)), sessionRow(OTHER, ownChildren(1))] }, ALICE);
    const bobs = await postBatch({ rows: [sessionRow(SESSION)] }, BOB);

    expect(await bobs.json()).toEqual({ written: 1 });

    expect(await rowCount(ALICE)).toBe(2);
    expect(await rowCount(BOB)).toBe(1);

    const rows = await window("days=2&endingOn=2026-08-22", BOB);
    expect(rows.map((row) => row.id)).toEqual([SESSION]);
  });
});

describe("the chunk's transaction", () => {
  /**
   * The one thing in this file that is evidence about D1 rather than about this Worker.
   *
   * `D1WorkoutRepository.upsertMany` writes a chunk through `env.DB.batch(...)` and relies on its
   * documented all-or-nothing behaviour for the promise the endpoint makes — *a failure writes
   * nothing and the same body can be sent again*. That promise is not reachable through HTTP with a
   * valid schema: every field a batch can carry is already checked by Zod, so there is no body that
   * passes validation and then fails in the database. Which means the only honest way to pin the
   * assumption is to make the database fail directly, the way the repository does when something is
   * wrong with the rows rather than with the request.
   *
   * **This is a probe, and it is written as one.** If miniflare's local D1 ever stops rolling a batch
   * back — the two databases this repo runs against are already documented to differ — this test is
   * where that is learned, rather than in a sync that half-wrote a chunk and reported the failure with
   * no way to tell how far it got. It matters more here than it does for `recoveries`: a session's
   * three tables are three statements, so a partial write is a session with a route and no splits, or
   * a route from the previous version of the body.
   */
  it("rolls a failed batch back rather than keeping the statements before it", async () => {
    const userId = await partition(ALICE);

    const lands = env.DB.prepare(
      "INSERT INTO workouts (user_id, id, date, started_at, ended_at) VALUES (?, ?, ?, ?, ?)",
    ).bind(userId, SESSION, "2026-08-22", "2026-08-22T07:15:00.000Z", "2026-08-22T08:15:00.000Z");

    // The second statement is missing every NOT NULL column but `user_id`, so it cannot land — and
    // it is the *second* deliberately: the question is whether the first one survives it.
    const fails = env.DB.prepare("INSERT INTO workouts (user_id) VALUES (?)").bind(userId);

    await expect(env.DB.batch([lands, fails])).rejects.toThrow();

    expect(await rowCount(ALICE)).toBe(0);
  });

  it("rolls a failed child insert back with its parent", async () => {
    const userId = await partition(ALICE);

    // The ordering this pins is `statementsFor`'s: parent first, then the child deletes and inserts.
    // A chunk that took the parent and lost the route would leave a session the client believes has a
    // path and the app draws as a session with none — which is a *plausible* row rather than a
    // missing one, and the reason the transaction is load-bearing here rather than merely tidy.
    const parent = env.DB.prepare(
      "INSERT INTO workouts (user_id, id, date, started_at, ended_at) VALUES (?, ?, ?, ?, ?)",
    ).bind(userId, SESSION, "2026-08-22", "2026-08-22T07:15:00.000Z", "2026-08-22T08:15:00.000Z");

    const child = env.DB.prepare(
      "INSERT INTO workout_route_points (user_id, id, workout_id, seq) VALUES (?, ?, ?, ?)",
    ).bind(userId, POINT_A, SESSION, 0);

    await expect(env.DB.batch([parent, child])).rejects.toThrow();

    expect(await rowCount(ALICE)).toBe(0);
    expect(await rowCount(ALICE, "workout_route_points")).toBe(0);
  });

  it("leaves the tables untouched when the repository's own chunk is refused", async () => {
    const rows = [sessionRow(SESSION), sessionRow(OTHER)];

    // Chunks that are refused *before* they reach D1 — here by the cap and by a repeated id — have
    // nothing to roll back, and the assertion is that the route validated before the service wrote
    // rather than after. Ordered against the two tests above on purpose: those cover the transaction
    // below the endpoint, this one covers the fact that a refusal above it never opens one.
    await postBatch({
      rows: Array.from({ length: MAX_BATCH_WORKOUTS + 1 }, (_, i) => sessionRow(uuid(i))),
    });
    await postBatch({ rows: [...rows, rows[0]!] });

    expect(await rowCount(ALICE)).toBe(0);
    expect(await rowCount(ALICE, "workout_route_points")).toBe(0);
  });
});
