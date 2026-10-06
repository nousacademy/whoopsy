/**
 * Storage adapters — the only layer that knows D1 and R2 exist.
 *
 * Every `D1Database` statement and every `R2Bucket` call in this Worker belongs in a file under this
 * directory, so that "what does the schema look like" has one answer and a service can be tested
 * against a fake. Today that is `d1BiometricSampleRepository.ts`, `d1RecoveryRepository.ts`,
 * `d1ReceptiveInactivityRepository.ts`, `d1SleepRepository.ts`, `d1StepCountRepository.ts`,
 * `d1StrainRepository.ts`, `d1UserProfileRepository.ts` and `d1WorkoutRepository.ts`, which between
 * them are the only files in the Worker that name a table or a column.
 *
 * **What an adapter implements is one directory over, in `domain/`.** Each `d1<Resource>Repository`
 * satisfies a port declared there — `D1RecoveryRepository` implements `RecoveryRepository` — and the
 * entity it reads and writes is declared beside that port. This barrel therefore exports adapters and
 * nothing else: a caller that wants the `Recovery` shape asks `domain/`, and a route that wants to
 * build one asks here. That is what keeps a service exercisable against a fake port with no Worker
 * and no database, and it is the only reason the two halves are separate directories rather than two
 * files in one.
 *
 * **The local schema is the starting point, not the target.** `ios/Sources/Whoopsy/Data/Persistence/`
 * already has a migrated SQLite schema with its own conventions — `workouts` is keyed on `id`
 * because a day holds several, `recoveries`/`sleeps`/`strains` are keyed on `date` because a day
 * holds one, and the day key is `startOfDay` of a night's *wake* onset. A D1 table that renames any
 * of that puts a second convention on the same quantity, and the app's own docs record what that
 * costs. Read the root `CLAUDE.md`'s column-naming and day-key gotchas before writing the first
 * migration.
 */
export { D1BiometricSampleRepository } from "./d1BiometricSampleRepository";
export { D1RecoveryRepository } from "./d1RecoveryRepository";
export { D1ReceptiveInactivityRepository } from "./d1ReceptiveInactivityRepository";
export { D1SleepRepository } from "./d1SleepRepository";
export { D1StepCountRepository } from "./d1StepCountRepository";
export { D1StrainRepository } from "./d1StrainRepository";
export { D1UserProfileRepository } from "./d1UserProfileRepository";
export { D1WorkoutRepository } from "./d1WorkoutRepository";
