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
        /// The keychain is locked. It may well unlock soon, so this can be tried again.
        case keychainLocked
        /// Someone clicked Deny when macOS asked, so it's theirs to allow.
        case accessDenied
        /// The keychain couldn't be read for some other reason.
        case keychainUnavailable(OSStatus)
        case couldNotCreate(OSStatus)
    }

    /// Test runs pass their own, so they can't touch the real key.
    nonisolated(unsafe) static var service = "com.kenansulayman.Elodie.vault"
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
        case errSecInteractionNotAllowed, errSecNotAvailable, errSecNoSuchKeychain:
            // None of these mean the key is gone, so they must not lead to a new key.
            throw .keychainLocked
        case errSecAuthFailed, errSecUserCanceled:
            throw .accessDenied
        default:
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
        attributes[kSecAttrLabel] = "Elodie recording key"
        attributes[kSecAttrDescription] = "Decrypts your Elodie recordings."
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw .couldNotCreate(status)
        }
        return bytes
    }

    /// Puts a key back, replacing anything there. Only do this once the key has been shown
    /// to open the vault.
    static func restore(_ key: Data) throws(Failure) {
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData] = key
        attributes[kSecAttrLabel] = "Elodie recording key"
        attributes[kSecAttrDescription] = "Decrypts your Elodie recordings."
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw .couldNotCreate(status)
        }
    }

    /// Removes the key, when the recordings it opened have been deleted.
    static func remove() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
