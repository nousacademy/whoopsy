import { SELF, env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import {
  MAX_BATCH_BIOMETRIC_SAMPLES,
  MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS,
} from "../../src/services";
import { deriveUserId, MIN_KEY_LENGTH } from "../../src/utils/identity";

/**
 * The seventh resource, and the first whose subject is neither a day nor a session: one notification
 * from the strap, written and read as one flat row in a table that a single worn day fills 86,400
 * times over.
 *
 * `receptiveInactivities.spec.ts` is the template and this file keeps its shape — the same two keys,
 * the same `partition`/`rowCount`/`put`/`read`/`postBatch` helpers, the same fresh storage per test —
 * so that what is *this* resource's is the only thing a reader has to hold. Six things about it are
 * not a sibling's, and every one of them is a consequence of the data rather than a preference:
 *
 * - **The window is by instant, not by day**, so there is no `days`/`endingOn` pair, no defaulted
 *   anchor and no `utcToday()` anywhere in this file. Both bounds are supplied and both are required,
 *   which is the app's own `getSamples(from:to:)` port carried through unchanged.
 * - **Twelve fields, nine of them nullable**, where the sibling has five and two. The nullable
 *   majority is the strap's ordinary case rather than an edge: a notification reports the channels it
 *   has, and the optical and motion blocks are absent whenever the strap is not in the mode that
 *   produces them.
 * - **One of those twelve is an array**, and it is the only JSON column any resource in this Worker
 *   publishes as a structured value rather than as an opaque blob.
 * - **Two of them are booleans stored as `0`/`1`**, so this is the only resource where a column's
 *   stored type and its wire type differ in a way a client could get wrong quietly.
 * - **The id is the client's own derivation**, because the app has no sample identifier that could
 *   travel — its local key is an autoincrement in that device's own SQLite, which two devices in one
 *   partition would both mint from 1. This file therefore asserts the *shape* the Worker validates and
 *   takes no view of the derivation, which is the whole of what the contract claims.
 * - **The chunk cap is far below the population it caps.** 200 samples is roughly three minutes at
 *   1 Hz and a day is about 432 chunks, so the cap assertions below are about a number that a real
 *   client hits on its first honest sync rather than at the tail of an import.
 *
 * **There is no delete**, as there is not anywhere in this Worker, and on this resource the omission
 * costs nothing: the app's `BiometricRepository` declares no removal either — a sample is written by a
 * strap and read as part of a series, and nothing on a phone asks to forget one. The batch block's
 * `never deletes a sample the caller leaves out` is the only statement this API makes about removal,
 * and here it is the shape a sync depends on: a chunk that omitted a sample must not be read as a
 * chunk that deleted it.
 *
 * Every assertion below maps to a rule this repo has already paid for once in the app, and the app's
 * own docs record what each cost. What this file is for is that those rules survive the trip across a
 * process boundary, where the failures are quieter than they are on-device: a `0.0` accelerometer axis
 * that came back where a `null` belonged reads as free fall, an R-R array that came back as `[]` reads
 * as a notification with no beats, and a `1` that reached a client as `1` rather than `true` breaks a
 * decoder that never sees an error. None of those raise anything, and each produces a response a
 * client would happily draw.
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
 * Two sample ids, and the pair is chosen so their **lexicographic order is the reverse of nothing in
 * particular** — `OTHER` sorts before `SAMPLE`, which is the fact the ordering block leans on when it
 * asserts that a tiebreak ordered by id is not ordered by arrival.
 *
 * Both are well-formed UUIDs because a non-UUID one is refused at the boundary — deliberately, and
 * with its own assertion below. `SAMPLE` is the DTO's own published example.
 */
const SAMPLE = "8f14e45f-ceea-467a-9c2b-1c3a5b7d0e11";
const OTHER = "1c3a5b7d-0e11-4f6a-8b2c-9d4e7f0a1b3c";

/** Three instants a second apart, plus one two days earlier, for the window's fixtures. */
const EARLIER = "2026-08-20T09:00:00.000Z";
const FIRST = "2026-08-21T09:00:00.000Z";
const SECOND = "2026-08-21T09:00:01.000Z";
const THIRD = "2026-08-22T09:00:00.000Z";

/** The measured values the fixtures carry. Named so an assertion can read against the fixture. */
const MEASURED_HR = 62;
const MEASURED_RR = [958, 962, 955];

/**
 * A well-formed UUID per index, so a fixture that needs two hundred ids does not list them.
 *
 * The version and variant nibbles are the ones a v4 has. `BIOMETRIC_SAMPLE_ID_PATTERN` deliberately
 * accepts any version, because a client deriving a v5 from its own content is as legitimate a producer
 * as one minting a v4 — but a fixture using a string the pattern accepted and a stricter reader did
 * not would be testing an id no client can send.
 */
function uuid(n: number): string {
  return `00000000-0000-4000-8000-${n.toString(16).padStart(12, "0")}`;
}

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
 * How many rows exist in one partition of the table. `null` when it is empty, so `?? 0` at the call
 * site.
 *
 * The `table` parameter is kept from the template even though this resource has only one table: a
 * helper whose arity changed between resources would be a difference a reader has to hold for no
 * reason, and the call sites below read with and without it interchangeably.
 */
async function rowCount(key: string, table = "biometric_samples"): Promise<number> {
  const counted = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`)
    .bind(await partition(key))
    .first<{ n: number }>();

  return counted?.n ?? 0;
}

/**
 * The wire shape, spelled out rather than inferred, so a renamed field fails here loudly.
 *
 * **Every optional field is `| null` and none of them is `?`.** That is not a convenience in the type:
 * it is the contract's own rule, and it is the reason the round-trip block below asserts with
 * `Object.hasOwn` rather than with `toEqual` alone. A field the mapper dropped would be *absent* from
 * the JSON, and a client merging two sources reads an absent key and an explicit `null` as the same
 * thing — the strap not reporting that channel — so the difference between the two is invisible
 * downstream and has to be caught here.
 */
interface SampleWire {
  id: string;
  timestamp: string;
  heartRate: number;
  rrIntervalsMs: number[] | null;
  accelX: number | null;
  accelY: number | null;
  accelZ: number | null;
  skinTemp: number | null;
  spo2Percentage: number | null;
  isOnBody: boolean | null;
  isCharging: boolean | null;
  rawSequenceNumber: number | null;
}

/** What a `PUT` body carries: the sample without its id, which is in the path. */
type SampleFields = Omit<SampleWire, "id">;

interface ErrorWire {
  error: { code: string; message: string };
}

/**
 * A sample with every channel reported — the state a notification in full optical and motion mode
 * produces, and the fixture the conversion assertions need.
 *
 * The values are the DTO's own published examples, so a reader can check this fixture against the
 * served document rather than against another fixture. They are chosen to be *non-zero and
 * non-integral* wherever the column is a REAL: a fixture of zeroes would pass every assertion here
 * while a mapper that dropped the field and a mapper that wrote `0` were indistinguishable.
 */
function measuredSample(overrides: Partial<SampleFields> = {}): SampleFields {
  return {
    timestamp: FIRST,
    heartRate: MEASURED_HR,
    rrIntervalsMs: [...MEASURED_RR],
    accelX: 0.98,
    accelY: -0.12,
    accelZ: 0.04,
    skinTemp: 33.6,
    spo2Percentage: 96.5,
    isOnBody: true,
    isCharging: false,
    rawSequenceNumber: 10342,
    ...overrides,
  };
}

/**
 * The same sample with all nine nullable channels absent — the strap reporting only a pulse.
 *
 * **This is not the "empty" fixture of a sibling file; it is the ordinary case.** A sample exists the
 * moment the decoder has a pulse to report, and the optical and motion blocks are produced only in the
 * modes that produce them, so a write path that folded any of these `null`s into a `0` would put a
 * reading on a row whose channel said nothing. The three non-nullable fields are kept, because a
 * sample with no instant or no rate is not a shape the producer can make.
 */
function bareSample(overrides: Partial<SampleFields> = {}): SampleFields {
  return measuredSample({
    rrIntervalsMs: null,
    accelX: null,
    accelY: null,
    accelZ: null,
    skinTemp: null,
    spo2Percentage: null,
    isOnBody: null,
    isCharging: null,
    rawSequenceNumber: null,
    ...overrides,
  });
}

/** A measured sample at a given instant — the fixture the window block is built from. */
function sampleAt(timestamp: string, overrides: Partial<SampleFields> = {}): SampleFields {
  return measuredSample({ timestamp, ...overrides });
}

/** One batch row, shaped the way a client assembles it: the sample's own id, then its fields. */
function sampleRow(id: string, overrides: Partial<SampleFields> = {}): SampleWire {
  return { id, ...measuredSample(overrides) };
}

/** The body with one key removed, so an omission can be asserted rather than described. */
function without<K extends keyof SampleFields>(
  fields: SampleFields,
  key: K,
): Record<string, unknown> {
  const copy: Record<string, unknown> = { ...fields };
  delete copy[key];
  return copy;
}

function put(id: string, body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/biometric-samples/${id}`, {
    method: "PUT",
    headers: { "content-type": "application/json", "x-whoopsy-user-id": userId },
    body: JSON.stringify(body),
  });
}

function read(path: string, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}${path}`, { headers: { "x-whoopsy-user-id": userId } });
}

function postBatch(body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/biometric-samples/batch`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-whoopsy-user-id": userId },
    body: JSON.stringify(body),
  });
}

async function sample(userId: string, id: string): Promise<SampleWire> {
  const response = await read(`/v1/biometric-samples/${id}`, userId);
  expect(response.status).toBe(200);
  return (await response.json()) as SampleWire;
}

/**
 * The window read, with both bounds percent-encoded.
 *
 * The encoding is not ceremony: an instant's `:` is legal in a query string but the format is fixed
 * and a client will encode it, so a test that sent the raw spelling would be testing a request the
 * contract does not describe. The refusal tests below deliberately use `windowQuery` instead, because
 * what they are asserting is what happens to a *malformed* query and encoding it would repair it.
 */
function windowQuery(from: string, to: string): string {
  return `from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}`;
}

function windowResponse(from: string, to: string, userId = ALICE): Promise<Response> {
  return read(`/v1/biometric-samples?${windowQuery(from, to)}`, userId);
}

async function window(from: string, to: string, userId = ALICE): Promise<SampleWire[]> {
  const response = await windowResponse(from, to, userId);
  expect(response.status).toBe(200);
  return (await response.json()) as SampleWire[];
}

/**
 * A raw row, written past the schema, so a damaged column can be read back.
 *
 * The four `NOT NULL` columns are supplied and the rest are left to the caller, which is the whole
 * point: every damaged-row assertion below is about a value that reached this table without passing
 * through `BiometricSampleWriteSchema`, and the adapter's rule is that such a row is *refused* rather
 * than served as a measurement.
 */
function insertRaw(values: Partial<Record<string, string | number | null>>): Promise<unknown> {
  return env.DB.prepare(
    "INSERT INTO biometric_samples (user_id, id, timestamp, heart_rate, rr_intervals_ms, is_on_body) VALUES (?, ?, ?, ?, ?, ?)",
  )
    .bind(
      values.user_id ?? null,
      values.id ?? SAMPLE,
      values.timestamp ?? FIRST,
      values.heart_rate ?? MEASURED_HR,
      values.rr_intervals_ms ?? null,
      values.is_on_body ?? null,
    )
    .run();
}

describe("a sample written and read back", () => {
  it("returns the stored row rather than an echo of the request", async () => {
    const body = measuredSample();

    const written = await put(SAMPLE, body);
    expect(written.status).toBe(200);

    const stored = (await written.json()) as SampleWire;
    expect(stored).toEqual({ id: SAMPLE, ...body });

    // The read is the assertion that the response was the database's answer rather than the request's:
    // the two agree here only because the write really happened. **On this resource that is worth more
    // than it is on a sibling**, because nine of these twelve fields are nullable, so a write path with
    // a stray default anywhere would echo the request back identically and the divergence would only
    // appear on the next read.
    expect(await sample(ALICE, SAMPLE)).toEqual(stored);
  });

  it("stores the R-R series as JSON text in wire order, and the two flags as 0 and 1", async () => {
    // Out of numerical order on purpose. The intervals are adjacent beats in the order the notification
    // carried them, so a mapper that sorted them would reorder beats that were never in that order —
    // and the successive-difference statistic built on them would be differencing pairs that never met.
    await put(SAMPLE, measuredSample({ rrIntervalsMs: [962, 955, 958] }));

    const stored = await sample(ALICE, SAMPLE);
    expect(stored.rrIntervalsMs).toEqual([962, 955, 958]);

    // And the raw row, because the *response* is the mapper's answer either way and only the column
    // says what was written. **This is the one assertion in the file that pins the storage form rather
    // than the contract**, and it is here because the two conversions in `bindings()` are the only
    // place either representation exists: SQLite has no array and no boolean, so the series is text and
    // the flags are integers, and a client reading `isOnBody: 1` would be reading a type the contract
    // never promised.
    const raw = await env.DB.prepare(
      "SELECT rr_intervals_ms, is_on_body, is_charging FROM biometric_samples WHERE user_id = ? AND id = ?",
    )
      .bind(await partition(ALICE), SAMPLE)
      .first<{ rr_intervals_ms: string; is_on_body: number; is_charging: number }>();

    expect(raw?.rr_intervals_ms).toBe("[962,955,958]");
    expect(raw?.is_on_body).toBe(1);
    expect(raw?.is_charging).toBe(0);
  });

  it("replaces a sample when the same id is written twice", async () => {
    await put(SAMPLE, measuredSample({ heartRate: 62 }));
    await put(SAMPLE, measuredSample({ heartRate: 71 }));

    // `UPSERT … ON CONFLICT (user_id, id) DO UPDATE`, which is the same key the app's own `save` is
    // INSERT-or-UPDATE by. **It is what makes the client's id derivation load-bearing rather than
    // tidy**: a producer that minted a fresh id per attempt would append a row here on every retry,
    // and the table would grow by one per timeout while every response looked correct.
    expect(await rowCount(ALICE)).toBe(1);
    expect((await sample(ALICE, SAMPLE)).heartRate).toBe(71);
  });

  it("files two samples in one millisecond as two rows", async () => {
    await put(SAMPLE, measuredSample({ timestamp: FIRST }));
    await put(OTHER, measuredSample({ timestamp: FIRST, heartRate: 63 }));

    // **The resource's whole shape, and the assertion a day-keyed table fails.** A second is a long
    // time to a strap — the beat-to-beat interval is under a second by construction — so two samples
    // sharing an instant is not an edge case but the ordinary density of this table, and a `timestamp`
    // primary key would have the second write overwrite the first and report success.
    expect(await rowCount(ALICE)).toBe(2);
    expect(await window(FIRST, FIRST)).toHaveLength(2);
  });

  it("returns every one of the nine nullable channels as null, under its own key", async () => {
    await put(SAMPLE, bareSample());

    const stored = await sample(ALICE, SAMPLE);

    // The keys first, and this is the half `toEqual` cannot make: a mapper that dropped `skinTemp`
    // entirely would satisfy a deep-equal against an expected object that also lacked it, and the
    // difference between a missing key and a `null` key is exactly what a client merging a phone's copy
    // with a server's cannot recover — it reads both as "the strap did not report this".
    for (const key of [
      "rrIntervalsMs",
      "accelX",
      "accelY",
      "accelZ",
      "skinTemp",
      "spo2Percentage",
      "isOnBody",
      "isCharging",
      "rawSequenceNumber",
    ]) {
      expect(Object.hasOwn(stored, key)).toBe(true);
    }

    // Then the values. Nine, and not one of them a zero, a `false` or an empty array: those are the four
    // ways an absence gets spelled as a reading, and each of them is a real measurement of something
    // else. `accelX: 0.0` is free fall, which is on the *still* side of every movement threshold and so
    // reads as a perfectly motionless body; `rrIntervalsMs: []` is a notification that carried beats in
    // a shape the RMSSD path would silently decline; `isOnBody: false` is an answer nobody gave.
    expect(stored.rrIntervalsMs).toBeNull();
    expect(stored.accelX).toBeNull();
    expect(stored.accelY).toBeNull();
    expect(stored.accelZ).toBeNull();
    expect(stored.skinTemp).toBeNull();
    expect(stored.spo2Percentage).toBeNull();
    expect(stored.isOnBody).toBeNull();
    expect(stored.isCharging).toBeNull();
    expect(stored.rawSequenceNumber).toBeNull();

    // And the three that are required are still there, so the block is asserting an absence of nine
    // rather than the absence of a row.
    expect(stored.id).toBe(SAMPLE);
    expect(stored.timestamp).toBe(FIRST);
    expect(stored.heartRate).toBe(MEASURED_HR);
  });

  it("round-trips a measured zero rather than reading it as an absence", async () => {
    // Every zero the schema permits, in one row. **This is the pair to the block above and the reason
    // the absence rule is stated as `null` and not as falsiness**: a heart rate of `0` is not a
    // measurement the decoder produces, but a `spo2Percentage` of `0`, an `isOnBody` of `false`, an
    // `accelX` of `0.0` and a `rawSequenceNumber` of `0` are all values a strap can really report, and
    // a mapper that tested truthiness would turn every one of them into the strap saying nothing.
    await put(
      SAMPLE,
      measuredSample({
        heartRate: 0,
        rrIntervalsMs: [0],
        accelX: 0,
        accelY: 0,
        accelZ: 0,
        skinTemp: 0,
        spo2Percentage: 0,
        isOnBody: false,
        isCharging: false,
        rawSequenceNumber: 0,
      }),
    );

    const stored = await sample(ALICE, SAMPLE);

    expect(stored.heartRate).toBe(0);
    expect(stored.rrIntervalsMs).toEqual([0]);
    expect(stored.accelX).toBe(0);
    expect(stored.skinTemp).toBe(0);
    expect(stored.spo2Percentage).toBe(0);
    expect(stored.rawSequenceNumber).toBe(0);
    // The two booleans, and the assertion is on the *type* as well as the value: `0` and `false` are
    // both falsy, so a `toEqual` on the pair would pass for a mapper that handed back the column's
    // integer. `toBe(false)` is a strict comparison and distinguishes them.
    expect(stored.isOnBody).toBe(false);
    expect(stored.isCharging).toBe(false);
  });
});

describe("the write shape", () => {
  it("refuses a body carrying an id of its own", async () => {
    const response = await put(SAMPLE, { id: OTHER, ...measuredSample() });

    // The id is in the path and nowhere else, so a body carrying one is a client that believes it is
    // choosing the row's identity — and the two would be free to disagree. `PUT /v1/biometric-samples/
    // {id}` with `{"id": …}` naming something else has no correct answer, so it is a refusal rather
    // than a silent strip that would leave the client's belief in place.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a body that omits a nullable channel rather than reading the omission as an absence", async () => {
    const response = await put(SAMPLE, without(measuredSample(), "accelX"));

    // **`null` and *omitted* are different, and only one of them is accepted.** Every optional field is
    // `.nullable()` and none is `.optional()`, so a client must say `"accelX": null` to mean the strap
    // reported nothing. The alternative — defaulting an omitted key to `null` — would make a typo in a
    // field name indistinguishable from a channel the strap did not report, and the client would never
    // learn it had misspelled anything.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a body with no timestamp, because the instant is the sample", async () => {
    const response = await put(SAMPLE, without(measuredSample(), "timestamp"));

    // This is the one required field whose absence has a plausible-looking server-side answer — stamp
    // it with the Worker's clock — and that answer is wrong in a way nothing downstream can detect: it
    // records when the write arrived rather than when the beats were heard, which on a sync replaying a
    // banked drain is hours or days out and lands the sample in a window it does not belong to.
    expect(response.status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a body with no heartRate, which is the one channel a sample cannot lack", async () => {
    const response = await put(SAMPLE, without(measuredSample(), "heartRate"));

    // A sample is created by the arrival of a pulse, so the rate is not one channel among twelve — it
    // is what makes the row a sample at all. Defaulting it would be the reserved-zero placeholder that
    // every absence rule in this repo exists to keep off the screens.
    expect(response.status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses an instant that is not the canonical form", async () => {
    // Four spellings of one moment, of which exactly one is accepted. The format is fixed at three
    // fractional digits and a `Z` because the column is compared as a *string*: `timestamp >= ?` is a
    // lexicographic range over the index, so two spellings of one instant sort to two different places
    // and a window would silently miss rows that are inside it.
    for (const timestamp of [
      "2026-08-21 09:00:00",
      "2026-08-21T09:00:00Z",
      "2026-08-21T09:00:00.000+00:00",
      "2026-08-21T09:00:00.0000Z",
    ]) {
      const response = await put(SAMPLE, measuredSample({ timestamp }));
      expect(response.status).toBe(400);
    }

    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a negative or fractional heart rate", async () => {
    expect((await put(SAMPLE, measuredSample({ heartRate: -1 }))).status).toBe(400);
    expect((await put(SAMPLE, measuredSample({ heartRate: 62.5 }))).status).toBe(400);

    // The bound is `.int().nonnegative()` and not `.positive()`: a stored `0` is a legitimate reading
    // on a channel the strap reported, and the pair above plus the round-trip block's zero test is what
    // separates a rate that must be refused from one that must be kept.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses an empty R-R series, which is the second spelling of no intervals", async () => {
    const response = await put(SAMPLE, measuredSample({ rrIntervalsMs: [] }));

    // **`.min(1)`, and this is the schema half of the adapter's own refusal.** `null` is the one
    // published spelling of "this notification carried no intervals", and an empty array is a second
    // one that a client sending it would believe was accepted. The app's own BLE layer collapses the
    // pair on the way in, so a stored `[]` means a writer that did not pass through this schema — and
    // the read side refuses it for the same reason, asserted in the damaged-row block below.
    expect(response.status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a negative R-R interval", async () => {
    // An interval is a duration — the gap between two beats — so there is no such thing as a negative
    // one. The failure would be quiet rather than loud: a negative interval sums into a shorter series
    // and differences into a *larger* RMSSD, so it reads as a calmer night rather than as a corrupt row.
    const response = await put(SAMPLE, measuredSample({ rrIntervalsMs: [958, -962] }));

    expect(response.status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a spo2Percentage outside nought to a hundred", async () => {
    expect((await put(SAMPLE, measuredSample({ spo2Percentage: 100.5 }))).status).toBe(400);
    expect((await put(SAMPLE, measuredSample({ spo2Percentage: -0.1 }))).status).toBe(400);

    // Both ends are closed, which is the only bound in this resource that is a physical range rather
    // than a sign or a width — a saturation is a percentage and cannot exceed its own scale.
    expect((await put(SAMPLE, measuredSample({ spo2Percentage: 100 }))).status).toBe(200);
    expect(await rowCount(ALICE)).toBe(1);
  });

  it("refuses a rawSequenceNumber past the width of its column", async () => {
    // A u32, and the ceiling is written as `0xffffffff` rather than as the literal so that the schema
    // and the strap's own field width are one statement. A number past it is not a large sequence — it
    // is a client whose value did not come from the field it claims to be.
    expect((await put(SAMPLE, measuredSample({ rawSequenceNumber: 0x1_0000_0000 }))).status).toBe(400);
    expect((await put(SAMPLE, measuredSample({ rawSequenceNumber: 0xffff_ffff }))).status).toBe(200);

    expect(await rowCount(ALICE)).toBe(1);
  });

  it("refuses a path parameter that could not name a sample at all", async () => {
    const response = await read("/v1/biometric-samples/13-45-00");

    // A 400 and not a 404, because the two say different things: this string cannot be an id, so the
    // request never asked about a row. Answering 404 would tell a client its well-formed request found
    // nothing, and the client would go on sending the string. **The message names the app's own reader**
    // — every stored id goes through `UUID(uuidString:)` on the phone — so a producer that derived a
    // plausible-looking non-UUID learns why it is refused rather than only that it is.
    expect(response.status).toBe(400);
    const body = (await response.json()) as ErrorWire;
    expect(body.error.code).toBe("invalid_request");
    expect(body.error.message).toContain("UUID");
  });
});

describe("a sample with no row", () => {
  it("is a 404 naming the code, not a zero-filled row", async () => {
    await put(OTHER, measuredSample());

    const response = await read(`/v1/biometric-samples/${SAMPLE}`);

    expect(response.status).toBe(404);
    // `not_found` and **not** the day-keyed resources' `no_measurement_for_day`. That code names a day
    // with no reading, which is a statement about a calendar; a sample is one notification and is never
    // "unmeasured" — it exists only when the decoder had a pulse to report — so the sibling's code
    // would be not merely imprecise here but false.
    expect(await response.json()).toEqual({
      error: {
        code: "not_found",
        message: `no biometric sample with id ${SAMPLE} in this partition`,
      },
    });
  });

  it("is omitted from a window rather than zero-filled", async () => {
    await put(SAMPLE, sampleAt(FIRST));
    await put(OTHER, sampleAt(THIRD, { heartRate: 71 }));

    const rows = await window(EARLIER, THIRD);

    // The count is the assertion, and on this resource the alternative is worse than it is on a
    // sibling: there is no per-instant slot for a placeholder to occupy, so the only way to fill a gap
    // would be to invent a sample at an instant the strap never reported one — a row that the RMSSD
    // path would then difference against its real neighbours.
    expect(rows.map((row) => row.id)).toEqual([SAMPLE, OTHER]);
  });
});

describe("the window", () => {
  /**
   * Four samples across three days, two of them sharing a millisecond.
   *
   * **The two that share an instant are written larger-id-first, and that is the whole reason this hook
   * exists in this shape.** If they went in ascending order the read's answer would be the write order
   * and the ordering test below could not tell the tiebreak from arrival order — which is precisely the
   * thing that test asserts is *not* happening.
   */
  beforeEach(async () => {
    await put(uuid(0), sampleAt(EARLIER));
    await put(uuid(2), sampleAt(FIRST));
    await put(uuid(1), sampleAt(FIRST));
    await put(uuid(3), sampleAt(THIRD, { heartRate: 71 }));
  });

  it("returns every sample in the window, oldest first", async () => {
    const rows = await window(EARLIER, THIRD);

    expect(rows.map((row) => row.id)).toEqual([uuid(0), uuid(1), uuid(2), uuid(3)]);
    expect(rows.map((row) => row.timestamp)).toEqual([EARLIER, FIRST, FIRST, THIRD]);
  });

  it("orders samples sharing a millisecond by id, which is not arrival order", async () => {
    const rows = await window(EARLIER, THIRD);

    // `uuid(2)` was written *before* `uuid(1)` and comes back *after* it, so the second clause of
    // `ORDER BY timestamp ASC, id ASC` is visibly doing something other than reproducing the write
    // order. **This is the resource's one honest caveat and it is asserted rather than described.** The
    // app's own read orders the same two columns, but its `id` is a local autoincrement and is therefore
    // *arrival order*; this one is client-derived from the sample's content, so it is arbitrary. What a
    // client gets is a stable order — two reads of one window agree — and not a recovered one: nothing
    // in this response says which of two samples in a millisecond was heard first.
    expect(rows.map((row) => row.id)).toEqual([uuid(0), uuid(1), uuid(2), uuid(3)]);
  });

  it("includes both bounds, so a window anchored on one sample returns it", async () => {
    const rows = await window(FIRST, FIRST);

    // **Inclusive at both ends, and the pair is the assertion.** An instant range has no natural
    // half-open form the way a day chunk does — there is no "next instant" to exclude — and a chunked
    // sync overlapping at one millisecond re-sends that sample as an upsert of an identical row rather
    // than as a duplicate, so the closed form costs nothing. A half-open spelling here would be a
    // window that silently drops the sample it was anchored on, which is the sample a client asking for
    // one instant most wants.
    expect(rows.map((row) => row.id)).toEqual([uuid(1), uuid(2)]);
    expect(await window(SECOND, SECOND)).toEqual([]);
  });

  it("returns an empty array for a window nothing covers", async () => {
    const rows = await window("2026-01-01T00:00:00.000Z", "2026-01-02T00:00:00.000Z");

    // A 200 holding `[]`, and on this resource that is the ordinary answer rather than an error: a
    // strap that was not worn reports nothing, and there is no value to guess. It is also the one
    // answer that must stay distinguishable from a refused window — which is why a reversed range
    // throws below rather than returning this.
    expect(rows).toEqual([]);
  });

  it("refuses a reversed window rather than answering it with an empty array", async () => {
    const response = await windowResponse(THIRD, EARLIER);

    expect(response.status).toBe(400);
    // The empty array would be indistinguishable from a week the strap did not cover, which is the one
    // distinction a syncing client most needs to keep: one means "nothing to send", the other means
    // "your two bounds are swapped and you will retry forever".
    expect(await response.json()).toEqual({
      error: {
        code: "invalid_request",
        message: `from must not be later than to, got ${THIRD} and ${EARLIER}`,
      },
    });
  });

  it("accepts a window of exactly the ceiling and refuses one second more", async () => {
    // Seven days exactly. The pair straddles the bound from both sides, so the assertion is about the
    // edge rather than about the refusal: a `>=` spelled `>` would admit the second request and pass
    // every other test in this file.
    // The accepted window is written to *span* the fixtures rather than to miss them, so the assertion
    // is that it reads as well as that it is admitted: three of the block's four rows fall inside these
    // bounds, and `THIRD`, one day past the top, deliberately does not. A window that returned `[]`
    // would satisfy a status check alone, and an empty array is exactly what a widest-possible read
    // answers with when its bounds never reached the query.
    const atCeiling = await windowResponse("2026-08-15T00:00:00.000Z", "2026-08-22T00:00:00.000Z");
    expect(atCeiling.status).toBe(200);
    expect((await atCeiling.json() as SampleWire[]).map((row) => row.id)).toEqual([
      uuid(0),
      uuid(1),
      uuid(2),
    ]);

    const past = await windowResponse("2026-08-15T00:00:00.000Z", "2026-08-22T00:00:01.000Z");
    expect(past.status).toBe(400);

    // The message names both numbers, so a client reading it can size its next chunk rather than only
    // learning that it was wrong. The published constant and the sentence agree by construction.
    expect(await past.json()).toEqual({
      error: {
        code: "invalid_request",
        message: `the window must span at most ${MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS} seconds, got ${MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS + 1}`,
      },
    });
  });

  it("refuses a window missing its upper bound rather than defaulting it to now", async () => {
    const response = await read(`/v1/biometric-samples?from=${encodeURIComponent(EARLIER)}`);

    // **The judgement this resource's read is built on.** A defaulted `to` would be the Worker's own
    // clock answering the caller's question, which is a different thing from a defaulted upper bound
    // expressed as a *day* the server can at least name — and this read has no day in it at all. The
    // app's own port requires both bounds, so the honest shape requires both.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses an instant that is not the canonical form", async () => {
    // The same rule the write path enforces, on the other side of the request. It matters more here:
    // the column is compared as a string, so a bound in another spelling is not merely refused — it
    // would be *compared*, and `2026-08-21 09:00:00` sorts before every canonical instant of that day,
    // which would silently widen the window rather than failing it.
    const response = await read(
      "/v1/biometric-samples?from=2026-08-21%2009:00:00&to=2026-08-22T09:00:00.000Z",
    );

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("keeps one caller's window out of another's partition", async () => {
    const rows = await window(EARLIER, THIRD, BOB);

    // Four rows exist and none of them is Bob's. The partition column is this Worker's only isolation,
    // so every read is keyed on `(user_id, …)` and a window scoped by instant alone would answer with
    // another caller's night — which on a 1 Hz stream is 86,400 rows of it.
    expect(rows).toEqual([]);
  });
});

describe("the partition", () => {
  it("keeps one caller's sample invisible to another", async () => {
    await put(SAMPLE, measuredSample());

    expect((await read(`/v1/biometric-samples/${SAMPLE}`, BOB)).status).toBe(404);

    // The window is the second half and it is not redundant: the addressed read is keyed on
    // `(user_id, id)` and a range read is keyed on `(user_id, timestamp)`, so they are two different
    // queries over two different columns and each is its own place to forget the partition.
    expect(await window(EARLIER, THIRD, BOB)).toEqual([]);
    expect(await rowCount(ALICE)).toBe(1);
  });

  it("lets two callers hold the same sample id without colliding", async () => {
    await put(SAMPLE, measuredSample({ heartRate: 62 }), ALICE);
    await put(SAMPLE, measuredSample({ heartRate: 71 }), BOB);

    // Two rows, one id. **This is what the composite primary key buys and the reason the id alone is
    // not the row's address**: a client-derived id is a function of the sample's content, so two
    // phones recording the same strap would derive the same string for the same beat — and a table
    // keyed on the id alone would have one of them silently overwrite the other's whole history.
    expect(await rowCount(ALICE)).toBe(1);
    expect(await rowCount(BOB)).toBe(1);
    expect((await sample(ALICE, SAMPLE)).heartRate).toBe(62);
    expect((await sample(BOB, SAMPLE)).heartRate).toBe(71);
  });

  it("files the row under the digest of the key, never under the key", async () => {
    await put(SAMPLE, measuredSample());

    expect(await rowCount(ALICE)).toBe(1);

    const keyed = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM biometric_samples WHERE user_id = ?",
    )
      .bind(ALICE)
      .first<{ n: number }>();

    // Zero rows under the raw header, which is the claim that a D1 dump holds no usable credential. A
    // `user_id` equal to `ALICE` would satisfy every other test in this file — the requests would still
    // work, because the same string would be hashed on the way in and matched on the way out — and
    // would be a database of working keys.
    expect(keyed?.n).toBe(0);
  });
});

describe("identity", () => {
  it("refuses a request with no X-Whoopsy-User-Id", async () => {
    const response = await SELF.fetch(`${BASE}/v1/biometric-samples/${SAMPLE}`);

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses an empty X-Whoopsy-User-Id", async () => {
    const response = await read(`/v1/biometric-samples/${SAMPLE}`, "");

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a key one character below the floor", async () => {
    const short = "a".repeat(MIN_KEY_LENGTH - 1);

    // The boundary from the inside, because the guard is a length test and an off-by-one is its only
    // realistic defect: `>=` spelled `>` would admit exactly this string and pass every other test in
    // this file, including the empty-key one above — nothing else here is near the edge.
    expect((await read(`/v1/biometric-samples/${SAMPLE}`, short)).status).toBe(400);

    // And one character above it is accepted, so the pair pins a boundary rather than restating a
    // refusal that a blank check would also produce.
    expect((await read(`/v1/biometric-samples/${SAMPLE}`, "a".repeat(MIN_KEY_LENGTH))).status).toBe(
      404,
    );
  });
});

describe("a chunk of samples", () => {
  it("answers with a tally that is also the row count, because a sample has no children", async () => {
    const rows = [sampleRow(SAMPLE), sampleRow(OTHER, { heartRate: 63 })];

    const response = await postBatch({ rows });
    expect(response.status).toBe(200);

    // **Two, and on this resource the two readings of the figure coincide.** A session's batch reports a
    // tally of sessions while the number of rows it touched is larger, so `MAX_BATCH_WORKOUTS`'s doc has
    // to say which one it is; here a sample is exactly one statement, so `written` is the row count.
    // That identity is the resource's shape rather than a second convention, and the read below is what
    // keeps the tally honest — a `written` counted from the request's own array would be the same number
    // here and would disagree with the table the moment an upsert stopped landing.
    expect(await response.json()).toEqual({ written: 2 });
    expect(await rowCount(ALICE)).toBe(2);
  });

  it("answers the same number for a replayed chunk and moves no row", async () => {
    const rows = [sampleRow(SAMPLE), sampleRow(OTHER)];

    const first = await postBatch({ rows });
    const second = await postBatch({ rows });

    expect(await first.json()).toEqual({ written: 2 });
    // **Not zero.** `INSERT … ON CONFLICT DO UPDATE` counts a row it matched as changed even when every
    // value is byte-identical, so a replayed chunk reports the same figure as the first send. That is
    // the honest answer — the statement did write that row — and it is why `written: 0` must never be
    // read as "there was nothing to do": nothing in this API answers `0` for a non-empty batch.
    //
    // **On this resource it is also the property the whole endpoint exists for**, more than on any
    // sibling: a sample's id is derived by the client from the sample itself, so a chunk replayed after
    // a timeout rewrites each row with the values it already holds and the client never has to know
    // whether the first attempt landed. The app's `getSamples(from:to:)` port is a window read for the
    // same reason — a sync that could not be replayed would need a reconciliation pass this API has no
    // endpoint for.
    expect(await second.json()).toEqual({ written: 2 });

    expect(await rowCount(ALICE)).toBe(2);
  });

  it("writes a full chunk of the cap in one request", async () => {
    const rows = Array.from({ length: MAX_BATCH_BIOMETRIC_SAMPLES }, (_, i) =>
      sampleRow(uuid(i), { timestamp: FIRST }),
    );

    const response = await postBatch({ rows });

    expect(response.status).toBe(200);
    // The cap is doing a job one of its siblings' does not: a chunk that arrives in one request is one
    // transaction, so this assertion is also that 200 statements in one `batch()` land together — and
    // `written` is what would catch a `NaN` from a `meta.changes` this runtime did not report.
    expect(await response.json()).toEqual({ written: MAX_BATCH_BIOMETRIC_SAMPLES });
    expect(await rowCount(ALICE)).toBe(MAX_BATCH_BIOMETRIC_SAMPLES);

    // And they are all inside one millisecond, which is the density this table really has: 200 samples
    // is about three minutes of a worn strap, and a client that had to space them out would be chunking
    // against a limit that does not exist.
    expect(await window(FIRST, FIRST)).toHaveLength(MAX_BATCH_BIOMETRIC_SAMPLES);
  });

  it("refuses a chunk one sample past the cap, and writes nothing", async () => {
    const rows = Array.from({ length: MAX_BATCH_BIOMETRIC_SAMPLES + 1 }, (_, i) =>
      sampleRow(uuid(i), { timestamp: FIRST }),
    );

    const response = await postBatch({ rows });

    expect(response.status).toBe(400);
    // **The code and not the sentence, and that is this family's convention rather than a weaker
    // assertion.** This rule is stated in two layers — `BiometricSampleBatchWriteSchema`'s `.max()` and
    // `writeMany`'s own refusal — and a request arriving over HTTP meets the schema first, so the
    // message a client actually reads is Zod's (`rows: Array must contain at most 200 element(s)`)
    // rather than the service's. Pinning the service's wording here would be pinning a string this path
    // cannot produce; the layer that owns the number is the layer the `400` and the count below come
    // from, and the wording is the service's for a caller that passed through no schema at all.
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    // Nothing, not "the first two hundred". The cap is a refusal rather than a truncation because a
    // client whose chunk was silently trimmed would believe the whole range had been uploaded — and at
    // this cap, against data this dense, that is a client that would go on believing it for days.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses an empty chunk rather than answering a successful sync of nothing", async () => {
    const response = await postBatch({ rows: [] });

    expect(response.status).toBe(400);
    // `200 {"written": 0}` is the tempting answer and it is the one that hides a bug: a sync loop that
    // built its rows wrongly would report success on every pass and never move a row. The sentence
    // carries the schema's `rows:` prefix for the cap test's reason — `.min(1)` fires before the
    // service sees the body — see the note above.
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a sample id carried twice, and writes nothing", async () => {
    const rows = [sampleRow(SAMPLE), sampleRow(OTHER)];
    const response = await postBatch({ rows: [...rows, rows[1]!] });

    expect(response.status).toBe(400);
    // The duplicate rule is the third of the batch's three, and it is the only one whose *schema* half
    // is a `.refine()` rather than a bound — so the message on this path is
    // `rows: names a sample id more than once; a batch must give each sample exactly one row`, which is
    // the DTO's constant. The service restates the rule for a caller that reached it directly, with a
    // count in it. Asserting the code keeps this test about the rule rather than about which of the two
    // wordings a client happens to meet. See the cap test above.
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    // The alternative is *nearly* harmless — the second write wins and the row on disk is whichever the
    // array put last — which is exactly the failure: a `200` whose result depends on the order of an
    // array the client built, reported as success.
    //
    // **On this resource that is the check most likely to fire rather than the least.** An id folded
    // from the arrival instant alone makes two samples in one millisecond the same id, and a batch is
    // exactly where a burst of those arrives together — so a client whose derivation ignores the
    // sub-millisecond part of its own content meets this refusal on its first dense chunk rather than
    // on a corrupted one.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("accepts two rows sharing a millisecond, which is the rule the id check does not reach", async () => {
    const rows = [sampleRow(SAMPLE, { timestamp: FIRST }), sampleRow(OTHER, { timestamp: FIRST })];

    const response = await postBatch({ rows });

    // **Read beside the duplicate-id refusal above, not on its own.** The uniqueness rule is on `id` and
    // not on `timestamp`, and the two are one assertion apart: two samples a millisecond apart are the
    // ordinary density of this table, so a rule that refused them would refuse the feature. What a
    // client must guarantee is that its derivation distinguishes them — which is a statement about the
    // derivation, and the reason the contract requires determinism rather than specifying a recipe.
    expect(response.status).toBe(200);
    expect(await rowCount(ALICE)).toBe(2);
    expect(await window(FIRST, FIRST)).toHaveLength(2);
  });

  it("refuses a row whose fields are not a sample", async () => {
    const response = await postBatch({ rows: [{ id: SAMPLE, timestamp: FIRST }] });

    // Every field but the id is required-or-explicitly-null here as it is on the single write, so a row
    // carrying only an id is refused rather than written with nine absent channels — which a client
    // would read back as a strap that reported nothing, on a row it never actually described.
    expect(response.status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a row carrying a field the contract does not have", async () => {
    const response = await postBatch({
      rows: [{ ...sampleRow(SAMPLE), rrIntervalMs: 958 }],
    });

    // **The legacy lossy scalar, named, because it is the one wrong field a real client would send.**
    // The app's own record carries `rrIntervalMs` as a single number from before the series was stored,
    // and this contract deliberately publishes `rrIntervalsMs` alone — one quantity, one column, one
    // meaning. A strict row makes the old spelling a `400` rather than a silently ignored key, which is
    // the difference between a client that learns and one whose R-R data quietly never arrives.
    expect(response.status).toBe(400);
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("never deletes a sample the caller leaves out", async () => {
    await put(SAMPLE, measuredSample());
    await put(OTHER, measuredSample({ timestamp: THIRD }));

    const response = await postBatch({ rows: [sampleRow(uuid(9), { timestamp: SECOND })] });

    expect(response.status).toBe(200);
    // **Three, and this is the only statement this API makes about removal.** A chunk that named one
    // sample left the two it did not name exactly where they were, because this is a `POST` on `/batch`
    // and not a `PUT` on the collection: a `PUT` would say "these are the samples", and a sync that says
    // that has to delete the ones it left out. Nothing in this Worker deletes anything, and on this
    // resource that costs nothing — the app's own port declares no removal either.
    expect(await rowCount(ALICE)).toBe(3);
    expect((await read(`/v1/biometric-samples/${SAMPLE}`)).status).toBe(200);
    expect((await read(`/v1/biometric-samples/${OTHER}`)).status).toBe(200);
  });

  it("keeps one caller's chunk out of another's partition", async () => {
    await postBatch({ rows: [sampleRow(SAMPLE), sampleRow(OTHER)] }, BOB);

    // The batch half of the partition block above: a chunk is keyed on `(user_id, id)` exactly as the
    // single write is, but it is a different statement and therefore its own place to forget the
    // partition column.
    expect(await rowCount(BOB)).toBe(2);
    expect(await rowCount(ALICE)).toBe(0);
    expect(await window(EARLIER, THIRD)).toEqual([]);
  });
});

describe("the chunk's transaction", () => {
  it("rolls a failed batch back rather than landing the statements before it", async () => {
    const userId = await partition(ALICE);

    const lands = env.DB.prepare(
      "INSERT INTO biometric_samples (user_id, id, timestamp, heart_rate) VALUES (?, ?, ?, ?)",
    ).bind(userId, SAMPLE, FIRST, MEASURED_HR);

    // `id` is `NOT NULL`, so this statement fails — and it fails *after* the one above it, which is what
    // makes the pair a probe of the transaction rather than of a single statement.
    const fails = env.DB.prepare("INSERT INTO biometric_samples (user_id) VALUES (?)").bind(userId);

    await expect(env.DB.batch([lands, fails])).rejects.toThrow();

    // **Zero, and this is the contract the whole sync is built on** rather than a property of D1 that
    // happens to hold: `POST /batch` is one transaction, so a request that fails is a request that wrote
    // nothing — and therefore one that can be retried without reconciling a half-applied run of
    // samples. On this resource the alternative is particularly bad, because a half-applied chunk is a
    // *contiguous* stretch of a night rather than a scattered handful of rows.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("leaves the table untouched when the repository's own chunk is refused", async () => {
    // The two refusals the service makes before the repository is reached: a chunk past the cap, and one
    // naming a sample twice. Both are `400`s and both must leave the table alone — a refusal that had
    // already written the rows it accepted would be a partial sync reported as a failed one, and the
    // client's retry would then be rewriting rows it does not know it sent.
    const overCap = Array.from({ length: MAX_BATCH_BIOMETRIC_SAMPLES + 1 }, (_, i) =>
      sampleRow(uuid(i), { timestamp: FIRST }),
    );
    const repeated = [sampleRow(SAMPLE), sampleRow(SAMPLE, { heartRate: 63 })];

    expect((await postBatch({ rows: overCap })).status).toBe(400);
    expect((await postBatch({ rows: repeated })).status).toBe(400);

    expect(await rowCount(ALICE)).toBe(0);
  });
});

describe("a damaged row", () => {
  it("answers 500 rather than a fabricated null when the R-R column is not JSON", async () => {
    await insertRaw({ user_id: await partition(ALICE), rr_intervals_ms: "958,962,955" });

    const response = await read(`/v1/biometric-samples/${SAMPLE}`);

    // **A 500, and the choice is the whole of the adapter's rule.** `null` on this resource is the
    // strap's word for *I did not report this channel*, so a malformed column decoded to `null` would
    // tell every consumer downstream that the strap stayed silent rather than that the row is damaged —
    // silently disabling the RMSSD path on a night that has beats in it. A 500 names the row; a
    // fabricated absence names nothing and disables a measurement.
    expect(response.status).toBe(500);
    expect((await response.json() as ErrorWire).error.code).toBe("internal_error");
  });

  it("answers 500 when the R-R column holds an array the schema refuses", async () => {
    // Both of the second spellings, at their own ids. `[]` is "no intervals" written the other way and a
    // negative element is a duration that cannot exist; the write path refuses both with a `400`, so a
    // stored one is proof of a writer that reached the table without passing through the schema — a
    // migration, a backfill, or a `wrangler d1 execute`. **A bound enforced only on the way in is a
    // bound on the API**, and this adapter is the only reader of the column.
    await insertRaw({ user_id: await partition(ALICE), id: SAMPLE, rr_intervals_ms: "[]" });
    await insertRaw({ user_id: await partition(ALICE), id: OTHER, rr_intervals_ms: "[958,-962]" });

    expect((await read(`/v1/biometric-samples/${SAMPLE}`)).status).toBe(500);
    expect((await read(`/v1/biometric-samples/${OTHER}`)).status).toBe(500);
  });

  it("refuses a flag value the column's domain does not allow", async () => {
    // **Written against D1 and not through the route, and on this resource that is forced rather than
    // chosen.** The `CHECK (is_on_body IN (0, 1))` migration `0007` declares refuses `2` a layer below
    // the mapper, so the adapter's `parseFlag` — whose throw the two R-R tests above reach — cannot be
    // reached through this table at all: `z.boolean()` refuses the value on the way in, and the
    // constraint refuses it on the way back out. What is left to assert is the constraint itself, which
    // is the same shape `strains.spec.ts` gives `has_measurement`, and the honest reading of the pair
    // is that the mapper's branch here is a second line of defence rather than a live path.
    //
    // The contrast with the R-R block above is the point of the two sitting together: `rr_intervals_ms`
    // has no `CHECK` — SQLite has no array type to constrain — so a damaged value in it really does
    // reach the mapper and really does answer a `500`, while a flag column cannot.
    await expect(insertRaw({ user_id: await partition(ALICE), is_on_body: 2 })).rejects.toThrow();

    expect(await rowCount(ALICE)).toBe(0);
  });

  it("reads a raw row whose columns are all null rather than inventing a channel", async () => {
    await insertRaw({ user_id: await partition(ALICE) });

    const stored = await sample(ALICE, SAMPLE);

    // The one hand-written row that is *not* a failure: every optional column genuinely absent, which is
    // the shape the schema permits and the shape a bare sample has. It is here so the block above is
    // read as a set of refusals of *damaged* values rather than as a refusal of hand-written rows.
    expect(stored.rrIntervalsMs).toBeNull();
    expect(stored.isOnBody).toBeNull();
    expect(stored.isCharging).toBeNull();
    expect(stored.accelX).toBeNull();
  });
});
