/**
 * The instant wire format: ISO-8601, canonical UTC, exactly three fractional digits.
 *
 * `2026-08-22T13:45:00.000Z` — and nothing else. `…:00Z`, `…:00.0Z`, `…:00.000+00:00` and
 * `…:00.000000Z` all name the same instant and are all refused, because a format with more than one
 * spelling is a format whose comparisons are somebody's guess about which spelling the other side
 * used.
 *
 * **There is one canonical spelling, and the reason is `ORDER BY`.** `workouts.started_at` and
 * `ended_at` are TEXT, and the window read sorts a day's sessions by `started_at`. A fixed-width
 * UTC spelling makes that a chronological order rather than a lexicographic accident: `…T09:00`
 * sorts before `…T13:45` because `0` precedes `1`, and would not if one row carried a `+02:00`
 * offset or a variable number of fractional digits. Normalising on write would be the other way to
 * get that, and it is worse here — the column stores the string it was handed, so pinning the
 * format means a client's own spelling round-trips, which is the property a sync is for.
 *
 * This is the sibling of `days.ts` rather than a part of it. That file is calendar-day arithmetic
 * on `YYYY-MM-DD` keys and says so in its own header; an instant is a different format with a
 * different validation rule, and folding it in would make one file the answer to two questions.
 * The two share the technique — a regex to fix the shape, then a round trip through the platform's
 * own parser to reject a value the regex accepts and the calendar does not — and nothing else.
 */

/**
 * The shape, before the calendar is consulted.
 *
 * A regex alone is not enough and the gap is not theoretical: `2026-02-31T00:00:00.000Z` matches
 * any pattern of digits you can write, and `Date.parse` either refuses it or rolls it forward to
 * March 3 — so a value that is not a real instant would be stored with a `date` that disagrees with
 * its own `started_at`, which is exactly the kind of row nothing downstream can repair.
 */
const INSTANT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

/**
 * Parse an instant, or answer `null` for anything that is not one.
 *
 * Returns epoch milliseconds, mirroring `parseDayKey`'s `number | null`: this layer's callers want
 * a test (`!== null`), not a second error type, and the epoch figure is what makes the round trip
 * below cheap. The value that is stored is the caller's own string, never this number.
 *
 * The round trip is the whole rule: `toISOString()` renders the canonical form, so a parsed value
 * that does not render back to the input is a value whose input was not canonical — a rolled-over
 * date, a missing or extra fractional digit, an offset instead of a `Z`. Both halves are needed. The
 * regex catches the offset and the fractional width; the round trip catches the calendar, and the
 * two failure modes are disjoint.
 */
export function parseInstant(value: string): number | null {
  if (!INSTANT_PATTERN.test(value)) {
    return null;
  }

  const milliseconds = Date.parse(value);
  if (Number.isNaN(milliseconds)) {
    return null;
  }

  // `toISOString` throws on an invalid date, which is why the NaN test above comes first.
  if (new Date(milliseconds).toISOString() !== value) {
    return null;
  }

  return milliseconds;
}
