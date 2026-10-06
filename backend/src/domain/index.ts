/**
 * The domain — what each resource *is*, and what may be done with it.
 *
 * Two things live under this directory and nothing else does: an entity (`BiometricSample`,
 * `Recovery`, `ReceptiveInactivity`, `Sleep`, `StepCount`, `Strain`, `UserProfile`, `Workout`) and
 * the port that reads and writes it (`BiometricSampleRepository`, `RecoveryRepository`,
 * `SleepRepository`, …). That pairing is what makes the layer boundary statable in one sentence — **a
 * service depends on a shape and a port, never on a table** — and it is why every file here is
 * dependency-free: none of the eight carries a single `import`, so nothing in this directory can
 * reach a database, a `Request` or a `Response` even by accident.
 *
 * **The adapters are deliberately not here.** `d1<Resource>Repository.ts` lives in `repositories/`,
 * which is the only layer that knows D1 exists, and `dto/` holds the wire contract, which is the only
 * place Zod does. Each resource is therefore two files split across two directories — `recovery.ts`
 * here, `d1RecoveryRepository.ts` there — and that pair is the one to copy. A new resource means a
 * table, a port, an adapter and a migration; it does not mean a new pattern.
 *
 * **Why this directory has a barrel and `dto/` does not** is a property of the code rather than a
 * style choice: no two resources name an entity or a port the same thing, so re-exporting all eight
 * costs nothing, while four of the eight DTO files publish a symbol under the *same* name —
 * `WindowQuerySchema` — on purpose. See the note at the head of `dto/shared.ts`.
 *
 * **The constants below are re-exported and the rest are not**, which is the same test applied one
 * level down: `BIOMETRIC_SAMPLE_ID_PATTERN`, `HRV_METRICS`, `RECEPTIVE_INACTIVITY_ID_PATTERN`,
 * `USER_PROFILE_GENDERS`, `WORKOUT_ID_PATTERN` and `ZONE_COUNT` are values two layers have to agree
 * about — an id shape, a closed enum, the zone count — while a resource's caps and its window widths
 * belong to its service and stay there. Three of those six are id patterns and they are three
 * constants rather than one alias: each is the published constraint on one resource's ids. Two are
 * closed enums and they are likewise two: a gender and an HRV metric are different vocabularies that
 * happen to be shaped the same way.
 */
export { BIOMETRIC_SAMPLE_ID_PATTERN } from "./biometricSample";
export type { BiometricSample, BiometricSampleRepository } from "./biometricSample";
export { HRV_METRICS } from "./recovery";
export type { HrvMetric, Recovery, RecoveryRepository } from "./recovery";
export { RECEPTIVE_INACTIVITY_ID_PATTERN } from "./receptiveInactivity";
export type { ReceptiveInactivity, ReceptiveInactivityRepository } from "./receptiveInactivity";
export type { Sleep, SleepRepository } from "./sleep";
export type { StepCount, StepCountRepository } from "./stepCount";
export type { Strain, StrainRepository } from "./strain";
export { USER_PROFILE_GENDERS } from "./userProfile";
export type { UserProfile, UserProfileGender, UserProfileRepository } from "./userProfile";
export { WORKOUT_ID_PATTERN, ZONE_COUNT } from "./workout";
export type { Workout, WorkoutRepository, WorkoutRoutePoint, WorkoutSplit } from "./workout";
