// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import Foundation
import Security
import XTEWalletCore

/// Stores the password-encrypted backup as a synchronizable Keychain item. iCloud Keychain
/// end-to-end encrypts it and syncs it to the user's other devices signed in to the same
/// Apple ID; no iCloud container or extra entitlement is needed. Only already-encrypted
/// backups (WalletBackup) are ever stored here.
enum CloudBackup {
    static let service = "io.traaitt.wallet.backup"
    static var account: String { "\(XTEConfig.ticker)-wallet-backup" }

    static func save(_ encryptedBackup: String) throws {
        delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(encryptedBackup.utf8),
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainStore.KeychainError.status(status) }
    }

    static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainStore.KeychainError.status(status) }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ] as CFDictionary)
    }
}
