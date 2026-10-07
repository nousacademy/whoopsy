import { SELF, env } from "cloudflare:test";
import { authHeaders } from "../Support/auth";
import { beforeEach, describe, expect, it } from "vitest";
import { MAX_BATCH_STRAINS, MAX_STRAIN_WINDOW_DAYS } from "../../src/services";
import { deriveUserId, MIN_KEY_LENGTH } from "../../src/utils/identity";

/**
 * `strains`, carried from HTTP through D1 and back.
 *
 * This file is `recoveries.spec.ts`'s sibling and it is deliberately not a copy of it. The two
 * resources share the day-keyed shape — one row per `(owner, day)`, an upsert, a range read, a chunk
 * — so most of what is asserted below is a rule this repo has already paid for once. What is
 * *strains*' own is the small set of places it diverges, and each of them is a place a reader would
 * be right to assume the sibling's answer:
 *
 *  - **A row that exists and was never measured is a `200`**, not the `404` a day with no row gets.
 *    `recoveries` has no such row in its schema, so the same absence code means something narrower
 *    one resource over, and the pair below is what says so.
 *  - **`0` is a legal measurement in three columns** — the score, the kilojoules and both rates —
 *    where `recoveries.restingHeartRate` is positive. So the absence rule here cannot be read off a
 *    figure at all, which is the whole of why `hasMeasurement` is on the wire.
 *  - **The day a batch row names is required and the day a `PUT` body names is refused**, the same
 *    asymmetry the sibling has, asserted on both sides because this resource's two schemas are
 *    separate files that could drift apart.
 *
 * **The storage is fresh per test.** The pool's `isolatedStorage` is on, so the rows one `it` writes
 * are invisible to the next; nothing here clears a table by hand, and nothing depends on another test
 * having run.
 */

const BASE = "https://whoopsy.test";

/**
 * Two real keys, at the length the app sends: 32 random bytes, 43 base64url characters.
 *
 * The same two values `recoveries.spec.ts` uses, and for its reason verbatim — `MIN_KEY_LENGTH` exists
 * so a one-character header is not a partition, and a suite that kept short fixtures would be the
 * first caller the rule broke. What reaches `user_id` is `sha256` of one of these, so every direct
 * read against `env.DB` goes through `partition(_:)` rather than binding the literal.
 */
const ALICE = "K7fQ2mZx9pLr4Tn6WvB1yHs8JcE3uGa5DkRm0Xq4YAb";
const BOB = "Qw3RtYuIoPaSdFgHjKlZxCvBnM1234567890abcdefg";

/**
 * The partition a key's rows live under — computed the way the Worker computes it.
 *
 * Not an independent implementation: `tests/utils/identity.spec.ts` pins the digest against a literal
 * computed outside this codebase, and what these tests need is a *handle* on the row a request just
 * wrote. The alternative — binding the raw key — would assert that `user_id` holds the header, which
 * is the one thing `utils/identity.ts` exists to prevent.
 */
function partition(key: string): Promise<string> {
  return deriveUserId(key);
}

/**
 * How many rows exist in one partition.
 *
 * `strains` is the default here rather than `recoveries`, and it is the only line of this helper that
 * differs from the sibling's — the scoping is what matters, since an unqualified `COUNT(*)` is a
 * claim about every caller's rows.
 */
async function rowCount(key: string, table = "strains"): Promise<number> {
  const counted = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`,
  )
    .bind(await partition(key))
    .first<{ n: number }>();

  return counted?.n ?? 0;
}

/** The wire shape, spelled out rather than inferred, so a renamed field fails here loudly. */
interface StrainWire {
  date: string;
  strainScore: number;
  kilojoules: number;
  averageHeartRate: number;
  maxHeartRate: number;
  hasMeasurement: boolean;
  source: string | null;
}

interface ErrorWire {
  error: { code: string; message: string };
}

/**
 * A measured day.
 *
 * `hasMeasurement` is `true` and `source` is `null` — a day this app measured itself, which is what
 * the app's own live path writes. The four figures are the reference's own shape rather than round
 * numbers: a strain, a kilojoule total, an average under the max, and a max under the app's assumed
 * 190 ceiling.
 */
function measuredDay(overrides: Partial<Omit<StrainWire, "date">> = {}): Omit<StrainWire, "date"> {
  return {
    strainScore: 4.1,
    kilojoules: 1046,
    averageHeartRate: 68,
    maxHeartRate: 151,
    hasMeasurement: true,
    source: null,
    ...overrides,
  };
}

/**
 * The placeholder row a build before the app's `v7` migration left behind: every figure zeroed and
 * the flag `false`.
 *
 * It is a fixture and not a hypothetical — such rows are on real devices, which is the entire reason
 * `hasMeasurement` exists — and it is written as `measuredDay` plus overrides so the two shapes
 * cannot drift into having different fields.
 */
function unmeasuredDay(overrides: Partial<Omit<StrainWire, "date">> = {}): Omit<StrainWire, "date"> {
  return measuredDay({
    strainScore: 0,
    kilojoules: 0,
    averageHeartRate: 0,
    maxHeartRate: 0,
    hasMeasurement: false,
    ...overrides,
  });
}

function put(date: string, body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/strains/${date}`, {
    method: "PUT",
    headers: { "content-type": "application/json", ...authHeaders(userId) },
    body: JSON.stringify(body),
  });
}

function read(path: string, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}${path}`, { headers: { ...authHeaders(userId) } });
}

function postBatch(body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/strains/batch`, {
    method: "POST",
    headers: { "content-type": "application/json", ...authHeaders(userId) },
    body: JSON.stringify(body),
  });
}

/**
 * `n` consecutive days ending on `endingOn`, oldest first, each carrying its own day.
 *
 * A batch row is a `measuredDay()` plus a `date`, so the fixture the single-day tests already use is
 * reused rather than restated — a second `measuredDay`-shaped literal here would be free to drift
 * from the one the `PUT` body is built out of.
 */
function batchRows(endingOn: string, n: number): (Omit<StrainWire, "date"> & { date: string })[] {
  const rows: (Omit<StrainWire, "date"> & { date: string })[] = [];
  const end = Date.parse(`${endingOn}T00:00:00Z`);

  for (let i = n - 1; i >= 0; i--) {
    const day = new Date(end - i * 86_400_000).toISOString().slice(0, 10);
    rows.push({ date: day, ...measuredDay() });
  }

  return rows;
}

async function day(userId: string, date: string): Promise<StrainWire> {
  const response = await read(`/v1/strains/${date}`, userId);
  expect(response.status).toBe(200);
  return (await response.json()) as StrainWire;
}

describe("a day written and read back", () => {
  it("returns the stored row, not an echo of the request", async () => {
    const body = measuredDay();

    const written = await put("2026-08-22", body);
    expect(written.status).toBe(200);

    const stored = (await written.json()) as StrainWire;
    expect(stored).toEqual({ date: "2026-08-22", ...body });

    // The read is the assertion that the response was the database's answer rather than the
    // request's: the two agree here only because the write really happened.
    expect(await day(ALICE, "2026-08-22")).toEqual(stored);
  });

  it("replaces a day's row when the same day is written twice", async () => {
    await put("2026-08-22", measuredDay({ strainScore: 4.1 }));
    await put("2026-08-22", measuredDay({ strainScore: 12.7 }));

    // `saveStrain` is INSERT-or-UPDATE by primary key, and `strains` is keyed on the day — so a
    // second write of one day must leave one row and not two. This is the assertion that fails if the
    // primary key is ever widened to include something else "for safety".
    expect(await rowCount(ALICE)).toBe(1);
    expect((await day(ALICE, "2026-08-22")).strainScore).toBe(12.7);
  });

  it("round-trips the boolean rather than the integer the column stores", async () => {
    await put("2026-08-22", measuredDay({ hasMeasurement: true }));
    await put("2026-08-23", unmeasuredDay());

    // `has_measurement` is an INTEGER with a `CHECK (… IN (0, 1))` behind it, so the two directions
    // are worth pinning separately: the write converts the boolean, and the read converts it back.
    // A repository that returned the column raw would answer `1` and `0` here, which every other
    // assertion in this file would pass.
    expect((await day(ALICE, "2026-08-22")).hasMeasurement).toBe(true);
    expect((await day(ALICE, "2026-08-23")).hasMeasurement).toBe(false);
  });
});

describe("a row that exists and was not measured", () => {
  it("is a 200 carrying the flag, never a 404", async () => {
    await put("2026-08-22", unmeasuredDay());

    const response = await read("/v1/strains/2026-08-22");

    // **This is where this resource parts company with `recoveries`, and the difference is a claim
    // about a row rather than about a figure.** The app stores such a row; `findByDay` finds it; and
    // every reader in the app tells it from a reading by this flag. Answering `404` here would be
    // this API deciding a row the client holds does not exist — and a client syncing it up would then
    // be told its own local row was never measured, which is the one claim the flag exists to make
    // honestly.
    expect(response.status).toBe(200);
    expect((await response.json()) as StrainWire).toEqual({
      date: "2026-08-22",
      ...unmeasuredDay(),
    });
  });

  it("keeps a measured zero as a zero in all three columns at once", async () => {
    // A genuine rest day with no weight on file: WHOOP's own export scores exactly `0.0` on two real
    // days, and the calorie estimate returns nothing without a weight, so this row is a *reading*
    // that happens to be all zeroes. It is the near miss the whole resource is shaped around.
    await put("2026-08-23", measuredDay({ strainScore: 0, kilojoules: 0 }));

    const rest = await day(ALICE, "2026-08-23");
    expect(rest.strainScore).toBe(0);
    expect(rest.kilojoules).toBe(0);
    // The flag is the only thing separating this row from the placeholder above, and asserting it
    // beside them is what stops a future `?? 0` or a score-derived flag from making the two
    // indistinguishable while every other assertion in this file still passes.
    expect(rest.hasMeasurement).toBe(true);
  });

  it("is omitted from a window rather than filtered out of it", async () => {
    await put("2026-08-20", measuredDay());
    await put("2026-08-22", unmeasuredDay());

    const response = await read("/v1/strains?days=4&endingOn=2026-08-22");
    const rows = (await response.json()) as StrainWire[];

    // The placeholder is *in* the window and *in* the answer, with its flag, because a window is a
    // read of rows. Filtering here is the tempting alternative and it is wrong for the same reason
    // the 404 is: it would silently drop rows the client holds, and a syncing client would read that
    // as "the server has lost these days".
    expect(response.status).toBe(200);
    expect(rows.map((row) => row.date)).toEqual(["2026-08-20", "2026-08-22"]);
    expect(rows[1]!.hasMeasurement).toBe(false);
  });

  it("refuses an integer the column's domain does not allow", async () => {
    // The `CHECK (has_measurement IN (0, 1))` is a statement in the migration and this is the
    // assertion that it is really there. It is written directly against D1 because no valid body can
    // reach it: Zod's `z.boolean()` refuses `2` long before SQLite would, so the constraint's only
    // visible effect is on a writer that bypassed the endpoint — which is exactly the writer the
    // mapper's `parseHasMeasurement` throws for.
    const userId = await partition(ALICE);

    const invalid = env.DB.prepare(
      "INSERT INTO strains (user_id, date, strain_score, kilojoules, average_heart_rate, max_heart_rate, has_measurement) VALUES (?, ?, ?, ?, ?, ?, ?)",
    ).bind(userId, "2026-08-22", 4.1, 1046, 68, 151, 2);

    await expect(invalid.run()).rejects.toThrow();
    expect(await rowCount(ALICE)).toBe(0);
  });
});

describe("NULL is not 0", () => {
  let stored: StrainWire;

  beforeEach(async () => {
    await put("2026-08-22", measuredDay());
    stored = await day(ALICE, "2026-08-22");
  });

  it("carries the one nullable column back as a key that is present and null", async () => {
    // `source` alone, and that is the point: this resource has exactly one column that can be absent
    // and every other field is a stored non-null one, so there is no wider sweep to make here. Present
    // at all — a stripped key would be a third state that means nothing, which is why the schema
    // declares `.nullable()` and never `.optional()`.
    expect(Object.hasOwn(stored, "source")).toBe(true);
    expect(stored.source).toBeNull();
  });

  it("keeps a provenance label when one is sent", async () => {
    await put("2026-08-23", measuredDay({ source: "whoop_export" }));

    const imported = await day(ALICE, "2026-08-23");
    expect(imported.source).toBe("whoop_export");
    // The pair matters more here than on `recoveries`: an imported strain is WHOOP's own figure
    // rather than this app's, so the label is the only thing distinguishing two producers'
    // measurements of the same quantity on the same column.
    expect(Object.hasOwn(imported, "source")).toBe(true);
  });

  it("refuses an empty provenance rather than storing it as a value", async () => {
    const response = await put("2026-08-23", measuredDay({ source: "" }));

    // `min(1)`. An empty string is a value nobody supplied, and the whole point of the column being
    // nullable is that absence already has a spelling — so `""` would put two spellings of "no
    // producer" on one column and no reader could tell which was meant.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a body that carries a date of its own rather than stripping it", async () => {
    const response = await put("2026-08-22", { ...measuredDay(), date: "2026-08-23" });

    // `.strict()` on the write schema, and on this resource the extra key that matters is this one:
    // every field the body legitimately carries is required and non-nullable, so a misspelling is
    // already caught by the missing-field check and no default can absorb it. `date` is the key a
    // client has a second opinion about — and the path wins in a way the client cannot see.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });
});

describe("the score's scale", () => {
  it("accepts both ends of WHOOP's 0–21 scale", async () => {
    for (const [date, score] of [
      ["2026-08-22", 0],
      ["2026-08-23", 21],
    ] as const) {
      expect((await put(date, measuredDay({ strainScore: score }))).status).toBe(200);
      expect((await day(ALICE, date)).strainScore).toBe(score);
    }
  });

  it("refuses a figure outside the scale", async () => {
    // The bounds are the scale's definition rather than a guard against a typo, so they are asserted
    // at the edges: a `20.9` passes and a `21.1` does not.
    expect((await put("2026-08-22", measuredDay({ strainScore: 21.1 }))).status).toBe(400);
    expect((await put("2026-08-22", measuredDay({ strainScore: -0.1 }))).status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("accepts a one-decimal figure the app really holds", async () => {
    // **The assertion that a `multipleOf(0.1)` refinement is absent, and it is here because the
    // refinement is the obvious thing to add.** `4.1 % 0.1` is not zero in IEEE-754, so a
    // float-modulo refinement would refuse a value the app computes on every scored day — and the
    // failure would arrive as a 400 on real data with nothing in the message naming the float.
    const response = await put("2026-08-22", measuredDay({ strainScore: 4.1 }));

    expect(response.status).toBe(200);
    expect((await response.json() as StrainWire).strainScore).toBe(4.1);
  });

  it("refuses a score that is not a number at all", async () => {
    // `JSON.stringify` turns `NaN` and `Infinity` into `null`, so the interesting half is the type
    // check rather than the finiteness one — but a body carrying a string is what a client with a
    // formatter bug sends, and `z.number()` is what refuses it.
    expect((await put("2026-08-22", measuredDay({ strainScore: "4.1" as unknown as number }))).status).toBe(400);
    expect((await put("2026-08-22", measuredDay({ strainScore: NaN }))).status).toBe(400);
  });

  it("refuses a negative kilojoule or heart rate", async () => {
    // Non-negative rather than positive is the rule — see the `0` cases above — but the floor itself
    // is still a floor. A negative rate is not a reading this app can produce or store.
    expect((await put("2026-08-22", measuredDay({ kilojoules: -1 }))).status).toBe(400);
    expect((await put("2026-08-22", measuredDay({ averageHeartRate: -1 }))).status).toBe(400);
    expect((await put("2026-08-22", measuredDay({ maxHeartRate: -1 }))).status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a fractional heart rate", async () => {
    // `z.number().int()`. The app's rates come from `Int` columns and the export's are whole, so a
    // fraction is a value from some other producer — and rounding it here would invent a reading
    // rather than lose one.
    expect((await put("2026-08-22", measuredDay({ averageHeartRate: 68.5 }))).status).toBe(400);
  });
});

describe("the day key", () => {
  it("refuses a key carrying a time component", async () => {
    const response = await put("2026-08-22T13:45:00Z", measuredDay());

    // Refused, and deliberately not snapped. The app snaps because it can — `startOfDay` is the
    // device's own calendar — and a server cannot re-derive a client's midnight without the client's
    // zone. Snapping here would store a key the client's own read could not find.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a calendar day that does not exist", async () => {
    // A regex alone lets this through and `Date.parse` rolls it forward to March 3, so the refusal is
    // the round trip through `Date.UTC` rather than the shape of the string.
    const response = await put("2026-02-31", measuredDay());

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("stores nothing when it refuses", async () => {
    await put("2026-08-22T13:45:00Z", measuredDay());

    // Scoped to the partition rather than the whole table: an unqualified count is a claim about
    // every caller's rows and would pass for the wrong reason the day another test's storage leaked.
    expect(await rowCount(ALICE)).toBe(0);
  });
});

describe("a day with no row at all", () => {
  it("is a 404 naming the code, not a zero-filled row", async () => {
    await put("2026-08-21", measuredDay());

    const response = await read("/v1/strains/2026-08-22");

    // The other absence, one file over from the `200` above, and the pair is the point: `no_measurement_for_day`
    // means "this day has no row" on this resource, where an unmeasured *row* is a perfectly ordinary
    // `200`. `recoveries` reuses the same code for its only absence, which is why the code's meaning
    // has to be read per resource rather than remembered across them.
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({
      error: {
        code: "no_measurement_for_day",
        message: "no strain measured on 2026-08-22",
      },
    });
  });

  it("is omitted from a window rather than zero-filled", async () => {
    for (const date of ["2026-08-20", "2026-08-22"]) {
      await put(date, measuredDay());
    }

    const response = await read("/v1/strains?days=4&endingOn=2026-08-22");
    const rows = (await response.json()) as StrainWire[];

    // 08-21 is inside the window and absent from the answer. An empty array would be a real answer
    // too — "nothing in this window has a row" — which is why the omission, not the count, is the
    // assertion.
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
    const response = await read("/v1/strains?days=2&endingOn=2026-08-22");
    const rows = (await response.json()) as StrainWire[];

    // The app's own arithmetic, mirrored rather than corrected: `from = endingOn - days`, inclusive
    // at both ends, so `days: 14` is fifteen days. A ported `getStrainHistory(days:endingOn:)` returns
    // what it returned on-device, and the off-by-one is a written-down fact rather than a surprise.
    expect(rows.map((row) => row.date)).toEqual(["2026-08-20", "2026-08-21", "2026-08-22"]);
  });

  it("excludes a day one past the upper bound", async () => {
    const response = await read("/v1/strains?days=2&endingOn=2026-08-22");
    const rows = (await response.json()) as StrainWire[];

    // 08-23 is stored and outside `[endingOn - days, endingOn]`. A range read that ran on to the
    // present — which is what `getStrainHistory(days:)` does on-device when it is not handed
    // `endingOn:` — would return it here, and the lower-bound test above cannot see that.
    expect(rows.map((row) => row.date)).not.toContain("2026-08-23");
  });

  it("takes days = 0 to mean the ending day alone", async () => {
    const response = await read("/v1/strains?days=0&endingOn=2026-08-22");
    const rows = (await response.json()) as StrainWire[];

    expect(rows.map((row) => row.date)).toEqual(["2026-08-22"]);
  });

  it("refuses a window wider than the service's ceiling", async () => {
    const response = await read(`/v1/strains?days=${MAX_STRAIN_WINDOW_DAYS + 1}&endingOn=2026-08-22`);

    // `MAX_STRAIN_WINDOW_DAYS` and not `recoveries`' `MAX_WINDOW_DAYS`, which is the same `4000`
    // today. The two are separate published limits — see the constants' own docs — and this is the
    // assertion that would catch a route wired to the wrong one.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a non-numeric days rather than coercing it to a window", async () => {
    const response = await read("/v1/strains?days=fortnight&endingOn=2026-08-22");

    // `z.coerce.number()` is what turns the query string into a number, and it is also what refuses
    // this: `Number("fortnight")` is `NaN`, which the `.int()` check rejects. Without the coercion
    // the schema would be testing a string against a numeric bound and every value would pass.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a fractional days", async () => {
    const response = await read("/v1/strains?days=1.5&endingOn=2026-08-22");

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("answers an empty array when nothing in the window has a row", async () => {
    const response = await read("/v1/strains?days=2&endingOn=2020-01-02");

    // A real answer rather than an error, and the day keys are checked so this cannot pass by
    // accident on a window that happens to include the rows written in the `beforeEach`.
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual([]);
    expect(await rowCount(ALICE)).toBe(6);
  });
});

describe("the partition", () => {
  it("keeps one user's day invisible to another", async () => {
    await put("2026-08-22", measuredDay(), ALICE);

    expect((await read("/v1/strains/2026-08-22", ALICE)).status).toBe(200);
    // Nothing verifies the header yet, so this is the `user_id` column doing real work: the row is
    // there, and a different owner cannot reach it.
    expect((await read("/v1/strains/2026-08-22", BOB)).status).toBe(404);

    const list = await read("/v1/strains?days=2&endingOn=2026-08-22", BOB);
    expect(await list.json()).toEqual([]);
  });

  it("lets two users hold the same day without colliding", async () => {
    await put("2026-08-22", measuredDay({ strainScore: 4.1 }), ALICE);
    await put("2026-08-22", measuredDay({ strainScore: 18.3 }), BOB);

    expect((await day(ALICE, "2026-08-22")).strainScore).toBe(4.1);
    expect((await day(BOB, "2026-08-22")).strainScore).toBe(18.3);
  });

  it("files the row under the digest of the key, never under the key", async () => {
    await put("2026-08-22", measuredDay());

    // The second read is the one that matters. The first says the row is reachable at all; the second
    // says the column holds something that is *not* the header, which is the whole of what a D1 dump
    // leaking no usable credentials means. A `user_id` equal to `ALICE` would satisfy every other test
    // in this file — the requests would still work, because the same string would be hashed on the way
    // in and matched on the way out — and would be a database of working keys.
    expect(await rowCount(ALICE)).toBe(1);

    const keyed = await env.DB.prepare("SELECT COUNT(*) AS n FROM strains WHERE user_id = ?")
      .bind(ALICE)
      .first<{ n: number }>();

    expect(keyed?.n).toBe(0);
  });
});

describe("identity", () => {
  it("refuses a request with no X-Whoopsy-User-Id", async () => {
    const response = await SELF.fetch(`${BASE}/v1/strains?days=2&endingOn=2026-08-22`, { headers: { ...authHeaders() } });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses an empty X-Whoopsy-User-Id", async () => {
    const response = await read("/v1/strains/2026-08-22", "");

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a key one character below the floor", async () => {
    const short = "a".repeat(MIN_KEY_LENGTH - 1);

    // The boundary from the inside, because the guard is a length test and an off-by-one is its only
    // realistic defect: `>=` spelled `>` would admit exactly this string and pass every other test in
    // this file, including the empty-key one above — nothing else here is near the edge.
    expect((await read("/v1/strains/2026-08-22", short)).status).toBe(400);

    // And one character above it is accepted, so the pair pins a boundary rather than restating a
    // refusal that a blank check would also produce. `404` rather than `200` because no day has been
    // written in this test — the status is the proof the header was let through, and it is the only
    // observable that separates "accepted" from "refused" without a fixture.
    expect((await read("/v1/strains/2026-08-22", "a".repeat(MIN_KEY_LENGTH))).status).toBe(404);
  });

  it("refuses a header on the batch endpoint too", async () => {
    const response = await SELF.fetch(`${BASE}/v1/strains/batch`, {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ rows: batchRows("2026-08-22", 1) }),
    });

    // Every handler goes through `partitionFor`, and this is the assertion that the batch route is
    // not the one that reads the raw header: it has a body to parse and a path with no parameters, so
    // it is the route most likely to be written without the identity step.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    expect(await rowCount(ALICE)).toBe(0);
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

    const list = await read("/v1/strains?days=3&endingOn=2026-08-22");
    expect(((await list.json()) as StrainWire[]).map((row) => row.date)).toEqual([
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

    // And idempotence is a claim about the table, not about the number: the chunk is keyed on the same
    // `(userId, date)` pair the single-day `PUT` writes, so replaying it cannot append. On this
    // resource that also means the flag cannot be overwritten by a re-send that carries the other
    // one — the row is replaced entire, which is why the two directions below are asserted.
    expect(await rowCount(ALICE)).toBe(3);
  });

  it("replaces a measured row with a placeholder rather than merging the two", async () => {
    await put("2026-08-22", measuredDay());

    await postBatch({ rows: [{ date: "2026-08-22", ...unmeasuredDay() }] });

    // The upsert sets every column from `excluded`, so a batch row is the whole row and not a patch.
    // A merge — `SET strain_score = excluded.strain_score` and forget the rest — would leave this day
    // measured with a zeroed score, which is the one state the flag exists to make impossible.
    const stored = await day(ALICE, "2026-08-22");
    expect(stored).toEqual({ date: "2026-08-22", ...unmeasuredDay() });
    expect(await rowCount(ALICE)).toBe(1);
  });

  it("writes a full chunk of the cap in one request", async () => {
    const rows = batchRows("2026-08-22", MAX_BATCH_STRAINS);

    const response = await postBatch({ rows });

    expect(response.status).toBe(200);
    // The cap is the app's whole strain history in five requests — 931 rows over 931 distinct days —
    // so this is the real corpus's chunk size rather than a round number. `written` is also the
    // assertion that would catch a `NaN` from a `meta.changes` this runtime did not report, and on a
    // two-hundred-statement batch it is the only assertion in this file that would see it.
    expect(await response.json()).toEqual({ written: MAX_BATCH_STRAINS });
    expect(await rowCount(ALICE)).toBe(MAX_BATCH_STRAINS);
  });

  it("refuses a chunk one row past the cap, and writes nothing", async () => {
    const response = await postBatch({ rows: batchRows("2026-08-22", MAX_BATCH_STRAINS + 1) });

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
    // an array the client built, reported as success. On this resource the two rows could also
    // disagree about `hasMeasurement`, leaving the day claiming whichever one the array put last.
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

    // The day is in the body here and in the path on the `PUT`, so this is the half that has no other
    // spelling: a row without one would have to be filed somewhere, and anywhere is a guess. The path
    // is asserted rather than only the status because it is what names the offending row among 200.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("rows.0.date");
  });

  it("refuses a row carrying a field the contract does not have", async () => {
    const rows = batchRows("2026-08-22", 2);
    const response = await postBatch({
      rows: [rows[0], { ...rows[1], strainScor: 12.7 }],
    });

    // `.strict()`, and it matters more at this volume than on the single-day body: a batch is
    // assembled by a client out of its own database, and a misspelled field in one row of two hundred
    // is exactly the failure a silent strip turns into one day written with a default in it and a
    // `200` beside it. The index names the row, which is what makes it findable among 200.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("rows.1");
  });

  it("lands on the day keys the single-day write uses", async () => {
    await put("2026-08-22", measuredDay({ strainScore: 4.1 }));

    const response = await postBatch({
      rows: [
        { date: "2026-08-22", ...measuredDay({ strainScore: 12.7 }) },
        { date: "2026-08-23", ...measuredDay() },
      ],
    });

    expect(response.status).toBe(200);
    // Three claims in one pair. The day the `PUT` wrote is *replaced* rather than duplicated, so the
    // batch and the single-day write share one key — which is the whole of what `partitionFor` exists
    // for, since a batch that hashed the header differently from the `PUT` would file the same day in
    // two partitions and neither request would report anything.
    expect(await rowCount(ALICE)).toBe(2);
    expect((await day(ALICE, "2026-08-22")).strainScore).toBe(12.7);

    // And a day with no row yet is inserted by the same call, so the two verbs are one upsert.
    expect((await day(ALICE, "2026-08-23")).strainScore).toBe(4.1);
  });

  it("never deletes a day the caller leaves out", async () => {
    const rows = batchRows("2026-08-22", 3);
    await postBatch({ rows });

    // One day of the three, alone in the chunk.
    await postBatch({ rows: [rows[1]!] });

    const list = await read("/v1/strains?days=3&endingOn=2026-08-22");
    // All three are still there. This is why the endpoint is a `POST` on `/batch` and not a `PUT` on
    // the collection: "these are the days" obliges the server to remove the ones left out, and a
    // client whose retry sent a *partial* chunk — the rest of it lost to a timeout — would erase its
    // own history while being told the request succeeded.
    expect(((await list.json()) as StrainWire[]).map((row) => row.date)).toEqual([
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

    const list = await read("/v1/strains?days=3&endingOn=2026-08-22", BOB);
    expect(((await list.json()) as StrainWire[]).map((row) => row.date)).toEqual(["2026-08-22"]);
  });
});

describe("the chunk's transaction", () => {
  /**
   * The one thing in this file that is evidence about D1 rather than about this Worker.
   *
   * `D1StrainRepository.upsertMany` writes a chunk through `env.DB.batch(...)` and relies on its
   * documented all-or-nothing behaviour for the promise the endpoint makes — *a failure writes nothing
   * and the same body can be sent again*. That promise is not reachable through HTTP with a valid
   * schema: every field a batch can carry is already checked by Zod, so there is no body that passes
   * validation and then fails in the database.
   *
   * **This is a probe, and it is written as one.** If miniflare's local D1 ever stops rolling a batch
   * back — the two databases this repo runs against are already documented to differ — this test is
   * where that is learned, rather than in a sync that half-wrote a chunk and reported the failure with
   * no way to tell how far it got.
   */
  it("rolls a failed batch back rather than keeping the statements before it", async () => {
    const userId = await partition(ALICE);

    const lands = env.DB.prepare(
      "INSERT INTO strains (user_id, date, strain_score, kilojoules, average_heart_rate, max_heart_rate, has_measurement) VALUES (?, ?, ?, ?, ?, ?, ?)",
    ).bind(userId, "2026-08-22", 4.1, 1046, 68, 151, 1);

    // The second statement is missing every NOT NULL column but `user_id`, so it cannot land — and it
    // is the *second* deliberately: the question is whether the first one survives it.
    const fails = env.DB.prepare("INSERT INTO strains (user_id) VALUES (?)").bind(userId);

    await expect(env.DB.batch([lands, fails])).rejects.toThrow();

    expect(await rowCount(ALICE)).toBe(0);
  });

  it("leaves the table untouched when the repository's own chunk is refused", async () => {
    const rows = batchRows("2026-08-22", 3);

    // A chunk that is refused *before* it reaches D1 — here by the cap and by a repeated day — has
    // nothing to roll back, and the assertion is that the route validated before the service wrote
    // rather than after. Ordered against the previous test on purpose: one covers the transaction
    // below the endpoint, this one covers the fact that a refusal above it never opens one.
    await postBatch({ rows: batchRows("2026-08-22", MAX_BATCH_STRAINS + 1) });
    await postBatch({ rows: [...rows, rows[0]!] });

    expect(await rowCount(ALICE)).toBe(0);
  });
});
