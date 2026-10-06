import { SELF, env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { MAX_BATCH_ROWS, MAX_WINDOW_DAYS } from "../../src/services";
import { deriveUserId, MIN_KEY_LENGTH } from "../../src/utils/identity";

/**
 * The one resource, carried from HTTP through D1 and back.
 *
 * Every assertion below maps to a rule this repo has already paid for once, in the app — and the
 * app's own docs record what each cost. The point of the file is that those rules survive the trip
 * across a process boundary, where the failures they prevent are quieter than they are on-device: a
 * day key that got snapped instead of refused, a `NULL` that came back as `0`, an unmeasured day
 * that came back as a row of zeroes — none of those raise anything, and each produces a response a
 * client would happily draw.
 *
 * **The storage is fresh per test.** The pool's `isolatedStorage` is on, so the rows one `it`
 * writes are invisible to the next; nothing here clears a table by hand, and nothing depends on
 * another test having run.
 */

const BASE = "https://whoopsy.test";

/**
 * Two real keys, at the length the app sends: 32 random bytes, 43 base64url characters.
 *
 * **These were `"alice"` and `"bob"` and the header guard made them invalid**, which is the point of
 * writing them out at full width rather than shortening the guard to suit the fixtures. `MIN_KEY_LENGTH`
 * exists so a one-character header is not a partition, and a test suite that kept the short values
 * would be the first caller the rule broke — every assertion below would come back `400` and the
 * failure would read as a broken endpoint rather than as a fixture that no longer describes a client.
 *
 * They are *keys* and not user ids. What reaches the `user_id` column is `sha256` of one of these, so
 * every direct read against `env.DB` below goes through `partition(_:)` rather than binding the
 * literal — see that helper for why that is not merely convenience.
 */
const ALICE = "K7fQ2mZx9pLr4Tn6WvB1yHs8JcE3uGa5DkRm0Xq4YAb";
const BOB = "Qw3RtYuIoPaSdFgHjKlZxCvBnM1234567890abcdefg";

/**
 * The partition a key's rows live under — computed the way the Worker computes it.
 *
 * **This is deliberately not an independent implementation.** `tests/utils/identity.spec.ts` pins the
 * digest against a literal computed outside this codebase, which is the assertion that the derivation
 * is what it claims to be; what these tests need is a *handle* on the row a request just wrote, so
 * that a direct `SELECT` and the endpoint agree about which partition they are talking about. If they
 * disagreed, every count below would read `0` for a reason that has nothing to do with what it is
 * asserting.
 *
 * The alternative — binding the raw key — would silently assert that the `user_id` column holds the
 * header, which is the one thing `utils/identity.ts` exists to prevent.
 */
function partition(key: string): Promise<string> {
  return deriveUserId(key);
}

/** How many rows exist in one partition. `null` when the table is empty, so `?? 0` at the call site. */
async function rowCount(key: string, table = "recoveries"): Promise<number> {
  const counted = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`,
  )
    .bind(await partition(key))
    .first<{ n: number }>();

  return counted?.n ?? 0;
}

/** The wire shape, spelled out rather than inferred, so a renamed field fails here loudly. */
interface RecoveryWire {
  date: string;
  recoveryScore: number;
  restingHeartRate: number;
  hrvValueMs: number;
  hrvMetric: string;
  skinTemperature: number | null;
  spo2Percentage: number | null;
  respiratoryRate: number | null;
  source: string | null;
}

interface ErrorWire {
  error: { code: string; message: string };
}

/**
 * A measured day. The four nullable columns start `null` on purpose — that is the state most of
 * these assertions are about, and a fixture that filled them would make the absence rule untested.
 */
function measuredDay(overrides: Partial<RecoveryWire> = {}): Omit<RecoveryWire, "date"> {
  return {
    recoveryScore: 68,
    restingHeartRate: 52,
    hrvValueMs: 71.4,
    hrvMetric: "rmssd",
    skinTemperature: null,
    spo2Percentage: null,
    respiratoryRate: null,
    source: null,
    ...overrides,
  };
}

function put(date: string, body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/recoveries/${date}`, {
    method: "PUT",
    headers: { "content-type": "application/json", "x-whoopsy-user-id": userId },
    body: JSON.stringify(body),
  });
}

function read(path: string, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}${path}`, { headers: { "x-whoopsy-user-id": userId } });
}

function postBatch(body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/recoveries/batch`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-whoopsy-user-id": userId },
    body: JSON.stringify(body),
  });
}

/**
 * `n` consecutive days ending on `endingOn`, oldest first, each carrying its own day.
 *
 * A batch row is a `measuredDay()` plus a `date`, so the fixture the single-day tests already use is
 * reused rather than restated — a second `measuredDay`-shaped literal here would be free to drift
 * from the one the `PUT` body is built out of, and the whole point of the batch is that the two
 * bodies describe the same nine fields.
 */
function batchRows(endingOn: string, n: number): (Omit<RecoveryWire, "date"> & { date: string })[] {
  const rows: (Omit<RecoveryWire, "date"> & { date: string })[] = [];
  const end = Date.parse(`${endingOn}T00:00:00Z`);

  for (let i = n - 1; i >= 0; i--) {
    const day = new Date(end - i * 86_400_000).toISOString().slice(0, 10);
    rows.push({ date: day, ...measuredDay() });
  }

  return rows;
}

async function day(userId: string, date: string): Promise<RecoveryWire> {
  const response = await read(`/v1/recoveries/${date}`, userId);
  expect(response.status).toBe(200);
  return (await response.json()) as RecoveryWire;
}

describe("a day written and read back", () => {
  it("returns the stored row, not an echo of the request", async () => {
    const body = measuredDay();

    const written = await put("2026-08-22", body);
    expect(written.status).toBe(200);

    const stored = (await written.json()) as RecoveryWire;
    expect(stored).toEqual({ date: "2026-08-22", ...body });

    // The read is the assertion that the response was the database's answer rather than the
    // request's: the two agree here only because the write really happened.
    expect(await day(ALICE, "2026-08-22")).toEqual(stored);
  });

  it("replaces a day's row when the same day is written twice", async () => {
    await put("2026-08-22", measuredDay({ recoveryScore: 68 }));
    await put("2026-08-22", measuredDay({ recoveryScore: 71 }));

    // `saveRecovery` is INSERT-or-UPDATE by primary key, and `recoveries` is the table whose
    // primary key is the day — so a second write of one day must leave one row and not two.
    expect(await rowCount(ALICE)).toBe(1);
    expect((await day(ALICE, "2026-08-22")).recoveryScore).toBe(71);
  });
});

describe("NULL is not 0", () => {
  let stored: RecoveryWire;

  beforeEach(async () => {
    await put("2026-08-22", measuredDay());
    stored = await day(ALICE, "2026-08-22");
  });

  it("carries every nullable column back as a key that is present and null", async () => {
    for (const key of [
      "skinTemperature",
      "spo2Percentage",
      "respiratoryRate",
      "source",
    ] as const) {
      // Present at all — a stripped key would be a third state that means nothing, which is why the
      // schema declares `.nullable()` and never `.optional()`.
      expect(Object.hasOwn(stored, key)).toBe(true);
      expect(stored[key]).toBeNull();
    }
  });

  it("keeps a measured zero as a zero, so the near miss is asserted rather than assumed", async () => {
    await put("2026-08-23", measuredDay({ skinTemperature: 0 }));

    const zero = await day(ALICE, "2026-08-23");
    expect(zero.skinTemperature).toBe(0);
    // `?? 0` anywhere in the repository would make the two states above indistinguishable, and the
    // pair is what catches it: the absences stay null and the measurement stays zero.
    expect(Object.hasOwn(zero, "skinTemperature")).toBe(true);
  });

  it("refuses a body that carries a date of its own rather than stripping it", async () => {
    const response = await put("2026-08-22", { ...measuredDay(), date: "2026-08-23" });

    // `.strict()` on the write schema. A silently-dropped date is a client posting to one day and
    // believing another was written — a disagreement nothing downstream can see.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });
});

describe("the day key", () => {
  it("refuses a key carrying a time component", async () => {
    const response = await put("2026-08-22T13:45:00Z", measuredDay());

    // Refused, and deliberately not snapped. The app snaps because it can — `startOfDay` is the
    // device's own calendar — and a server cannot re-derive a client's midnight without the
    // client's zone. Snapping here would store a key the client's own read could not find, which is
    // the app's silent-unreachable-row failure moved somewhere the app cannot see it.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a calendar day that does not exist", async () => {
    // A regex alone lets this through and `Date.parse` rolls it forward to March 3, so the refusal
    // is the round-trip through `Date.UTC` rather than the shape of the string.
    const response = await put("2026-02-31", measuredDay());

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("stores nothing when it refuses", async () => {
    await put("2026-08-22T13:45:00Z", measuredDay());

    // Scoped to the partition rather than the whole table: an unqualified `COUNT(*) FROM recoveries`
    // is a claim about every caller's rows, and it would pass here for the wrong reason the day some
    // other test's storage leaked into this one.
    expect(await rowCount(ALICE)).toBe(0);
  });
});

describe("a day with no measurement", () => {
  it("is a 404 naming the code, not a zero-filled row", async () => {
    await put("2026-08-21", measuredDay());

    const response = await read("/v1/recoveries/2026-08-22");

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({
      error: {
        code: "no_measurement_for_day",
        message: "no recovery measured on 2026-08-22",
      },
    });
  });

  it("is omitted from a window rather than zero-filled", async () => {
    for (const date of ["2026-08-20", "2026-08-22"]) {
      await put(date, measuredDay());
    }

    const response = await read("/v1/recoveries?days=4&endingOn=2026-08-22");
    const rows = (await response.json()) as RecoveryWire[];

    // 08-21 is inside the window and absent from the answer. An empty array would be a real answer
    // too — "nothing in this window was measured" — which is why the omission, not the count, is
    // the assertion.
    expect(response.status).toBe(200);
    expect(rows.map((row) => row.date)).toEqual(["2026-08-20", "2026-08-22"]);
  });
});

describe("the window", () => {
  beforeEach(async () => {
    for (const date of [
      "2026-08-18",
      "2026-08-19",
      "2026-08-20",
      "2026-08-21",
      "2026-08-22",
      "2026-08-23",
    ]) {
      await put(date, measuredDay());
    }
  });

  it("returns days + 1 calendar days, oldest first", async () => {
    const response = await read("/v1/recoveries?days=2&endingOn=2026-08-22");
    const rows = (await response.json()) as RecoveryWire[];

    // The app's own arithmetic, mirrored rather than corrected: `from = endingOn - days`, inclusive
    // at both ends, so `days: 14` is fifteen days. A ported call returns what it returned on-device,
    // and the off-by-one is a written-down fact instead of a surprise found later.
    expect(rows.map((row) => row.date)).toEqual(["2026-08-20", "2026-08-21", "2026-08-22"]);
  });

  it("takes days = 0 to mean the ending day alone", async () => {
    const response = await read("/v1/recoveries?days=0&endingOn=2026-08-22");
    const rows = (await response.json()) as RecoveryWire[];

    expect(rows.map((row) => row.date)).toEqual(["2026-08-22"]);
  });

  it("refuses a window wider than the service's ceiling", async () => {
    const response = await read(`/v1/recoveries?days=${MAX_WINDOW_DAYS + 1}&endingOn=2026-08-22`);

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a non-numeric days rather than coercing it to a window", async () => {
    const response = await read("/v1/recoveries?days=fortnight&endingOn=2026-08-22");

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });
});

describe("the partition", () => {
  it("keeps one user's day invisible to another", async () => {
    await put("2026-08-22", measuredDay(), ALICE);

    expect((await read("/v1/recoveries/2026-08-22", ALICE)).status).toBe(200);
    // Nothing verifies the header yet, so this is the `user_id` column doing real work: the row is
    // there, and a different owner cannot reach it.
    expect((await read("/v1/recoveries/2026-08-22", BOB)).status).toBe(404);

    const list = await read("/v1/recoveries?days=2&endingOn=2026-08-22", BOB);
    expect(await list.json()).toEqual([]);
  });

  it("lets two users hold the same day without colliding", async () => {
    await put("2026-08-22", measuredDay({ recoveryScore: 68 }), ALICE);
    await put("2026-08-22", measuredDay({ recoveryScore: 91 }), BOB);

    expect((await day(ALICE, "2026-08-22")).recoveryScore).toBe(68);
    expect((await day(BOB, "2026-08-22")).recoveryScore).toBe(91);
  });

  it("files the row under the digest of the key, never under the key", async () => {
    await put("2026-08-22", measuredDay());

    // The two reads are the assertion, and the second is the one that matters. The first says the
    // row is reachable at all; the second says the column holds something that is *not* the header,
    // which is the whole of what a D1 dump leaking no usable credentials means. A `user_id` equal to
    // `ALICE` would satisfy every other test in this file — the requests would still work, because
    // the same string would be hashed on the way in and matched on the way out — and would be a
    // database of working keys.
    expect(await rowCount(ALICE)).toBe(1);

    const keyed = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM recoveries WHERE user_id = ?",
    )
      .bind(ALICE)
      .first<{ n: number }>();

    expect(keyed?.n).toBe(0);
  });
});

describe("identity", () => {
  it("refuses a request with no X-Whoopsy-User-Id", async () => {
    const response = await SELF.fetch(`${BASE}/v1/recoveries?days=2&endingOn=2026-08-22`);

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses an empty X-Whoopsy-User-Id", async () => {
    const response = await read("/v1/recoveries/2026-08-22", "");

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a key one character below the floor", async () => {
    const short = "a".repeat(MIN_KEY_LENGTH - 1);

    // The boundary from the inside, because the guard is a length test and an off-by-one is its only
    // realistic defect: `>=` spelled `>` would admit exactly this string and pass every other test in
    // this file, including the empty-key one above — nothing else here is near the edge.
    expect((await read("/v1/recoveries/2026-08-22", short)).status).toBe(400);

    // And one character above it is accepted, so the pair pins a boundary rather than restating a
    // refusal that a blank check would also produce.
    expect((await read("/v1/recoveries/2026-08-22", "a".repeat(MIN_KEY_LENGTH))).status).toBe(404);
  });
});

describe("a chunk of days", () => {
  it("writes every row and answers with the database's tally", async () => {
    const rows = batchRows("2026-08-22", 3);

    const response = await postBatch({ rows });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ written: 3 });

    // The read is the assertion that the tally was about real rows: a `written` counted from the
    // request's own array would be the same number here, and would disagree with the table the moment
    // an upsert stopped landing.
    expect(await rowCount(ALICE)).toBe(3);

    const list = await read("/v1/recoveries?days=3&endingOn=2026-08-22");
    expect(((await list.json()) as RecoveryWire[]).map((row) => row.date)).toEqual([
      "2026-08-20",
      "2026-08-21",
      "2026-08-22",
    ]);
  });

  it("answers the same number for a replayed chunk and moves no row", async () => {
    const rows = batchRows("2026-08-22", 3);

    const first = await postBatch({ rows });
    const second = await postBatch({ rows });

    expect(await first.json()).toEqual({ written: 3 });
    // **Not zero.** `INSERT … ON CONFLICT DO UPDATE` counts a row it matched as changed even when
    // every value is byte-identical, so a replayed chunk reports the same figure as the first send.
    // That is the honest answer — the statement did write that row — and it is why `written: 0` must
    // never be read as "there was nothing to do": nothing in this API answers `0` for a non-empty
    // batch. A client that treated 0 as a completion signal would hang on a retry that succeeded.
    expect(await second.json()).toEqual({ written: 3 });

    // And idempotence is a claim about the table, not about the number: the chunk is keyed on the
    // same `(userId, date)` pair the single-day `PUT` writes, so replaying it cannot append.
    expect(await rowCount(ALICE)).toBe(3);
  });

  it("writes a full chunk of the cap in one request", async () => {
    const rows = batchRows("2026-08-22", MAX_BATCH_ROWS);

    const response = await postBatch({ rows });

    expect(response.status).toBe(200);
    // The cap is the app's whole history in five requests, so this is the real corpus's chunk size
    // rather than a round number — and `written` is the assertion that would catch a `NaN` from a
    // `meta.changes` this runtime did not report. `@cloudflare/workers-types` declares it
    // non-optional, so a sum that came back `NaN` would be a fact about miniflare rather than about
    // the types, and this is the only assertion in the suite that would see it.
    expect(await response.json()).toEqual({ written: MAX_BATCH_ROWS });
    expect(await rowCount(ALICE)).toBe(MAX_BATCH_ROWS);
  });

  it("refuses a chunk one row past the cap, and writes nothing", async () => {
    const response = await postBatch({ rows: batchRows("2026-08-22", MAX_BATCH_ROWS + 1) });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    // Nothing, not "the first two hundred". The cap is a refusal rather than a truncation because a
    // client whose chunk was silently trimmed would believe the whole range had been uploaded.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a day carried twice, and writes nothing", async () => {
    const rows = batchRows("2026-08-22", 2);
    const response = await postBatch({ rows: [...rows, rows[1]!] });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    // The alternative is *nearly* harmless — the second write wins and the row on disk is whichever
    // the array put last — which is exactly the failure: a `200` whose result depends on the order of
    // an array the client built, reported as success.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses an empty chunk", async () => {
    const response = await postBatch({ rows: [] });

    // A `200` with `written: 0` would render as "a successful sync of nothing", indistinguishable
    // from a chunk that worked.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a row that carries no day of its own", async () => {
    const response = await postBatch({ rows: [measuredDay()] });

    // The day is in the body here and in the path on the `PUT`, so this is the half that has no
    // other spelling: a row without one would have to be filed somewhere, and anywhere is a guess.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("rows.0.date");
  });

  it("refuses a row carrying a field the contract does not have", async () => {
    const rows = batchRows("2026-08-22", 2);
    const response = await postBatch({
      rows: [rows[0], { ...rows[1], recoveryScor: 71 }],
    });

    // `.strict()`, and it matters more at this volume than on the single-day body: a batch is
    // assembled by a client out of its own database, and a misspelled field in one row of two
    // hundred is exactly the failure a silent strip turns into one day written with a `null` in it
    // and a `200` beside it. The path names the row, which is what makes it findable among 200.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("rows.1");
  });

  it("lands on the day keys the single-day write uses", async () => {
    await put("2026-08-22", measuredDay({ recoveryScore: 68 }));

    const response = await postBatch({
      rows: [{ date: "2026-08-22", ...measuredDay({ recoveryScore: 71 }) }, { date: "2026-08-23", ...measuredDay() }],
    });

    expect(response.status).toBe(200);
    // Three claims in one pair. The day the `PUT` wrote is *replaced* rather than duplicated, so the
    // batch and the single-day write share one key — which is the whole of what `partitionFor` exists
    // for, since a batch that hashed the header differently from the `PUT` would file the same day in
    // two partitions and neither request would report anything.
    expect(await rowCount(ALICE)).toBe(2);
    expect((await day(ALICE, "2026-08-22")).recoveryScore).toBe(71);

    // And a day with no row yet is inserted by the same call, so the two verbs are one upsert.
    expect((await day(ALICE, "2026-08-23")).recoveryScore).toBe(68);
  });

  it("never deletes a day the caller leaves out", async () => {
    const rows = batchRows("2026-08-22", 3);
    await postBatch({ rows });

    // One day of the three, alone in the chunk.
    await postBatch({ rows: [rows[1]!] });

    const list = await read("/v1/recoveries?days=3&endingOn=2026-08-22");
    // All three are still there. This is why the endpoint is a `POST` on `/batch` and not a `PUT` on
    // the collection: "these are the days" obliges the server to remove the ones left out, and a
    // client whose retry sent a *partial* chunk — the rest of it lost to a timeout — would erase its
    // own history while being told the request succeeded.
    expect(((await list.json()) as RecoveryWire[]).map((row) => row.date)).toEqual([
      "2026-08-20",
      "2026-08-21",
      "2026-08-22",
    ]);
    expect(await rowCount(ALICE)).toBe(3);
  });

  it("keeps one caller's chunk out of another's partition", async () => {
    await postBatch({ rows: batchRows("2026-08-22", 3) }, ALICE);
    const bobs = await postBatch({ rows: batchRows("2026-08-22", 1) }, BOB);

    expect(await bobs.json()).toEqual({ written: 1 });

    expect(await rowCount(ALICE)).toBe(3);
    expect(await rowCount(BOB)).toBe(1);

    const list = await read("/v1/recoveries?days=3&endingOn=2026-08-22", BOB);
    expect(((await list.json()) as RecoveryWire[]).map((row) => row.date)).toEqual(["2026-08-22"]);
  });
});

describe("the chunk's transaction", () => {
  /**
   * The one thing in this file that is evidence about D1 rather than about this Worker.
   *
   * `D1RecoveryRepository.upsertMany` writes a chunk through `env.DB.batch(...)` and relies on its
   * documented all-or-nothing behaviour for the promise the endpoint makes — *a failure writes nothing
   * and the same body can be sent again*. That promise is not reachable through HTTP with a valid
   * schema: every field a batch can carry is already checked by Zod, so there is no body that passes
   * validation and then fails in the database. Which means the only honest way to pin the assumption
   * is to make the database fail directly, the way the repository does when something is wrong with
   * the rows rather than with the request.
   *
   * **This is a probe, and it is written as one.** If miniflare's local D1 ever stops rolling a batch
   * back — the two databases this repo runs against are already documented to differ — this test is
   * where that is learned, rather than in a sync that half-wrote a chunk and reported the failure with
   * no way to tell how far it got.
   */
  it("rolls a failed batch back rather than keeping the statements before it", async () => {
    const userId = await partition(ALICE);

    const lands = env.DB.prepare(
      "INSERT INTO recoveries (user_id, date, recovery_score, resting_heart_rate, hrv_value_ms, hrv_metric) VALUES (?, ?, ?, ?, ?, ?)",
    ).bind(userId, "2026-08-22", 68, 52, 71.4, "rmssd");

    // The second statement is missing every NOT NULL column but `user_id`, so it cannot land — and
    // it is the *second* deliberately: the question is whether the first one survives it.
    const fails = env.DB.prepare("INSERT INTO recoveries (user_id) VALUES (?)").bind(userId);

    await expect(env.DB.batch([lands, fails])).rejects.toThrow();

    expect(await rowCount(ALICE)).toBe(0);
  });

  it("leaves the table untouched when the repository's own chunk is refused", async () => {
    const rows = batchRows("2026-08-22", 3);

    // A chunk that is refused *before* it reaches D1 — here by the cap — has nothing to roll back,
    // and the assertion is that the route validated before the service wrote rather than after.
    // Ordered against the previous test on purpose: one covers the transaction below the endpoint,
    // this one covers the fact that a refusal above it never opens one.
    await postBatch({ rows: batchRows("2026-08-22", MAX_BATCH_ROWS + 1) });
    await postBatch({ rows: [...rows, rows[0]!] });

    expect(await rowCount(ALICE)).toBe(0);
  });
});
