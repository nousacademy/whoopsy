/**
 * `user_profiles` — the person using the app, as opposed to something the app measured about them.
 *
 * This file has no `import` and must not gain one, for `receptiveInactivity.ts`'s reason: the layer
 * boundary is that a service depends on a shape and a port and never on a table, and a dependency-free
 * file is what makes that statable rather than merely intended.
 *
 * **The resource is a singleton and the port says so by taking no identity.** `find` and `upsert` are
 * keyed on the partition alone, because a partition holds at most one profile and a second key would
 * be a second thing to disagree about. That is the app's own port mirrored -- `getUserProfile()` and
 * `saveUserProfile(_:)` take no id, and its record's key is the literal `"primary"` -- and it is why
 * this resource has no `{id}` path, no window query and no `/batch` endpoint. See
 * `migrations/0008_create_user_profiles.sql` for the key and why the local `id` column is not
 * translated.
 *
 * **`upsert` is a whole-row write, and that is a property callers have to know rather than a detail.**
 * The app's `save` is INSERT-or-UPDATE over the entire row, so a `PUT` carrying `weightKg: null`
 * *clears* the weight rather than leaving it alone: there is one write verb here and no partial
 * update. A client that wanted to change one field reads the row first, changes it, and sends the
 * whole thing back -- which is exactly what the app's own form does.
 */

/**
 * The app's gender vocabulary, and a value two layers have to agree about.
 *
 * Re-exported from `domain/index.ts` on the rule that barrel states: a constant belongs there when two
 * layers must agree about it, and this one is the same kind of value as `HRV_METRICS` -- a closed
 * enum the wire publishes as `z.enum(...)`. It is the app's own `UserProfile.Gender` raw values
 * verbatim, never re-spelled: the string stored here is the string a reader sees in `sqlite3`.
 *
 * **It is closed rather than an open `string`, and the cost is deliberate.** A fifth case on the app's
 * enum would need a deploy here to be writable -- but the alternative is a field whose legal values
 * are published nowhere, and the app resolves an unrecognised word to `null` rather than guessing at
 * it, so an open string would store values that every reader silently drops. Refusing at the boundary
 * what the reader would discard is the honest half of that trade.
 */
export const USER_PROFILE_GENDERS = ["man", "woman", "nonBinary", "preferNotToSay"] as const;

/** One of the app's four gender words. */
export type UserProfileGender = (typeof USER_PROFILE_GENDERS)[number];

/**
 * One person's profile, as this Worker holds it.
 *
 * `userId` is the partition and is not on the wire; every other field is, and the two that are not
 * nullable are the two the zone table cannot be built without. The other five are `| null` because
 * the app's own storage has no column for "the user did not say" beyond the null itself -- and `null`
 * is a different answer from every value, including `""`.
 *
 * **`birthDate` is a day key**: `YYYY-MM-DD`, matching `Recovery.date`'s wire shape. It is a string
 * here rather than a `Date` for the same reason the column is `TEXT` -- see the migration -- and the
 * client is the only side that converts.
 */
export interface UserProfile {
  readonly userId: string;
  readonly maxHeartRate: number;
  readonly restingHeartRate: number;
  readonly weightKg: number | null;
  readonly name: string | null;
  readonly birthDate: string | null;
  readonly gender: UserProfileGender | null;
  readonly heightCm: number | null;
}

/**
 * The port. **Two methods and deliberately not four**: there is no `listWindow`, because a singleton
 * has no range, and there is no `delete`, which is the standing convention this Worker applies to
 * every resource -- `WorkoutRepository.delete(_:)` and `ReceptiveInactivityRepository.delete(_:)`
 * both exist on the app's side with no counterpart in any route here.
 *
 * `find` answers `null` for a partition holding no profile rather than a fabricated one. That is this
 * Worker's absence rule applied to a resource where the app deviates from it -- the app's own
 * repository returns a cold-start 190/60 for a missing row, which is its tolerance for a zone table
 * that cannot be built at all. That constant is the *client's* to apply, at the moment it merges a
 * remote absence with its local copy; a server that published it would be inventing a measurement and
 * calling it a row, which is the one thing this project's absence rule forbids everywhere.
 */
export interface UserProfileRepository {
  find(userId: string): Promise<UserProfile | null>;
  upsert(profile: UserProfile): Promise<UserProfile>;
}
