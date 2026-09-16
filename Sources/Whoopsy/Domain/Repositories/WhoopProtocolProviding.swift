import Foundation

/// Which strap generations this build can actually speak to.
///
/// A protocol rather than a property on `WhoopHardwareGeneration`, because the answer is a fact about
/// *this code*, not about the hardware: the 5.0 and 5.0 MG envelopes are described in
/// `BLE_PROTOCOL.md` §2 and implemented nowhere, so answering `false` for them is a statement about
/// the app that goes stale the day that changes. On the enum it would read as a property of the
/// strap, and the picker would say "the 5.0 cannot sync" as though the strap were the limitation.
///
/// Presentation depends on this so the device screen can say plainly that a chosen model has no
/// implementation behind it, instead of offering a sync button that quietly does nothing.
public protocol WhoopProtocolProviding: Sendable {
    /// Whether this build can encode and decode this generation's proprietary frames.
    func supportsProprietarySync(_ generation: WhoopHardwareGeneration) -> Bool
}
