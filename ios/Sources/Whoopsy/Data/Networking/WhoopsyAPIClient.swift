import Foundation

/// The app's first and only `URLSession`, and the lowest layer that knows the API exists.
///
/// **Nothing above `HTTPCloudSync` sees this type.** It speaks `RecoveryDTO` — the wire's spelling of a
/// day — while every layer above speaks `RecoverySyncRow`, whose names are the *record's*. That split is
/// what lets the whole sync be tested with no socket at all: the mapper converts between the two shapes
/// as a pure value, and this file is the only place a byte ever moves.
///
/// **It is a `struct` that builds its encoder and decoder per call rather than storing them.** Both are
/// reference types with mutable configuration and neither is `Sendable`, so holding one on a type that
/// crosses actors is a concurrency question with no upside: a full history is a few dozen requests even
/// across all seven resources, and a fresh `JSONEncoder` costs nothing at that volume. Cheap and
/// obviously-correct beats cached and arguable.
///
/// **The day in a path is the caller's, already formatted.** This type does no calendar arithmetic — it
/// takes a `YYYY-MM-DD` string, because building one is the mapper's job and getting it wrong files
/// every day one early in a way nothing on screen shows. See `RecoveryWireMapper.dayKey(for:in:)`.
public struct WhoopsyAPIClient: Sendable {

    /// The header that selects **which partition** a request is about.
    ///
    /// **It is a partition name and not a credential, and the difference is the thing to hold on to.**
    /// The server hashes this value and never stores it, and it verifies nothing about it: anyone can
    /// mint a key and get a partition of their own, and a key someone guesses is a partition someone
    /// can read. That is why the key is 32 random bytes rather than anything derived from the device.
    /// What the header does **not** do is earn the right to read that partition — `authorizationToken`
    /// below is what the Worker checks first, and this header is not looked at until it has passed.
    public static let userIDHeader = "X-Whoopsy-User-Id"

    /// The `Info.plist` key the base URL is read from.
    ///
    /// It is a key rather than a constant in this file so that the dev server's address — which is
    /// `http://localhost:8787` and therefore blocked by ATS by default — is a build-level decision, and
    /// so a clone that has not configured one gets no client at all rather than one pointed at a host
    /// that does not exist.
    public static let baseURLInfoKey = "WHOOPSYAPIBaseURL"

    /// The `Info.plist` key the shared deployment secret is read from.
    ///
    /// **A second key rather than a second meaning for the first**, because the two answer different
    /// questions and either can be present without the other: the base URL says *where* the database
    /// is, this says *what to present* when asking. A build holding the address and not the secret is
    /// not half-configured in an interesting way — the Worker refuses every `/v1` request without a
    /// credential — so it is an install that opens a socket on every read to collect a `401`, which is
    /// why `DIContainer` treats the pair as one decision and wires the offline stub when either is
    /// missing.
    public static let tokenInfoKey = "WHOOPSYAPIToken"

    private let baseURL: URL
    private let token: String
    private let keyStore: any SyncKeyStore
    private let session: URLSession

    /// - Parameter keyStore: **the store rather than the key, and that is a constraint rather than a
    ///   preference.** `SyncKeyStore` is an actor whose one door is `async`, while `DIContainer.init` —
    ///   the only place this client is built — is synchronous, because a `DIContainer` is constructed
    ///   inside a `View`'s `init` and cannot await anything. Handing this type a `String` would therefore
    ///   mean reading the Keychain outside the actor that exists to make the read-or-mint single-flight,
    ///   which is precisely the race `SyncKeyStore`'s own doc comment forbids. Holding the store and
    ///   asking it per request costs one cached `String` return for the life of the process — the actor
    ///   caches after its first call — and it keeps the key from ever being a value copied onto a type
    ///   that crosses actors.
    /// - Parameter token: **a `String`, where the identity key above is a store — and the two looking
    ///   alike is exactly why this is worth stating.** The identity key is *minted* on first read and
    ///   kept in the Keychain, so it has to be asked for behind an actor that makes read-or-mint
    ///   single-flight. This is a constant of the build: expanded into `Info.plist` at compile time
    ///   from the gitignored `Whoopsy.local.xcconfig`, the same value on every request, and never
    ///   written down by the app. There is nothing to mint, nothing to persist and no race to close, so
    ///   a plain value is the whole of it — and it is **required rather than defaulted**, so a caller
    ///   cannot build a client that would send no credential. The failure that produces is a `401` on
    ///   every read with nothing at the call site to suggest why; `DIContainer` is the only caller and
    ///   it holds both halves.
    public init(baseURL: URL, token: String, keyStore: any SyncKeyStore, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.keyStore = keyStore
        self.session = session
    }

    /// The base URL this build was configured with, or `nil` when it was configured with none.
    ///
    /// `nil` is an ordinary answer and not an error: a clone that has never set the key is a build with
    /// no database behind it, which is the state every build was in until this feature existed. What a
    /// caller does about it is a policy question — `DIContainer` answers it by wiring the offline stub —
    /// and answering it here would put that policy in the transport.
    public static func configuredBaseURL(bundle: Bundle = .main) -> URL? {
        guard let raw = bundle.object(forInfoDictionaryKey: baseURLInfoKey) as? String,
              !raw.trimmingCharacters(in: .whitespaces).isEmpty,
              let url = URL(string: raw)
        else { return nil }
        return url
    }

    /// The shared secret this build was configured with, or `nil` when it was configured with none.
    ///
    /// **The same `nil`-for-missing-and-whitespace rule as above, and here it is doing more work.** An
    /// xcconfig line left empty expands to an empty `Info.plist` string rather than to a missing key,
    /// so a build with no credential and a build with a blank one are the same build — and both must
    /// read as *unconfigured* rather than as *configured with the empty string*, which would send
    /// `Authorization: Bearer ` and collect a `401` on every request.
    ///
    /// The value is **trimmed and the trimmed copy is what a caller gets.** Whitespace around an
    /// xcconfig assignment is not part of the secret, and a token compared with a trailing space
    /// against the deployment's own is a mismatch nothing on any screen explains.
    public static func configuredToken(bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: tokenInfoKey) as? String else { return nil }
        let token = raw.trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    // MARK: - The four calls

    /// One day, or `nil` when the database holds no row for it.
    ///
    /// **A `404` is the absence, not a failure.** The server answers `no_measurement_for_day` for a day
    /// it has nothing for, and that is the same statement this app makes by having no row — so it is
    /// translated here into `nil` rather than thrown, and every caller above deals in one spelling of
    /// absence instead of two. Any *other* refusal is a real one and propagates.
    public func recovery(onDay day: String) async throws -> RecoveryDTO? {
        let (data, response) = try await perform(try await makeRequest(method: "GET", path: "v1/recoveries/\(day)"))

        if response.statusCode == 404, let refusal = try? decodeRefusal(from: data),
           refusal.error.code == "no_measurement_for_day" {
            return nil
        }
        try check(response, data)
        return try decode(RecoveryDTO.self, from: data)
    }

    /// Every day the database holds in the window, ascending.
    ///
    /// An empty array is a real answer and not an error — a window over days nothing measured is the
    /// common case for a new user, and the app's own absence rule says the same thing.
    public func recoveries(in window: RecoveryWindow) async throws -> [RecoveryDTO] {
        let request = try await makeRequest(
            method: "GET",
            path: "v1/recoveries",
            query: [
                URLQueryItem(name: "days", value: String(window.days)),
                URLQueryItem(name: "endingOn", value: window.endingOn),
            ]
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode([RecoveryDTO].self, from: data)
    }

    /// Write one day, replacing whatever the database holds for it.
    ///
    /// **The body carries no `date`, and that is the schema's rule rather than a simplification.** The
    /// day is in the path, `RecoveryWriteSchema` is `.strict()`, and a body carrying a `date` key is a
    /// `400` — which is why this call takes the eight fields through `RecoveryWriteDTO` while the batch
    /// below takes all nine through `RecoveryDTO`. One API, two payload shapes, and the difference
    /// between them is exactly where the day is written down.
    ///
    /// The server's answer is the stored row and it is decoded rather than discarded: a `200` carrying
    /// something this client cannot read is a contract mismatch, and the only place it can be caught is
    /// here. `@discardableResult` because the port above has no use for the echo — its own caller is a
    /// save that has already decided what it wrote.
    @discardableResult
    public func writeRecovery(_ row: RecoveryDTO) async throws -> RecoveryDTO {
        let request = try await makeRequest(
            method: "PUT",
            path: "v1/recoveries/\(row.date)",
            body: try encode(RecoveryWriteDTO(row))
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode(RecoveryDTO.self, from: data)
    }

    /// Write many days at once and report how many the database says it wrote.
    ///
    /// **An empty batch is not sent.** The schema requires at least one row, so a request carrying none
    /// could only ever be a `400` — and a caller that has already filtered its rows down to nothing has
    /// nothing to ask. It answers `0` without opening a socket, which is the honest number for *nothing
    /// was written*.
    ///
    /// The count is the database's own tally of changed rows, passed through untouched. It is
    /// deliberately **not** `rows.count`: a replayed chunk reports the same number as the first send
    /// rather than zero, and a caller reading `0` as *there was nothing to do* would be reading the
    /// wrong field.
    public func writeRecoveries(_ rows: [RecoveryDTO]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }

        let request = try await makeRequest(
            method: "POST",
            path: "v1/recoveries/batch",
            body: try encode(RecoveryBatchBody(rows: rows))
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode(RecoveryBatchResult.self, from: data).written
    }

    // MARK: - The four strains calls

    /// One day, or `nil` when the database holds no row for it.
    ///
    /// **The code read here is the recoveries one and the answer it produces is not the same shape.**
    /// The server answers `no_measurement_for_day` for a day with no row at all, exactly as its sibling
    /// does, and that is translated to `nil` — one spelling of absence for both day-keyed resources,
    /// merged above by one comparison.
    ///
    /// **A `200` is a row even when it carries `hasMeasurement: false`, and that is this resource's whole
    /// divergence from `recoveries`.** An unmeasured strain is a row the app stores and the server
    /// stores, told apart from a reading by that flag; the `404` is reserved for a day with no row at
    /// all. This function therefore must not look at the flag — reading it as an absence would report a
    /// day the database holds as a day this app has never heard of, which is a different fact and a
    /// wrong one. `kilojoules == 0` beside `hasMeasurement == true` is a measured reading of no work
    /// done and lands on the ordinary path for the same reason.
    ///
    /// Any *other* refusal is a real one and propagates.
    public func strain(onDay day: String) async throws -> StrainDTO? {
        let (data, response) = try await perform(try await makeRequest(method: "GET", path: "v1/strains/\(day)"))

        if response.statusCode == 404, let refusal = try? decodeRefusal(from: data),
           refusal.error.code == "no_measurement_for_day" {
            return nil
        }
        try check(response, data)
        return try decode(StrainDTO.self, from: data)
    }

    /// Every day the database holds in the window, ascending.
    ///
    /// An empty array is a real answer and not an error — a window over days nothing measured is the
    /// common case for a new user, and this app's own absence rule says the same thing.
    public func strains(in window: StrainWindow) async throws -> [StrainDTO] {
        let request = try await makeRequest(
            method: "GET",
            path: "v1/strains",
            query: [
                URLQueryItem(name: "days", value: String(window.days)),
                URLQueryItem(name: "endingOn", value: window.endingOn),
            ]
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode([StrainDTO].self, from: data)
    }

    /// Write one day, replacing whatever the database holds for it.
    ///
    /// **The body carries no `date`**, on `writeRecovery(_:)`'s argument and for its reason: the day is
    /// in the path, `StrainWriteSchema` is `.strict()`, and the six stored fields go through
    /// `StrainWriteDTO` while a batch row carries all seven through `StrainDTO`.
    ///
    /// The server's answer is the stored row and it is decoded rather than discarded: a `200` carrying
    /// something this client cannot read is a contract mismatch, and the only place it can be caught is
    /// here. `@discardableResult` because the port above has no use for the echo — its own caller is a
    /// save that has already decided what it wrote.
    @discardableResult
    public func writeStrain(_ row: StrainDTO) async throws -> StrainDTO {
        let request = try await makeRequest(
            method: "PUT",
            path: "v1/strains/\(row.date)",
            body: try encode(StrainWriteDTO(row))
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode(StrainDTO.self, from: data)
    }

    /// Write many days at once and report how many the database says it wrote.
    ///
    /// **An empty batch is not sent**, on `writeRecoveries(_:)`'s argument: the schema requires at least
    /// one row, so a request carrying none could only ever be a `400`. It answers `0` without opening a
    /// socket, which is the honest number for *nothing was written*.
    ///
    /// The count is the database's own tally of changed rows, passed through untouched and deliberately
    /// **not** `rows.count`: a replayed chunk reports the same number as the first send rather than zero,
    /// and a caller reading `0` as *there was nothing to do* would be reading the wrong field.
    public func writeStrains(_ rows: [StrainDTO]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }

        let request = try await makeRequest(
            method: "POST",
            path: "v1/strains/batch",
            body: try encode(StrainBatchBody(rows: rows))
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode(StrainBatchResult.self, from: data).written
    }

    // MARK: - The four workouts calls

    /// One session and its children, or `nil` when the partition holds no such id.
    ///
    /// **A `404` is the absence, not a failure — and the code it is read by is not the recoveries
    /// one.** The sibling answers `no_measurement_for_day`, which names a *day* that has no reading;
    /// this resource answers `not_found`, which names an *id* the partition does not hold. The two are
    /// different sentences because the absences are different shapes: a day either has a reading or it
    /// does not, while a session id is either known here or it is not, and a client that matched the
    /// sibling's code would fall through to `check` and throw on the ordinary case of asking about an
    /// id this partition has never seen.
    public func workout(id: String) async throws -> WorkoutDTO? {
        let (data, response) = try await perform(try await makeRequest(method: "GET", path: "v1/workouts/\(id)"))

        if response.statusCode == 404, let refusal = try? decodeRefusal(from: data),
           refusal.error.code == "not_found" {
            return nil
        }
        try check(response, data)
        return try decode(WorkoutDTO.self, from: data)
    }

    /// Every session filed on a day in the window, oldest first, each with its children.
    ///
    /// **An empty array is a real answer and not an error**, exactly as `recoveries(in:)`'s is — and
    /// here it is the answer to two different situations this client cannot tell apart: a window whose
    /// days hold no session, and a window whose days hold no *reading*. The server pads nothing, so a
    /// day inside the window with no session is simply absent from the array, and a caller wanting to
    /// know which days were covered has to ask the calendar rather than the length.
    ///
    /// The children come back attached, which is the whole reason a session is one request rather than
    /// three: a route has no identity outside the session that owns it, so there is no `/v1/routes/{id}`
    /// to fetch and no second round trip to make.
    public func workouts(in window: WorkoutWindow) async throws -> [WorkoutDTO] {
        let request = try await makeRequest(
            method: "GET",
            path: "v1/workouts",
            query: [
                URLQueryItem(name: "days", value: String(window.days)),
                URLQueryItem(name: "endingOn", value: window.endingOn),
            ]
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode([WorkoutDTO].self, from: data)
    }

    /// Write one session, replacing it and **both of its child tables**.
    ///
    /// **A write is a replacement rather than a merge, and the children are what that costs.** The
    /// server deletes a stored route and a stored split list and re-inserts whatever this body carried,
    /// so an empty `route` is an affirmative claim that the session has none — which is why
    /// `WorkoutDTO`'s two arrays are non-optional and never defaulted. A body that could leave them out
    /// would delete a path the user recorded rather than leaving it alone.
    ///
    /// **The body carries no `id`, for the recoveries' reason moved from the day to the session.** The
    /// id is in the path, `WorkoutWriteSchema` is `.strict()`, and a body carrying an `id` key is a
    /// `400` — which is why this takes the thirteen fields through `WorkoutWriteDTO` while the batch
    /// below takes all fourteen through `WorkoutDTO`.
    ///
    /// **`date` *is* in the body, and that is not the same kind of exception.** A recovery's day is in
    /// the path and nowhere else; a session's day is not derivable from its id and not derivable by the
    /// server from `startedAt` either, because it is `startOfDay(startedAt)` in *this device's*
    /// calendar. So it is carried, and `WorkoutWireMapper` is where it is computed.
    @discardableResult
    public func writeWorkout(_ row: WorkoutDTO) async throws -> WorkoutDTO {
        let request = try await makeRequest(
            method: "PUT",
            path: "v1/workouts/\(row.id)",
            body: try encode(WorkoutWriteDTO(row))
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode(WorkoutDTO.self, from: data)
    }

    /// Write many sessions at once and report how many the database says it wrote.
    ///
    /// **An empty batch is not sent**, on `writeRecoveries(_:)`'s argument: the schema requires at
    /// least one row, so a request carrying none could only ever be a `400`. It answers `0` without
    /// opening a socket.
    ///
    /// **The count is sessions, not rows.** A session with a two-thousand-point route touches two
    /// thousand and three rows in the server's batch, and the server sums only the parent upserts — so
    /// the number that comes back is a function of how many sessions were written and not of how much
    /// GPS a run collected. It is passed through untouched and deliberately **not** compared against
    /// `rows.count`: a replayed chunk reports the same number as the first send rather than zero, and a
    /// caller reading `0` as *there was nothing to do* would be reading the wrong field.
    ///
    /// **A batch that exceeds the aggregate child caps is a `400` naming the total rather than the
    /// session**, which is why the caller has to chunk on the totals and not on the session count —
    /// two hundred sessions with no routes fit easily; two hundred long ones do not.
    public func writeWorkouts(_ rows: [WorkoutDTO]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }

        let request = try await makeRequest(
            method: "POST",
            path: "v1/workouts/batch",
            body: try encode(WorkoutBatchBody(rows: rows))
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode(WorkoutBatchResult.self, from: data).written
    }

    // MARK: - The four sleeps calls

    /// Write one night, replacing whatever the database holds for its day.
    ///
    /// **The body carries no `date`**, on `writeRecovery(_:)`'s argument and for its reason: the day is
    /// in the path, `SleepWriteSchema` is `.strict()`, and the fourteen remaining fields go through
    /// `SleepWriteDTO` while a batch row carries all fifteen through `SleepDTO`.
    ///
    /// **The day in the path is the night's wake day**, which the schema states in as many words is not
    /// derived from `startTime`. Nothing here checks that — a caller holding the row is holding the
    /// answer, and this type does no calendar arithmetic.
    ///
    /// The answer is the stored row and it is decoded rather than discarded, so a `200` carrying
    /// something this client cannot read is caught here rather than passing as a success.
    /// `@discardableResult` because the port above has no use for the echo.
    @discardableResult
    public func writeSleep(_ row: SleepDTO) async throws -> SleepDTO {
        let request = try await makeRequest(
            method: "PUT",
            path: "v1/sleeps/\(row.date)",
            body: try encode(SleepWriteDTO(row))
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode(SleepDTO.self, from: data)
    }

    /// Write many nights at once and report how many the database says it wrote.
    ///
    /// **An empty batch is not sent**, on `writeRecoveries(_:)`'s argument: the schema requires at least
    /// one row, so a request carrying none could only ever be a `400`. It answers `0` without opening a
    /// socket, which is the honest number for *nothing was written*.
    ///
    /// The count is the database's own tally of changed rows, passed through untouched and deliberately
    /// **not** `rows.count` — a replayed chunk reports the same number as the first send rather than
    /// zero, and a caller reading `0` as *there was nothing to do* would be reading the wrong field.
    public func writeSleeps(_ rows: [SleepDTO]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }

        let request = try await makeRequest(
            method: "POST",
            path: "v1/sleeps/batch",
            body: try encode(SleepBatchBody(rows: rows))
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode(SleepBatchResult.self, from: data).written
    }

    // MARK: - The four step-count calls

    /// Write one day, replacing whatever the database holds for it.
    ///
    /// **The body carries no `date`**, on `writeRecovery(_:)`'s argument: the day is in the path,
    /// `StepCountWriteSchema` is `.strict()`, and the two remaining fields go through
    /// `StepCountWriteDTO` while a batch row carries all three through `StepCountDTO`.
    ///
    /// The answer is the stored row and it is decoded rather than discarded, so a `200` carrying
    /// something this client cannot read is caught here. `@discardableResult` for `writeSleep`'s reason.
    @discardableResult
    public func writeStepCount(_ row: StepCountDTO) async throws -> StepCountDTO {
        let request = try await makeRequest(
            method: "PUT",
            path: "v1/step-counts/\(row.date)",
            body: try encode(StepCountWriteDTO(row))
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode(StepCountDTO.self, from: data)
    }

    /// Write many days at once and report how many the database says it wrote.
    ///
    /// An empty batch is not sent, on `writeRecoveries(_:)`'s argument, and the count is the database's
    /// own tally rather than `rows.count`, for the same reason.
    public func writeStepCounts(_ rows: [StepCountDTO]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }

        let request = try await makeRequest(
            method: "POST",
            path: "v1/step-counts/batch",
            body: try encode(StepCountBatchBody(rows: rows))
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode(StepCountBatchResult.self, from: data).written
    }

    // MARK: - The four receptive-inactivity calls

    /// Write one entry, replacing whatever the database holds under its id.
    ///
    /// **The id in the path is the entry's own and not a day**, which is what separates this resource
    /// from its two day-keyed siblings above: `PUT /v1/receptive-inactivities/{id}` addresses an entry,
    /// and the day it is filed on rides in the body because the server cannot derive it. So
    /// `ReceptiveInactivityWriteDTO` drops the `id` and keeps the `date`, where `SleepWriteDTO` does the
    /// opposite.
    ///
    /// The answer is the stored row and it is decoded rather than discarded. `@discardableResult` for
    /// `writeSleep`'s reason.
    @discardableResult
    public func writeReceptiveInactivity(_ row: ReceptiveInactivityDTO) async throws -> ReceptiveInactivityDTO {
        let request = try await makeRequest(
            method: "PUT",
            path: "v1/receptive-inactivities/\(row.id)",
            body: try encode(ReceptiveInactivityWriteDTO(row))
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode(ReceptiveInactivityDTO.self, from: data)
    }

    /// Write many entries at once and report how many the database says it wrote.
    ///
    /// An empty batch is not sent, on `writeRecoveries(_:)`'s argument. **The cap is the whole bound on
    /// a request's work here**, because an entry is one row with no children — where a batch of sessions
    /// is bounded twice over, this one is bounded once, and the count that comes back is entries and
    /// rows at the same time.
    public func writeReceptiveInactivities(_ rows: [ReceptiveInactivityDTO]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }

        let request = try await makeRequest(
            method: "POST",
            path: "v1/receptive-inactivities/batch",
            body: try encode(ReceptiveInactivityBatchBody(rows: rows))
        )
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode(ReceptiveInactivityBatchResult.self, from: data).written
    }

    // MARK: - The profile, which has one call

    /// Write the caller's profile, replacing the whole row, and answer with the row read back.
    ///
    /// **This is the one call in this file with no separate write type, and the absence is the schema's
    /// doing rather than a shortcut.** `UserProfileWrite` is seven fields and no id —
    /// `UserProfileDTO` is already exactly that — so there is nothing to subtract and a `UserProfileWriteDTO`
    /// would be a second declaration of one schema. Every other resource needs the pair because its
    /// single-write path names the row's key in the *URL* while its row carries that key in the body;
    /// here the key is the path itself.
    ///
    /// **There is no batch method and no window, and there is nothing missing.** A profile is a
    /// singleton, so a chunk of one is not a batch and a range of one is not a window; `PUT` is the whole
    /// of what a sync does to it.
    ///
    /// **The answer is decoded rather than discarded and it is worth saying why here more than
    /// anywhere.** The route answers with the row *as the database holds it* rather than with the request
    /// echoed, which is how a caller can see that a `weightKg` sent as `null` is still `null` and not a
    /// `0` some layer defaulted. The port above returns nothing, so this decoding is the only place that
    /// difference could be noticed at all.
    @discardableResult
    public func writeProfile(_ row: UserProfileDTO) async throws -> UserProfileDTO {
        let request = try await makeRequest(method: "PUT", path: "v1/profile", body: try encode(row))
        let (data, response) = try await perform(request)
        try check(response, data)
        return try decode(UserProfileDTO.self, from: data)
    }

    // MARK: - The transport

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Every `URLSession` failure lands here — no route, a refused connection, a timeout, a
            // cancelled task — and every one of them means the same thing to a caller: no answer was
            // received. They are not distinguished further because nothing above could act on the
            // difference, and `.unreachable` is the one error a caller is allowed to draw a stored copy
            // over.
            throw CloudSyncError.unreachable(message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CloudSyncError.malformed(message: "the answer to \(request.url?.path ?? "the request") was not an HTTP response")
        }
        return (data, http)
    }

    /// Refuse a non-2xx answer, in the API's own vocabulary where the body allows it.
    private func check(_ response: HTTPURLResponse, _ data: Data) throws {
        guard !(200 ... 299).contains(response.statusCode) else { return }

        if let refusal = try? decodeRefusal(from: data) {
            throw CloudSyncError.rejected(code: refusal.error.code, message: refusal.error.message)
        }

        // A status with a body this client cannot read is still a refusal — the server said no — so it
        // stays `.rejected` rather than becoming `.malformed`, which would send the caller looking for a
        // contract mismatch that is not there. The status is carried in the code so the sentence can
        // name it.
        throw CloudSyncError.rejected(
            code: "http_\(response.statusCode)",
            message: "the server answered \(response.statusCode) with a body this app could not read"
        )
    }

    /// Both headers are written here and nowhere else, so every request the app makes carries the same
    /// pair and there is one place to look when one of them is wrong.
    ///
    /// **The two are set together and answer to different failures.** The credential is the build's own
    /// constant, so a request that goes out without it is a bug in this app — visible immediately as a
    /// `401`, which is the server saying it did not recognise this deployment's secret. The identity
    /// header is a value read per request, so the failure below is about the Keychain rather than the
    /// network.
    ///
    /// **A store failure is reported as `.unreachable`, and that is a judgement rather than a
    /// convenience.** The two facts a caller can act on are "the database answered" and "it did not", and
    /// a Keychain that will not open is the second: no request was made and none could be. It is
    /// deliberately *not* `.rejected` or `.malformed`, which are the two the decorator refuses to degrade
    /// over — degradable is exactly the right treatment for this, and a screen holding the phone's own
    /// copy of the day should draw it with its note rather than blank because a Keychain call failed. The
    /// message names the key store so the note is not read as a network fault, and the distinction is not
    /// lost in the log.
    private func makeRequest(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query.isEmpty ? nil : query

        guard let url = components?.url else {
            throw CloudSyncError.malformed(message: "the configured base URL and \(path) do not make a URL")
        }

        let key: String
        do {
            key = try await keyStore.key()
        } catch {
            throw CloudSyncError.unreachable(message: "this install's sync key is unavailable: \(error)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: Self.userIDHeader)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }
        return request
    }

    private func encode(_ value: some Encodable) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            // Unreachable from `RecoveryDTO`, whose four nullable fields are written as `null` and whose
            // numbers are refused upstream by `RecoveryWireMapper.isSendable` — a `NaN` or an infinity is
            // the one value `JSONEncoder` throws on. If it is ever reached it is a client bug, and the
            // message says so rather than reporting a network failure.
            throw CloudSyncError.malformed(message: "this app could not write a request body: \(error)")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CloudSyncError.malformed(message: "an answer did not match the shape this app expects: \(error)")
        }
    }

    private func decodeRefusal(from data: Data) throws -> APIErrorEnvelope {
        try JSONDecoder().decode(APIErrorEnvelope.self, from: data)
    }
}

// MARK: - The request bodies, which are not the same shape as the answer

/// One day's fields, without the day — the body `PUT /v1/recoveries/{date}` takes.
///
/// **This type exists because the API writes a day down in two different places and only one of them is
/// the body.** A single-day write names its day in the *path*, and `RecoveryWriteSchema` is `.strict()`,
/// so a body that carried a `date` key would be refused with a `400` naming a field the caller thought
/// it was being helpful by including. A batch row has no path to carry a day, so it carries one in the
/// body and its schema *requires* it. Same nine fields, two payloads, and the difference is not a detail
/// that can be smoothed over: getting it wrong is a request the server rejects.
///
/// The `encode(to:)` is written out rather than synthesised, for the reason `RecoveryDTO`'s is — the
/// nullable fields must arrive as `null` rather than as absent keys.
struct RecoveryWriteDTO: Encodable {
    let recoveryScore: Int
    let restingHeartRate: Int
    let hrvValueMs: Double
    let hrvMetric: HRVMetric
    let skinTemperature: Double?
    let spo2Percentage: Double?
    let respiratoryRate: Double?
    let source: String?

    init(_ row: RecoveryDTO) {
        self.recoveryScore = row.recoveryScore
        self.restingHeartRate = row.restingHeartRate
        self.hrvValueMs = row.hrvValueMs
        self.hrvMetric = row.hrvMetric
        self.skinTemperature = row.skinTemperature
        self.spo2Percentage = row.spo2Percentage
        self.respiratoryRate = row.respiratoryRate
        self.source = row.source
    }

    private enum CodingKeys: String, CodingKey {
        case recoveryScore
        case restingHeartRate
        case hrvValueMs
        case hrvMetric
        case skinTemperature
        case spo2Percentage
        case respiratoryRate
        case source
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recoveryScore, forKey: .recoveryScore)
        try container.encode(restingHeartRate, forKey: .restingHeartRate)
        try container.encode(hrvValueMs, forKey: .hrvValueMs)
        try container.encode(hrvMetric, forKey: .hrvMetric)
        try container.encode(skinTemperature, forKey: .skinTemperature)
        try container.encode(spo2Percentage, forKey: .spo2Percentage)
        try container.encode(respiratoryRate, forKey: .respiratoryRate)
        try container.encode(source, forKey: .source)
    }
}

/// The batch body: `{ "rows": [...] }`, with the day on every row.
struct RecoveryBatchBody: Encodable {
    let rows: [RecoveryDTO]
}

/// What the batch answers: the database's own count of the rows it changed.
struct RecoveryBatchResult: Decodable {
    let written: Int
}

/// One day's fields, without the day — the body `PUT /v1/strains/{date}` takes.
///
/// **Seven fields become six, and the subtraction is the whole type**, on `RecoveryWriteDTO`'s argument:
/// a single-day write names its day in the *path* and `StrainWriteSchema` is `.strict()`, so a body
/// carrying a `date` key would be refused with a `400` naming a field the caller thought it was being
/// helpful by including. A batch row has no path to carry a day, so it carries one in the body and its
/// schema *requires* it.
///
/// **The strictness on this body buys less than its sibling's and the difference is worth knowing.**
/// Every field here is required and none is nullable but `source`, so a client that misspells one — or
/// leaves `hasMeasurement` out — is already refused by the missing-field check and no default can absorb
/// it. What `.strict()` catches is the **extra** key, and the extra key that matters on this body is
/// `date`: a client holding two opinions about which day it is writing, where the path wins in a way it
/// cannot see.
///
/// The `encode(to:)` is written out rather than synthesised, for the reason `StrainDTO`'s is — `source`
/// must arrive as `null` rather than as an absent key, and the synthesised `encodeIfPresent` would drop
/// it on every row this app scored itself.
struct StrainWriteDTO: Encodable {
    let strainScore: Double
    let kilojoules: Double
    let averageHeartRate: Int
    let maxHeartRate: Int
    let hasMeasurement: Bool
    let source: String?

    init(_ row: StrainDTO) {
        self.strainScore = row.strainScore
        self.kilojoules = row.kilojoules
        self.averageHeartRate = row.averageHeartRate
        self.maxHeartRate = row.maxHeartRate
        self.hasMeasurement = row.hasMeasurement
        self.source = row.source
    }

    private enum CodingKeys: String, CodingKey {
        case strainScore
        case kilojoules
        case averageHeartRate
        case maxHeartRate
        case hasMeasurement
        case source
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(strainScore, forKey: .strainScore)
        try container.encode(kilojoules, forKey: .kilojoules)
        try container.encode(averageHeartRate, forKey: .averageHeartRate)
        try container.encode(maxHeartRate, forKey: .maxHeartRate)
        try container.encode(hasMeasurement, forKey: .hasMeasurement)
        try container.encode(source, forKey: .source)
    }
}

/// The batch body: `{ "rows": [...] }`, with the day on every row.
struct StrainBatchBody: Encodable {
    let rows: [StrainDTO]
}

/// What the batch answers: the database's own count of the rows it changed.
struct StrainBatchResult: Decodable {
    let written: Int
}

/// One session's fields, without the id — the body `PUT /v1/workouts/{id}` takes.
///
/// **The same thirteen fields as `WorkoutDTO` minus `id`, and the subtraction is the whole type.**
/// `WorkoutWriteSchema` is `.strict()`, so a body carrying an `id` key is a `400` naming a field the
/// caller thought it was being helpful by including — the id is in the path. That is
/// `RecoveryWriteDTO`'s shape one level over: there the day was in the path and the body carried
/// everything else, here the id is and the body carries everything else *including the day*.
///
/// **`route` and `splits` are required and never omitted**, because on this API an empty array is an
/// affirmative claim rather than a silence — the server deletes a stored route and re-inserts whatever
/// the body carried. Both go through `container.encode` like every other field here, which is
/// belt-and-braces for a non-optional array and is what keeps the two nullable rules from being
/// invisible: nothing in this file may reach for `encodeIfPresent`, and the one way to be sure of that
/// is for every field to be written the same way.
///
/// The `encode(to:)` is written out rather than synthesised, for `RecoveryWriteDTO`'s reason — the
/// eight nullable fields must arrive as `null` rather than as absent keys, and `encodeIfPresent` would
/// drop each of them.
struct WorkoutWriteDTO: Encodable {
    let date: String
    let startedAt: String
    let endedAt: String
    let strain: Double?
    let averageHeartRate: Int?
    let maxHeartRate: Int?
    let source: String?
    let activityName: String?
    let hrZonePercents: [Double]?
    let steps: Int?
    let offlineRegionID: String?
    let route: [WorkoutRoutePointDTO]
    let splits: [WorkoutSplitDTO]

    init(_ row: WorkoutDTO) {
        self.date = row.date
        self.startedAt = row.startedAt
        self.endedAt = row.endedAt
        self.strain = row.strain
        self.averageHeartRate = row.averageHeartRate
        self.maxHeartRate = row.maxHeartRate
        self.source = row.source
        self.activityName = row.activityName
        self.hrZonePercents = row.hrZonePercents
        self.steps = row.steps
        self.offlineRegionID = row.offlineRegionID
        self.route = row.route
        self.splits = row.splits
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case startedAt
        case endedAt
        case strain
        case averageHeartRate
        case maxHeartRate
        case source
        case activityName
        case hrZonePercents
        case steps
        case offlineRegionID
        case route
        case splits
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(strain, forKey: .strain)
        try container.encode(averageHeartRate, forKey: .averageHeartRate)
        try container.encode(maxHeartRate, forKey: .maxHeartRate)
        try container.encode(source, forKey: .source)
        try container.encode(activityName, forKey: .activityName)
        try container.encode(hrZonePercents, forKey: .hrZonePercents)
        try container.encode(steps, forKey: .steps)
        try container.encode(offlineRegionID, forKey: .offlineRegionID)
        try container.encode(route, forKey: .route)
        try container.encode(splits, forKey: .splits)
    }
}

/// The batch body: `{ "rows": [...] }`, with the id on every row.
///
/// **The rows are `WorkoutDTO` and not `WorkoutWriteDTO`, which is the opposite of the recoveries
/// pair and is the schemas' own doing.** There, a batch row is `{ date } + the write fields` — the day
/// becomes the key — so the batch row and the write body are different shapes and the client needs two
/// types. Here `WorkoutBatchRowSchema` is `{ id } + workoutFields`, which is field-for-field the
/// fourteen fields `WorkoutSchema` already describes, so the batch row *is* the read shape and a second
/// type would be a second declaration of one schema.
struct WorkoutBatchBody: Encodable {
    let rows: [WorkoutDTO]
}

/// What the batch answers: the database's own count of the sessions it wrote — not of the rows, since
/// a session's route can be two thousand of them. See `writeWorkouts(_:)`.
struct WorkoutBatchResult: Decodable {
    let written: Int
}

/// One night's fields, without the day — the body `PUT /v1/sleeps/{date}` takes.
///
/// **Fifteen fields become fourteen, and the subtraction is the whole type**, on `RecoveryWriteDTO`'s
/// argument: a single-night write names its day in the *path* and `SleepWriteSchema` is `.strict()`, so a
/// body carrying a `date` key would be refused with a `400` naming a field the caller thought it was
/// being helpful by including. A batch row has no path to carry a day, so it carries one in the body and
/// its schema *requires* it.
///
/// **`sleepStages` is a `String?` here and stays one.** It is the one field on this resource the server
/// neither parses nor validates the interior of, so passing the app's own JSON through as text is the
/// whole of what this type does with it — the conversion between segments and that text lives in
/// `SleepWireMapper`, one layer up.
///
/// The `encode(to:)` is written out rather than synthesised, for the reason `RecoveryDTO`'s is: the six
/// nullable fields must arrive as `null` rather than as absent keys, and `encodeIfPresent` — which is
/// what a synthesised encoder emits — would drop every one of them. On this resource that is not a
/// corner case: `sleepStages`, `disturbanceCount` and `sleepConsistency` are `nil` on all 910 imported
/// nights.
struct SleepWriteDTO: Encodable {
    let startTime: String
    let endTime: String
    let sleepPerformance: Double
    let totalSleepNeeded: Double
    let lightSleep: Double
    let deepSleep: Double
    let remSleep: Double
    let awakeTime: Double
    let respiratoryRate: Double?
    let disturbanceCount: Int?
    let sleepConsistency: Int?
    let sleepDebt: Double?
    let sleepStages: String?
    let source: String?

    init(_ row: SleepDTO) {
        self.startTime = row.startTime
        self.endTime = row.endTime
        self.sleepPerformance = row.sleepPerformance
        self.totalSleepNeeded = row.totalSleepNeeded
        self.lightSleep = row.lightSleep
        self.deepSleep = row.deepSleep
        self.remSleep = row.remSleep
        self.awakeTime = row.awakeTime
        self.respiratoryRate = row.respiratoryRate
        self.disturbanceCount = row.disturbanceCount
        self.sleepConsistency = row.sleepConsistency
        self.sleepDebt = row.sleepDebt
        self.sleepStages = row.sleepStages
        self.source = row.source
    }

    private enum CodingKeys: String, CodingKey {
        case startTime
        case endTime
        case sleepPerformance
        case totalSleepNeeded
        case lightSleep
        case deepSleep
        case remSleep
        case awakeTime
        case respiratoryRate
        case disturbanceCount
        case sleepConsistency
        case sleepDebt
        case sleepStages
        case source
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(sleepPerformance, forKey: .sleepPerformance)
        try container.encode(totalSleepNeeded, forKey: .totalSleepNeeded)
        try container.encode(lightSleep, forKey: .lightSleep)
        try container.encode(deepSleep, forKey: .deepSleep)
        try container.encode(remSleep, forKey: .remSleep)
        try container.encode(awakeTime, forKey: .awakeTime)
        try container.encode(respiratoryRate, forKey: .respiratoryRate)
        try container.encode(disturbanceCount, forKey: .disturbanceCount)
        try container.encode(sleepConsistency, forKey: .sleepConsistency)
        try container.encode(sleepDebt, forKey: .sleepDebt)
        try container.encode(sleepStages, forKey: .sleepStages)
        try container.encode(source, forKey: .source)
    }
}

/// The batch body: `{ "rows": [...] }`, with the day on every row.
///
/// **The rows are `SleepDTO` and not `SleepWriteDTO`, on `WorkoutBatchBody`'s argument and for its
/// reason.** `SleepBatchRowSchema` is `{ date } + sleepFields`, which is field-for-field the fifteen
/// fields `SleepSchema` already describes, so the batch row *is* the read shape and a second type would
/// be a second declaration of one schema.
struct SleepBatchBody: Encodable {
    let rows: [SleepDTO]
}

/// What the batch answers: the database's own count of the rows it changed.
struct SleepBatchResult: Decodable {
    let written: Int
}

/// One day's fields, without the day — the body `PUT /v1/step-counts/{date}` takes.
///
/// **Three fields become two, and this is the smallest subtraction in the file.** On
/// `RecoveryWriteDTO`'s argument: the day is in the path and `StepCountWriteSchema` is `.strict()`, so a
/// body carrying a `date` would be a `400`. Both remaining fields are required and neither is nullable,
/// so the `encode(to:)` below is synthesised — there is no absent key for `encodeIfPresent` to drop, and
/// writing out an encoder that has no rule to state would be noise rather than care.
struct StepCountWriteDTO: Encodable {
    let stepCount: Int
    let measuredSeconds: Double

    init(_ row: StepCountDTO) {
        self.stepCount = row.stepCount
        self.measuredSeconds = row.measuredSeconds
    }
}

/// The batch body: `{ "rows": [...] }`, with the day on every row. `StepCountBatchRowSchema` is the
/// three fields of `StepCountSchema`, so the batch row is the read shape, as on both resources above.
struct StepCountBatchBody: Encodable {
    let rows: [StepCountDTO]
}

/// What the batch answers: the database's own count of the rows it changed.
struct StepCountBatchResult: Decodable {
    let written: Int
}

/// One entry's fields, without the id — the body `PUT /v1/receptive-inactivities/{id}` takes.
///
/// **Five fields become four and the one subtracted is the id rather than the day**, which is the
/// opposite of its two siblings above and the whole of this resource's oddity: the path addresses an
/// *entry*, and the day it is filed on is a field the server cannot derive from that path. So the date
/// stays and `ReceptiveInactivityWriteSchema` requires it.
///
/// **`note` and `startedAt` are the two nullable fields this whole API cares most about spelling
/// correctly.** Both are `minLength: 1` when present, so `""` is a `400` and `null` is a value — which
/// is why the encoder below writes each with `container.encode` rather than letting a synthesised
/// `encodeIfPresent` drop the key, an omission that would be refused as a missing field instead.
struct ReceptiveInactivityWriteDTO: Encodable {
    let date: String
    let name: String
    let note: String?
    let startedAt: String?

    init(_ row: ReceptiveInactivityDTO) {
        self.date = row.date
        self.name = row.name
        self.note = row.note
        self.startedAt = row.startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case name
        case note
        case startedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(name, forKey: .name)
        try container.encode(note, forKey: .note)
        try container.encode(startedAt, forKey: .startedAt)
    }
}

/// The batch body: `{ "rows": [...] }`, with the id on every row.
/// `ReceptiveInactivityBatchRowSchema` is the five fields of `ReceptiveInactivitySchema`, so the batch
/// row is the read shape.
struct ReceptiveInactivityBatchBody: Encodable {
    let rows: [ReceptiveInactivityDTO]
}

/// What the batch answers: the database's own count of the entries it wrote — which on this resource is
/// also the row count, since an entry has no children. See `writeReceptiveInactivities(_:)`.
struct ReceptiveInactivityBatchResult: Decodable {
    let written: Int
}

/// The API's error envelope, `{ "error": { "code": …, "message": … } }`.
///
/// It is decoded only to read a refusal, and a body that does not match it is not an error in itself —
/// `check(_:_:)` falls back to the status code. The `code` is the field that carries meaning: the
/// server's codes are a closed set this client reads by name, and there are exactly two it acts on —
/// `no_measurement_for_day`, which `recovery(onDay:)` reads as a day with no reading, and `not_found`,
/// which `workout(id:)` reads as an id this partition does not hold. Every other code falls through to
/// `check(_:_:)` and throws, which is what makes an unrecognised refusal a failure rather than a
/// silently empty answer. The `message` is the server's own sentence for a person to read.
struct APIErrorEnvelope: Decodable {
    struct Refusal: Decodable {
        let code: String
        let message: String
    }

    let error: Refusal
}
