/**
 * A biometric sample, as a shape rather than a table.
 *
 * This file knows a *shape*, not a table: no SQL, no column name, no `D1Database`. The adapter behind
 * it (`d1BiometricSampleRepository.ts`) is the only file in the Worker that names a table or a
 * column, which is what lets a service be exercised against an in-memory fake of this interface with
 * no database in the room.
 *
 * **This is the finest-grained row in the Worker, and that is the whole of what makes it different
 * from its six siblings.** A recovery is a day, a workout is a session, and an inactivity is an
 * entry; a sample is one notification off the strap's heart-rate characteristic. A day of wear is up
 * to 86,400 of them, so nothing here may be counted in days: the window is an instant range, and the
 * batch cap is a chunk size rather than a day's worth.
 *
 * **The identity is client-derived, because the app has no identity for a sample that could travel.**
 * The phone's local row identity is an autoincrement `Int` assigned by that device's own SQLite, and
 * it does not reach the app's entity at all — `GRDBBiometricRepository.saveSamples` never writes it
 * and its `makeSample` never reads it, so every read mints a fresh identity. Two devices in one
 * partition would therefore both mint that integer from 1 and overwrite each other. The wire id is a
 * string the client derives instead, and the derivation is the producer's business rather than this
 * Worker's — what this shape requires of it is only that it be **deterministic**, so that re-sending
 * the same sample is an upsert rather than a second row. See
 * `migrations/0007_create_biometric_samples.sql`.
 *
 * **A channel the strap did not report is `null`, and every optional field here is that.** A
 * notification carries what it happened to carry: R-R intervals arrive only when the
 * characteristic's R-R bit is set, skin temperature and SpO₂ only when the optical engine produced an
 * estimate, a sequence number only on a frame that came off the flash. `null` is the absence and
 * there is no second spelling of it, which is why none of these fields is optional (`?`) — an absent
 * key and an explicit `null` would be two words for one answer, and a reader merging two sources
 * would have to test both.
 *
 * **`heartRate` is the one field that is always present**, because a sample exists only when the
 * decoder had a pulse to report. It is not a rounded figure and it may legitimately be `0`: a stored
 * zero is a reading the strap gave, which is why the contract bounds it at `nonnegative` rather than
 * `positive`.
 */

/**
 * The id shape the app can read back.
 *
 * Not decoration, and not a general-purpose UUID rule: the app's `BiometricSample.id` is a `UUID`, so
 * an id this Worker accepted but the app cannot parse is a row that is written, is returned by every
 * read here, and reaches no screen — an import that reports success and delivers nothing, which is
 * the failure `RECEPTIVE_INACTIVITY_ID_PATTERN` documents at length against the app's own reader.
 *
 * It is a **separate constant from that one and from `WORKOUT_ID_PATTERN`** rather than an alias,
 * even though the three regexes are identical today: each is the published constraint on one
 * resource's ids, and a client is told the rule for the resource it is writing. Two resources whose
 * id shapes happen to match are still two published rules, for the reason the six batch caps give.
 *
 * Any version and either case is accepted, because `UUID(uuidString:)` is: a v4 id and a v5 id are
 * both readable and a version nibble is not something either side has an opinion about.
 */
export const BIOMETRIC_SAMPLE_ID_PATTERN =
  /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

/** One notification off the strap: when it arrived, what the pulse was, and whatever else it carried. */
export interface BiometricSample {
  readonly userId: string;
  /** The sample's identity. A UUID string — see `BIOMETRIC_SAMPLE_ID_PATTERN`. */
  readonly id: string;
  /**
   * When the app heard the beats, in the canonical instant form.
   *
   * **An arrival instant and not a beat time**, which is the app's own documented caveat and is
   * inherited rather than fixed here: `WhoopBLEManager` stamps `Date()` when the notification is
   * decoded, so this is when the beats were heard and not when they happened. The two coincide at
   * the resolution a millisecond spelling can express, and they do not in the general case.
   */
  readonly timestamp: string;
  /** The pulse at this notification, in beats per minute. Always present; may legitimately be `0`. */
  readonly heartRate: number;
  /**
   * The beat-to-beat intervals **one notification** carried, in wire order, in milliseconds.
   *
   * A series rather than a single figure, because that is what the Heart Rate characteristic sends:
   * one notification may carry several R-R values and, *within* a notification, they are adjacent
   * beats by definition. Across notifications they are not, and nothing on this row distinguishes
   * the runs from one another — so a consumer differencing them must not difference across a
   * boundary, which is why the array is published whole rather than flattened.
   *
   * `null` is "this notification carried no intervals", and an empty array is not a second spelling
   * of it: the app's BLE layer collapses the empty case to `nil` on the way in, so a stored `[]`
   * would be a value no producer writes.
   */
  readonly rrIntervalsMs: readonly number[] | null;
  /**
   * The strap's three accelerometer axes in Gs, or `null` when the notification carried no motion.
   *
   * **Independently nullable, and deliberately not constrained to agree.** The strap sends the
   * triplet as one record, so in practice all three arrive together or none does — but "none" is
   * three `null`s and not a fourth flag, and a partial triplet is a storable fact rather than an
   * impossible one. The app has a defined reading for that case (its `accelerationMagnitude` is
   * `nil` unless every axis is present), so a rule refusing it here would reject a row the storage
   * holds. A `0.0` would be the one value that must never be substituted: free fall is physically
   * unreachable on a body and lands on the *still* side of every movement threshold.
   */
  readonly accelX: number | null;
  readonly accelY: number | null;
  readonly accelZ: number | null;
  /** Skin temperature in degrees Celsius, or `null` when the optical engine reported none. */
  readonly skinTemp: number | null;
  /** Blood-oxygen saturation as a percentage, or `null` when no estimate was produced. */
  readonly spo2Percentage: number | null;
  /**
   * Whether the strap was on a wrist, or `null` when it did not say.
   *
   * **The app's own mapper resolves this absence to `true` on read, and that default is not copied
   * here.** `true` and `false` are opposite measurements of a question nobody answered, and a
   * defaulted `true` would put "worn" on a row the strap never described.
   */
  readonly isOnBody: boolean | null;
  /** Whether the strap was charging, or `null` when it did not say. Defaulting to `false` is the same fabrication. */
  readonly isCharging: boolean | null;
  /**
   * The frame's own sequence number, or `null` for a frame that did not carry one.
   *
   * A narrow integer — the app types it `UInt32` — so the contract bounds it rather than letting a
   * number that no producer can emit be stored.
   */
  readonly rawSequenceNumber: number | null;
}

/**
 * The storage the service is written against.
 *
 * Four methods and deliberately not five: there is no `delete`. That is the Worker's standing shape
 * rather than an omission on this resource — no endpoint here deletes anything, because the only
 * destructive control in the app is on the device and this API is the sync.
 *
 * **`listWindow` takes two instants, and that is the shape this port does not share with its
 * siblings.** The other six resources read a range of day keys and count their windows in days; here
 * a day is up to 86,400 rows, so a day-counted window would be a read nothing should ask for. The
 * app's own port is `getSamples(from:to:)` — both bounds from the caller — and this mirrors it
 * rather than defaulting an upper bound, because a defaulted one would be the server's clock rather
 * than the caller's own question.
 *
 * **The ordering is `timestamp ASC, id ASC`, and the second clause is a tiebreak rather than a
 * reproduction of arrival order.** The app orders `timestamp ASC, id ASC` too, but its `id` *is*
 * arrival order (a local autoincrement) while this one is content-derived and therefore arbitrary.
 * So the primary order is preserved exactly and two samples sharing a millisecond have a stable
 * order here without having their original one — which a client must not read as meaning anything.
 */
export interface BiometricSampleRepository {
  /** One sample, or `null` when the partition holds no such id. */
  findById(userId: string, id: string): Promise<BiometricSample | null>;
  /**
   * Samples whose instant falls in `from`…`to` inclusive, oldest first.
   *
   * Ordered by `timestamp`, then `id` — see the tiebreak note above. The bounds are inclusive at
   * both ends, matching the app's own read; a chunked sync overlapping at a single millisecond
   * therefore re-sends that sample, which is an upsert of an identical row and not a duplicate.
   */
  listWindow(userId: string, from: string, to: string): Promise<BiometricSample[]>;
  /**
   * Write one sample, answering what is now stored.
   *
   * INSERT-or-UPDATE by `(user_id, id)`, mirroring GRDB's `save`: a re-sent sample is a new statement
   * of the same sample, not a duplicate row. There are no children to replace, which is the whole of
   * how this upsert differs from the aggregate's.
   */
  upsert(sample: BiometricSample): Promise<BiometricSample>;
  /**
   * Write many samples as one unit, answering **how many samples** were written.
   *
   * Not how many rows: a sample is one row here, so on this resource the two agree — but the port
   * says *samples* because that is the quantity `POST /batch` publishes, and a caller must not have
   * to know that this resource's arithmetic happens to be the identity.
   */
  upsertMany(samples: readonly BiometricSample[]): Promise<number>;
}
