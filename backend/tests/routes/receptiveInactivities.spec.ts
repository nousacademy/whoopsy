import { SELF, env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { MAX_BATCH_RECEPTIVE_INACTIVITIES, MAX_WINDOW_DAYS } from "../../src/services";
import { deriveUserId, MIN_KEY_LENGTH } from "../../src/utils/identity";

/**
 * The sixth resource, and the second that is keyed on an id: an entry in a notes log, written and read
 * as one flat row.
 *
 * `workouts.spec.ts` is the template and this file keeps its shape — the same two keys, the same
 * `partition`/`rowCount`/`put`/`read`/`postBatch` helpers, the same fresh storage per test — so that
 * the differences between the two id-keyed resources are the *only* thing a reader has to hold. There
 * are four, and each is a subtraction rather than a variation:
 *
 * - **An entry has no children**, so it is one table rather than three, `toWire` is a flat map rather
 *   than a three-level one, and an omitted field cannot silently delete a stored child. The batch
 *   tally and the row count are therefore the *same number*, where a session's differ by more than an
 *   order of magnitude.
 * - **An entry carries `date` in its body**, exactly as a session does, and for a reason that survives
 *   the difference: `startedAt` is optional on this row, so when no time was given there is nothing for
 *   a UTC Worker to derive the day *from*.
 * - **Two of its five fields are nullable, and each is absent for a different reason.** `startedAt` is
 *   `null` on every one of the app's 62 bundled rows — they are untimed, which is the *majority* case
 *   rather than an edge — while `note` is `null` on none of them, because the app's parser refuses a
 *   record carrying no text. So the corpus supplies one of the two absences and the app's own sheet
 *   supplies the other, a blank field there being dropped to `nil` rather than to `""`. The
 *   `NULL is not 0` block below asserts both, and the fact that they come from two populations is why
 *   it cannot assert one and call it the corpus.
 * - **The uniqueness check on a batch is on `id`**, as it is for a session, and the pair of assertions
 *   that pins it is the same pair: a repeated id is refused while two rows sharing a day are accepted,
 *   which is the inverse of the day-keyed resources.
 *
 * **There is no delete.** Nothing in this Worker has a delete path, and this resource is where the
 * omission is most visible, because the app's own port declares one — `ReceptiveInactivityRepository`
 * in `ios/Sources/Whoopsy/Domain/Repositories/PresentationRepositories.swift` carries
 * `delete(_ id: UUID) async throws -> Bool`. That method has no counterpart here and this file asserts
 * the absence rather than leaving it to be discovered: `never deletes an entry the caller leaves out`
 * below is the batch half, and it is the only statement this API can make about removal.
 *
 * Every assertion below maps to a rule this repo has already paid for once in the app, and the app's
 * own docs record what each cost. What the file is for is that those rules survive the trip across a
 * process boundary, where the failures they prevent are quieter than they are on-device: a `null` that
 * came back as `""`, an untimed entry that came back at midnight, a re-worded note that left its
 * predecessor beside it — none of those raise anything, and each produces a response a client would
 * happily draw.
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

/** Entry ids. Well-formed UUIDs because a non-UUID one is refused at the boundary — deliberately. */
const ENTRY = "6f9619ff-8b86-d011-b42d-00c04fc964ff";
const OTHER = "7a2c1d40-5e83-4b16-9f27-3c8a6d5b0e91";

/**
 * The four ids `the window`'s ordering test needs, named for what each row is rather than for where it
 * lands.
 *
 * That test asserts on *names* and on the position of the untimed rows among the timed ones, so a
 * generated id would carry no information the fixture does not already state — and the names read in
 * the array the test expects, which is what makes `[EARLY, LATE, DREAM, MEDITATION]` a sentence about
 * `ORDER BY date ASC, started_at ASC NULLS LAST, name ASC` rather than four anonymous strings in an
 * order. The block uses them on a day of its own, clear of the six the hook writes.
 */
const EARLY = "8b1c2d3e-4f50-4a61-9b7c-8d9e0f1a2b3c";
const LATE = "9c2d3e4f-5061-4b72-8c8d-9e0f1a2b3c4d";
const DREAM = "ad3e4f50-6172-4c83-9d9e-0f1a2b3c4d5e";
const MEDITATION = "be4f5061-7283-4d94-8e0f-1a2b3c4d5e6f";

/**
 * A well-formed UUID per index, so a fixture that needs two hundred ids does not list them.
 *
 * The version and variant nibbles are the ones a v4 has, which is what the app mints for a hand-entered
 * row — `RECEPTIVE_INACTIVITY_ID_PATTERN` deliberately accepts any version, because the app derives v5
 * ids for an import, but a fixture that used one the pattern accepted and `UUID(uuidString:)` did not
 * would be testing a string no client can send.
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
 * The `table` parameter is kept from the sibling file even though this resource has only one table:
 * the call sites below read `rowCount(ALICE)` and `rowCount(ALICE, "receptive_inactivities")`
 * interchangeably, and a helper whose arity changed between the two id-keyed resources would be a
 * difference a reader has to hold for no reason.
 */
async function rowCount(key: string, table = "receptive_inactivities"): Promise<number> {
  const counted = await env.DB.prepare(
    `SELECT COUNT(*) AS n FROM ${table} WHERE user_id = ?`,
  )
    .bind(await partition(key))
    .first<{ n: number }>();

  return counted?.n ?? 0;
}

/** The wire shape, spelled out rather than inferred, so a renamed field fails here loudly. */
interface ReceptiveInactivityWire {
  id: string;
  date: string;
  name: string;
  note: string | null;
  startedAt: string | null;
}

/** What a `PUT` body carries: the entry, without its id, which is in the path. */
type ReceptiveInactivityFields = Omit<ReceptiveInactivityWire, "id">;

interface ErrorWire {
  error: { code: string; message: string };
}

/**
 * The two absences, named, because they are the two states this file is mostly about.
 *
 * `MEASURED_NOTE` and `MEASURED_START` are a timed, annotated entry. `absentEntry` below empties both,
 * and that is the *union* of two populations rather than the shape of the import: all 62 of the app's
 * bundled rows are untimed, and all 62 carry a note, since the app's parser refuses a record with no
 * text. What does empty `note` is the sheet, which drops a blank field to `nil` — so each half of
 * `absentEntry` is a state the app really writes and the two are simply never in the same row.
 */
const MEASURED_NOTE = "Standing in a house that was not mine.";
const MEASURED_START = "2026-08-22T03:40:00.000Z";

/** A complete entry: named, annotated, and carrying a time-of-day on its own date. */
function measuredEntry(
  overrides: Partial<ReceptiveInactivityFields> = {},
): ReceptiveInactivityFields {
  return {
    date: "2026-08-22",
    name: "Dream",
    note: MEASURED_NOTE,
    startedAt: MEASURED_START,
    ...overrides,
  };
}

/**
 * The same entry with both nullable columns absent — one row per absence, and each is a real one.
 *
 * **This is not the "empty" fixture of the sibling file; both states are the app's own.** Every one of
 * the app's 62 bundled rows is untimed, so a write path that folded `startedAt` into midnight would
 * rewrite the whole import into a time nobody gave; and a row saved from the sheet with its text field
 * left blank stores `nil`, so a path that folded `note` into `""` would do the same to that entry.
 * Both failures leave every screen looking plausible, which is why the fixture pairs them — reach for
 * a single-absence row when the difference between the two matters, as the `min(1)` pair below does.
 *
 * The name is kept, because a nameless entry is not a shape the producer can make.
 */
function absentEntry(overrides: Partial<ReceptiveInactivityFields> = {}): ReceptiveInactivityFields {
  return measuredEntry({ note: null, startedAt: null, ...overrides });
}

/** One batch row, shaped the way a client assembles it: the entry's own id, then its fields. */
function entryRow(id: string, overrides: Partial<ReceptiveInactivityFields> = {}): ReceptiveInactivityWire {
  return { id, ...measuredEntry(overrides) };
}

/**
 * An entry filed on a given day, with its own time-of-day inside that day.
 *
 * **This helper supplies a `startedAt`, so it and `absentEntry` cannot be nested.** Both spread their
 * argument last, so `absentEntry(entryOn(date))` hands `entryOn`'s clock to `absentEntry`'s overrides
 * and the row is written *timed* — the opposite of what the call reads as, and a mistake that surfaces
 * as an ordering assertion failing over a correct `ORDER BY`. Write a day onto the row directly
 * (`absentEntry({ date, name })`) whenever the absence is the point; this helper is for the fixtures
 * where the time is.
 */
function entryOn(
  date: string,
  overrides: Partial<ReceptiveInactivityFields> = {},
): Partial<ReceptiveInactivityFields> {
  return { date, startedAt: `${date}T03:40:00.000Z`, ...overrides };
}

/** The body with one key removed, so an omission can be asserted rather than described. */
function without<K extends keyof ReceptiveInactivityFields>(
  fields: ReceptiveInactivityFields,
  key: K,
): Record<string, unknown> {
  const copy: Record<string, unknown> = { ...fields };
  delete copy[key];
  return copy;
}

function put(id: string, body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/receptive-inactivities/${id}`, {
    method: "PUT",
    headers: { "content-type": "application/json", "x-whoopsy-user-id": userId },
    body: JSON.stringify(body),
  });
}

function read(path: string, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}${path}`, { headers: { "x-whoopsy-user-id": userId } });
}

function postBatch(body: unknown, userId = ALICE): Promise<Response> {
  return SELF.fetch(`${BASE}/v1/receptive-inactivities/batch`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-whoopsy-user-id": userId },
    body: JSON.stringify(body),
  });
}

async function entry(userId: string, id: string): Promise<ReceptiveInactivityWire> {
  const response = await read(`/v1/receptive-inactivities/${id}`, userId);
  expect(response.status).toBe(200);
  return (await response.json()) as ReceptiveInactivityWire;
}

async function window(query: string, userId = ALICE): Promise<ReceptiveInactivityWire[]> {
  const response = await read(`/v1/receptive-inactivities?${query}`, userId);
  expect(response.status).toBe(200);
  return (await response.json()) as ReceptiveInactivityWire[];
}

describe("an entry written and read back", () => {
  it("returns the stored row rather than an echo of the request", async () => {
    const body = measuredEntry();

    const written = await put(ENTRY, body);
    expect(written.status).toBe(200);

    const stored = (await written.json()) as ReceptiveInactivityWire;
    expect(stored).toEqual({ id: ENTRY, ...body });

    // The read is the assertion that the response was the database's answer rather than the request's:
    // the two agree here only because the write really happened.
    expect(await entry(ALICE, ENTRY)).toEqual(stored);
  });

  it("replaces an entry when the same id is written twice", async () => {
    await put(ENTRY, measuredEntry({ name: "Dream" }));
    await put(ENTRY, measuredEntry({ name: "Meditation" }));

    // `UPSERT … ON CONFLICT (user_id, id) DO UPDATE`, which is the same key the app's own `save` is
    // INSERT-or-UPDATE by — so a re-import of a re-worded entry lands on the row rather than beside it.
    expect(await rowCount(ALICE)).toBe(1);
    expect((await entry(ALICE, ENTRY)).name).toBe("Meditation");
  });

  it("files two entries on one day as two rows", async () => {
    await put(ENTRY, measuredEntry(entryOn("2026-08-22")));
    await put(OTHER, measuredEntry(entryOn("2026-08-22", { name: "Meditation" })));

    // **The resource's whole shape, and the assertion a day-keyed table fails.** A day holds several
    // entries — two dreams on one night is an ordinary night — so `recoveries` would hold one row
    // here, with the second write having overwritten the first and reported success.
    expect(await rowCount(ALICE)).toBe(2);

    const rows = await window("days=0&endingOn=2026-08-22");
    expect(rows.map((row) => row.id)).toEqual([ENTRY, OTHER]);
  });

  it("returns both absences as null, on the path every imported row takes", async () => {
    const body = absentEntry();

    const written = await put(ENTRY, body);
    expect(written.status).toBe(200);

    const stored = (await written.json()) as ReceptiveInactivityWire;

    // Present at all — a stripped key would be a third state that means nothing, which is why the
    // schema declares `.nullable()` and never `.optional()`.
    expect(Object.hasOwn(stored, "note")).toBe(true);
    expect(Object.hasOwn(stored, "startedAt")).toBe(true);

    // **`null` in, `null` out.** This is the round trip a screenshot cannot make and the one that
    // matters most here: an untimed entry is the majority case, so a `?? ""` or a `?? "00:00:00"` in
    // the mapper or the adapter would rewrite every imported row into a fabricated value — an empty
    // note nobody wrote, a midnight nobody gave — while every screen went on looking plausible.
    expect(stored.note).toBeNull();
    expect(stored.startedAt).toBeNull();
    expect(await entry(ALICE, ENTRY)).toEqual(stored);
  });

  it("keeps a measured empty-ish note as the string it is, so the near miss is asserted rather than assumed", async () => {
    // The other half of the pair, and the half a mapper reading `note || null` would destroy: a note of
    // `"-"` is prose someone typed, and it must come back byte-identical rather than being folded into
    // the absence above. The `""` case is refused outright — see `the write shape` — which is what
    // leaves exactly two states on this column and no third.
    const response = await put(ENTRY, measuredEntry({ note: "-" }));

    expect(response.status).toBe(200);
    expect((await entry(ALICE, ENTRY)).note).toBe("-");
  });
});

describe("the write shape", () => {
  it("refuses a body that carries an id of its own rather than stripping it", async () => {
    const response = await put(ENTRY, { ...measuredEntry(), id: OTHER });

    // `.strict()`, and the failure it prevents is the quietest in this file: a client posting to one id
    // and believing another was written. A silent strip answers `200` and the entry is not where the
    // client will look for it.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a body missing its day", async () => {
    const response = await put(ENTRY, without(measuredEntry(), "date"));

    // The day is in the body rather than the path, and it is **not** derived from `startedAt` — which
    // is the difference from a session's own body. A session's day is at least derivable in principle
    // from its start instant; this row's start time is optional and may be absent altogether, so when
    // no time was given there is nothing to derive the day *from*. A Worker in UTC cannot know which
    // zone filed an entry, so the client — which knows the day its screen was showing — states it.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("date");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a body missing its name", async () => {
    const response = await put(ENTRY, without(measuredEntry(), "name"));

    // Required and never defaulted, because there is no honest stand-in: a name is what the row *is*
    // — `Dream`, `Meditation`, and whatever a future producer names — and a defaulted one would draw a
    // card titled with a word the producer never supplied.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("name");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses an empty name", async () => {
    const response = await put(ENTRY, measuredEntry({ name: "" }));

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("name");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses an empty note rather than reading it as an absence", async () => {
    const response = await put(ENTRY, measuredEntry({ note: "" }));

    // **The rule that makes this column's nullability mean something, and the one field in the Worker
    // where the refusal is the interesting half.** `null` is the column's word for "nothing was
    // written"; `""` is a value nobody supplied. Accepting both would give one state two spellings, and
    // the app's own reader — which compares a stored note against the text it derived the row's id
    // from — would then hold two rows that look identical and are not.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("note");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("accepts a null note and a null start, which is not the refusal above", async () => {
    // The pair to it, read beside it rather than alone: a `min(1)` written without `.nullable()` would
    // refuse this too, and with it every entry the app's sheet saves with its text field left blank —
    // an ordinary row there, and one the corpus is *not* in, since the import refuses a record that
    // carries no note.
    const response = await put(ENTRY, absentEntry());

    expect(response.status).toBe(200);
    expect((await entry(ALICE, ENTRY)).note).toBeNull();
    expect((await entry(ALICE, ENTRY)).startedAt).toBeNull();
  });

  it("refuses an instant that is not the canonical form", async () => {
    const response = await put(ENTRY, measuredEntry({ startedAt: "2026-08-22 03:40:00" }));

    // The export writes `2026-08-22 00:17:13`, so this is the shape a parser built on
    // `ISO8601DateFormatter` would hand over having read nothing. Storing it would make an entry's
    // start sort as text in a column the window read orders by, and `started_at`'s position in that
    // `ORDER BY` is what puts a day's timed entries in sequence.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("startedAt");
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses a path parameter that could not name an entry at all", async () => {
    const response = await read("/v1/receptive-inactivities/this-morning");

    // A 400 and not a 404, because the two say different things: this string cannot be an id, so the
    // request never asked about a row. Answering 404 would tell a client its well-formed request found
    // nothing, and the client would go on sending the string.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });
});

describe("an entry with no row", () => {
  it("is a 404 naming the code, not a zero-filled row", async () => {
    await put(OTHER, measuredEntry());

    const response = await read(`/v1/receptive-inactivities/${ENTRY}`);

    expect(response.status).toBe(404);
    // `not_found` and **not** the day-keyed resources' `no_measurement_for_day`. That code names a day
    // with no reading, which is a statement about a calendar; nothing in this resource is addressed by
    // a day, and nothing on the row is a measurement — so the sibling's code would be not merely
    // imprecise here but false.
    expect(await response.json()).toEqual({
      error: {
        code: "not_found",
        message: `no receptive inactivity with id ${ENTRY} in this partition`,
      },
    });
  });

  it("is omitted from a window rather than zero-filled", async () => {
    await put(ENTRY, measuredEntry(entryOn("2026-08-20")));
    await put(OTHER, measuredEntry(entryOn("2026-08-22", { name: "Meditation" })));

    const rows = await window("days=4&endingOn=2026-08-22");

    // 08-21 is inside the window and absent from the answer. An empty array would be a real answer too
    // — "nothing in this window was recorded" — which is why the omission, not the count, is the
    // assertion. A day inside the window holding no entry is simply not represented: there is no
    // per-day slot for a placeholder to occupy, because a day holds several entries.
    expect(rows.map((row) => row.id)).toEqual([ENTRY, OTHER]);
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
    // Six entries, six days: the days are what this block is about, and one entry per day is what makes
    // each assertion below a statement about a *day* rather than about a day's ordering.
    for (const [i, date] of DAYS.entries()) {
      await put(uuid(i), measuredEntry(entryOn(date)));
    }
  });

  it("returns days + 1 calendar days, oldest first", async () => {
    const rows = await window("days=2&endingOn=2026-08-22");

    // The app's own arithmetic, mirrored rather than corrected: `from = endingOn - days`, inclusive at
    // both ends, so `days: 14` is fifteen days. A ported call returns what it returned on-device, and
    // the off-by-one is a written-down fact instead of a surprise found later.
    expect(rows.map((row) => row.date)).toEqual(["2026-08-20", "2026-08-21", "2026-08-22"]);
  });

  it("takes days = 0 to mean the ending day alone", async () => {
    const rows = await window("days=0&endingOn=2026-08-22");

    // **The app's ordinary per-day read**, and the reason this resource is mounted at a collection
    // rather than at a `{date}`: a day holds several entries, so there is no per-day slot for one to
    // occupy, and the port's one day-shaped method maps onto this query rather than onto an address.
    expect(rows.map((row) => row.date)).toEqual(["2026-08-22"]);
  });

  it("returns an empty array for a window nothing covers", async () => {
    const response = await read("/v1/receptive-inactivities?days=0&endingOn=2026-08-22");
    const rows = (await response.json()) as ReceptiveInactivityWire[];

    // Non-empty here, deliberately, so the assertion below is about a *different* window.
    expect(rows).toHaveLength(1);

    // "Nothing was recorded in this window" is a real answer and the honest one — the alternative,
    // padding the window with a row per day, is the reserved-zero placeholder this repo's absence rule
    // exists to forbid.
    expect(await window("days=0&endingOn=2020-01-01")).toEqual([]);
  });

  it("refuses a window wider than the service's ceiling", async () => {
    const response = await read(
      `/v1/receptive-inactivities?days=${MAX_WINDOW_DAYS + 1}&endingOn=2026-08-22`,
    );

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a non-numeric days rather than coercing it to a window", async () => {
    const response = await read("/v1/receptive-inactivities?days=week&endingOn=2026-08-22");

    // `z.coerce.number()` turns this into `NaN`, and a handler that read `NaN` as "no bound" would
    // answer the caller's typo with the whole table.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("orders a day's entries by start time, untimed ones last, then by name", async () => {
    // Four entries on one day, written in an order that is none of the orders the read must produce.
    // The `ORDER BY` is `date ASC, started_at ASC NULLS LAST, name ASC`, and every clause of it is
    // load-bearing:
    //
    // - **`NULLS LAST` is the clause a naive port drops**, and the one this resource cannot afford to
    //   lose: SQLite sorts NULL *first* ascending, and untimed entries are the *majority* case — all 62
    //   of the app's bundled rows are untimed. Without it, every imported entry would be drawn above
    //   the timed ones on its own day.
    // - **`name ASC` is the tie-break between two untimed entries**, which is the only tie a day full
    //   of untimed rows can have.
    // Written with the day spelled out rather than through `entryOn`, and that is deliberate: the two
    // untimed rows below have to be *untimed*, and `absentEntry(entryOn(date, …))` reads as "an absent
    // entry on this day" while doing the opposite — `entryOn` supplies a `startedAt`, `absentEntry`
    // spreads its argument last, so the day helper's clock overwrites the absence and the row is
    // written with a time. Four timed rows come back in exactly the order the SQL asks for, so the
    // mistake fails this assertion rather than passing it quietly, but it fails it *here*, pointing at
    // the `ORDER BY`, which is not what is wrong.
    await put(DREAM, absentEntry({ date: "2026-08-24", name: "Dream" }));
    await put(LATE, measuredEntry({ date: "2026-08-24", startedAt: "2026-08-24T18:00:00.000Z" }));
    await put(EARLY, measuredEntry({ date: "2026-08-24", startedAt: "2026-08-24T07:00:00.000Z" }));
    await put(MEDITATION, absentEntry({ date: "2026-08-24", name: "Meditation" }));

    const rows = await window("days=0&endingOn=2026-08-24");

    expect(rows.map((row) => row.id)).toEqual([EARLY, LATE, DREAM, MEDITATION]);
    expect(rows.map((row) => row.startedAt)).toEqual([
      "2026-08-24T07:00:00.000Z",
      "2026-08-24T18:00:00.000Z",
      null,
      null,
    ]);
  });
});

describe("the partition", () => {
  it("keeps one user's entry invisible to another", async () => {
    await put(ENTRY, measuredEntry(), ALICE);

    expect((await read(`/v1/receptive-inactivities/${ENTRY}`, ALICE)).status).toBe(200);
    // Nothing verifies the header yet, so this is the `user_id` column doing real work: the row is
    // there, and a different owner cannot reach it.
    expect((await read(`/v1/receptive-inactivities/${ENTRY}`, BOB)).status).toBe(404);
    expect(await window("days=2&endingOn=2026-08-22", BOB)).toEqual([]);
  });

  it("lets two users hold the same entry id without colliding", async () => {
    await put(ENTRY, measuredEntry({ name: "Dream" }), ALICE);
    await put(ENTRY, measuredEntry({ name: "Meditation" }), BOB);

    // The table is keyed `(user_id, id)` rather than on `id` alone, which is the only isolation this
    // Worker has: a read or a write keyed on the id by itself would cross partitions.
    expect((await entry(ALICE, ENTRY)).name).toBe("Dream");
    expect((await entry(BOB, ENTRY)).name).toBe("Meditation");
    expect(await rowCount(ALICE)).toBe(1);
    expect(await rowCount(BOB)).toBe(1);
  });

  it("files the row under the digest of the key, never under the key", async () => {
    await put(ENTRY, measuredEntry());

    // The two reads are the assertion, and the second is the one that matters. The first says the row
    // is reachable at all; the second says the column holds something that is *not* the header, which
    // is the whole of what a D1 dump leaking no usable credentials means. A `user_id` equal to `ALICE`
    // would satisfy every other test in this file — the requests would still work, because the same
    // string would be hashed on the way in and matched on the way out — and would be a database of
    // working keys.
    expect(await rowCount(ALICE)).toBe(1);

    const keyed = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM receptive_inactivities WHERE user_id = ?",
    )
      .bind(ALICE)
      .first<{ n: number }>();

    expect(keyed?.n).toBe(0);
  });
});

describe("identity", () => {
  it("refuses a request with no X-Whoopsy-User-Id", async () => {
    const response = await SELF.fetch(
      `${BASE}/v1/receptive-inactivities?days=2&endingOn=2026-08-22`,
    );

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses an empty X-Whoopsy-User-Id", async () => {
    const response = await read(`/v1/receptive-inactivities/${ENTRY}`, "");

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a key one character below the floor", async () => {
    const short = "a".repeat(MIN_KEY_LENGTH - 1);

    // The boundary from the inside, because the guard is a length test and an off-by-one is its only
    // realistic defect: `>=` spelled `>` would admit exactly this string and pass every other test in
    // this file, including the empty-key one above — nothing else here is near the edge.
    expect((await read(`/v1/receptive-inactivities/${ENTRY}`, short)).status).toBe(400);

    // And one character above it is accepted, so the pair pins a boundary rather than restating a
    // refusal that a blank check would also produce.
    expect((await read(`/v1/receptive-inactivities/${ENTRY}`, "a".repeat(MIN_KEY_LENGTH))).status).toBe(
      404,
    );
  });
});

describe("a chunk of entries", () => {
  it("answers with a tally that is also the row count, because an entry has no children", async () => {
    const rows = [entryRow(ENTRY), entryRow(OTHER, absentEntry())];

    const response = await postBatch({ rows });
    expect(response.status).toBe(200);

    // **Two, and on this resource the two readings of the figure coincide.** A session's batch reports
    // a tally of sessions while the number of rows it touched is an order of magnitude larger, so
    // `MAX_BATCH_WORKOUTS`'s doc has to say which one it is; here an entry is exactly one statement, so
    // `written` is the row count and the row count is `written`. That identity is the resource's shape
    // rather than a second convention, and the read below is what keeps the tally honest — a `written`
    // counted from the request's own array would be the same number here and would disagree with the
    // table the moment an upsert stopped landing.
    expect(await response.json()).toEqual({ written: 2 });
    expect(await rowCount(ALICE)).toBe(2);

    const rowsBack = await window("days=0&endingOn=2026-08-22");
    expect(rowsBack.find((row) => row.id === OTHER)?.note).toBeNull();
  });

  it("answers the same number for a replayed chunk and moves no row", async () => {
    const rows = [entryRow(ENTRY), entryRow(OTHER, absentEntry())];

    const first = await postBatch({ rows });
    const second = await postBatch({ rows });

    expect(await first.json()).toEqual({ written: 2 });
    // **Not zero.** `INSERT … ON CONFLICT DO UPDATE` counts a row it matched as changed even when every
    // value is byte-identical, so a replayed chunk reports the same figure as the first send. That is
    // the honest answer — the statement did write that row — and it is why `written: 0` must never be
    // read as "there was nothing to do": nothing in this API answers `0` for a non-empty batch. On this
    // resource it is also what makes the import safe to press twice, since the app derives each row's
    // id from the entry's own date, type and text.
    expect(await second.json()).toEqual({ written: 2 });

    // And idempotence is a claim about the table, not about the number.
    expect(await rowCount(ALICE)).toBe(2);
  });

  it("writes a full chunk of the cap in one request", async () => {
    const rows = Array.from({ length: MAX_BATCH_RECEPTIVE_INACTIVITIES }, (_, i) =>
      entryRow(uuid(i), absentEntry()),
    );

    const response = await postBatch({ rows });

    expect(response.status).toBe(200);
    // The cap is sized against the corpus rather than against cost: the app's bundled notes file is 62
    // entries over 57 days, and an entry is exactly one statement — so 200 is a chunk that fits a real
    // import three times over, and `written` is the assertion that would catch a `NaN` from a
    // `meta.changes` this runtime did not report.
    expect(await response.json()).toEqual({ written: MAX_BATCH_RECEPTIVE_INACTIVITIES });
    expect(await rowCount(ALICE)).toBe(MAX_BATCH_RECEPTIVE_INACTIVITIES);
  });

  it("refuses a chunk one entry past the cap, and writes nothing", async () => {
    const rows = Array.from({ length: MAX_BATCH_RECEPTIVE_INACTIVITIES + 1 }, (_, i) =>
      entryRow(uuid(i), absentEntry()),
    );

    const response = await postBatch({ rows });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    // Nothing, not "the first two hundred". The cap is a refusal rather than a truncation because a
    // client whose chunk was silently trimmed would believe the whole range had been uploaded.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("refuses an entry id carried twice, and writes nothing", async () => {
    const rows = [entryRow(ENTRY), entryRow(OTHER)];
    const response = await postBatch({ rows: [...rows, rows[1]!] });

    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
    // The alternative is *nearly* harmless — the second write wins and the entry on disk is whichever
    // the array put last — which is exactly the failure: a `200` whose result depends on the order of
    // an array the client built, reported as success.
    expect(await rowCount(ALICE)).toBe(0);
  });

  it("accepts two rows sharing a day, which is the rule the day-keyed resources invert", async () => {
    const rows = [
      entryRow(ENTRY, entryOn("2026-08-22")),
      entryRow(OTHER, entryOn("2026-08-22", { name: "Meditation" })),
    ];

    const response = await postBatch({ rows });

    // **Read beside the duplicate-id refusal above, not on its own.** `recoveries` refuses a date
    // carried twice because its primary key is the day; here two rows on one day are the ordinary case
    // and the uniqueness check is on `id`. The pair of assertions is what pins which key the check is
    // on, and neither alone can tell the right rule from the wrong one: a check written against `date`
    // passes the refusal above and fails this.
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ written: 2 });
    expect(await rowCount(ALICE)).toBe(2);
  });

  it("refuses an empty chunk", async () => {
    const response = await postBatch({ rows: [] });

    // A `200` with `written: 0` would render as "a successful sync of nothing", indistinguishable from
    // a chunk that worked.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.code).toBe("invalid_request");
  });

  it("refuses a row that carries no id of its own", async () => {
    const response = await postBatch({ rows: [measuredEntry()] });

    // The id is in the path on the `PUT` and in the body here, so this is the half that has no other
    // spelling: a row without one would have to be keyed on something, and the day is the one candidate
    // that must not be used — it is what makes the second entry overwrite the first.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("rows.0.id");
  });

  it("refuses a row carrying a field the contract does not have", async () => {
    const rows = [entryRow(ENTRY), entryRow(OTHER)];
    const response = await postBatch({
      rows: [rows[0], { ...rows[1], endedAt: "2026-08-22T04:10:00.000Z" }],
    });

    // `.strict()`, and it matters more at this volume than on the single-entry body: a batch is
    // assembled by a client out of its own database, and a field it copied from a session row — an
    // `endedAt` this resource deliberately has no column for — is exactly the failure a silent strip
    // turns into an entry written with no sign that half of what the client sent was discarded. The
    // path names the row, which is what makes it findable among 200.
    expect(response.status).toBe(400);
    expect((await response.json() as ErrorWire).error.message).toContain("rows.1");
  });

  it("never deletes an entry the caller leaves out", async () => {
    const rows = [entryRow(ENTRY, entryOn("2026-08-20")), entryRow(OTHER, entryOn("2026-08-21"))];
    await postBatch({ rows });

    // One entry of the two, alone in the chunk.
    await postBatch({ rows: [rows[1]!] });

    // Both are still there, and the one the second chunk carried is still there *once*. This is why the
    // endpoint is a `POST` on `/batch` and not a `PUT` on the collection: "these are the entries"
    // obliges the server to remove the ones left out, and a client whose retry sent a partial chunk —
    // the rest of it lost to a timeout — would erase its own history while being told the request
    // succeeded.
    //
    // **It is also the whole of what this API can say about removal, and the answer to the app's own
    // port.** `ReceptiveInactivityRepository.delete(_:)` exists on the iOS side and has no counterpart
    // here: there is no `DELETE` route, no `delete` on the domain port and no delete path anywhere in
    // this Worker, so a row a client removes on-device stays here and comes back on the next sync of
    // the day it is filed on. That is a documented convention rather than an omission, and this
    // assertion is where it is pinned.
    const rowsBack = await window("days=3&endingOn=2026-08-22");
    expect(rowsBack.map((row) => row.id)).toEqual([ENTRY, OTHER]);
    expect(await rowCount(ALICE)).toBe(2);
  });

  it("keeps one caller's chunk out of another's partition", async () => {
    await postBatch({ rows: [entryRow(ENTRY), entryRow(OTHER)] }, ALICE);
    const bobs = await postBatch({ rows: [entryRow(ENTRY, { name: "Meditation" })] }, BOB);

    expect(await bobs.json()).toEqual({ written: 1 });

    expect(await rowCount(ALICE)).toBe(2);
    expect(await rowCount(BOB)).toBe(1);

    const rows = await window("days=2&endingOn=2026-08-22", BOB);
    expect(rows.map((row) => row.id)).toEqual([ENTRY]);
  });
});

describe("the chunk's transaction", () => {
  /**
   * The one thing in this file that is evidence about D1 rather than about this Worker.
   *
   * `D1ReceptiveInactivityRepository.upsertMany` writes a chunk through `env.DB.batch(...)` and relies
   * on its documented all-or-nothing behaviour for the promise the endpoint makes — *a failure writes
   * nothing and the same body can be sent again*. That promise is not reachable through HTTP with a
   * valid schema: every field a batch can carry is already checked by Zod, so there is no body that
   * passes validation and then fails in the database. Which means the only honest way to pin the
   * assumption is to make the database fail directly, the way the repository does when something is
   * wrong with the rows rather than with the request.
   *
   * **This is a probe, and it is written as one.** If miniflare's local D1 ever stops rolling a batch
   * back — the two databases this repo runs against are already documented to differ — this test is
   * where that is learned, rather than in a sync that half-wrote a chunk and reported the failure with
   * no way to tell how far it got.
   */
  it("rolls a failed batch back rather than keeping the statements before it", async () => {
    const userId = await partition(ALICE);

    const lands = env.DB.prepare(
      "INSERT INTO receptive_inactivities (user_id, id, date, name) VALUES (?, ?, ?, ?)",
    ).bind(userId, ENTRY, "2026-08-22", "Dream");

    // The second statement is missing every NOT NULL column but `user_id`, so it cannot land — and it
    // is the *second* deliberately: the question is whether the first one survives it.
    const fails = env.DB.prepare("INSERT INTO receptive_inactivities (user_id) VALUES (?)").bind(
      userId,
    );

    await expect(env.DB.batch([lands, fails])).rejects.toThrow();

    expect(await rowCount(ALICE)).toBe(0);
  });

  it("leaves the table untouched when the repository's own chunk is refused", async () => {
    const rows = [entryRow(ENTRY), entryRow(OTHER)];

    // Chunks that are refused *before* they reach D1 — here by the cap and by a repeated id — have
    // nothing to roll back, and the assertion is that the route validated before the service wrote
    // rather than after. Ordered against the test above on purpose: that one covers the transaction
    // below the endpoint, this one covers the fact that a refusal above it never opens one.
    await postBatch({
      rows: Array.from({ length: MAX_BATCH_RECEPTIVE_INACTIVITIES + 1 }, (_, i) =>
        entryRow(uuid(i)),
      ),
    });
    await postBatch({ rows: [...rows, rows[0]!] });

    expect(await rowCount(ALICE)).toBe(0);
  });
});
