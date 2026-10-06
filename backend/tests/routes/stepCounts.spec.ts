import { SELF, env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { MAX_BATCH_STEP_COUNTS, MAX_STEP_COUNT_WINDOW_DAYS } from "../../src/services";
import { deriveUserId, MIN_KEY_LENGTH } from "../../src/utils/identity";

/**
 * `stepCounts`, carried from HTTP through D1 and back.
 *
 * This file is the family's shortest spec, and **what it does not carry is the point.** `sleeps.spec.ts`
 * and `strains.spec.ts` are its siblings and it deliberately drops every block that exists because of a
 * column this table does not have:
 *
 *  - **There is no null round trip.** `sleeps` devotes its longest block to six nullable columns, and
 *    `strains` has one. `step_counts` has **none** — `0005_create_step_counts.sql` declares every column
 *    `NOT NULL` — so there is no `null` to carry back, no key to keep present-and-null, and no third
 *    state between a value and an absence. That is why this file has no "NULL is not 0" describe block.
 *  - **There is no blob and no string field.** `sleeps` bounds `sleep_stages` and asserts it is never
 *    parsed; the only strings here are the day key and the primary key's own columns, and both are
 *    already the subject of a block below.
 *  - **There is no boundary pair and no ordering rule.** `sleeps` refines `endTime > startTime` and
 *    asserts it from both sides — present on both write bodies, absent from the response. Neither field
 *    here is an instant, so there is no cross-field rule to state, no `.refine` to compose, and no
 *    asymmetry to assert.
 *  - **There is no CHECK-constraint probe.** `0005` declares none, exactly as `0004` does not — every
 *    rule this table has is enforced by a Zod schema above it.
 *
 * What *is* this resource's own is the absence rule, and it is the one place it parts company with the
 * sibling it otherwise copies. `strains` stores a `hasMeasurement` flag, so a row can exist saying
 * `false` and its route has two cases to tell apart. `step_counts` has no such column: a row that exists
 * **is** a day the strap was worn, so `null` is the whole of this resource's absence, the 404 line is
 * `=== null` and nothing else, and there is no pair to assert. `stepCount.hasMeasurement` on the phone
 * is a *computed* property — `measuredSeconds > 0` — which is why the wire carries the number and not
 * the flag, and why the block below asserts the flag's **absence** from the payload rather than its
 * value.
 *
 * **The storage is fresh per test.** The pool's `isolatedStorage` is on, so the rows one `it` writes are
 * invisible to the next; nothing here clears a table by hand, and nothing depends on another test having
 * run.
 */

const BASE = "https://whoopsy.test";

/**
 * Two real keys, at the length the app sends: 32 random bytes, 43 base64url characters.
 *
 * The same two values the sibling specs use, and for their reason verbatim — `MIN_KEY_LENGTH` exists so
 * a one-character header is not a partition, and a suite that kept short fixtures would be the first
 * caller the rule broke. What reaches `user_id` is `sha256` of one of these, so every direct read
 * against `env.DB` goes through `partition(_:)` rather than binding the literal.
 */
const ALICE = "K7fQ2mZx9pLr4Tn6WvB1yHs8JcE3uGa5DkRm0Xq4YAb";
const BOB = "Qw3RtYuIoPaSdFgHjKlZxCvBnM1234567890abcdefg";

/**
 * The partition a key's rows live under — computed the way the Worker computes it.
 *
 * Not an independent implementation: `tests/utils/identity.spec.ts` pins the digest against a literal
 * computed outside this codebase, and what these tests need is a *handle* on the row a request just
 * wrote. The alternative — binding the raw key — would assert that `user_id` holds the header, which is
 * the one thing `utils/identity.ts` exists to prevent.
 */
function partition(key: string): Promise<string> {
  return deriveUserId(key);
}

/** How many rows exist in one partition. Scoped, because an unqualified `COUNT(*)` is a claim about every caller's rows. */
async function rowCount(key: string, table = "step_counts"): Promise<number> {
  const counted = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`)
    .bind(await partition(key))
    .first<{ n: number }>();

  return counted?.n ?? 0;
}

/**
 * The wire shape, spelled out rather than inferred, so a renamed field fails here loudly.
 *
 * Three fields and no `| null` anywhere, which is the whole difference from `SleepWire`: this resource
 * has no nullable column, so there is no key that can be present-and-null and no `?` to get wrong. The
 * type deliberately does **not** carry `hasMeasurement` — the contract does not publish it, and a field
 * declared here that the API never sends is how a spec comes to assert a value that does not exist.
 */
interface StepCountWire {
  date: string;
  stepCount: number;
  measuredSeconds: number;
}

interface ErrorWire {
  error: { code: string; message: string };
}

/**
 * A measured day.
 *
 * `measuredSeconds` is positive and the count is not, and that combination is the resource's entire
 * vocabulary: it is what "the strap was worn and counted 8,432 steps" looks like on the wire. The
 * figures are a plausible walking day rather than a round number, so a default that shuffled a field
 * would produce a visibly wrong row rather than one that happens to read as its own placeholder.
 *
 * `measuredSeconds` is fractional on purpose. It is an accumulator's sum — `Σ min(5.0, Δt)` over the
 * batches the strap was handed — so a whole number is the special case, not the ordinary one, and a
 * fixture built on integers would let a `.int()` accidentally added to the wrong field pass this file.
 */
function measuredDay(overrides: Partial<Omit<StepCountWire, "date">> = {}): Omit<StepCountWire, "date"> {
  return {
    stepCount: 8432,
    measuredSeconds: 41_760,
    ...overrides,
  };
}

function put(date: string, body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/step-counts/${date}`, {
    method: "PUT",
    headers: { "content-type": "application/json", "x-whoopsy-user-id": userId },
    body: JSON.stringify(body),
  });
}

function read(path: string, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}${path}`, { headers: { "x-whoopsy-user-id": userId } });
}

function postBatch(body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/step-counts/batch`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-whoopsy-user-id": userId },
    body: JSON.stringify(body),
  });
}

/**
 * `n` consecutive days ending on `endingOn`, oldest first, each carrying its own day.
 *
 * A batch row is a `measuredDay()` plus a `date`, so the fixture the single-day tests already use is
 * reused rather than restated — a second `measuredDay`-shaped literal here would be free to drift from
 * the one the `PUT` body is built out of.
 */
function batchRows(endingOn: string, n: number): (Omit<StepCountWire, "date"> & { date: string })[] {
  const rows: (Omit<StepCountWire, "date"> & { date: string })[] = [];
  const end = Date.parse(`${endingOn}T00:00:00Z`);

  for (let i = n - 1; i >= 0; i--) {
    const day = new Date(end - i * 86_400_000).toISOString().slice(0, 10);
    rows.push({ date: day, ...measuredDay() });
  }

  return rows;
}

async function day(userId: string, date: string): Promise<StepCountWire> {
  const response = await read(`/v1/step-counts/${date}`, userId);
  expect(response.status).toBe(200);
  return (await response.json()) as StepCountWire;
}

describe("a day written and read back", () => {
  it("returns the stored row, not an echo of the request", async () => {
    const body = measuredDay();

    const written = await put("2026-08-22", body);
    expect(written.status).toBe(200);

    const stored = (await written.json()) as StepCountWire;
    expect(stored).toEqual({ date: "2026-08-22", ...body });

    // The read is the assertion that the response was the database's answer rather than the request's:
    // the two agree here only because the write really happened.
    expect(await day(ALICE, "2026-08-22")).toEqual(stored);
  });

  it("replaces a day's row when the same day is written twice", async () => {
    await put("2026-08-22", measuredDay({ stepCount: 8432 }));
    await put("2026-08-22", measuredDay({ stepCount: 1204 }));

    // GRDB's `save` is INSERT-or-UPDATE by primary key and `step_counts` is keyed on the day — so a
    // second write of one day must leave one row and not two. This is the assertion that fails if the
    // primary key is ever widened "for safety", and the tempting extra key on this table is the
    // `measuredSeconds` span, which a reader could reasonably think identifies a reading. It does not:
    // the app files a day under its own day and nothing else, and a day's count is rewritten as the
    // accumulator sums more motion into it.
    expect(await rowCount(ALICE)).toBe(1);
    expect((await day(ALICE, "2026-08-22")).stepCount).toBe(1204);
  });

  it("does not publish hasMeasurement, which the client derives", async () => {
    await put("2026-08-22", measuredDay());
    const stored = await day(ALICE, "2026-08-22");

    // `StepCount.hasMeasurement` is a computed property on the phone — `measuredSeconds > 0` — so there
    // is nothing for this Worker to carry: the field that decides it is already in the payload one key
    // over. A flag here would be a second answer to a question that already has one, and the failure it
    // invites is a row whose flag and whose span disagree, with the flag drawn on screen and the number
    // beside it. Asserted as an absence because that is the only observable form the rule has.
    expect(Object.keys(stored).sort()).toEqual(["date", "measuredSeconds", "stepCount"]);
    expect("hasMeasurement" in stored).toBe(false);
    expect("source" in stored).toBe(false);
  });
});

describe("the measured zero against the absent row", () => {
  it("stores a zero count beside a positive span as a real measurement", async () => {
    const response = await put("2026-08-22", measuredDay({ stepCount: 0, measuredSeconds: 36_000 }));

    expect(response.status).toBe(200);
    const stored = (await response.json()) as StepCountWire;
    expect(stored.stepCount).toBe(0);

    // **This is the row the whole resource is shaped around.** A day the strap was worn and the wearer
    // walked nowhere is a real `0`, and it is distinguished from a day nothing measured by
    // `measuredSeconds` alone. A `?? 0` anywhere on the read path would be harmless here and fatal one
    // test below, which is why the two are a pair.
    expect((await day(ALICE, "2026-08-22")).stepCount).toBe(0);
    expect((await day(ALICE, "2026-08-22")).measuredSeconds).toBe(36_000);
  });

  it("stores a zero span rather than refusing it, because the app can hold one", async () => {
    const response = await put("2026-08-22", measuredDay({ stepCount: 0, measuredSeconds: 0 }));

    // No current writer produces this row — the app's own gates would leave it absent — but the app can
    // still *hold* one, and an API that refused it would be deciding a row the client has does not
    // exist. What must never happen is the server *producing* one, which is the no-default rule the
    // service and the adapter both state: a `measuredSeconds` this Worker filled in would publish a day
    // nothing measured as a day that was.
    expect(response.status).toBe(200);
    const stored = (await response.json()) as StepCountWire;
    expect(stored.measuredSeconds).toBe(0);
    expect((await day(ALICE, "2026-08-22")).measuredSeconds).toBe(0);
  });

  it("answers an absent day with a 404 naming the code, not a zero-filled row", async () => {
    const response = await read("/v1/step-counts/2026-08-22");

    expect(response.status).toBe(404);
    const body = (await response.json()) as ErrorWire;
    // The day-shaped absence, reused rather than minted a third word — the same code `recoveries` and
    // `strains` answer with, because the same thing is missing: a day, not an id.
    expect(body.error.code).toBe("no_measurement_for_day");
    // And the message names the day, so a client that logged the body alone can still tell two absences
    // apart in a sync.
    expect(body.error.message).toContain("2026-08-22");
  });

  it("answers a 404 for a measured-zero day that was never written", async () => {
    await put("2026-08-21", measuredDay({ stepCount: 0, measuredSeconds: 36_000 }));

    // The pair the flag's absence makes load-bearing. There is no `hasMeasurement` column and so no
    // second kind of row: a `0` day that was written answers `200`, and a `0` day that was not answers
    // `404`. A zero-filled `200` for the second would make the two indistinguishable to a client that
    // only read the body, which is the fabrication the absence rule exists to prevent — and on a step
    // history it would be a fabrication at the *majority* of days rather than at an edge.
    expect((await read("/v1/step-counts/2026-08-22")).status).toBe(404);

    const measured = await read("/v1/step-counts/2026-08-21");
    expect(measured.status).toBe(200);
    expect(((await measured.json()) as StepCountWire).stepCount).toBe(0);
  });

  it("omits an absent day from a window rather than zero-filling it", async () => {
    await put("2026-08-20", measuredDay({ stepCount: 100 }));
    await put("2026-08-22", measuredDay({ stepCount: 300 }));

    const response = await read("/v1/step-counts?days=2&endingOn=2026-08-22");
    const rows = (await response.json()) as StepCountWire[];

    // 08-21 has no row and is simply not in the answer. On this resource a hole inside the range is the
    // ordinary case rather than an edge — the strap is worn intermittently — so a filling pass would
    // invent most of a history rather than a day of one.
    expect(rows.map((row) => row.date)).toEqual(["2026-08-20", "2026-08-22"]);
    expect(rows.every((row) => row.stepCount > 0)).toBe(true);
  });

  it("refuses a body that carries a date of its own rather than stripping it", async () => {
    const response = await put("2026-08-22", { date: "2026-08-19", ...measuredDay() });

    // `.strict()` catches the extra key, and `date` is the extra key that matters: a `PUT` whose body
    // names its own day is a client with two opinions about which day it is writing, and the path wins
    // every time in a way the client cannot see. A silent strip would file the row under 08-22 and
    // answer a `200` that agreed with neither of the client's two beliefs.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    expect(await rowCount(ALICE)).toBe(0);
  });
});

describe("the day key", () => {
  it("refuses a key carrying a time component", async () => {
    const response = await put("2026-08-22T13:45:00Z", measuredDay());

    // Refused rather than snapped. The app's writers snap silently because they hold a real `Date` and
    // the snap is the only sensible reading; here the string *is* the payload — and the day is
    // `startOfDay` in the *device's* calendar, which this server cannot re-derive. Snapping would
    // reproduce the app's own written-at-a-raw-timestamp-inserted-never-updated failure somewhere the
    // app cannot see it.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a calendar day that does not exist", async () => {
    // A regex accepts `2026-02-31`; `Date.UTC` rolls it forward to March 3 rather than refusing it. So
    // the round-trip check in `utils/days.ts` is what makes "this is a day" a fact — and without it the
    // Worker would accept this write, file it under a day nobody named, and then answer a follow-up
    // `GET` on the same impossible string consistently, so nothing anywhere would look wrong.
    expect((await put("2026-02-31", measuredDay())).status).toBe(400);
  });

  it("stores nothing when it refuses", async () => {
    await put("2026-08-22T13:45:00Z", measuredDay());
    await put("2026-02-31", measuredDay());

    expect(await rowCount(ALICE)).toBe(0);
  });
});

describe("the fields' scale", () => {
  it("accepts a fractional measured span, which is what an accumulator sums to", async () => {
    // `Σ min(5.0, Δt)` over batches, so a fractional value is ordinary rather than an error — and this
    // is the assertion that fails if a `.int()` is ever added to this field on the assumption that the
    // two columns are the same kind of number. They are not: the count is whole and the span is not.
    const response = await put("2026-08-22", measuredDay({ measuredSeconds: 41_760.25 }));

    expect(response.status).toBe(200);
    expect(((await response.json()) as StepCountWire).measuredSeconds).toBe(41_760.25);
  });

  it("refuses a negative step count and a negative span", async () => {
    expect((await put("2026-08-22", measuredDay({ stepCount: -1 }))).status).toBe(400);
    expect((await put("2026-08-22", measuredDay({ measuredSeconds: -1 }))).status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a fractional step count rather than truncating it", async () => {
    const response = await put("2026-08-22", measuredDay({ stepCount: 8432.5 }));

    // Refused rather than rounded, on the rule that this API does not edit a client's figure. There is
    // no fraction to round in the first place — the app stores an `Int` and the accumulator adds whole
    // peaks — so a fractional count is a value from some other producer, and truncating it would invent
    // a reading instead of losing one.
    expect(response.status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a value that is not a number rather than coercing it", async () => {
    // No `z.coerce` on either field, deliberately: coercion on a body is how `"8432"` becomes a
    // measurement nobody took, and how `""` becomes a `0` that reads as a day of no walking.
    expect((await put("2026-08-22", measuredDay({ stepCount: "8432" as unknown as number }))).status).toBe(400);
    expect((await put("2026-08-22", measuredDay({ measuredSeconds: "41760" as unknown as number }))).status).toBe(400);
    expect((await put("2026-08-22", { stepCount: null, measuredSeconds: 41_760 })).status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a body missing one of the two fields", async () => {
    // Every field is required and none is defaulted, so a *misspelling* is already caught by the
    // missing-field check — which is the second half of why `.strict()` matters here and not the whole
    // of it, the first being the extra key.
    expect((await put("2026-08-22", { stepCount: 8432 })).status).toBe(400);
    expect((await put("2026-08-22", { measuredSeconds: 41_760 })).status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
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
    const response = await read("/v1/step-counts?days=2&endingOn=2026-08-22");
    const rows = (await response.json()) as StepCountWire[];

    // The app's own arithmetic, mirrored rather than corrected: `from = endingOn - days`, inclusive at
    // both ends, so `days: 14` is fifteen days. A ported `getStepHistory(days:endingOn:)` returns what
    // it returned on-device, and the off-by-one is a written-down fact rather than a surprise.
    expect(rows.map((row) => row.date)).toEqual(["2026-08-20", "2026-08-21", "2026-08-22"]);
  });

  it("excludes a day one past the upper bound", async () => {
    const response = await read("/v1/step-counts?days=2&endingOn=2026-08-22");
    const rows = (await response.json()) as StepCountWire[];

    // 08-23 is stored and outside `[endingOn - days, endingOn]`. A range read that ran on to the present
    // — which is what the app's `getXHistory(days:)` does when it is not handed `endingOn:` — would
    // return it here, and the lower-bound test above cannot see that.
    expect(rows.map((row) => row.date)).not.toContain("2026-08-23");
  });

  it("takes days = 0 to mean the ending day alone", async () => {
    const response = await read("/v1/step-counts?days=0&endingOn=2026-08-22");
    const rows = (await response.json()) as StepCountWire[];

    expect(rows.map((row) => row.date)).toEqual(["2026-08-22"]);
  });

  it("refuses a window wider than the service's ceiling", async () => {
    const response = await read(
      `/v1/step-counts?days=${MAX_STEP_COUNT_WINDOW_DAYS + 1}&endingOn=2026-08-22`,
    );

    // `MAX_STEP_COUNT_WINDOW_DAYS` and not a sibling's constant, which is the same `4000` today. The
    // four are separate published limits — see the constants' own docs — and this is the assertion that
    // would catch a route wired to the wrong one, which on this family is the likeliest wiring mistake
    // in the Worker, the four resources being as alike as they are.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a non-numeric days rather than coercing it to a window", async () => {
    // `z.coerce.number()` is what turns the query string into a number, and it is also what refuses
    // this: `Number("fortnight")` is `NaN`, which the `.int()` check rejects. Without the coercion the
    // schema would be testing a string against a numeric bound and every value would pass.
    expect((await read("/v1/step-counts?days=fortnight&endingOn=2026-08-22")).status).toBe(400);
  });

  it("refuses a fractional days", async () => {
    expect((await read("/v1/step-counts?days=1.5&endingOn=2026-08-22")).status).toBe(400);
  });

  it("answers an empty array when nothing in the window has a row", async () => {
    const response = await read("/v1/step-counts?days=2&endingOn=2020-01-02");

    // A real answer rather than an error — and on this resource it is the *common* one, because a
    // window over a period the strap was not worn and a window over days nothing measured are the same
    // absence: there is no flag to tell a hole from an unworn day, so `[]` is the only honest answer
    // for both.
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual([]);
    expect(await rowCount(ALICE)).toBe(6);
  });

  it("defaults endingOn to the server's own UTC today when it is omitted", async () => {
    await put("2026-08-22", measuredDay());

    // `endingOn` is optional only because the server has no notion of the caller's local today, and the
    // default is a poor one — it exists so the endpoint is usable from a browser address bar. What is
    // asserted here is that the default is applied **in the handler and not in the schema**: a Zod
    // `.default(utcToday())` would be evaluated once, when the module was first loaded, and a long-lived
    // isolate would then answer every request for the rest of its life with the day it cold-started on.
    // This window is wide enough to contain 2026-08-22 under either, so what the assertion holds is that
    // the request is answerable at all without the parameter.
    const response = await read(`/v1/step-counts?days=1`);
    expect(response.status).toBe(200);
  });
});

describe("the partition", () => {
  it("keeps one user's day invisible to another", async () => {
    await put("2026-08-22", measuredDay(), ALICE);

    expect((await read("/v1/step-counts/2026-08-22", BOB)).status).toBe(404);
    expect((await read("/v1/step-counts/2026-08-22", ALICE)).status).toBe(200);
  });

  it("lets two users hold the same day without colliding", async () => {
    await put("2026-08-22", measuredDay({ stepCount: 8432 }), ALICE);
    await put("2026-08-22", measuredDay({ stepCount: 1204 }), BOB);

    // The primary key is `(user_id, date)` and not `date`, and this is the assertion that would fail if
    // it were narrowed to the day alone: the second write would overwrite the first rather than sitting
    // beside it, and both callers would read one row.
    expect((await day(ALICE, "2026-08-22")).stepCount).toBe(8432);
    expect((await day(BOB, "2026-08-22")).stepCount).toBe(1204);
    expect(await rowCount(ALICE)).toBe(1);
    expect(await rowCount(BOB)).toBe(1);
  });

  it("files the row under the digest of the key, never under the key", async () => {
    await put("2026-08-22", measuredDay());

    const literal = await env.DB.prepare("SELECT COUNT(*) AS n FROM step_counts WHERE user_id = ?")
      .bind(ALICE)
      .first<{ n: number }>();

    // A dump of the database must not be a list of usable keys. Bound here as the *raw header*, so this
    // fails the moment a route skips `partitionFor` and files a row under the literal — which is the one
    // mistake in this file that no other test can see, every other read going through `partition(_:)`
    // and therefore agreeing with whatever the route did.
    expect(literal?.n ?? 0).toBe(0);
    expect(await rowCount(ALICE)).toBe(1);
  });
});

describe("identity", () => {
  it("refuses a request with no X-Whoopsy-User-Id", async () => {
    const response = await SELF.fetch(`${BASE}/v1/step-counts?days=2&endingOn=2026-08-22`);

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses an empty X-Whoopsy-User-Id", async () => {
    const response = await read("/v1/step-counts/2026-08-22", "");

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a key one character below the floor", async () => {
    const short = "a".repeat(MIN_KEY_LENGTH - 1);

    // The boundary from the inside, because the guard is a length test and an off-by-one is its only
    // realistic defect: `>=` spelled `>` would admit exactly this string and pass every other test in
    // this file, including the empty-key one above — nothing else here is near the edge.
    expect((await read("/v1/step-counts/2026-08-22", short)).status).toBe(400);

    // And one character above it is accepted, so the pair pins a boundary rather than restating a
    // refusal that a blank check would also produce. `404` rather than `200` because no day has been
    // written in this test — the status is the proof the header was let through, and it is the only
    // observable that separates "accepted" from "refused" without a fixture.
    expect((await read("/v1/step-counts/2026-08-22", "a".repeat(MIN_KEY_LENGTH))).status).toBe(404);
  });

  it("refuses a header on the batch endpoint too", async () => {
    const response = await SELF.fetch(`${BASE}/v1/step-counts/batch`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ rows: batchRows("2026-08-22", 1) }),
    });

    // Every handler goes through `partitionFor`, and this is the assertion that the batch route is not
    // the one that reads the raw header: it has a body to parse and a path with no parameters, so it is
    // the route most likely to be written without the identity step. On this resource the consequence
    // would be a chunk of days filed in a partition nobody can read.
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
    // request's own array would be the same number here, and would disagree with the table the moment an
    // upsert stopped landing.
    expect(await rowCount(ALICE)).toBe(3);

    const list = await read("/v1/step-counts?days=3&endingOn=2026-08-22");
    expect(((await list.json()) as StepCountWire[]).map((row) => row.date)).toEqual([
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
    // **Not zero.** `INSERT … ON CONFLICT DO UPDATE` counts a row it matched as changed even when every
    // value is byte-identical, so a replayed chunk reports the same figure as the first send. That is
    // the honest answer — the statement did write that row — and it is why `written: 0` must never be
    // read as "there was nothing to do": nothing in this API answers `0` for a non-empty batch. A client
    // that treated 0 as a completion signal would hang on a retry that succeeded.
    expect(await second.json()).toEqual({ written: 3 });

    // And idempotence is a claim about the table, not about the number: the chunk is keyed on the same
    // `(userId, date)` pair the single-day `PUT` writes, so replaying it cannot append.
    expect(await rowCount(ALICE)).toBe(3);
  });

  it("replaces a whole day rather than merging two versions of it", async () => {
    await put("2026-08-22", measuredDay({ stepCount: 8432, measuredSeconds: 41_760 }));

    await postBatch({ rows: [{ date: "2026-08-22", ...measuredDay({ stepCount: 12, measuredSeconds: 65 }) }] });

    // The upsert sets every column from `excluded`, so a batch row is the whole row and not a patch.
    // A merge would leave this day holding one field from each send, which is a day assembled from two
    // readings and attributable to neither.
    expect(await day(ALICE, "2026-08-22")).toEqual({
      date: "2026-08-22",
      ...measuredDay({ stepCount: 12, measuredSeconds: 65 }),
    });
    expect(await rowCount(ALICE)).toBe(1);
  });

  it("writes a full chunk of the cap in one request", async () => {
    const rows = batchRows("2026-08-22", MAX_BATCH_STEP_COUNTS);

    const response = await postBatch({ rows });

    expect(response.status).toBe(200);
    // A step history is the same order of magnitude as the sleep history's 910 nights, so a chunk of
    // the cap is the real corpus's chunk size rather than a round number. `written` is also the
    // assertion that would catch a `NaN` from a `meta.changes` this runtime did not report, and on a
    // two-hundred-statement batch it is the only assertion in this file that would see it.
    expect(await response.json()).toEqual({ written: MAX_BATCH_STEP_COUNTS });
    expect(await rowCount(ALICE)).toBe(MAX_BATCH_STEP_COUNTS);
  });

  it("refuses a chunk one row past the cap, and writes nothing", async () => {
    const response = await postBatch({ rows: batchRows("2026-08-22", MAX_BATCH_STEP_COUNTS + 1) });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    // One past rather than far past: the cap is a boundary and the only realistic defect is an
    // off-by-one in it, which a chunk of ten thousand would pass straight through.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a day carried twice, and writes nothing", async () => {
    const rows = batchRows("2026-08-22", 3);
    const response = await postBatch({ rows: [...rows, rows[0]!] });

    // Allowing this would be *nearly* harmless — the second write wins and the row on disk is whichever
    // the array happened to put last — and that is precisely the problem: a client that computed its
    // day set twice and disagreed with itself would get a `200` and a silently order-dependent result
    // instead of a `400` it can act on.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses an empty chunk", async () => {
    const response = await postBatch({ rows: [] });

    // An empty batch is a client that has not decided what to send. A `200` with `written: 0` would make
    // that look like a successful sync of nothing — and `written: 0` is a number this API must never
    // answer, because a replayed chunk legitimately reports a non-zero tally.
    expect(response.status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a row that carries no day of its own", async () => {
    const response = await postBatch({ rows: [measuredDay()] });

    // The day is required in a batch row and forbidden in a `PUT` body, and the two schemas enforce
    // opposite halves of that rule. Here there is no path to carry it, so a row without one does not
    // mean anything rather than meaning "today".
    expect(response.status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a row carrying a field the contract does not have", async () => {
    const rows = batchRows("2026-08-22", 2);
    const response = await postBatch({
      rows: [{ ...rows[0]!, source: "whoop_export" }, rows[1]!],
    });

    // `.strict()` matters more here than on the single-day body and for a reason that is about volume: a
    // batch is assembled by a client out of its own database, and a misspelled or invented field in one
    // row of two hundred is exactly the failure a silent strip would turn into one day's reading written
    // with a defaulted field and a `200` beside it. `source` is the tempting one on this resource,
    // because every sibling has it and this one must not.
    expect(response.status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("lands on the day keys the single-day write uses", async () => {
    const rows = batchRows("2026-08-22", 3);

    await postBatch({ rows });
    await put("2026-08-19", measuredDay({ stepCount: 55 }));

    // 08-19 sits immediately below the chunk and is written by a single-day `PUT` afterwards, so one
    // read over `days=3` — which is `[08-19, 08-22]` inclusive, four calendar days — returns the
    // chunk's three days and the `PUT` day interleaved in one ascending sequence. That is the whole
    // assertion: two paths writing one key space rather than two that merely overlap. If they keyed a
    // day differently the read would come back with four rows over three visible days, or with a day
    // missing from between two that are present, and either way the count and the sequence disagree.
    const list = await read("/v1/step-counts?days=3&endingOn=2026-08-22");
    const readBack = (await list.json()) as StepCountWire[];

    expect(readBack.map((row) => row.date)).toEqual([
      "2026-08-19",
      "2026-08-20",
      "2026-08-21",
      "2026-08-22",
    ]);
    expect(await rowCount(ALICE)).toBe(4);
    expect((await day(ALICE, "2026-08-19")).stepCount).toBe(55);
  });

  it("never deletes a day the caller leaves out", async () => {
    await postBatch({ rows: batchRows("2026-08-22", 3) });

    const response = await postBatch({ rows: [{ date: "2026-08-22", ...measuredDay({ stepCount: 7 }) }] });
    expect(response.status).toBe(200);

    // **The whole reason this endpoint is a `POST` on `/batch` and not a `PUT` on the collection.** A
    // `PUT` on `/v1/step-counts` would say "these are the days", which obliges the server to remove the
    // ones the caller left out — and this API has no delete path at all. That promise is worth more here
    // than on any sibling because a step history is mostly days the strap was not worn, so "these are
    // the days" would be a request to delete most of the user's record every time it was sent.
    expect(await rowCount(ALICE)).toBe(3);
    expect((await day(ALICE, "2026-08-20")).stepCount).toBe(8432);
    expect((await day(ALICE, "2026-08-22")).stepCount).toBe(7);
  });

  it("keeps one caller's chunk out of another's partition", async () => {
    await postBatch({ rows: batchRows("2026-08-22", 3) }, ALICE);
    await postBatch({ rows: [{ date: "2026-08-22", ...measuredDay({ stepCount: 91 }) }] }, BOB);

    // A batch is the widest write in this API and therefore the one whose partition is worth asserting
    // twice: three days in one caller's partition must not be reachable — or overwritten — from another.
    expect(await rowCount(ALICE)).toBe(3);
    expect(await rowCount(BOB)).toBe(1);

    const list = await read("/v1/step-counts?days=3&endingOn=2026-08-22", BOB);
    expect(((await list.json()) as StepCountWire[]).map((row) => row.date)).toEqual(["2026-08-22"]);
    expect((await day(BOB, "2026-08-22")).stepCount).toBe(91);
  });
});

describe("the chunk's transaction", () => {
  /**
   * The one thing in this file that is evidence about D1 rather than about this Worker.
   *
   * `D1StepCountRepository.upsertMany` writes a chunk through `env.DB.batch(...)` and relies on its
   * documented all-or-nothing behaviour for the promise the endpoint makes — *a failure writes nothing
   * and the same body can be sent again*. That promise is not reachable through HTTP with a valid
   * schema: every field a batch can carry is already checked by Zod, and `0005` declares **no CHECK
   * constraints** behind it either, so there is no body that passes validation and then fails in the
   * database.
   *
   * **This is a probe, and it is written as one.** If miniflare's local D1 ever stops rolling a batch
   * back — the two databases this repo runs against are already documented to differ — this test is
   * where that is learned, rather than in a sync that half-wrote a chunk and reported the failure with
   * no way to tell how far it got. On this resource a half-written chunk is the worst version of that
   * failure, because the days it dropped are exactly the days a later read cannot distinguish from days
   * the strap was not worn.
   */
  it("rolls a failed batch back rather than keeping the statements before it", async () => {
    const userId = await partition(ALICE);

    const lands = env.DB.prepare(
      "INSERT INTO step_counts (user_id, date, step_count, measured_seconds) VALUES (?, ?, ?, ?)",
    ).bind(userId, "2026-08-22", 8432, 41_760);

    // The second statement is missing every NOT NULL column but `user_id`, so it cannot land — and it is
    // the *second* deliberately: the question is whether the first one survives it.
    const fails = env.DB.prepare("INSERT INTO step_counts (user_id) VALUES (?)").bind(userId);

    await expect(env.DB.batch([lands, fails])).rejects.toThrow();

    expect(await rowCount(ALICE)).toBe(0);
  });

  it("leaves the table untouched when the repository's own chunk is refused", async () => {
    const rows = batchRows("2026-08-22", 3);

    // A chunk that is refused *before* it reaches D1 — here by the cap and by a repeated day — has
    // nothing to roll back, and the assertion is that the route validated before the service wrote
    // rather than after. Ordered against the previous test on purpose: one covers the transaction below
    // the endpoint, this one covers the fact that a refusal above it never opens one.
    await postBatch({ rows: batchRows("2026-08-22", MAX_BATCH_STEP_COUNTS + 1) });
    await postBatch({ rows: [...rows, rows[0]!] });

    expect(await rowCount(ALICE)).toBe(0);
  });
});
