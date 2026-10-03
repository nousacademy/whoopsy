import Foundation

/// Which model the user has said each strap is, remembered per device.
///
/// **Keyed by the peripheral's identifier, not by name.** A strap advertises its name only sometimes
/// — `WhoopBLEManager` falls back to the literal `"WHOOP Strap"` — so a name-keyed store would file
/// every unnamed strap under one entry. The identifier is assigned per peripheral by CoreBluetooth and
/// is stable across launches for a bonded strap, though not across a reinstall; losing the mapping
/// that way is a prompt to re-pick, not a wrong answer.
///
/// This exists because the alternative is a guess. `WhoopBLEManager` infers the generation from a
/// substring of the advertised name (`contains("5")`), which cannot tell a 5.0 from a 5.0 MG and
/// answers `.whoop4` for a strap that advertises nothing at all. A stored choice is the source of
/// truth; the guess is only what a strap with no stored choice falls back to.
public protocol StrapModelRepository: Sendable {
    /// Every strap the user has assigned a model to, keyed by peripheral identifier.
    ///
    /// The whole map rather than a per-device read because the one caller that matters —
    /// `WhoopBLEManager` — has to answer inside a synchronous CoreBluetooth callback and so keeps a
    /// copy of this in memory, refreshed in one call.
    func allModels() async -> [String: WhoopHardwareGeneration]

    /// Records the model for one strap. `nil` clears the entry, which hands the strap back to the
    /// name heuristic rather than pinning it to whatever was there before.
    func setModel(_ model: WhoopHardwareGeneration?, forDeviceId: String) async
}
