/**
 * Calendar-day arithmetic on `YYYY-MM-DD` keys, in UTC and only in UTC.
 *
 * This file exists because a day key is a *calendar day*, not an instant, and the two are only
 * interchangeable if nothing in the chain has a timezone of its own. The Worker's own zone is UTC by
 * definition and `Date.UTC` is the one constructor that cannot be moved by `TZ`, so every function
 * here is stable under whatever the runtime or a test harness happens to be set to. A local-time
 * `new Date(y, m, d)` would make `addDays` an identity on a DST boundary and would make
 * `parseDayKey` accept or reject `2026-03-08` depending on the machine.
 *
 * Deliberately *not* a date library: the four operations below are the whole of what this Worker
 * needs, and the one that is easy to get wrong — `parseDayKey` refusing a day that does not exist —
 * is a round trip rather than a table.
 */

const DAY_KEY_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

const MS_PER_DAY = 86_400_000;

/**
 * Parse a `YYYY-MM-DD` day key to the epoch milliseconds of that day's UTC midnight, or `null` if it
 * is not a day.
 *
 * A regex alone is not enough and the failure it lets through is the reason this is a round trip:
 * `Date.UTC(2026, 1, 31)` does not refuse February 31, it rolls it forward to March 3. A `PUT` to
 * `/v1/recoveries/2026-02-31` would then be accepted and filed under a day nobody asked for, and the
 * client's own follow-up `GET` on `2026-02-31` would — consistently — find it, so nothing anywhere
 * would look wrong. Re-reading the components back out of the constructed instant is what makes
 * "this string is a day" a fact rather than a hope.
 *
 * Components are taken by slice rather than by destructuring a `match`, because
 * `noUncheckedIndexedAccess` is on and every capture group would be `string | undefined` for no
 * benefit.
 */
export function parseDayKey(value: string): number | null {
  if (!DAY_KEY_PATTERN.test(value)) return null;

  const year = Number(value.slice(0, 4));
  const month = Number(value.slice(5, 7));
  const day = Number(value.slice(8, 10));

  const ms = Date.UTC(year, month - 1, day);
  const roundTrip = new Date(ms);

  if (roundTrip.getUTCFullYear() !== year) return null;
  if (roundTrip.getUTCMonth() !== month - 1) return null;
  if (roundTrip.getUTCDate() !== day) return null;

  return ms;
}

/**
 * Format an instant as a day key.
 *
 * `toISOString` is always UTC, so this is the exact inverse of `parseDayKey` on any instant that is
 * already a UTC midnight — which is the only kind this Worker ever passes it. An instant carrying a
 * time component is truncated rather than refused, which is why callers in this codebase only ever
 * hand it one built by `parseDayKey` or `addDays`.
 */
export function formatDayKey(date: Date): string {
  return date.toISOString().slice(0, 10);
}

/**
 * Step a day key by whole days — negative to go back.
 *
 * Stepping is done on the parsed UTC instant rather than by decomposing and reassembling the string,
 * so a month or year boundary is the runtime's problem and not this function's. `MS_PER_DAY` is a
 * safe stride here precisely because UTC has no DST: the arithmetic would be wrong in a local zone
 * and is exact in this one.
 */
export function addDays(dayKey: string, delta: number): string {
  const ms = parseDayKey(dayKey);
  if (ms === null) {
    throw new Error(`addDays: ${JSON.stringify(dayKey)} is not a day key`);
  }
  return formatDayKey(new Date(ms + delta * MS_PER_DAY));
}

/**
 * The server's own idea of today, as a day key.
 *
 * This is a *fallback* and the API treats it as one: `endingOn` is optional so that a caller with no
 * opinion still gets a sensible window, but the server's UTC day is not the user's local day, and a
 * client that cares about which calendar day it is asking about must send its own. `GET
 * /v1/recoveries?days=0` from a device eight hours behind UTC is the case where the two disagree.
 */
export function utcToday(now: Date = new Date()): string {
  return formatDayKey(now);
}
