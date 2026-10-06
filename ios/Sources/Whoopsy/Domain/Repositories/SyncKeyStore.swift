import Foundation

/// The install's identity: one secret, minted on this phone, never sent anywhere as itself.
///
/// **There is no account, and that is the whole of the design.** Nothing registers, nothing signs in,
/// and no server has ever been told this install exists. The key is 32 random bytes generated on first
/// use and kept beside the app in its own Keychain, and it is what the Worker hashes into the
/// `user_id` partition every row of this install's history is filed under. A second install is a
/// second key and therefore a second partition, with no way to reach the first — which is the cost,
/// stated on the storage pane rather than discovered, and the reason the key is shown and copyable.
///
/// **It is a bearer credential, and nothing here pretends otherwise.** Anyone holding the string can
/// read and write its rows: there is no signature, no expiry, no revocation and no way for this Worker
/// to tell a key it issued from one somebody invented. What the length buys is that a key cannot be
/// guessed; what it cannot buy is anything else. That is why the value never leaves the phone in a
/// form a database dump could replay — the Worker stores `sha256` of it and never the key — and why
/// the deployment question is a separate, still-open one.
///
/// **Reading is a write on the first call, and the implementation has to make that safe.** A store
/// that found nothing mints a key and persists it, so two concurrent first-reads that both find
/// nothing would mint two keys and one of them would silently become the other's orphan — a partition
/// created, written to, and then unreachable from the app that wrote it. The protocol cannot state
/// that requirement as a type, so it is stated here: a conforming store must be single-flight across
/// the whole read-or-mint.
public protocol SyncKeyStore: Sendable {
    /// This install's key, minting and persisting one if none is stored yet.
    ///
    /// The returned string is the value that goes in the `X-Whoopsy-User-Id` header verbatim. Its
    /// encoding is the store's business — the Worker validates a length floor rather than a shape,
    /// exactly so that the app's encoding is not part of the contract.
    func key() async throws -> String
}

/// Why a key could not be produced.
///
/// One case, because there is one realistic failure: the Keychain refused, or is not available on this
/// device. It is deliberately not `Error`-as-a-string at the call sites — the storage pane shows a
/// sentence and the sync refuses to run, and both of those want a value they can switch on rather
/// than a message they would have to parse.
public enum SyncKeyStoreError: Error, Equatable, Sendable {
    /// The key could not be read from or written to the Keychain.
    ///
    /// The associated value is for the log, not for a screen: what a user is told is that syncing is
    /// unavailable on this device, not which `OSStatus` came back.
    case unavailable(String)
}
