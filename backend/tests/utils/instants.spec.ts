import { describe, expect, it } from "vitest";
import { parseInstant } from "../../src/utils/instants";

/**
 * The instant format, asserted against values that did not come from this code.
 *
 * No Worker and no database: `parseInstant` is a string in and a number out, so this file is the
 * pure-value half of the suite and it is deliberately the sibling of `identity.spec.ts` rather than
 * a block inside `routes/workouts.spec.ts`. The temptation is to cover this through the route — a
 * malformed `startedAt` is a 400 — and that would be the weaker place for it. Through the route the
 * assertion is "some 400 came back", which a hundred different regexes would satisfy; here it is
 * "this spelling is refused and this one is accepted", which is the rule the column's ordering
 * depends on and which nothing above this layer can see.
 *
 * **The epoch figures come from `date(1)`, not from `Date.parse`.** `parseInstant` is built on
 * `Date.parse` and on `toISOString`, so a test that computed its expectations with either would be
 * checking that the platform agrees with itself: `1970-01-01T00:00:00.000Z → 0` and the two 2026
 * figures were read out of `TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S.000Z" … "+%s"`, which shares no
 * code with this Worker. That is the CRC-vector rule as it applies to a date parser, and it is the
 * same bargain `identity.spec.ts` strikes with `shasum`.
 */

/** One second past the epoch is `1000`, so a zero must be a zero and not a falsy accident. */
const EPOCH = "1970-01-01T00:00:00.000Z";

/** The instant most of this file is written around, and the three the sort block sweeps. */
const CANONICAL = "2026-08-22T13:45:00.000Z";
const EARLIER = "2026-08-22T09:00:00.000Z";

/** A leap day in a leap year, which is the one date shape a regex cannot get right on its own. */
const LEAP_DAY = "2024-02-29T12:00:00.000Z";

describe("the one canonical spelling", () => {
  it("parses the form to the epoch milliseconds, pinned against values read elsewhere", () => {
    // `date -u`, not `Date.parse`. The three figures are the whole of what this function is for, and
    // an expectation computed by the same platform call the implementation makes would pass for an
    // implementation that had the wrong unit, the wrong epoch or a timezone offset folded in — a
    // `getTime()` divided by 1000 would answer 1787406300 here and still be self-consistent.
    expect(parseInstant(CANONICAL)).toBe(1787406300000);
    expect(parseInstant(EARLIER)).toBe(1787389200000);
    expect(parseInstant(LEAP_DAY)).toBe(1709208000000);
  });

  it("answers 0 for the epoch itself rather than treating it as absent", () => {
    // The one value where a `|| null` and a falsy check part company from a `!== null` test: the
    // epoch is a real instant, and the callers' guard is a `!== null` comparison precisely so that
    // this row is storable. An implementation answering `null` here would refuse 1970 and nothing
    // else — a defect reachable only from a fixture, which is why the fixture is here.
    expect(parseInstant(EPOCH)).toBe(0);
    expect(parseInstant(EPOCH)).not.toBeNull();
  });

  it("keeps the caller's own string, and the number it returns is not what gets stored", () => {
    // The round trip is a test and not a normaliser: every spelling that reaches this function and
    // survives is already byte-identical to `toISOString`'s output, so a stored `started_at` is the
    // string the client sent. That is what makes a client's own value round-trip through a sync
    // rather than being rewritten by the server into an equivalent one — and it is why the parsing
    // is strict rather than lenient, since a lenient parser here would be silently rewriting.
    expect(new Date(parseInstant(CANONICAL)!).toISOString()).toBe(CANONICAL);
  });
});

describe("the shapes it refuses", () => {
  it("refuses a fractional-second field of any width but three", () => {
    // The widths are one, zero and six. `toISOString` renders three and only three, so the round trip
    // already refuses these — and the assertion is here anyway because the failure they describe is
    // the one a reader is most likely to reintroduce: the tempting relaxation is to accept any width
    // and re-render, which is the rewriting the block above exists to forbid. All three name the
    // same instant as `CANONICAL` and none of them is it.
    expect(parseInstant("2026-08-22T13:45:00.0Z")).toBeNull();
    expect(parseInstant("2026-08-22T13:45:00Z")).toBeNull();
    expect(parseInstant("2026-08-22T13:45:00.000000Z")).toBeNull();
  });

  it("refuses an offset where the format says Z", () => {
    // `+02:00`, `-00:00` and `+0200`. The first two name real instants and the third is the same
    // spelling without its colon, which several parsers in the wild accept. All three are refused,
    // and the sort block at the end of this file is the argument for why: an offset is a second way
    // to spell one instant, and two spellings of one instant is what makes a TEXT column's order a
    // guess rather than a chronology.
    expect(parseInstant("2026-08-22T15:45:00.000+02:00")).toBeNull();
    expect(parseInstant("2026-08-22T13:45:00.000-00:00")).toBeNull();
    expect(parseInstant("2026-08-22T15:45:00.000+0200")).toBeNull();
  });

  it("refuses the separators, the casing and the truncations around the shape", () => {
    for (const spelling of [
      "2026-08-22 13:45:00.000Z", // the export's own separator, and the one a Swift parser hands over
      "2026-08-22T13:45:00.000z", // `Z` is uppercase in the format
      "2026-08-22t13:45:00.000Z", // and `T` likewise
      "2026-08-22T13:45:00.000", // no zone at all, which `Date.parse` reads as local time
      "2026-08-22T13:45.000Z", // no seconds
      "2026-08-22T13:45:00.000+00:00",
      "2026-08-22",
      "",
    ]) {
      // The pair worth naming is the first and the fourth. The export writes `2026-08-22 00:17:13`, so
      // the space form is the exact string a parser built on `ISO8601DateFormatter` produces having
      // read the file — and the fourth is the same instant with the zone dropped, which the platform
      // resolves against **this machine's** timezone. Accepting either would put a value in
      // `started_at` whose day the server cannot agree with the client about, and the window read
      // sorts on that column.
      expect(parseInstant(spelling)).toBeNull();
    }
  });
});

describe("the calendar behind the shape", () => {
  it("refuses a day the month does not have, which the pattern alone accepts", () => {
    // **The value that makes the round trip load-bearing.** `2026-02-31` is four digits, a dash and
    // two digits in exactly the right places, so `INSTANT_PATTERN` matches it and any pattern of
    // digits a reader could write would match it too. What refuses it is the second half: the
    // platform parses it by rolling forward, `Date.parse` answering 1772496000000 — which is
    // `2026-03-03T00:00:00.000Z` — and that does not render back to the input.
    //
    // The alternative design is a regex that knows the month lengths and the leap rule. This is the
    // same refusal for a fraction of the code, and it cannot be wrong about February: the calendar
    // that checks it is the platform's, not one written here.
    expect(parseInstant("2026-02-31T00:00:00.000Z")).toBeNull();
    expect(parseInstant("2026-04-31T00:00:00.000Z")).toBeNull();
    expect(parseInstant("2026-02-30T00:00:00.000Z")).toBeNull();
  });

  it("gets the leap rule from the calendar rather than from a four-year cycle", () => {
    // The pair that separates a real leap rule from the tempting `year % 4`. 2024 was a leap year and
    // 2100 will not be, and a hand-written month table with the four-year rule in it admits the
    // second — a value that would be stored, read back, and disagree with every calendar downstream.
    // 2026 is not a leap year, so the same day in it is refused.
    expect(parseInstant(LEAP_DAY)).toBe(1709208000000);
    expect(parseInstant("2026-02-29T12:00:00.000Z")).toBeNull();
    expect(parseInstant("2100-02-29T00:00:00.000Z")).toBeNull();
  });

  it("refuses an hour, a month or a minute past the end of its range", () => {
    // `24:00:00` is the interesting one: ISO 8601 permits it as a synonym for the next midnight, the
    // platform accepts it, and this format does not — the round trip refuses it because
    // `2026-08-22T24:00:00.000Z` renders as `2026-08-23T00:00:00.000Z`. It has to be refused here
    // rather than stored, because the *string* is what the column holds: `started_at` would say the
    // 22nd while every parse of it says the 23rd, and the window read that sorts on that column
    // would place the session by the string while a client placed it by the value.
    expect(parseInstant("2026-08-22T24:00:00.000Z")).toBeNull();
    expect(parseInstant("2026-08-22T13:60:00.000Z")).toBeNull();
    expect(parseInstant("2026-13-01T00:00:00.000Z")).toBeNull();
    expect(parseInstant("2026-00-01T00:00:00.000Z")).toBeNull();
  });
});

describe("the order the format buys", () => {
  it("sorts as text in the same order it sorts as time", () => {
    const instants = [
      "2026-08-22T09:00:00.000Z",
      "2026-08-22T09:00:00.001Z",
      "2026-08-22T13:45:00.000Z",
      "2026-08-22T23:59:59.999Z",
      "2026-08-23T00:00:00.000Z",
      "2026-12-31T23:59:59.999Z",
      "2027-01-01T00:00:00.000Z",
    ];

    const byText = [...instants].sort();
    const byTime = [...instants].sort((a, b) => parseInstant(a)! - parseInstant(b)!);

    // **This is the reason the format is fixed-width and UTC, and it is a property of the strings
    // rather than of this function.** `workouts.started_at` is TEXT and `SELECT_WINDOW` orders a
    // day's sessions by it, so the database is doing a lexicographic comparison and the app is
    // reading a chronology. The two agree here and only here — the last three fixtures are the edges
    // that would show it, since the year rolls, the month rolls and the second rolls within one
    // sweep.
    expect(byText).toEqual(byTime);
    expect(byText[0]).toBe("2026-08-22T09:00:00.000Z");
    expect(byText.at(-1)).toBe("2027-01-01T00:00:00.000Z");
  });

  it("refuses the spelling that would break that order, rather than sorting it wrongly", () => {
    // The counterexample, and the whole case for refusing offsets. `2026-08-22T15:45:00.000+02:00`
    // names **exactly** the same instant as `CANONICAL` — 13:45 UTC — and as text it sorts *after*
    // it, because `5` follows `3`. So a column holding both spellings would order two rows that are
    // simultaneous, and would order a `+02:00` row against a `Z` one by a rule nobody wrote down.
    // Refusing the form is the only way to keep the sort honest; normalising it on write would fix
    // the column and break the round trip above.
    expect(parseInstant("2026-08-22T15:45:00.000+02:00")).toBeNull();

    // Read the three statements together, because neither the first nor the second says why on its
    // own: the platform calls the two spellings one instant, the strings compare as two, and the
    // spelling that would corrupt the order is the one this function refuses. The middle assertion
    // is the only place in this file that reaches for `Date.parse` deliberately — it is not checking
    // `parseInstant`, it is establishing that the counterexample is a counterexample.
    const offset = "2026-08-22T15:45:00.000+02:00";
    expect(Date.parse(offset)).toBe(Date.parse(CANONICAL));
    expect(offset > CANONICAL).toBe(true);
    expect(parseInstant(offset)).toBeNull();
  });
});
