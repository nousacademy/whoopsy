import { SELF, env } from "cloudflare:test";
import { authHeaders } from "../Support/auth";
import { beforeEach, describe, expect, it } from "vitest";
import { MAX_BATCH_SLEEPS, MAX_SLEEP_WINDOW_DAYS } from "../../src/services";
import { MAX_SLEEP_STAGES_LENGTH } from "../../src/dto/sleeps";
import { deriveUserId, MIN_KEY_LENGTH } from "../../src/utils/identity";

/**
 * `sleeps`, carried from HTTP through D1 and back.
 *
 * This file is `strains.spec.ts`'s sibling — both are day-keyed, one row per `(owner, day)`, with an
 * upsert, a range read and a chunk — and it is deliberately not a copy of it. Two of the sibling's
 * blocks have **no counterpart here at all**, and the absence is the interesting part:
 *
 *  - **There is no "a row that exists and was not measured" block.** `strains` stores a
 *    `hasMeasurement` flag, so a row can exist saying `false` and the same 404 code means something
 *    narrower one resource over. `sleeps` has no such column: a night the classifier could not read
 *    is an absent row, which is `recoveries`' rule, so `null` is the whole of this resource's absence
 *    and there is no pair to assert.
 *  - **There is no CHECK-constraint probe.** `0003_create_strains.sql` declares
 *    `CHECK (has_measurement IN (0, 1))` and the sibling writes an illegal integer straight at D1 to
 *    prove it is really there. `0004_create_sleeps.sql` declares **no CHECK constraints at all** —
 *    every rule this table has is enforced by a Zod schema above it — so there is nothing to probe,
 *    and a "constraint test" here would be an assertion about SQLite rather than about this Worker.
 *
 * What is *this* resource's own is the six nullable columns and the two boundary instants, and each
 * is a place a reader would be right to assume the sibling's answer:
 *
 *  - **Six fields can be `null` where `strains` has one**, and three of those six have a model on the
 *    client that would produce a plausible number if a server invited one. `?? 0` anywhere on the
 *    write path turns "the estimator declined" into a reading, which is why the null round trip is the
 *    longest block below.
 *  - **The two boundary instants are the only fields in this Worker's contract with a cross-field
 *    rule**, and it is enforced on **both** write bodies and on **neither** response. That asymmetry
 *    is asserted from both sides, because a response schema that could reject its own storage is a
 *    `500` waiting for a row written before the rule existed.
 *  - **The day is the night's *wake* day**, so the natural fixture — a night spanning midnight — is
 *    the one that would file itself a day early if anything re-derived the key from `startTime`.
 *
 * **The storage is fresh per test.** The pool's `isolatedStorage` is on, so the rows one `it` writes
 * are invisible to the next; nothing here clears a table by hand, and nothing depends on another test
 * having run.
 */

const BASE = "https://whoopsy.test";

/**
 * Two real keys, at the length the app sends: 32 random bytes, 43 base64url characters.
 *
 * The same two values `recoveries.spec.ts` and `strains.spec.ts` use, and for their reason verbatim —
 * `MIN_KEY_LENGTH` exists so a one-character header is not a partition, and a suite that kept short
 * fixtures would be the first caller the rule broke. What reaches `user_id` is `sha256` of one of
 * these, so every direct read against `env.DB` goes through `partition(_:)` rather than binding the
 * literal.
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

/** How many rows exist in one partition. Scoped, because an unqualified `COUNT(*)` is a claim about every caller's rows. */
async function rowCount(key: string, table = "sleeps"): Promise<number> {
  const counted = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`)
    .bind(await partition(key))
    .first<{ n: number }>();

  return counted?.n ?? 0;
}

/**
 * The wire shape, spelled out rather than inferred, so a renamed field fails here loudly.
 *
 * The six nullable fields are written as `| null` rather than as `?` on purpose: this resource's whole
 * absence rule is that a key is **present and null**, never stripped — a stripped key would be a third
 * state meaning nothing, which is why the contract declares `.nullable()` everywhere and `.optional()`
 * nowhere.
 */
interface SleepWire {
  date: string;
  startTime: string;
  endTime: string;
  sleepPerformance: number;
  totalSleepNeeded: number;
  lightSleep: number;
  deepSleep: number;
  remSleep: number;
  awakeTime: number;
  respiratoryRate: number | null;
  disturbanceCount: number | null;
  sleepConsistency: number | null;
  sleepDebt: number | null;
  sleepStages: string | null;
  source: string | null;
}

interface ErrorWire {
  error: { code: string; message: string };
}

/**
 * A measured night, with every nullable field absent.
 *
 * **This is the shape the app's own live path writes for an imported night**, and it is the fixture
 * rather than a night with six values in it, because the nulls are the case that breaks. The four
 * stage totals are the reference's own night — 7h33m asleep against a 9h17m need is 81% — and the two
 * boundaries are chosen so the arithmetic closes: `asleep + awake` is exactly 28800 s, which is
 * exactly the span from `23:12` to `07:12`. A reader can check that on a stored row, and the boundary
 * block below does.
 *
 * The night spans midnight deliberately. Its day is `2026-08-22` — the morning it woke on — so every
 * fixture in this file is a night whose `startTime` belongs to the *previous* day, and a layer that
 * re-derived the key would file them all a day early.
 */
function measuredNight(overrides: Partial<Omit<SleepWire, "date">> = {}): Omit<SleepWire, "date"> {
  return {
    startTime: "2026-08-21T23:12:00.000Z",
    endTime: "2026-08-22T07:12:00.000Z",
    sleepPerformance: 81.3,
    totalSleepNeeded: 33420,
    lightSleep: 18720,
    deepSleep: 5400,
    remSleep: 3060,
    awakeTime: 1620,
    respiratoryRate: null,
    disturbanceCount: null,
    sleepConsistency: null,
    sleepDebt: null,
    sleepStages: null,
    source: null,
    ...overrides,
  };
}

/**
 * The same night with all six nullable columns supplied.
 *
 * Written as `measuredNight` plus overrides so the two shapes cannot drift into having different
 * fields. The stage blob is `dto/sleeps.ts`'s own published example, copied verbatim rather than
 * composed here — it is the one string in this file whose exact bytes matter, and quoting the
 * contract's own example is what makes the round trip below a claim about the contract.
 */
function describedNight(overrides: Partial<Omit<SleepWire, "date">> = {}): Omit<SleepWire, "date"> {
  return measuredNight({
    respiratoryRate: 14.4,
    disturbanceCount: 7,
    sleepConsistency: 88,
    sleepDebt: 6240,
    sleepStages:
      '[{"id":"8B1F0C24-3E5A-4D77-9C21-6F0B7A2E4D18","start":1787372263000,"end":1787372293000,"stage":"Light"}]',
    source: "whoop_export",
    ...overrides,
  });
}

function put(date: string, body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/sleeps/${date}`, {
    method: "PUT",
    headers: { "content-type": "application/json", ...authHeaders(userId) },
    body: JSON.stringify(body),
  });
}

function read(path: string, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}${path}`, { headers: { ...authHeaders(userId) } });
}

function postBatch(body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/sleeps/batch`, {
    method: "POST",
    headers: { "content-type": "application/json", ...authHeaders(userId) },
    body: JSON.stringify(body),
  });
}

/**
 * `n` consecutive days ending on `endingOn`, oldest first, each carrying its own day.
 *
 * A batch row is a `measuredNight()` plus a `date`, so the fixture the single-day tests already use
 * is reused rather than restated — a second `measuredNight`-shaped literal here would be free to
 * drift from the one the `PUT` body is built out of.
 */
function batchRows(endingOn: string, n: number): (Omit<SleepWire, "date"> & { date: string })[] {
  const rows: (Omit<SleepWire, "date"> & { date: string })[] = [];
  const end = Date.parse(`${endingOn}T00:00:00Z`);

  for (let i = n - 1; i >= 0; i--) {
    const day = new Date(end - i * 86_400_000).toISOString().slice(0, 10);
    rows.push({ date: day, ...measuredNight() });
  }

  return rows;
}

async function day(userId: string, date: string): Promise<SleepWire> {
  const response = await read(`/v1/sleeps/${date}`, userId);
  expect(response.status).toBe(200);
  return (await response.json()) as SleepWire;
}

describe("a night written and read back", () => {
  it("returns the stored row, not an echo of the request", async () => {
    const body = describedNight();

    const written = await put("2026-08-22", body);
    expect(written.status).toBe(200);

    const stored = (await written.json()) as SleepWire;
    expect(stored).toEqual({ date: "2026-08-22", ...body });

    // The read is the assertion that the response was the database's answer rather than the
    // request's: the two agree here only because the write really happened.
    expect(await day(ALICE, "2026-08-22")).toEqual(stored);
  });

  it("replaces a night's row when the same day is written twice", async () => {
    await put("2026-08-22", measuredNight({ sleepPerformance: 81.3 }));
    await put("2026-08-22", measuredNight({ sleepPerformance: 64.9 }));

    // `saveSleep` is INSERT-or-UPDATE by primary key, and `sleeps` is keyed on the day — so a second
    // write of one night must leave one row and not two. This is the assertion that fails if the
    // primary key is ever widened to include something else "for safety", and on this table the
    // tempting extra key is the night's own onset, which a client might reasonably think identifies
    // a night. It does not: the app files a night under its wake day and nothing else.
    expect(await rowCount(ALICE)).toBe(1);
    expect((await day(ALICE, "2026-08-22")).sleepPerformance).toBe(64.9);
  });

  it("keeps the night's span equal to its four stage totals", async () => {
    await put("2026-08-22", measuredNight());
    const stored = await day(ALICE, "2026-08-22");

    // The identity a reader can check on the screen itself — `asleep + awake == duration` — asserted
    // against the row as it came back. It is not a restatement of the fixture: the four totals and the
    // two instants reach the database through six separate bindings and come back through six separate
    // columns, so a `start_time`/`end_time` pair swapped *in the adapter's own two places* (which a
    // plain equality round trip cannot see) shows up here as a sign flip.
    const duration = (Date.parse(stored.endTime) - Date.parse(stored.startTime)) / 1000;
    expect(duration).toBe(28_800);
    expect(stored.lightSleep + stored.deepSleep + stored.remSleep + stored.awakeTime).toBe(duration);
  });

  it("files a night that spans midnight under the morning it woke on", async () => {
    await put("2026-08-22", measuredNight());

    // Three claims that are one claim. The night starts on the 21st and is filed on the 22nd; the day
    // before has no row; and the read at the start instant's own day is therefore a 404. That is the
    // app's convention — `CalculateRecoveryUseCase` reads the sleep session *for the day it is
    // scoring* — and it is the one thing about this resource most likely to be re-derived by someone
    // reading `startTime` and reaching for `slice(0, 10)`.
    expect((await day(ALICE, "2026-08-22")).date).toBe("2026-08-22");
    expect((await read("/v1/sleeps/2026-08-21")).status).toBe(404);
    expect(await rowCount(ALICE)).toBe(1);
  });
});

describe("NULL is not 0", () => {
  it("carries all six nullable columns back as keys that are present and null", async () => {
    await put("2026-08-22", measuredNight());
    const stored = await day(ALICE, "2026-08-22");

    // Six, not one — that is the whole of what this block is for. `strains` has a single nullable
    // column and its assertion can name it; here a sweep is the only honest form, because the failure
    // this catches is one field being filled in while the other five stay right.
    for (const field of [
      "respiratoryRate",
      "disturbanceCount",
      "sleepConsistency",
      "sleepDebt",
      "sleepStages",
      "source",
    ] as const) {
      expect(Object.hasOwn(stored, field)).toBe(true);
      expect(stored[field]).toBeNull();
    }

    // And the eight non-nullable ones are really there, so the sweep above cannot pass on a payload
    // that dropped every field it was not asked about.
    expect(Object.keys(stored).sort()).toEqual(
      [
        "awakeTime",
        "date",
        "deepSleep",
        "disturbanceCount",
        "endTime",
        "lightSleep",
        "remSleep",
        "respiratoryRate",
        "sleepConsistency",
        "sleepDebt",
        "sleepPerformance",
        "sleepStages",
        "source",
        "startTime",
        "totalSleepNeeded",
      ].sort(),
    );
  });

  it("returns every nullable field when one is supplied", async () => {
    await put("2026-08-22", describedNight());

    // The other direction, and it is a separate assertion rather than the same one reversed: a mapper
    // that replaced `null` with a default would pass the test above and fail this one, and a mapper
    // that dropped non-null values would do the opposite. On this resource three of these six are
    // values a device model computes, so "the client sent one and got it back" is the contract.
    const stored = await day(ALICE, "2026-08-22");
    expect(stored.respiratoryRate).toBe(14.4);
    expect(stored.disturbanceCount).toBe(7);
    expect(stored.sleepConsistency).toBe(88);
    expect(stored.sleepDebt).toBe(6240);
    expect(stored.source).toBe("whoop_export");
  });

  it("keeps a measured zero distinct from an absent value on the same column", async () => {
    await put("2026-08-22", measuredNight({ disturbanceCount: null, sleepDebt: null }));
    await put("2026-08-23", measuredNight({ disturbanceCount: 0, sleepDebt: 0 }));

    // **This pair is the resource's whole absence rule stated as one fixture.** A `0` disturbance
    // count is a night nobody stirred and a `0` debt is a night in perfect credit; `null` on either
    // is "nobody scored this". They are one keystroke apart in a payload and a `??` anywhere on the
    // path collapses them — and the collapse is invisible, because a zero is a perfectly plausible
    // reading on both columns.
    const absent = await day(ALICE, "2026-08-22");
    const measured = await day(ALICE, "2026-08-23");

    expect(absent.disturbanceCount).toBeNull();
    expect(absent.sleepDebt).toBeNull();
    expect(measured.disturbanceCount).toBe(0);
    expect(measured.sleepDebt).toBe(0);
  });

  it("refuses an empty provenance rather than storing it as a value", async () => {
    const response = await put("2026-08-22", measuredNight({ source: "" }));

    // `min(1)`. An empty string is a value nobody supplied, and the whole point of the column being
    // nullable is that absence already has a spelling — so `""` would put two spellings of "no
    // producer" on one column and no reader could tell which was meant. That matters more here than
    // on `strains`: `source` is the *only* thing separating WHOOP's figure from this app's on four
    // columns, and a second empty spelling is a second way for that gate to be got wrong.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a body that carries a date of its own rather than stripping it", async () => {
    const response = await put("2026-08-22", { ...measuredNight(), date: "2026-08-23" });

    // `.strict()` on the write schema, and this is the key that matters: every field the body
    // legitimately carries is required, so a misspelling is already caught by the missing-field check.
    // `date` is the key a client has a second opinion about, and on this resource the opinion is a
    // whole day out — the night's *wake* day is exactly the thing a client computing it locally is
    // most likely to have got wrong.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });
});

describe("the stage blob", () => {
  it("round-trips byte-for-byte and is never parsed", async () => {
    const blob =
      '[{"id":"8B1F0C24-3E5A-4D77-9C21-6F0B7A2E4D18","start":1787372263000,"end":1787372293000,"stage":"Light"}]';

    await put("2026-08-22", measuredNight({ sleepStages: blob }));
    const stored = await day(ALICE, "2026-08-22");

    // The string is bound and copied, and the assertion is on the *string* rather than on a parsed
    // form: this Worker takes no opinion about the JSON inside it, so an adapter that parsed and
    // re-serialised would be free to reorder keys, drop whitespace or — the failure that matters —
    // reformat the two instants, which are unix **milliseconds** and not this API's instant format.
    // Byte equality is the only assertion that says a server did not touch it.
    expect(stored.sleepStages).toBe(blob);
  });

  it("accepts a blob that is not JSON at all", async () => {
    // Deliberate: `sleepStages` is a `string` with a length bound and no content rule, so a client
    // that PUTs garbage gets the same garbage back. That is the property a sync exists for — the
    // alternative is a second decoder here that has to agree with the app's `Codable` one forever,
    // and a disagreement would surface as a night losing its timeline rather than as an error.
    expect((await put("2026-08-22", measuredNight({ sleepStages: "not json" }))).status).toBe(200);
    expect((await day(ALICE, "2026-08-22")).sleepStages).toBe("not json");
  });

  it("refuses an empty blob and one past the published bound", async () => {
    // The empty string is refused because a night with no stages and a night that was never staged
    // are the same thing, and `null` is that thing's only representation — so `""` would be a second.
    expect((await put("2026-08-22", measuredNight({ sleepStages: "" }))).status).toBe(400);

    // The ceiling is `MAX_SLEEP_STAGES_LENGTH`, imported rather than typed here, so this assertion
    // moves with the constant instead of against it. It is a payload-shape bound with no policy
    // behind it, which is why it lives in the schema and not beside the window's cap.
    const overlong = "x".repeat(MAX_SLEEP_STAGES_LENGTH + 1);
    expect((await put("2026-08-22", measuredNight({ sleepStages: overlong }))).status).toBe(400);
    expect((await put("2026-08-22", measuredNight({ sleepStages: "x" }))).status).toBe(200);
  });
});

describe("the night's boundaries", () => {
  it("refuses a night of zero length", async () => {
    const response = await put(
      "2026-08-22",
      measuredNight({ startTime: "2026-08-21T23:12:00.000Z", endTime: "2026-08-21T23:12:00.000Z" }),
    );

    // **Strictly after, not "not before".** The refinement's own words are asserted because it is the
    // only cross-field rule in this resource's contract: every other refusal in this file is a bound
    // on one field, and this is the one a reader would have to open the schema to find.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain(
      "endTime must be strictly after startTime — a night of zero length is not a night",
    );
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a reversed night", async () => {
    const response = await put(
      "2026-08-22",
      measuredNight({ startTime: "2026-08-22T07:12:00.000Z", endTime: "2026-08-21T23:12:00.000Z" }),
    );

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("reads back a reversed row a writer put there, because the response schema does not refine", async () => {
    const userId = await partition(ALICE);

    // **The asymmetry, asserted from the side that matters.** Both write bodies refine; the response
    // schema deliberately does not, because a response schema that could reject its own storage turns
    // a legacy row into a `500` — and this table has no CHECK behind it, so a writer that bypassed the
    // endpoint can leave exactly this row. Written directly against D1 because no valid body can reach
    // it: the two writes above are the assertions that a client cannot, and this one is the assertion
    // that a stored one is still readable.
    await env.DB.prepare(
      "INSERT INTO sleeps (user_id, date, start_time, end_time, sleep_performance, total_sleep_needed, light_sleep, deep_sleep, rem_sleep, awake_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )
      .bind(userId, "2026-08-22", "2026-08-22T07:12:00.000Z", "2026-08-21T23:12:00.000Z", 81.3, 33420, 18720, 5400, 3060, 1620)
      .run();

    const response = await read("/v1/sleeps/2026-08-22");

    expect(response.status).toBe(200);
    expect(((await response.json()) as SleepWire).endTime).toBe("2026-08-21T23:12:00.000Z");
  });

  it("refuses an instant that is not in the one canonical spelling", async () => {
    // Four spellings of the same instant, and every one of them is refused. The reason is `ORDER BY`:
    // the column is TEXT, and a fixed-width UTC spelling is what makes a string sort chronological.
    // `…:00Z` and `…:00.000000Z` are the two a client with its own formatter sends.
    for (const startTime of [
      "2026-08-21T23:12:00Z",
      "2026-08-21T23:12:00.000+00:00",
      "2026-08-21T23:12:00.000000Z",
      "2026-08-21T23:12:00.000",
      "2026-08-21 23:12:00.000Z",
    ]) {
      const response = await put("2026-08-22", measuredNight({ startTime }));

      expect(response.status).toBe(400);
      expect((await response.json() as ErrorWire).error.message).toContain(
        "must be an instant in canonical UTC form",
      );
    }

    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses an instant the calendar does not have", async () => {
    // The regex accepts this and `Date.parse` rolls it to March 3, so the refusal is the round trip
    // through `toISOString()` rather than the shape of the string — the same two-half rule the day
    // key's own refusal has, applied to a different format.
    expect((await put("2026-08-22", measuredNight({ endTime: "2026-02-31T00:00:00.000Z" }))).status).toBe(400);
  });
});

describe("the performance's scale", () => {
  it("accepts both ends of the 0–100 scale", async () => {
    for (const [date, performance] of [
      ["2026-08-22", 0],
      ["2026-08-23", 100],
    ] as const) {
      expect((await put(date, measuredNight({ sleepPerformance: performance }))).status).toBe(200);
      expect((await day(ALICE, date)).sleepPerformance).toBe(performance);
    }
  });

  it("refuses a figure outside the scale", async () => {
    // The bounds are the scale's definition rather than a guard against a typo, so they are asserted
    // at the edges: a `100` passes and a `100.1` does not. A figure outside them describes a
    // different quantity — the app's own performance is a clamped `asleep ÷ need`, so nothing on the
    // device can produce one.
    expect((await put("2026-08-22", measuredNight({ sleepPerformance: 100.1 }))).status).toBe(400);
    expect((await put("2026-08-22", measuredNight({ sleepPerformance: -0.1 }))).status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("accepts a one-decimal figure the app really holds", async () => {
    // **The assertion that a `multipleOf(0.1)` refinement is absent, and it is here because the
    // refinement is the obvious thing to add.** `81.3 % 0.1` is not zero in IEEE-754, so a
    // float-modulo refinement would refuse a value the app computes on every night — and the failure
    // would arrive as a 400 on real data with nothing in the message naming the float.
    const response = await put("2026-08-22", measuredNight({ sleepPerformance: 81.3 }));

    expect(response.status).toBe(200);
    expect((await response.json() as SleepWire).sleepPerformance).toBe(81.3);
  });

  it("refuses a performance that is not a number at all", async () => {
    // `JSON.stringify` turns `NaN` into `null`, so the interesting half is the type check rather than
    // the finiteness one — but a body carrying a string is what a client with a formatter bug sends,
    // and `z.number()` is what refuses it.
    expect((await put("2026-08-22", measuredNight({ sleepPerformance: "81.3" as unknown as number }))).status).toBe(400);
    expect((await put("2026-08-22", measuredNight({ sleepPerformance: NaN }))).status).toBe(400);
  });

  it("refuses a negative stage total or requirement", async () => {
    // Non-negative rather than positive is the rule — a night of no deep sleep is a real night, and
    // the export holds one with 15h40m of light sleep and no deep or REM at all — but the floor is
    // still a floor. A negative duration is not a measurement this app can produce or store.
    expect((await put("2026-08-22", measuredNight({ lightSleep: -1 }))).status).toBe(400);
    expect((await put("2026-08-22", measuredNight({ totalSleepNeeded: -1 }))).status).toBe(400);
    expect((await put("2026-08-22", measuredNight({ sleepDebt: -1 }))).status).toBe(400);
    expect((await put("2026-08-22", measuredNight({ respiratoryRate: -1 }))).status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("accepts a zero stage total, which is a measurement", async () => {
    // The pair to the refusals above, and the reason the bounds are `nonnegative` rather than
    // `positive`. 2024-12-10 in the bundled export is 15h40m of light sleep with no deep and no REM:
    // a real night, and one a `positive()` bound would refuse.
    await put("2026-08-22", measuredNight({ deepSleep: 0, remSleep: 0 }));

    const stored = await day(ALICE, "2026-08-22");
    expect(stored.deepSleep).toBe(0);
    expect(stored.remSleep).toBe(0);
    expect(stored.lightSleep).toBe(18720);
  });

  it("refuses a fractional count or consistency", async () => {
    // `z.number().int()` on the two whole-number columns. A disturbance count is a tally and WHOOP's
    // consistency is a whole percent, so a fraction is a value from some other producer — and
    // rounding it here would invent a reading rather than lose one.
    expect((await put("2026-08-22", measuredNight({ disturbanceCount: 7.5 }))).status).toBe(400);
    expect((await put("2026-08-22", measuredNight({ sleepConsistency: 88.5 }))).status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a consistency outside 0–100", async () => {
    // The one nullable field with its own range. `null` is "not scored" and is refused no more than
    // any other value is — the bound is on the figure, not on its presence.
    expect((await put("2026-08-22", measuredNight({ sleepConsistency: 101 }))).status).toBe(400);
    expect((await put("2026-08-22", measuredNight({ sleepConsistency: -1 }))).status).toBe(400);
    expect((await put("2026-08-22", measuredNight({ sleepConsistency: 0 }))).status).toBe(200);
  });
});

describe("the day key", () => {
  it("refuses a key carrying a time component", async () => {
    const response = await put("2026-08-22T07:12:00Z", measuredNight());

    // Refused, and deliberately not snapped. The app snaps because it can — `startOfDay` is the
    // device's own calendar — and a server cannot re-derive a client's midnight without the client's
    // zone. Snapping here would store a key the client's own read could not find, and on this
    // resource it would be worse than on either sibling: the key is the *wake* day, so a snap in the
    // wrong zone moves the night onto the day before it.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain(
      "must be a calendar day in YYYY-MM-DD form",
    );
  });

  it("refuses a calendar day that does not exist", async () => {
    // A regex alone lets this through and `Date.parse` rolls it forward to March 3, so the refusal is
    // the round trip through `Date.UTC` rather than the shape of the string.
    expect((await put("2026-02-31", measuredNight())).status).toBe(400);
  });

  it("stores nothing when it refuses", async () => {
    await put("2026-08-22T07:12:00Z", measuredNight());

    // Scoped to the partition rather than the whole table: an unqualified count is a claim about
    // every caller's rows and would pass for the wrong reason the day another test's storage leaked.
    expect(await rowCount(ALICE)).toBe(0);
  });
});

describe("a day with no row at all", () => {
  it("is a 404 naming the code, not a zero-filled row", async () => {
    await put("2026-08-21", measuredNight());

    const response = await read("/v1/sleeps/2026-08-22");

    // **The only absence this resource has.** `strains` reuses the same code for a *narrower* thing —
    // a row that exists carrying `hasMeasurement: false` is a 200 there — so the code's meaning has to
    // be read per resource. Here it is `recoveries`' meaning and nothing else: no row, no measurement.
    // The whole message is asserted, including the day, because it is the only thing in the response
    // that says *which* night was absent.
    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({
      error: {
        code: "no_measurement_for_day",
        message: "no sleep measured on 2026-08-22",
      },
    });
  });

  it("is omitted from a window rather than zero-filled", async () => {
    for (const date of ["2026-08-20", "2026-08-22"]) {
      await put(date, measuredNight());
    }

    const response = await read("/v1/sleeps?days=4&endingOn=2026-08-22");
    const rows = (await response.json()) as SleepWire[];

    // 08-21 is inside the window and absent from the answer. On this resource that hole is the
    // ordinary case rather than an edge — a night the user did not wear the strap — which is why the
    // omission and not the count is the assertion.
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
      await put(date, measuredNight());
    }
  });

  it("returns days + 1 calendar days, oldest first", async () => {
    const response = await read("/v1/sleeps?days=2&endingOn=2026-08-22");
    const rows = (await response.json()) as SleepWire[];

    // The app's own arithmetic, mirrored rather than corrected: `from = endingOn - days`, inclusive
    // at both ends, so `days: 14` is fifteen days. A ported `getSleepHistory(days:endingOn:)` returns
    // what it returned on-device, and the off-by-one is a written-down fact rather than a surprise.
    expect(rows.map((row) => row.date)).toEqual(["2026-08-20", "2026-08-21", "2026-08-22"]);
  });

  it("excludes a day one past the upper bound", async () => {
    const response = await read("/v1/sleeps?days=2&endingOn=2026-08-22");
    const rows = (await response.json()) as SleepWire[];

    // 08-23 is stored and outside `[endingOn - days, endingOn]`. A range read that ran on to the
    // present — which is what `getSleepHistory(days:)` does on-device when it is not handed
    // `endingOn:` — would return it here, and the lower-bound test above cannot see that.
    expect(rows.map((row) => row.date)).not.toContain("2026-08-23");
  });

  it("takes days = 0 to mean the ending day alone", async () => {
    const response = await read("/v1/sleeps?days=0&endingOn=2026-08-22");
    const rows = (await response.json()) as SleepWire[];

    expect(rows.map((row) => row.date)).toEqual(["2026-08-22"]);
  });

  it("refuses a window wider than the service's ceiling", async () => {
    const response = await read(`/v1/sleeps?days=${MAX_SLEEP_WINDOW_DAYS + 1}&endingOn=2026-08-22`);

    // `MAX_SLEEP_WINDOW_DAYS` and not `MAX_STRAIN_WINDOW_DAYS`, which is the same `4000` today. The
    // two are separate published limits — see the constants' own docs — and this is the assertion
    // that would catch a route wired to the wrong one, which on this pair is the likeliest wiring
    // mistake in the Worker, the two resources being the ones that are alike.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a non-numeric days rather than coercing it to a window", async () => {
    // `z.coerce.number()` is what turns the query string into a number, and it is also what refuses
    // this: `Number("fortnight")` is `NaN`, which the `.int()` check rejects. Without the coercion
    // the schema would be testing a string against a numeric bound and every value would pass.
    expect((await read("/v1/sleeps?days=fortnight&endingOn=2026-08-22")).status).toBe(400);
  });

  it("refuses a fractional days", async () => {
    expect((await read("/v1/sleeps?days=1.5&endingOn=2026-08-22")).status).toBe(400);
  });

  it("answers an empty array when nothing in the window has a row", async () => {
    const response = await read("/v1/sleeps?days=2&endingOn=2020-01-02");

    // A real answer rather than an error — and on this resource the distinction is sharper than on
    // either sibling, because an empty window and a window of unmeasured nights are *the same
    // absence*: there is no flag to tell a hole from an unworn night, so `[]` is the only honest
    // answer for both.
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual([]);
    expect(await rowCount(ALICE)).toBe(6);
  });
});

describe("the partition", () => {
  it("keeps one user's night invisible to another", async () => {
    await put("2026-08-22", measuredNight(), ALICE);

    expect((await read("/v1/sleeps/2026-08-22", ALICE)).status).toBe(200);
    // Nothing verifies the header yet, so this is the `user_id` column doing real work: the row is
    // there, and a different owner cannot reach it.
    expect((await read("/v1/sleeps/2026-08-22", BOB)).status).toBe(404);

    const list = await read("/v1/sleeps?days=2&endingOn=2026-08-22", BOB);
    expect(await list.json()).toEqual([]);
  });

  it("lets two users hold the same day without colliding", async () => {
    await put("2026-08-22", measuredNight({ sleepPerformance: 81.3 }), ALICE);
    await put("2026-08-22", measuredNight({ sleepPerformance: 43.7 }), BOB);

    expect((await day(ALICE, "2026-08-22")).sleepPerformance).toBe(81.3);
    expect((await day(BOB, "2026-08-22")).sleepPerformance).toBe(43.7);
  });

  it("files the row under the digest of the key, never under the key", async () => {
    await put("2026-08-22", measuredNight());

    // The second read is the one that matters. The first says the row is reachable at all; the second
    // says the column holds something that is *not* the header, which is the whole of what a D1 dump
    // leaking no usable credentials means. A `user_id` equal to `ALICE` would satisfy every other test
    // in this file — the requests would still work, because the same string would be hashed on the way
    // in and matched on the way out — and would be a database of working keys.
    expect(await rowCount(ALICE)).toBe(1);

    const keyed = await env.DB.prepare("SELECT COUNT(*) AS n FROM sleeps WHERE user_id = ?")
      .bind(ALICE)
      .first<{ n: number }>();

    expect(keyed?.n).toBe(0);
  });
});

describe("identity", () => {
  it("refuses a request with no X-Whoopsy-User-Id", async () => {
    const response = await SELF.fetch(`${BASE}/v1/sleeps?days=2&endingOn=2026-08-22`, { headers: { ...authHeaders() } });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses an empty X-Whoopsy-User-Id", async () => {
    const response = await read("/v1/sleeps/2026-08-22", "");

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a key one character below the floor", async () => {
    const short = "a".repeat(MIN_KEY_LENGTH - 1);

    // The boundary from the inside, because the guard is a length test and an off-by-one is its only
    // realistic defect: `>=` spelled `>` would admit exactly this string and pass every other test in
    // this file, including the empty-key one above — nothing else here is near the edge.
    expect((await read("/v1/sleeps/2026-08-22", short)).status).toBe(400);

    // And one character above it is accepted, so the pair pins a boundary rather than restating a
    // refusal that a blank check would also produce. `404` rather than `200` because no night has been
    // written in this test — the status is the proof the header was let through, and it is the only
    // observable that separates "accepted" from "refused" without a fixture.
    expect((await read("/v1/sleeps/2026-08-22", "a".repeat(MIN_KEY_LENGTH))).status).toBe(404);
  });

  it("refuses a header on the batch endpoint too", async () => {
    const response = await SELF.fetch(`${BASE}/v1/sleeps/batch`, {
      method: "POST",
      headers: { "content-type": "application/json", ...authHeaders() },
      body: JSON.stringify({ rows: batchRows("2026-08-22", 1) }),
    });

    // Every handler goes through `partitionFor`, and this is the assertion that the batch route is
    // not the one that reads the raw header: it has a body to parse and a path with no parameters, so
    // it is the route most likely to be written without the identity step. On this resource the
    // consequence of missing it would be a sixteen-column night filed in a partition nobody can read.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    expect(await rowCount(ALICE)).toBe(0);
  });
});

describe("a chunk of nights", () => {
  it("writes every row and answers with the database's tally", async () => {
    const rows = batchRows("2026-08-22", 3);

    const response = await postBatch({ rows });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ written: 3 });

    // The read is the assertion that the tally was about real rows: a `written` counted from the
    // request's own array would be the same number here, and would disagree with the table the moment
    // an upsert stopped landing.
    expect(await rowCount(ALICE)).toBe(3);

    const list = await read("/v1/sleeps?days=3&endingOn=2026-08-22");
    expect(((await list.json()) as SleepWire[]).map((row) => row.date)).toEqual([
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
    // `(userId, date)` pair the single-day `PUT` writes, so replaying it cannot append.
    expect(await rowCount(ALICE)).toBe(3);
  });

  it("replaces a whole night rather than merging two versions of it", async () => {
    await put("2026-08-22", describedNight());

    await postBatch({ rows: [{ date: "2026-08-22", ...measuredNight() }] });

    // The upsert sets every column from `excluded`, so a batch row is the whole row and not a patch.
    // A merge would leave this night with the six nullable columns of the `PUT` — a `source` of
    // `whoop_export`, a debt, a consistency and a stage timeline — and the four stage totals of the
    // batch row, which is a night assembled from two producers and attributable to neither. That is
    // worse here than on `strains`, where the equivalent merge leaves one flag wrong.
    const stored = await day(ALICE, "2026-08-22");
    expect(stored).toEqual({ date: "2026-08-22", ...measuredNight() });
    expect(stored.source).toBeNull();
    expect(stored.sleepStages).toBeNull();
    expect(await rowCount(ALICE)).toBe(1);
  });

  it("writes a full chunk of the cap in one request", async () => {
    const rows = batchRows("2026-08-22", MAX_BATCH_SLEEPS);

    const response = await postBatch({ rows });

    expect(response.status).toBe(200);
    // The cap is the app's whole sleep history in five requests — 910 nights over 910 distinct days —
    // so this is the real corpus's chunk size rather than a round number. `written` is also the
    // assertion that would catch a `NaN` from a `meta.changes` this runtime did not report, and on a
    // two-hundred-statement batch it is the only assertion in this file that would see it.
    expect(await response.json()).toEqual({ written: MAX_BATCH_SLEEPS });
    expect(await rowCount(ALICE)).toBe(MAX_BATCH_SLEEPS);
  });

  it("refuses a chunk one row past the cap, and writes nothing", async () => {
    const response = await postBatch({ rows: batchRows("2026-08-22", MAX_BATCH_SLEEPS + 1) });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    // Nothing, not "the first two hundred". The cap is a refusal rather than a truncation because a
    // client whose chunk was silently trimmed would believe the whole range had been uploaded — and
    // on this resource a trimmed chunk is likelier than on either sibling, since a night's blob makes
    // the body the largest this Worker accepts.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a day carried twice, and writes nothing", async () => {
    const rows = batchRows("2026-08-22", 2);
    const response = await postBatch({ rows: [...rows, rows[1]!] });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    // The alternative is *nearly* harmless — the second write wins and the row on disk is whichever
    // the array put last — which is exactly the failure: a `200` whose result depends on the order of
    // an array the client built, reported as success. The stakes are the highest on this resource of
    // the three that share the rule: a night carries fourteen fields and two versions of it could
    // differ in any of them, so the day would end up holding a night assembled from one array position
    // and its boundary instants from another, with nothing anywhere reporting it.
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
    const response = await postBatch({ rows: [measuredNight()] });

    // The day is in the body here and in the path on the `PUT`, so this is the half that has no other
    // spelling: a row without one would have to be filed somewhere, and on this resource every
    // candidate is a day out — the night's own onset is the *previous* day. The path is asserted
    // rather than only the status because it is what names the offending row among 200.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("rows.0.date");
  });

  it("refuses a row carrying a field the contract does not have", async () => {
    const rows = batchRows("2026-08-22", 2);
    const response = await postBatch({
      rows: [rows[0], { ...rows[1], sleepPerformace: 64.9 }],
    });

    // `.strict()`, and it matters more at this volume than on the single-day body: a batch is
    // assembled by a client out of its own database, and a misspelled field in one row of two hundred
    // is exactly the failure a silent strip turns into one night written with a null where a
    // measurement was and a `200` beside it. The index names the row, which is what makes it findable
    // among 200 — and here the misspelling is the plausible one, a transposed vowel in the field whose
    // absence a reader would most readily read as "the estimator declined".
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("rows.1");
  });

  it("refuses a row whose boundaries are reversed", async () => {
    // `endsAfterItStarts` is stated twice — once on the `PUT` body and once on the batch row — and the
    // two are separate schemas that could drift. This is the batch half, asserted on the same message
    // the `PUT` half asserts above, because a rule that held on one body and not the other would let
    // a client write through `/batch` a night it could not write through `/{date}`.
    const response = await postBatch({
      rows: [
        {
          date: "2026-08-22",
          ...measuredNight({ startTime: "2026-08-22T07:12:00.000Z", endTime: "2026-08-21T23:12:00.000Z" }),
        },
      ],
    });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain(
      "endTime must be strictly after startTime — a night of zero length is not a night",
    );
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("round-trips a row's nullable fields through a batch as faithfully as through a PUT", async () => {
    await postBatch({
      rows: [
        { date: "2026-08-22", ...describedNight() },
        { date: "2026-08-23", ...measuredNight() },
      ],
    });

    // The two write paths are two schemas and two bindings lists reaching one table, so the pair is
    // the assertion: a batch row's six nullables must survive the same round trip the single-day body
    // gives them. `upsertMany` binds through the same `bindings` function `upsert` uses, and this is
    // what fails if a future refactor gives it its own.
    expect(await day(ALICE, "2026-08-22")).toEqual({ date: "2026-08-22", ...describedNight() });
    expect(await day(ALICE, "2026-08-23")).toEqual({ date: "2026-08-23", ...measuredNight() });
  });

  it("lands on the day keys the single-day write uses", async () => {
    await put("2026-08-22", measuredNight({ sleepPerformance: 81.3 }));

    const response = await postBatch({
      rows: [
        { date: "2026-08-22", ...measuredNight({ sleepPerformance: 64.9 }) },
        { date: "2026-08-23", ...measuredNight() },
      ],
    });

    expect(response.status).toBe(200);
    // Three claims in one pair. The day the `PUT` wrote is *replaced* rather than duplicated, so the
    // batch and the single-day write share one key — which is the whole of what `partitionFor` exists
    // for, since a batch that hashed the header differently from the `PUT` would file the same night in
    // two partitions and neither request would report anything.
    expect(await rowCount(ALICE)).toBe(2);
    expect((await day(ALICE, "2026-08-22")).sleepPerformance).toBe(64.9);

    // And a day with no row yet is inserted by the same call, so the two verbs are one upsert.
    expect((await day(ALICE, "2026-08-23")).sleepPerformance).toBe(81.3);
  });

  it("never deletes a day the caller leaves out", async () => {
    const rows = batchRows("2026-08-22", 3);
    await postBatch({ rows });

    // One day of the three, alone in the chunk.
    await postBatch({ rows: [rows[1]!] });

    const list = await read("/v1/sleeps?days=3&endingOn=2026-08-22");
    // All three are still there. This is why the endpoint is a `POST` on `/batch` and not a `PUT` on
    // the collection: "these are the nights" obliges the server to remove the ones left out, and a
    // client whose retry sent a *partial* chunk — the rest of it lost to a timeout — would erase its
    // own sleep history while being told the request succeeded. On a nine-hundred-night history with
    // holes in it, that is a fourth of the record on the first sync of a partially-worn range.
    expect(((await list.json()) as SleepWire[]).map((row) => row.date)).toEqual([
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

    const list = await read("/v1/sleeps?days=3&endingOn=2026-08-22", BOB);
    expect(((await list.json()) as SleepWire[]).map((row) => row.date)).toEqual(["2026-08-22"]);
  });
});

describe("the chunk's transaction", () => {
  /**
   * The one thing in this file that is evidence about D1 rather than about this Worker.
   *
   * `D1SleepRepository.upsertMany` writes a chunk through `env.DB.batch(...)` and relies on its
   * documented all-or-nothing behaviour for the promise the endpoint makes — *a failure writes nothing
   * and the same body can be sent again*. That promise is not reachable through HTTP with a valid
   * schema: every field a batch can carry is already checked by Zod, and this table has **no CHECK
   * constraints** behind it either, so there is no body that passes validation and then fails in the
   * database.
   *
   * **This is a probe, and it is written as one.** If miniflare's local D1 ever stops rolling a batch
   * back — the two databases this repo runs against are already documented to differ — this test is
   * where that is learned, rather than in a sync that half-wrote a chunk and reported the failure with
   * no way to tell how far it got.
   */
  it("rolls a failed batch back rather than keeping the statements before it", async () => {
    const userId = await partition(ALICE);

    const lands = env.DB.prepare(
      "INSERT INTO sleeps (user_id, date, start_time, end_time, sleep_performance, total_sleep_needed, light_sleep, deep_sleep, rem_sleep, awake_time) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    ).bind(userId, "2026-08-22", "2026-08-21T23:12:00.000Z", "2026-08-22T07:12:00.000Z", 81.3, 33420, 18720, 5400, 3060, 1620);

    // The second statement is missing every NOT NULL column but `user_id`, so it cannot land — and it
    // is the *second* deliberately: the question is whether the first one survives it.
    const fails = env.DB.prepare("INSERT INTO sleeps (user_id) VALUES (?)").bind(userId);

    await expect(env.DB.batch([lands, fails])).rejects.toThrow();

    expect(await rowCount(ALICE)).toBe(0);
  });

  it("leaves the table untouched when the repository's own chunk is refused", async () => {
    const rows = batchRows("2026-08-22", 3);

    // A chunk that is refused *before* it reaches D1 — here by the cap and by a repeated day — has
    // nothing to roll back, and the assertion is that the route validated before the service wrote
    // rather than after. Ordered against the previous test on purpose: one covers the transaction
    // below the endpoint, this one covers the fact that a refusal above it never opens one.
    await postBatch({ rows: batchRows("2026-08-22", MAX_BATCH_SLEEPS + 1) });
    await postBatch({ rows: [...rows, rows[0]!] });

    expect(await rowCount(ALICE)).toBe(0);
  });
});
