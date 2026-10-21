import Foundation
import Security

/// The sync destination, kept in the Keychain so it survives an app uninstall.
///
/// **Why not `UserDefaults`.** `UserDefaults` is wiped when the app is deleted, which is what made
/// "sync API selected" silently reset to `.device` on a reinstall — and a fresh install that no longer
/// knew it was a cloud install could not read its own rows back. The Keychain survives a delete on this
/// device, on the same `AfterFirstUnlockThisDeviceOnly` attribute the install key uses, so the
/// destination is the one settings value that lives here rather than in `UserDefaults`.
///
/// **Best-effort, not throwing.** The settings protocol does not throw, and the worst a failed Keychain
/// write can do is leave a reinstall at `.device` — the state that sends nothing anywhere, which is the
/// safe direction to fall.
public actor KeychainDestinationStore: DestinationStore {

    private let service: String
    private let account: String

    public init(service: String = "org.whoopsy.sync", account: String = "destination") {
        self.service = service
        self.account = account
    }

    /// The stored destination, or `nil` when nothing was ever written or the value is unreadable.
    public func load() -> SyncSettings.Destination? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return SyncSettings.Destination(rawValue: raw)
    }

    /// Upsert the destination — add it if absent, replace it if present — so switching back to
    /// `.device` updates rather than leaving a stale `.cloud` behind.
    public func save(_ destination: SyncSettings.Destination) {
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = Data(destination.rawValue.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecDuplicateItem else { return }
        SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: Data(destination.rawValue.utf8)] as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
