import type { UserProfile, UserProfileRepository } from "../domain";

/**
 * Policy for `user_profiles` — and on this resource the policy is entirely the DTO's.
 *
 * **This is the shortest service in the Worker, and it is short because the resource has no shape to
 * police rather than because it is unfinished.** `services/index.ts` blesses that reading for
 * `receptiveInactivityService` and this is the same argument taken one step further, so it is worth
 * naming exactly what is absent and why each absence is structural rather than skipped:
 *
 * - **No `days` cap and no window arithmetic.** The two refusals every day-keyed sibling opens
 *   `readWindow` with have no counterpart here, because a singleton has no range to ask for. There is
 *   no `MAX_USER_PROFILE_WINDOW_DAYS` and no `MAX_BATCH_USER_PROFILES`, and that is the whole of why
 *   neither constant family in `services/index.ts` grows by one for this resource.
 * - **No batch, and therefore none of its three checks.** No empty-list refusal, no row cap and no
 *   repeated-key check, because a partition holds one profile and there is nothing to chunk, so there
 *   is no array in which a mistake could be made twice.
 * - **No rule of its own to refuse, and that is why there is no `UserProfileError` beside the seven
 *   siblings'.** The one rule this resource publishes — `restingHeartRate` strictly below
 *   `maxHeartRate` — is a rule about a *body*, and this Worker has a place for those: it is stated as
 *   a `.refine()` on `UserProfileWriteSchema`, which is what publishes it in the OpenAPI document.
 *   `SleepWriteSchema`'s `endsAfterItStarts` is the identical shape and lives on its body alone, with
 *   `sleepService.writeDay` forwarding exactly as `write` does below. The rule that *does* live in a
 *   service is the one with nowhere else to go — `biometricSampleService`'s `from <= to` is on a query
 *   object, and a `.refine()` on a query object is deliberately not the shape of this Worker. Restating
 *   the heart-rate rule here would be a second definition of one rule, free to drift from the one the
 *   contract publishes.
 *
 * There is deliberately no `D1Database`, no `Request`/`Response`, no status code and no Zod import in
 * this file, which is what makes it exercisable against a fake port with no Worker and no database.
 */

/**
 * One profile's payload: the stored fields, less the one the request already determines.
 *
 * Derived from `UserProfile` rather than written out, so a field added to the entity is a compile
 * error here until it is accepted or explicitly excluded — the alternative is a new field that
 * silently never leaves the request body. **Only `userId` is dropped**, and unlike a sibling's input
 * type there is no `date` or `id` clause beside it: this resource has no path identity and no day, so
 * the partition is the only thing the request supplies that the body must not carry.
 */
export type UserProfileInput = Omit<UserProfile, "userId">;

export class UserProfileService {
  constructor(private readonly repository: UserProfileRepository) {}

  /**
   * The partition's profile, or `null` when it holds none.
   *
   * `null` rather than a fabricated record, and rather than a throw: whether an absent profile is a
   * 404 or a 200 with a body is an HTTP question and belongs to the route. This method answers the
   * only question it can — is there a row?
   *
   * **On this resource the `null` is not the same `null` as a sibling's, and the difference is a
   * client-visible one.** A day with no recovery row is a day nothing measured; a partition with no
   * profile row is a user who has not filled the form in. Both are absences and both are 404s, but the
   * app's answer to the second is a cold-start 190/60 pair rather than a dash, and that pair is
   * applied by the *client* at the moment it merges this absence with its local copy. Answering it
   * here would be inventing a measurement and calling it a row — see `UserProfileRepository`.
   */
  async read(userId: string): Promise<UserProfile | null> {
    return this.repository.find(userId);
  }

  /**
   * Write the partition's profile, and answer with the row as it is on disk.
   *
   * An upsert on the partition alone rather than an insert, because that is what the app's
   * `saveUserProfile` is: GRDB's `save` is INSERT-or-UPDATE over the whole record, so a `PUT` to a
   * partition that already holds a profile replaces it. **Whole-row is the load this method carries**,
   * and it is why every field is passed through exactly as it arrived: there is no `?? 0`, no
   * `?? null` and no default of any kind, so a `weightKg` sent as `null` clears the weight and one
   * that was omitted could not have arrived at all. A layer that filled a missing field in with a
   * previous value would be doing a partial update this resource does not have and no client could
   * see.
   *
   * The route has already refused a body carrying `id` or `userId`, and the schema has already
   * refused a reversed heart-rate pair — so there is nothing left for this method to check. That is
   * the short-ness argued at the head of this file rather than an omission here.
   */
  async write(userId: string, input: UserProfileInput): Promise<UserProfile> {
    return this.repository.upsert({ userId, ...input });
  }
}
