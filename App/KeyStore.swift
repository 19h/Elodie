import Foundation
import Security

/// Keeps the vault's master key in the login keychain.
///
/// The key decides whether years of history can be read, so the one rule here is that
/// a key is only ever created for a vault that doesn't exist yet. If a vault exists and
/// its key can't be read, that's an error to show, because creating a new key would
/// silently orphan everything.
enum KeyStore {
    enum Failure: Error, Equatable {
        /// A vault exists, but its key isn't in the keychain.
        case keyMissing
        /// The keychain couldn't be read right now, for example because it's locked.
        case keychainUnavailable(OSStatus)
        case couldNotCreate(OSStatus)
    }

    private static let service = "app.remind.vault"
    private static let account = "master-key"

    private static var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    /// Returns the key for a vault, creating one only if the vault is new.
    static func key(vaultExists: Bool) throws(Failure) -> Data {
        var query = baseQuery
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, data.count == 32 else {
                throw .keychainUnavailable(errSecDecode)
            }
            return data
        case errSecItemNotFound:
            guard !vaultExists else { throw .keyMissing }
            return try create()
        default:
            // Locked, or otherwise unavailable. This isn't the same as missing, so it
            // must not lead to a new key.
            throw .keychainUnavailable(status)
        }
    }

    private static func create() throws(Failure) -> Data {
        var bytes = Data(count: 32)
        let randomStatus = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            throw .couldNotCreate(randomStatus)
        }
        var attributes = baseQuery
        attributes[kSecValueData] = bytes
        attributes[kSecAttrLabel] = "Remind recording key"
        attributes[kSecAttrDescription] = "Decrypts your Remind recordings."
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw .couldNotCreate(status)
        }
        return bytes
    }

    /// The key as text for safekeeping, in groups that are easy to copy accurately.
    static func recoveryText(for key: Data) -> String {
        let hex = key.map { String(format: "%02X", $0) }.joined()
        let groups = stride(from: 0, to: hex.count, by: 8).map { start -> String in
            let from = hex.index(hex.startIndex, offsetBy: start)
            let to = hex.index(from, offsetBy: min(8, hex.count - start))
            return String(hex[from..<to])
        }
        return groups.joined(separator: "-")
    }
}
