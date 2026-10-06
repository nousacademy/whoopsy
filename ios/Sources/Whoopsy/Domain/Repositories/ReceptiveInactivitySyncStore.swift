import Foundation

/// Range reads and range writes of `receptive_inactivities`, expressed in the shape the sync moves —
/// records, not entities.
///
/// **The one store in this family that is keyed on an id and still read by a range**, and that pairing
/// is the whole of what makes it different from its siblings. A recovery, a strain and a step count are
/// addressed by their day; an entry is addressed by its own `id` and merely *filed* on a day, because a
/// day can hold several. So a read here is a window over a column that is not the key, and a save is an
/// upsert on a key that is not in the window — both fine, and both worth knowing before assuming this
/// is `RecoverySyncStore` with a different table name.
///
/// **`RecoverySyncStore`'s arguments carry over verbatim and are not restated**: its own protocol rather
/// than two methods on `LocalDatabaseManager`, a second door into a table because
/// `ReceptiveInactivityRepository` speaks the entity while a sync moves the stored row, and half-open
/// `[from, to)` bounds so two chunks abut without sharing an instant. There are no children, so the
/// save is a plain upsert rather than a replacement.
///
/// **The id's determinism is load-bearing and this protocol is where a caller can break it.** Every
/// entry the import writes gets its id from `InactivityParser.identifier(date:type:note:)`, a UUIDv5
/// over the entry's own facts — which is what makes re-importing the same file rewrite the same rows
/// instead of appending a second copy of every one. A save that minted a fresh `UUID()` for a row
/// arriving without one would not fail; it would double the table, quietly, on the next import.
public protocol ReceptiveInactivitySyncStore: Sendable {

    /// Every entry filed on a day in `[from, to)`, **half-open**, ascending by day.
    ///
    /// Ascending for the reason the day-keyed stores give — an upload advances its boundary to each
    /// chunk's last row — and here that means the day, since the id is not an order. A day holding
    /// several entries therefore hands them back in an order this protocol does not promise and no
    /// caller may depend on: nothing about an entry's identity or its upload depends on which of its
    /// day's entries comes first.
    func syncReceptiveInactivityRows(from: Date, to: Date) async throws -> [ReceptiveInactivitySyncRow]

    /// Insert or replace every entry given, in **one** transaction.
    ///
    /// One transaction rather than a loop, on the recoveries' argument: a chunk that fails halfway
    /// leaves a range the sync cannot describe. Each entry lands on its own id, so a replayed chunk
    /// rewrites what it already wrote rather than appending — which is the same property the import
    /// relies on, expressed one layer down.
    ///
    /// The day key is snapped to `startOfDay` by the implementation, centrally, for the reason every
    /// other writer in this app snaps it there. The id is **not** touched: it is the row's identity and
    /// the reason a re-import is idempotent.
    func saveSyncReceptiveInactivityRows(_ rows: [ReceptiveInactivitySyncRow]) async throws
}
