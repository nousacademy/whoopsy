/**
 * Orchestration and policy.
 *
 * This is where the questions that are neither HTTP nor SQL get answered: what a device is allowed
 * to overwrite, whether a batch is a re-send or a new measurement, how a partial sync resolves. A
 * route must not decide these and a repository must not be asked. Today it holds the day-window
 * arithmetic and the absence decision for `recoveries`, `sleeps`, `stepCounts` and `strains`, the
 * aggregate's caps, ordering rule and duplicate check for `workouts`, — on
 * `receptiveInactivities` — the same window arithmetic with the duplicate check moved onto `id`, which
 * is the whole of what that resource adds to a sibling's policy and is deliberate: **a service that is
 * short is not a service that is unfinished**, and the file says so where a reader arriving from
 * `workoutService.ts` will look for the validator that is not there.
 *
 * **`userProfiles` is where that argument reaches its end: it is the one service here with no policy of
 * its own at all.** A profile is a singleton, so nothing is chunked — there is no batch and therefore
 * none of its three checks — and nothing is ranged, so there is no window to derive and neither of the
 * refusals a day-keyed service opens `readWindow` with has a counterpart. The one rule the resource
 * does publish — `restingHeartRate` strictly below `maxHeartRate` — is a rule about a *body*, which is
 * where this Worker puts those: it is stated on `UserProfileWriteSchema` and publishes itself in the
 * contract, exactly as `SleepWriteSchema`'s `endsAfterItStarts` does, rather than being restated in a
 * service as a second definition free to drift. What is left here is a method that attaches a
 * partition to a write and a method that forwards a read. **It is also the only resource whose refusal
 * type does not exist**, for the same reason: a class nothing can throw is a name in this barrel that
 * no code path can produce. That is `receptiveInactivities`' sentence one step further on — a service
 * that is short is not a service that is unfinished, and one that is empty of rules is short because
 * every rule it has found somewhere better to live.
 *
 * **`biometricSamples` is the one resource whose window is not a window of days**, and that single fact
 * is the whole of what its service does differently: it is handed two instants rather than a count and
 * an anchor, so it checks the *span* between them instead of deriving a lower bound, and it refuses a
 * reversed pair as well as an over-wide one. Its duplicate check is on `id` like the two above it, and
 * on this resource that check is the likeliest one to fire rather than the least — an id derived from
 * the arrival instant alone collides on two samples in the same millisecond, and a batch is exactly
 * where a burst of those arrives. It has no measurable-field rule and no share to sum: a sample is one
 * notification with no children, so the row cap **is** the work cap.
 *
 * Nothing here touches `Env`'s bindings directly — a service is handed repositories.
 *
 * A service takes day keys, numbers and plain objects, and gives back the same. It imports no Zod,
 * no `Request`/`Response` and no status code, which is what lets it be exercised against an
 * in-memory fake of its port with no Worker and no database in the room. A refusal travels out as an
 * `ApiRefusal` — a `RecoveryError`, a `SleepError`, a `StepCountError`, a `StrainError`, a
 * `WorkoutError`, a `ReceptiveInactivityError` or a `BiometricSampleError` — carrying the published
 * error code; turning that code into a status is the route's job and happens in one place there.
 * **`userProfiles` is the one resource with no name in that list**, which is not an omission: its
 * service refuses nothing, so a `UserProfileError` would be a class no code path could ever produce
 * and a reader would take for a live refusal.
 *
 * **The resources' caps are deliberately separate names, and the equality is what makes the rule
 * worth stating.** `MAX_BATCH_BIOMETRIC_SAMPLES`, `MAX_BATCH_ROWS`, `MAX_BATCH_RECEPTIVE_INACTIVITIES`,
 * `MAX_BATCH_SLEEPS`, `MAX_BATCH_STEP_COUNTS`, `MAX_BATCH_STRAINS` and `MAX_BATCH_WORKOUTS` are seven
 * constants that are all `200` today, and the four day-keyed windows are four constants that are all
 * `4000`. They stay separate because a recovery is one statement and a night is one statement while a
 * session is at least three before its children: the day one is retuned for cost, a shared constant
 * would move the others' published limits with it and nothing would say so. Two resources whose limits
 * happen to match are still two published limits — and the temptation grows with the count, since the
 * day-keyed four now share a port shape and a window size as well as a limit. Each of the seven names
 * the pair it is closest to; none of them is an alias. **`receptiveInactivities` is the one where that
 * argument has to be made rather than inherited**, because an entry is one row like a recovery — the
 * resource's own cap doc carries the corpus argument that keeps it a real number rather than a sixth
 * copy. **`biometricSamples` is the one where the inherited number is the wrong *shape***: its cap is
 * still `200` for the cost reason every sibling gives, but a day of its rows is up to 86,400, so the
 * same number means a three-minute chunk where a sibling's means a day's worth — and its window is
 * `MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS`, a **fifth** kind of constant, measured in seconds where the
 * other six windows are counted in days, because a day here is a row count rather than a row.
 *
 * **`userProfiles` adds no constant to either family, and that is the same fact stated from the caps'
 * side.** The seven caps and the five windows above stand as they are, because a singleton has no
 * batch to cap and no range to bound: there is no second row for a limit to be about, and no window
 * for a lower bound to be derived from. A `MAX_BATCH_USER_PROFILES` would be a published ceiling on an
 * endpoint that does not exist, which is worse than a missing constant — a client generator would draw
 * a batch writer from it.
 */
export {
  MAX_BATCH_BIOMETRIC_SAMPLES,
  MAX_BIOMETRIC_SAMPLE_WINDOW_SECONDS,
  BiometricSampleError,
  BiometricSampleService,
} from "./biometricSampleService";
export type { BiometricSampleBatchEntry, BiometricSampleInput } from "./biometricSampleService";
export { MAX_BATCH_ROWS, MAX_WINDOW_DAYS, RecoveryError, RecoveryService } from "./recoveryService";
export type { RecoveryBatchEntry, RecoveryInput } from "./recoveryService";
export {
  MAX_BATCH_RECEPTIVE_INACTIVITIES,
  ReceptiveInactivityError,
  ReceptiveInactivityService,
} from "./receptiveInactivityService";
export type {
  ReceptiveInactivityBatchEntry,
  ReceptiveInactivityInput,
} from "./receptiveInactivityService";
export { MAX_BATCH_SLEEPS, MAX_SLEEP_WINDOW_DAYS, SleepError, SleepService } from "./sleepService";
export type { SleepBatchEntry, SleepInput } from "./sleepService";
export {
  MAX_BATCH_STEP_COUNTS,
  MAX_STEP_COUNT_WINDOW_DAYS,
  StepCountError,
  StepCountService,
} from "./stepCountService";
export type { StepCountBatchEntry, StepCountInput } from "./stepCountService";
export {
  MAX_BATCH_STRAINS,
  MAX_STRAIN_WINDOW_DAYS,
  StrainError,
  StrainService,
} from "./strainService";
export type { StrainBatchEntry, StrainInput } from "./strainService";
export { UserProfileService } from "./userProfileService";
export type { UserProfileInput } from "./userProfileService";
export {
  MAX_BATCH_ROUTE_POINTS,
  MAX_BATCH_SPLITS,
  MAX_BATCH_WORKOUTS,
  MAX_ROUTE_POINTS,
  MAX_SPLITS,
  WorkoutError,
  WorkoutService,
} from "./workoutService";
export type { WorkoutBatchEntry, WorkoutInput } from "./workoutService";
