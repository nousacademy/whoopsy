/**
 * A receptive inactivity, as a shape rather than a table.
 *
 * This file knows a *shape*, not a table: no SQL, no column name, no `D1Database`. The adapter behind
 * it (`d1ReceptiveInactivityRepository.ts`) is the only file in the Worker that names a table or a
 * column, which is what lets a service be exercised against an in-memory fake of this interface with
 * no database in the room.
 *
 * **The name is the app's and it is the app's own category, not a measurement.** "Receptive
 * inactivity" is the states where conscious exertion drops to zero and the internal, autonomic work
 * happens — a dream, a meditation, qigong. Nothing on this row is measured: there is no strain, no
 * heart rate, no steps and no zone block, so a defaulted number anywhere here would be a fabricated
 * reading rather than an absence.
 *
 * **An inactivity has no end.** There is no `endedAt`, and that single missing field is what the rest
 * of the shape follows from: no `covers(_:)`, no duration, no aggregation, and a repository with a
 * single read rather than a day-keyed read beside a `covering` one. That second read exists for a
 * session that can still be underway at a day's midnight, and nothing here can be — the app's own
 * port carries one read for exactly this reason.
 *
 * **A day holds several, so the identity is the `id`.** This is the second resource in the Worker
 * that breaks the day-key rule, and it breaks it for `workouts`' reason: two dreams on one night is
 * an ordinary night, and a `date` primary key would make the second overwrite the first. See
 * `migrations/0006_create_receptive_inactivities.sql`.
 *
 * **`null` is an absence on both optional fields and is never a placeholder.** `startedAt: null` is
 * an entry filed with no clock time — which is every one of the app's 62 bundled note rows — and
 * must not be normalised to midnight or to `00:00:00`, because a time nobody gave would then sort
 * and print as one that was. `note: null` is "nothing was written", which is a different answer from
 * `""`; the app never stores the empty string, and `?? ""` must not appear anywhere in the adapter.
 */

/**
 * The id shape the app can read back.
 *
 * Not decoration, and not a general-purpose UUID rule: `GRDBReceptiveInactivityRepository`
 * builds a `UUID` from each stored id and **silently drops the row** when that fails. So an id this
 * Worker accepted but the app cannot parse is a row that is written, is returned by every read here,
 * and appears on no screen — an import that reports success and delivers nothing, which is the exact
 * failure the app's own docs record against string ids.
 *
 * It is allowed to be any version and either case, because `UUID(uuidString:)` is: the app mints v4
 * ids for a hand-entered row and derives **v5** ids for an import, and a version nibble is not
 * something either side has an opinion about.
 */
export const RECEPTIVE_INACTIVITY_ID_PATTERN =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

/** One entry in the log: what it was, which day it belongs to, and optionally when and what was written. */
export interface ReceptiveInactivity {
  readonly userId: string;
  /** The entry's identity. A UUID string — see `RECEPTIVE_INACTIVITY_ID_PATTERN`. */
  readonly id: string;
  /**
   * The device's day key: `YYYY-MM-DD`. The day the screen was showing when the entry was filed,
   * which is not derivable from `startedAt` — that may be absent, and when it is present it is a
   * time-of-day rebuilt onto this same day by the client.
   */
  readonly date: string;
  /** What the entry was: `"Dream"`, `"Meditation"`, and whatever a future producer names. */
  readonly name: string;
  /** The entry's own prose, or `null` when nothing was written. Never `""`. */
  readonly note: string | null;
  /**
   * A time-of-day on `date`, in the canonical instant form, or `null` for an untimed entry.
   *
   * Nullable where every other instant in this Worker is not: `workouts.startedAt` is `NOT NULL`
   * because a session has a beginning by definition, while an entry in a notes log routinely has no
   * recorded time at all. The column stores the caller's spelling verbatim, so `date` is the only
   * thing that says which day the clock belongs to.
   */
  readonly startedAt: string | null;
}

/**
 * The storage the service is written against.
 *
 * Four methods and deliberately not five: there is no `delete`, and its absence is the Worker's
 * standing shape rather than an oversight — no resource here has a delete path, because the only
 * destructive control in the app is on the device and this API is the sync. The app's own
 * `ReceptiveInactivityRepository` declares `delete(_ id: UUID) async throws -> Bool`; that method has
 * **no counterpart here**, so a client reaching for one is reaching for an endpoint that does not
 * exist.
 *
 * **`listWindow` answers the day-keyed question and there is deliberately no `covering` sibling.**
 * The app reads two things over that column for a *session* — which day is this row filed on, and
 * which sessions were underway on this day — and only the first has a meaning here: an inactivity
 * has no end, so it cannot be underway at a midnight and cannot overlap a day. A covering read would
 * be a second way to ask one question, with nothing to double-count. It is also why a single day is
 * read as a zero-width window (`from === to`) rather than by a method of its own.
 */
export interface ReceptiveInactivityRepository {
  /** One entry, or `null` when the partition holds no such id. */
  findById(userId: string, id: string): Promise<ReceptiveInactivity | null>;
  /**
   * Entries filed on the days `from`…`to` inclusive, oldest first.
   *
   * Ordered by `date`, then `started_at` **with nulls last**, then `name`: two entries on one day
   * have a stable order here, because a client diffing two responses should see the same list twice.
   * The null placement is load-bearing rather than incidental — SQLite sorts NULL *first* in an
   * ascending order, which would draw a day's untimed entries above its timed ones, and the app's own
   * `ReceptiveInactivity.isOrderedBefore` states the same three clauses and sorts `nil` last.
   */
  listWindow(userId: string, from: string, to: string): Promise<ReceptiveInactivity[]>;
  /**
   * Write one entry, answering what is now stored.
   *
   * INSERT-or-UPDATE by `(user_id, id)`, mirroring GRDB's `save`: a re-sent entry is a new statement
   * of the same entry, not a duplicate row. There are no children to replace, which is the whole of
   * how this upsert differs from the aggregate's.
   */
  upsert(activity: ReceptiveInactivity): Promise<ReceptiveInactivity>;
  /**
   * Write many entries as one unit, answering **how many entries** were written.
   *
   * Not how many rows: an entry is one row here, so on this resource the two agree — but the port
   * says *entries* because that is the quantity `POST /batch` publishes, and a caller must not have
   * to know that this resource's arithmetic happens to be the identity.
   */
  upsertMany(activities: readonly ReceptiveInactivity[]): Promise<number>;
}
