import Foundation
import Security

/// This install's key, minted once and kept in the Keychain beside the app.
///
/// **It is an `actor` rather than a class behind a lock, and that is the protocol's own requirement
/// made structural.** `SyncKeyStore` documents that a conforming store must be single-flight across the
/// whole read-or-mint, because two first-reads that both find nothing would mint two keys and the
/// second would overwrite the first — leaving a partition that was written to and is now unreachable
/// from the app that wrote it, with nothing anywhere reporting an error. An actor makes that
/// unrepresentable rather than merely unlikely: `key()` is the only door, and the read, the mint and
/// the write happen in one uninterrupted turn.
///
/// **The accessibility attribute is `AfterFirstUnlockThisDeviceOnly`, and both halves of it are
/// decisions.** `AfterFirstUnlock` rather than `WhenUnlocked`, because a key that can only be read
/// while the phone is unlocked is a key that cannot be read from anything that runs in the background —
/// and this app's eventual direction is a sync that does not require the user to be looking at it.
/// `ThisDeviceOnly` rather than the default, because it is the attribute that stops the key riding an
/// encrypted backup onto a **different** device: without it, restoring a backup would put one key on
/// two phones, both writing to one partition under a scheme whose entire premise is that a key is an
/// install. It also implies not-synchronizable, so an iCloud Keychain cannot carry it either, and no
/// `kSecAttrSynchronizable` is needed beside it — the two are mutually exclusive rather than
/// complementary.
///
/// **What that buys and what it costs, stated exactly rather than implied by the word "install".** The
/// key survives deleting and reinstalling the app on this device, which is the useful direction — a
/// user who reinstalls finds their history rather than a fresh partition. It does **not** survive a
/// restore onto a new device, and that is the case the storage pane's own sentence is about: the key is
/// the only way to reach those days and there is no account to recover it.
///
/// **The value is 32 bytes of `SecRandomCopyBytes`, rendered as 64 uppercase hex characters.** Hex
/// because the key travels as an HTTP header value — it must contain nothing that needs quoting,
/// escaping or a charset agreement — and because it is shown to a user to copy, where a base64 alphabet
/// mixing cases with `+`, `/` and `=` is a transcription error waiting to happen. Uppercase to match
/// the form the storage pane draws, so there is one spelling of a key rather than a display form and a
/// sent form that could drift. Sixty-four characters sits inside the Worker's own window (`MIN_KEY_LENGTH`
/// 32, `MAX_KEY_LENGTH` 200) with room either side, and that window exists precisely so the app's
/// encoding is not part of the contract — this is one choice inside it, not the choice it names.
public actor KeychainSyncKeyStore: SyncKeyStore {

    /// How many random bytes one key is made of. 256 bits, which is chosen to be unguessable rather
    /// than to satisfy a rule: the length floor the Worker enforces is what makes a key *long*, and
    /// this is what makes it *unknowable*. The two are not the same property and the floor alone would
    /// admit a key of thirty-two zeroes.
    public static let keyByteCount = 32

    private let service: String
    private let account: String

    /// The key, once it has been read or minted. The Keychain is the record; this only saves a
    /// round trip per request, and the value cannot change for the life of the process.
    private var cached: String?

    public init(service: String = "org.whoopsy.sync", account: String = "install-key") {
        self.service = service
        self.account = account
    }

    public func key() async throws -> String {
        if let cached { return cached }

        // The read comes first because after the first launch it is the only branch that runs, and
        // because it is what makes the mint conditional rather than unconditional.
        if let existing = try load() {
            cached = existing
            return existing
        }

        let minted = try mint()
        switch try store(minted) {
        case .stored:
            cached = minted
            return minted
        case let .alreadyPresent(existing):
            // Unreachable through this actor, which serialises the whole read-or-mint — and handled
            // anyway, because the consequence of getting it wrong is the orphan the protocol's own doc
            // describes. Returning `minted` here would hand back a key that is **not** the one on disk,
            // so every request would be filed under a partition nothing was ever written to, and both
            // halves would look perfectly healthy from inside the app.
            cached = existing
            return existing
        }
    }

    // MARK: - The Keychain, in three calls

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            // A stored item whose bytes are not UTF-8 is not a key this app wrote, and it is refused
            // rather than replaced: overwriting it would destroy whatever put it there, and returning
            // it would send bytes the Worker will hash into a partition nothing maps to.
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw SyncKeyStoreError.unavailable("the stored key is not readable text")
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SyncKeyStoreError.unavailable("reading the key failed (OSStatus \(status))")
        }
    }

    private func mint() throws -> String {
        var bytes = [UInt8](repeating: 0, count: Self.keyByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        guard status == errSecSuccess else {
            // Never a fallback generator. A key from a weaker source is a key someone else can arrive
            // at, and the failure it produces is not a broken sync but a silent collision with a
            // partition somebody else is reading.
            throw SyncKeyStoreError.unavailable("no random bytes are available (OSStatus \(status))")
        }

        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    private enum StoreResult {
        case stored
        /// Something else wrote first between this store's read and its write.
        case alreadyPresent(String)
    }

    private func store(_ key: String) throws -> StoreResult {
        var query = baseQuery
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return .stored
        case errSecDuplicateItem:
            guard let existing = try load() else {
                throw SyncKeyStoreError.unavailable("the key already exists but could not be read back")
            }
            return .alreadyPresent(existing)
        default:
            throw SyncKeyStoreError.unavailable("writing the key failed (OSStatus \(status))")
        }
    }
}
