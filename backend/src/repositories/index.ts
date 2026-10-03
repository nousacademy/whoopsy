/**
 * Storage adapters — the only layer that knows D1 and R2 exist.
 *
 * Empty. Every `D1Database` statement and every `R2Bucket` call in this Worker belongs in a file
 * under this directory, so that "what does the schema look like" has one answer and a service can
 * be tested against a fake.
 *
 * **The local schema is the starting point, not the target.** `ios/Sources/Whoopsy/Data/Persistence/`
 * already has a migrated SQLite schema with its own conventions — `workouts` is keyed on `id`
 * because a day holds several, `recoveries`/`sleeps`/`strains` are keyed on `date` because a day
 * holds one, and the day key is `startOfDay` of a night's *wake* onset. A D1 table that renames any
 * of that puts a second convention on the same quantity, and the app's own docs record what that
 * costs. Read the root `CLAUDE.md`'s column-naming and day-key gotchas before writing the first
 * migration.
 */
export {};
