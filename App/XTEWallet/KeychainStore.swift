// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import Foundation
import LocalAuthentication
import Security
import XTEWalletCore

/// The wallet as stored: full keys, or a watch-only wallet (address + private view key).
enum StoredWallet {
    case full(WalletKeys)
    case viewOnly(ViewOnlyKeys)

    var address: String {
        switch self {
        case .full(let k): return k.address.encoded()
        case .viewOnly(let v): return v.address.encoded()
        }
    }
}

/// Stores the private spend/view keys in the iOS Keychain. Items are bound to this device
/// (never synced to iCloud) and every read requires Face ID / Touch ID or the device passcode.
/// With the optional hardware vault the item is additionally encrypted by a Secure Enclave key.
enum KeychainStore {
    static let service = "io.traaitt.osx.ipad.wallet"
    static let account = "primary-wallet-keys"
    /// Opt-in (notifications): view-only keys readable in the background, without Face ID.
    static let notifyAccount = "notification-view-keys"

    struct StoredKeys: Codable {
        let privateSpendKey: String?
        let privateViewKey: String
        let publicSpendKey: String?
    }

    enum KeychainError: LocalizedError {
        case status(OSStatus)
        case accessControl
        case corrupt

        var errorDescription: String? {
            switch self {
            case .status(let s):
                if s == errSecUserCanceled { return "Authentication cancelled." }
                if s == errSecAuthFailed { return "Authentication failed." }
                return (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)"
            case .accessControl: return "Could not create keychain access control."
            case .corrupt: return "Stored wallet keys are unreadable."
            }
        }
    }

    static func save(_ keys: WalletKeys) throws {
        try write(StoredKeys(privateSpendKey: keys.privateSpendKey.hex, privateViewKey: keys.privateViewKey.hex, publicSpendKey: nil))
    }

    static func save(viewOnly keys: ViewOnlyKeys) throws {
        try write(StoredKeys(privateSpendKey: nil, privateViewKey: keys.privateViewKey.hex, publicSpendKey: keys.publicSpendKey.hex))
    }

    static func save(_ wallet: StoredWallet) throws {
        switch wallet {
        case .full(let k): try save(k)
        case .viewOnly(let v): try save(viewOnly: v)
        }
    }

    private static func write(_ stored: StoredKeys) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error) else {
            throw KeychainError.accessControl
        }
        var payload = try JSONEncoder().encode(stored)
        if SecurityPrefs.shared.hardwareVault {
            payload = try SecureEnclaveVault.seal(payload)
        }
        try? delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessControl as String: access,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecValueData as String: payload,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// Prompts for biometrics / passcode, then returns the keys.
    static func load(reason: String) throws -> WalletKeys {
        guard case .full(let keys) = try loadWallet(reason: reason) else { throw TransferError.viewOnlyWallet }
        return keys
    }

    static func loadWallet(reason: String) throws -> StoredWallet {
        let context = LAContext()
        context.localizedReason = reason
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let raw = item as? Data else { throw KeychainError.status(status) }
        let data = try SecureEnclaveVault.open(raw)
        guard let stored = try? JSONDecoder().decode(StoredKeys.self, from: data) else { throw KeychainError.corrupt }
        if let spend = stored.privateSpendKey {
            return .full(try WalletKeys.fromKeys(privateSpendKeyHex: spend, privateViewKeyHex: stored.privateViewKey))
        }
        guard let ps = stored.publicSpendKey.flatMap(PublicKey.init(hex:)),
              let vk = SecretKey(hex: stored.privateViewKey),
              let pv = try? CNCrypto.secretKeyToPublicKey(vk) else { throw KeychainError.corrupt }
        return .viewOnly(try ViewOnlyKeys(address: XTEAddress(publicSpendKey: ps, publicViewKey: pv).encoded(), privateViewKey: vk))
    }

    // MARK: Background notifications (opt-in)

    static func saveNotificationKeys(_ keys: ViewOnlyKeys) throws {
        deleteNotificationKeys()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: notifyAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecValueData as String: try JSONEncoder().encode(keys),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    static func loadNotificationKeys() -> ViewOnlyKeys? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: notifyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ViewOnlyKeys.self, from: data)
    }

    static func deleteNotificationKeys() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: notifyAccount,
        ] as CFDictionary)
    }

    static func exists() -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }

    /// Re-authenticates the user without reading keys (used before showing secrets).
    static func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw error ?? KeychainError.accessControl
        }
        try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    }
}
