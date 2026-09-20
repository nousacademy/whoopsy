import Foundation

/// Which strap generations this build can actually speak to.
///
/// A protocol rather than a property on `WhoopHardwareGeneration`, because the answer is a fact about
/// *this code*, not about the hardware. On the enum it would read as a property of the strap, and the
/// picker would say "the 5.0 cannot sync" as though the strap were the limitation — which is exactly
/// the wording this protocol was introduced to avoid, and which then went stale in the other
/// direction when the 5.0's command set landed.
///
/// Presentation depends on this so the device screen can say plainly which envelope it will frame for
/// a chosen model — rather than naming one envelope for all three, which is now wrong for two of them.
public protocol WhoopProtocolProviding: Sendable {
    /// Whether this build can encode and decode this generation's proprietary frames — **which is a
    /// question about writing, since decoding is answered by the profile's existence.**
    func supportsProprietarySync(_ generation: WhoopHardwareGeneration) -> Bool

    /// What `BLE_PROTOCOL.md` calls the envelope this build frames commands with for this generation,
    /// or `nil` when it frames none.
    ///
    /// Read off the profile's own header checksum rather than listed per generation, so the name a
    /// caption prints and the envelope a builder writes cannot come to disagree.
    func protocolEnvelopeName(_ generation: WhoopHardwareGeneration) -> String?
}
