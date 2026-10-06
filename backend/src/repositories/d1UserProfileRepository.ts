import type { Env } from "../env";
import { USER_PROFILE_GENDERS } from "../domain";
import type { UserProfile, UserProfileGender, UserProfileRepository } from "../domain";

/**
 * The D1 adapter for `user_profiles`.
 *
 * **The only file in this Worker that names this table or its columns**, and on this resource that
 * matters for the reason `d1StrainRepository.ts` states rather than by inheritance: the app's local
 * table has the **same name** and a **different naming convention**. `UserProfileRecord` declares no
 * `CodingKeys`, so its property names *are* its column names and the phone's columns are camelCase —
 * `maxHeartRate`, `weightKg`, `birthDate`, `heightCm` — while the D1 table created by
 * `0008_create_user_profiles.sql` is snake_case. A reader who copies a name from one side to the other
 * writes a query against a column that does not exist, and `strains` is the only other resource here
 * where that is true.
 *
 * **There is no `id` column and therefore no `id` line in the mapper.** That is the migration's
 * decision restated where a reader will look for it: the phone keys this row with the literal
 * `"primary"`, which is a local-storage constant with no meaning on this side, so the partition is the
 * whole identity — `PRIMARY KEY (user_id)` — and neither `UserProfileRow` below nor the `UserProfile`
 * it maps to has a field for one. A reader arriving from the app's `UserProfileRecord` will find its
 * `id` missing here and should not add it back.
 *
 * **No `?? null` and no `?? 0` anywhere, and on this table that is most of the file.** Five of the
 * seven stored columns are nullable and every one of them is a fact the user either supplied or did
 * not, so `NULL` has to arrive at the domain as `null` — a defensive default here would turn "the user
 * has not told us their weight" into a number the calorie estimate divides into. That is the same rule
 * `d1StrainRepository.ts` states for `source`, applied to five columns rather than one.
 */

/**
 * A row exactly as D1 hands it back — snake_case, five columns nullable, `gender` an unparsed string.
 *
 * Spelled out rather than derived from `UserProfile` so the compiler holds both ends of the mapping:
 * adding a property to the entity without adding it here is a type error in `toUserProfile`, which is
 * the one place a new column can be forgotten. `gender` is deliberately `string | null` rather than
 * `UserProfileGender | null` — the column holds whatever was written, and narrowing it to the closed
 * vocabulary is `parseGender`'s job rather than a claim this interface can make about bytes.
 */
interface UserProfileRow {
  readonly user_id: string;
  readonly max_heart_rate: number;
  readonly resting_heart_rate: number;
  readonly weight_kg: number | null;
  readonly name: string | null;
  readonly birth_date: string | null;
  readonly gender: string | null;
  readonly height_cm: number | null;
}

/**
 * The columns, named once because two statements select them and a `SELECT *` would make the mapper's
 * contract depend on the table's column order — which a later `ALTER TABLE` is free to change without
 * any file here mentioning it.
 */
const COLUMNS = [
  "user_id",
  "max_heart_rate",
  "resting_heart_rate",
  "weight_kg",
  "name",
  "birth_date",
  "gender",
  "height_cm",
].join(", ");

/**
 * Map a row to the domain type.
 *
 * `gender` goes through `parseGender` rather than a cast, and every other field is a straight copy —
 * including the four that are nullable, which pass `null` through untouched rather than being resolved
 * to a default. `birth_date` is a `YYYY-MM-DD` string on both sides: it is `TEXT` in the schema
 * precisely so no date function has to touch it, and the conversion to a `Date` is the client's.
 */
function toUserProfile(row: UserProfileRow): UserProfile {
  return {
    userId: row.user_id,
    maxHeartRate: row.max_heart_rate,
    restingHeartRate: row.resting_heart_rate,
    weightKg: row.weight_kg,
    name: row.name,
    birthDate: row.birth_date,
    gender: parseGender(row.gender),
    heightCm: row.height_cm,
  };
}

/**
 * A gender word read back as one of the four the API publishes, `null` passed through, or a throw
 * naming the value.
 *
 * Modelled on `parseHrvMetric`'s temperament rather than on the app's, and the two differ deliberately
 * on exactly one case. The app's `GRDBUserProfileRepository` resolves an unrecognised word to `nil`,
 * because on the phone that word can only have come from a build of the app that knew a vocabulary
 * this one does not — and dropping a fact it cannot name is the lesser failure there. Here a value
 * outside the set means the boundary was bypassed, in one of two ways: a hand-run `UPDATE`, or a row
 * written by a *newer* deploy whose vocabulary has a fifth word and read back by this one after a
 * rollback. **`null` would be the wrong answer to both**, because it is the word this API uses for
 * "the user did not say" — so a throw is what keeps the absent answer from standing in for an answer
 * this build cannot read. `parseHasMeasurement`'s argument, on a column with more than two values.
 *
 * **There is no `CHECK` constraint behind this**, unlike `strains.has_measurement`, and the asymmetry
 * is the schema's decision rather than an omission: a `CHECK (gender IN (…))` would freeze a
 * vocabulary that is expected to be able to grow into a migration file that is frozen once shipped, so
 * a fifth word would need a new migration where the `z.enum` in `dto/userProfiles.ts` needs only a
 * deploy. The set is published at the boundary, which is where a client can be told about it; this
 * function is the read side of the same rule and reads `USER_PROFILE_GENDERS` rather than restating
 * the four words.
 */
function parseGender(value: string | null): UserProfileGender | null {
  if (value === null) {
    return null;
  }

  const known = USER_PROFILE_GENDERS.find((gender) => gender === value);
  if (known === undefined) {
    throw new Error(
      `user_profiles.gender holds ${JSON.stringify(value)}, which is not a known gender`,
    );
  }
  return known;
}

/**
 * `ON CONFLICT (user_id)` and not `(user_id, id)`, because the partition is the whole key.
 *
 * `user_id` appears in the column list and not in the `DO UPDATE SET` list, which is the one
 * structural difference from every sibling's upsert: on a collection the conflict target names at
 * least one column that is also a value being written (`date`, `id`), while here it names the
 * ownership column alone, which is never updated because a write cannot move a row between
 * partitions.
 */
const UPSERT = `
  INSERT INTO user_profiles (${COLUMNS})
  VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT (user_id) DO UPDATE SET
    max_heart_rate      = excluded.max_heart_rate,
    resting_heart_rate  = excluded.resting_heart_rate,
    weight_kg           = excluded.weight_kg,
    name                = excluded.name,
    birth_date          = excluded.birth_date,
    gender              = excluded.gender,
    height_cm           = excluded.height_cm
`;

const SELECT_PROFILE = `SELECT ${COLUMNS} FROM user_profiles WHERE user_id = ?`;

export class D1UserProfileRepository implements UserProfileRepository {
  constructor(private readonly db: D1Database) {}

  /** Construct from the Worker's bindings. The composition root's one line of wiring. */
  static from(env: Env): D1UserProfileRepository {
    return new D1UserProfileRepository(env.DB);
  }

  async find(userId: string): Promise<UserProfile | null> {
    const row = await this.db.prepare(SELECT_PROFILE).bind(userId).first<UserProfileRow>();

    // `null`, never a fabricated profile. This is the one resource where a sibling client hardcodes a
    // value for this case -- the app's own repository answers a cold-start 190/60 -- and the reason
    // this file does not is argued on `UserProfileRepository`: that pair is the client's tolerance for
    // a zone table it cannot build, applied at the moment it merges a remote absence with its local
    // copy. A server that published it would be inventing a measurement and calling it a row.
    return row === null ? null : toUserProfile(row);
  }

  async upsert(profile: UserProfile): Promise<UserProfile> {
    // One statement, one write. There is no `upsertMany` beside this and no batch endpoint above it:
    // a partition holds one profile, so there is nothing to chunk, and a list of one would be a
    // concurrency question this resource does not have.
    await this.db.prepare(UPSERT).bind(...bindings(profile)).run();

    // Read back rather than `RETURNING`, on `d1StrainRepository.ts`'s argument and with more riding on
    // it here. The semantics are identical and it is still exactly one write; what it buys is that the
    // answer is provably what is on disk rather than what was sent -- and on a whole-row write over
    // five nullable columns, "the `null` I sent is the `null` stored" is the entire contract. A
    // `null` that came back as a `0` would mean a form's cleared field had been silently filled in.
    const stored = await this.find(profile.userId);
    if (stored === null) {
      throw new Error(`user_profiles upsert for one partition reported success but the row is absent`);
    }
    return stored;
  }
}

/**
 * Positional bindings, in `COLUMNS` order.
 *
 * A function rather than an inline array so the order is stated once: the `INSERT`'s column list and
 * this list are the same eight names, and a mismatch is a value written into the wrong column — which
 * SQLite will accept whenever the types happen to line up, and which nothing downstream can detect.
 * On this table that is a live risk rather than a theoretical one, because `max_heart_rate` and
 * `resting_heart_rate` are adjacent and both integers: swapping them writes a plausible profile whose
 * zone table is silently reversed.
 */
function bindings(profile: UserProfile): (string | number | null)[] {
  return [
    profile.userId,
    profile.maxHeartRate,
    profile.restingHeartRate,
    profile.weightKg,
    profile.name,
    profile.birthDate,
    profile.gender,
    profile.heightCm,
  ];
}
