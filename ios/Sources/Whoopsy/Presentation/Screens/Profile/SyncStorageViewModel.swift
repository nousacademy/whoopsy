import Foundation
import SwiftUI

/// The `STORAGE` tab: where this phone's own SQLite file and the database behind it meet.
///
/// **A view model of its own rather than three more properties on `ProfileViewModel`**, on
/// `LocalDataViewModel`'s argument one pane over: `BIOMETRICS`, `LOGS` and `STORAGE` are three panes a
/// reader can visit inside one page's lifetime, and a shared instance would give them one `status`
/// string and one `isSyncing` flag — so a failed run would rewrite the sentence a refused save had just
/// written, under a pane that is no longer on screen. `MainContainerView` is still the only place this
/// is built and `DIContainer` the only place its dependencies come from.
///
/// **One engine behind it, where this pane used to hold three use cases and a resource selector.** The
/// three were near-copies of one walk that differed in which table they walked, and the settings that
/// justified keeping them apart are gone — there is one destination and one span for the install, so
/// three copies of them were three things to keep in step for no reader. What is left is one object
/// that walks all seven resources, which is why the `RECOVERIES | WORKOUTS | STRAINS` segment and
/// everything it selected are deleted: a pane that drew one resource's boundary while the run sent
/// seven would be drawing a control that governs nothing.
///
/// **The two controls are a destination and a span, and neither of them is a mode.** *"If a DB is
/// selected, it doesnt purge anything, it just switches where data will be stored to"* is the whole of
/// the destination: it says where a day goes from here, and it moves nothing. The span is what a run
/// sends — `SYNC FROM` and `SYNC TO`, both drawn, because a range has two ends and a pane that drew
/// only one would be hiding half of what a press does.
///
/// **The run is unconditionally a write-through and the button says `SYNC`.** It used to carry a verb —
/// `UPLOAD` or `DOWNLOAD` — read off which way two cutoffs disagreed, and there are no two cutoffs to
/// disagree: the span is drawn rather than derived and the direction follows from it, so a button
/// labelled with one of the two would be naming a choice the user did not make. `SyncSummary.message`
/// still reports how much moved and in which direction, which is the *report* rather than the verb.
///
/// **`syncStatus` is deliberately not a dependency.** The marking that a read had to fall back to the
/// phone's copy is written by the routing decorator and drawn by `RecoveryDetailView` and
/// `HomeDashboardView` — the two screens that show a *day*. This pane shows no day, so a dependency here
/// would be an object nothing on it could read.
@MainActor @Observable public final class SyncStorageViewModel {

    /// What the pane draws: where data goes, and how much of it a run would send.
    public private(set) var settings = SyncSettings()

    /// This install's key, as the store spells it — 64 unbroken uppercase hex characters.
    ///
    /// `nil` until `load()` has read it, and left `nil` on a build with no database behind it, where the
    /// pane draws a sentence instead of a credential nothing could be filed under.
    public private(set) var key: String?

    /// Why the key could not be produced, when the Keychain refused.
    ///
    /// A separate field rather than a `status` write, because a Keychain failure is not something the
    /// user just did: the pane draws it under the row it belongs to rather than in the run's footer.
    public private(set) var keyError: String?

    /// The last thing that happened on this pane — a run's own sentence, or why it stopped.
    public private(set) var status = ""

    /// True while a run is in flight, so the button cannot be pressed twice and the pane can say so.
    public private(set) var isSyncing = false

    /// True once the stored settings have been read, which is what gates the controls.
    ///
    /// It is `saveButton`'s own gate one pane over: a control drawn over a value nothing has read yet is
    /// a control whose first press would write the default over the stored answer.
    public private(set) var hasLoaded = false

    /// The `Info.plist` key this build is missing, or `nil` when it has both — **and the pane's one
    /// branch condition**.
    ///
    /// Read from `DIContainer` rather than probed here, because it is the container that decides which
    /// `CloudSync` the engine got, and a second answer derived a second way is a second answer free to
    /// disagree with the object doing the work.
    ///
    /// **It carries the key rather than a bare `Bool`, because there are two keys now and the pane's
    /// sentence has to name the one that is empty.** A build missing only `WHOOPSYAPIToken` has a
    /// correct `WHOOPSYAPIBaseURL`, and a sentence pointing at the address would send its reader to a
    /// line they already filled in.
    public let missingCloudKey: String?

    /// Whether this build was given a database to talk to.
    ///
    /// **Derived from `missingCloudKey` rather than passed beside it**, so the button's gate and the
    /// pane's sentence cannot come from two answers that agree today. There is one stored fact here and
    /// two spellings of it: a build is configured exactly when no key is absent.
    public var isCloudConfigured: Bool { missingCloudKey == nil }

    /// Where data is stored: this phone, or the database. **A switch and not a move** — see the type's
    /// own doc comment, and `SyncSettings.Destination`.
    public var destination: SyncSettings.Destination { settings.destination }

    /// The span a run would send, or `nil` when the user has not drawn one.
    ///
    /// `nil` and an empty range are different states that both run nothing: the first is *no span drawn*
    /// and the second is *both ends on the same day*, which the pickers can produce and which covers no
    /// days. `canRun` refuses both, and the engine throws `.nothingToDo` on both.
    public var range: SyncSettings.SyncRange? { settings.range }

    /// Whether the run button is live. It is greyed in the states where pressing it could only fail.
    ///
    /// **Three conditions, and the middle one is where the old third used to be.** `canRun` used to read
    /// `isCloudConfigured && runTitle != nil && !isSyncing`, where `runTitle` was `nil` whenever the two
    /// cutoffs agreed — that is, whenever a run would have had nothing to do. There are no cutoffs to
    /// agree, so the same question is asked of the span directly: a run over no span has nothing to do,
    /// and the pane withholds the button rather than offering one that could only answer *nothing to
    /// send*. That is the rule this pane already keeps for the copy-policy row it no longer has — *never
    /// offer a setting that would do nothing* — restated on the one control left.
    public var canRun: Bool { isCloudConfigured && hasSpan && !isSyncing }

    /// The run button's title, and **a constant rather than a derived verb**.
    ///
    /// The plan's mockup for this pane draws `UPLOAD 912 DAYS` and `DOWNLOAD 912 DAYS`, and neither can
    /// be drawn honestly. The number cannot: it is a count *before* the run, and the only store holding
    /// it is the one the run has not read yet — counting local rows instead would be a 4000-row read on
    /// every pane open and would be counting the wrong store on the direction where the database is what
    /// decides. And the verb cannot either, for the reason the destination is a switch: the run is a
    /// write-through over a span the user drew, so there is no disagreement between two markers for a
    /// verb to be read off. What a reader gets instead is `SYNC`, and one honest sentence afterwards.
    public nonisolated static let runTitle = "SYNC"

    private let engine: SyncEngine
    private let keyStore: any SyncKeyStore

    public init(
        engine: SyncEngine,
        keyStore: any SyncKeyStore,
        missingCloudKey: String?
    ) {
        self.engine = engine
        self.keyStore = keyStore
        self.missingCloudKey = missingCloudKey
    }

    // MARK: - What the pane draws

    /// Whether a run over the stored span would send anything.
    ///
    /// **It has two readers on the pane and both are gates rather than reports.** `canRun` asks it to
    /// decide whether the button is live, and `storageTab` asks it to decide whether the button and the
    /// span's note are drawn at all — which is why it is public rather than folded into `canRun`. The two
    /// questions are different on exactly the state that matters: mid-run, where the span is still drawn
    /// and the button is greyed, so a single `canRun` gate would take the button and its `Working…` line
    /// off the screen the instant it was pressed. See `runRow`.
    ///
    /// The empty-range arm is not defensive: `SyncSettings.SyncRange` snaps both ends to their day, so
    /// two picks inside one day collapse onto one date and `from >= to` reads as *covers no days*. The
    /// engine refuses that case in the same words, which is what keeps the button's gate and the run's
    /// own guard describing one condition rather than two that agree today.
    public var hasSpan: Bool {
        guard let range = settings.range else { return false }
        return !range.isEmpty
    }

    // MARK: - The three actions

    /// Reads the destination, the span and the key.
    ///
    /// **The key is read only on a configured build, and that ordering is deliberate.** Reading the key
    /// is a write on the first call — `SyncKeyStore` mints and persists one when it finds nothing — so
    /// doing it unconditionally would mint a credential on a build that has no database to file it
    /// under, and then draw it on a pane whose whole content is the sentence saying there is none.
    public func load() async {
        settings = await engine.settings()
        hasLoaded = true
        guard isCloudConfigured else { return }
        await readKey()
    }

    /// Switch where data is stored.
    ///
    /// **Nothing is moved and nothing is deleted, which is what the user asked for and what the type's
    /// doc comment records.** Pressing this changes the answer to *where does the next write go* and to
    /// *which store does a read fall back to*; every row already on the phone stays on the phone, and
    /// every row already in the database stays there. The pane says so on its face, because a control
    /// labelled `WHOOPSY SYNC API` under a heading about storage reads like a move if nothing says
    /// otherwise.
    ///
    /// The status sentence is cleared: a report about a run is about the store that run wrote to, and a
    /// sentence left standing under a destination it did not describe is a sentence about the wrong one.
    public func setDestination(_ destination: SyncSettings.Destination) async {
        settings = await engine.setDestination(destination)
        status = ""
    }

    /// Move one end of the span. **Both ends or neither**, which is the engine's contract and not a
    /// convenience here: a half-drawn span is not a span, and storing one end alone would leave the
    /// button's gate describing a range that does not exist.
    ///
    /// The snap belongs to `SyncSettings.SyncRange` and not to this call, on the old cutoff control's
    /// reasoning kept verbatim: a `DatePicker` hands back an instant carrying the current clock time, and
    /// an unsnapped end would make the set of days a run covers depend on what time of day the user
    /// happened to tap.
    public func setRange(from: Date?, to: Date?) async {
        settings = await engine.setRange(from: from, to: to)
        status = ""
    }

    /// Send the drawn span to whichever store the destination names.
    ///
    /// **The settings are re-read on every path, including the failing ones, and that is not tidiness.**
    /// A run of seven resources can die on the fourth, and the three that landed are genuinely in the
    /// database — a pane still holding the pre-run settings would be drawing a state that no longer
    /// describes either store. Re-reading is what makes the pane's next state a fact about the world
    /// rather than about this object.
    ///
    /// The failure sentences are `message(for:)`'s, and the successful one is the engine's own: nothing
    /// here composes a sentence about a transfer, so a run cannot come to describe itself two ways.
    public func run() async {
        guard !isSyncing else { return }
        isSyncing = true
        status = ""
        do {
            status = Self.report(try await engine.run())
        } catch let error as SyncError {
            status = Self.message(for: error)
        } catch let error as CloudSyncError {
            status = Self.message(for: error)
        } catch {
            status = error.localizedDescription
        }
        settings = await engine.settings()
        isSyncing = false
    }

    // MARK: - The key

    private func readKey() async {
        do {
            key = try await keyStore.key()
            keyError = nil
        } catch let error as SyncKeyStoreError {
            keyError = Self.message(for: error)
        } catch {
            keyError = error.localizedDescription
        }
    }

    // MARK: - The sentences

    /// The run's one sentence, out of the seven the engine hands back.
    ///
    /// **Only the resources that had something to say are quoted**, which is what keeps an ordinary run
    /// to a line rather than to seven. A resource with no rows in the span says *there was nothing to
    /// send* in its own words; seven of those is not a report, and it is not what the reader asked. A
    /// resource that had rows it could not send **is** quoted even though it moved none — that is the one
    /// case where the honest answer is a warning rather than a silence, and `SyncSummary`'s own sentence
    /// is where it is written.
    ///
    /// **When nothing at all moved, the sentence is still the engine's.** All seven say it identically,
    /// so the first is the run's; composing a second phrasing here would be the pane inventing a way to
    /// describe a transfer, which is exactly what the old three-use-case design avoided by handing the
    /// message straight to the screen.
    ///
    /// The empty-`results` fallback is unreachable — `SyncEngine` walks its resource list, which is seven
    /// long — and it answers with no sentence rather than with a claim, because an unreachable branch
    /// that invents a report is worse than one that draws nothing.
    private nonisolated static func report(_ results: [SyncResult]) -> String {
        let spoken = results
            .filter { $0.summary.rows > 0 || $0.summary.skipped > 0 }
            .map(\.summary.message)
        if !spoken.isEmpty { return spoken.joined(separator: " ") }
        return results.first?.summary.message ?? ""
    }

    /// Why the run did not happen, in the user's terms rather than the error's.
    ///
    /// **Not one sentence with the error appended.** The failures want different things done about them
    /// — draw a span, or narrow one — and a single `localizedDescription` for all of them is how a user
    /// is told to check their connection when the real answer is that the span is wider than the server
    /// will read.
    private nonisolated static func message(for error: SyncError) -> String {
        switch error {
        case .nothingToDo:
            // Reachable from this pane's own `canRun` gate only in the window between the pickers
            // changing and the view redrawing, and kept as a sentence rather than `fatalError`d for the
            // reason every other arm here is: it is the sentence a future second route to `run()` would
            // deserve. It names the two controls rather than the state, because the state is one the
            // reader can see and the fix is not.
            return "Draw a span first — a run sends the days between SYNC FROM and SYNC TO, "
                + "and there is nothing to send until both ends are set."

        case let .rangeTooWide(days):
            // Deliberately not a clamp, so the sentence has to name the limit and what to do about it.
            // The unit is days and not *the span*, because the ceiling is a resource's own lookback and
            // a reader narrowing a range needs to know how far back it can reach.
            return "That span reaches further back than the database can read in one request — "
                + "\(days) days is the limit. Bring SYNC FROM forward and try again."
        }
    }

    /// The three transport failures, which are three different problems.
    ///
    /// `.unreachable` says nothing about what moved, because on a run of seven resources the honest
    /// answer to *how much landed* is a number this type does not have — the engine throws rather than
    /// answering a partly-completed list. Saying *nothing was moved* would be false on every run that
    /// failed after its first resource, and it is the one claim a failed sync must never make.
    private nonisolated static func message(for error: CloudSyncError) -> String {
        switch error {
        case let .unreachable(message):
            return "The database could not be reached: \(message)"
        case let .rejected(code, message):
            return "The database refused it (\(code)): \(message)"
        case let .malformed(message):
            return "The database's answer was not one this app could read: \(message)"
        }
    }

    /// The Keychain's one failure, said in terms of what the user loses.
    private nonisolated static func message(for error: SyncKeyStoreError) -> String {
        switch error {
        case .unavailable:
            // The `OSStatus` the case carries is for the log and not for the screen — a reader is told
            // syncing is unavailable on this device, which is the only part of it they can act on.
            return "This phone's Keychain would not open, so the sync key could not be read. "
                + "Syncing is unavailable on this device."
        }
    }
}
