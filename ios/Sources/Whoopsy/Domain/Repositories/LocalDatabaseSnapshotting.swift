import Foundation

/// The whole store, read out in one call.
///
/// **Its own protocol rather than a method on `LocalDatabaseManager`**, on the rule the rest of
/// `Domain/Repositories/` follows: `ExportLocalDataUseCase` is a Domain type and must not name a
/// concrete Data one, so what it depends on is this and what implements it is
/// `LocalDatabaseManager` — the same arrangement `GRDBRecoveryRepository` has with
/// `RecoveryRepository`.
///
/// **It is not a `Repository` in the sense the others are, and the name says so.** Every other protocol
/// here answers a question about one kind of thing and carries the absence rules for it. This one has
/// no subject: it hands back whatever is in the file, so it can make no claim about what any of it
/// means. That is exactly what an export wants and exactly what nothing else in the app wants — which
/// is why no screen, view model or use case other than the exporter takes this.
///
/// **The read is whole-history by construction**, which is the difference from every other read here:
/// there is no `days:` and no `endingOn:` to get wrong, because the question is not "what happened
/// recently" but "what is stored".
public protocol LocalDatabaseSnapshotting: Sendable {

    /// Every row of every table the migrations created.
    ///
    /// Throws rather than answering an empty snapshot when the read fails: an export that reported
    /// "0 rows" over a database it could not open would be the silent-success failure
    /// `ZeroFastingError.notBundled` exists to refuse on the import side, and here it would hand the
    /// user a file that looks like a backup of nothing.
    func exportAllRows() async throws -> LocalDataSnapshot
}
