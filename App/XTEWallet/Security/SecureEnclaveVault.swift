// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import Foundation
import Security

/// Hardware vault: an EC P-256 key generated inside the Secure Enclave (it never leaves
/// the chip) encrypts the wallet keys with ECIES (X9.63 SHA-256, AES-GCM) before they are
/// written to the Keychain. Same scheme as the React Native wallets' XTESecurity module.
/// Falls back to a Keychain-held key where there is no Secure Enclave (simulator).
enum SecureEnclaveVault {
    static let prefix = Data("XTEVAULT1:".utf8)
    static var tag: Data { Data("\(KeychainStore.service).vault.v1".utf8) }
    static let algorithm: SecKeyAlgorithm = .eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    enum VaultError: LocalizedError {
        case unavailable, failed(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "The hardware vault key is not available."
            case .failed(let m): return m
            }
        }
    }

    /// "Secure Enclave" or "Keychain" (no enclave on this device), nil if no key yet.
    static var level: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecReturnAttributes as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let attrs = out as? [String: Any] else { return nil }
        return (attrs[kSecAttrTokenID as String] as? String) == (kSecAttrTokenIDSecureEnclave as String) ? "Secure Enclave" : "Keychain"
    }

    private static func existingKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let out else { return nil }
        return (out as! SecKey)
    }

    static func privateKey() throws -> SecKey {
        if let k = existingKey() { return k }
        for enclave in [true, false] {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                enclave ? .privateKeyUsage : [], &error) else { continue }
            var attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: tag,
                    kSecAttrAccessControl as String: access,
                ] as [String: Any],
            ]
            if enclave { attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave }
            if let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) { return key }
        }
        throw VaultError.unavailable
    }

    static func isSealed(_ data: Data) -> Bool { data.starts(with: prefix) }

    static func seal(_ plaintext: Data) throws -> Data {
        guard let pub = SecKeyCopyPublicKey(try privateKey()) else { throw VaultError.unavailable }
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(pub, algorithm, plaintext as CFData, &error) as Data? else {
            throw VaultError.failed(error?.takeRetainedValue().localizedDescription ?? "Encryption failed")
        }
        return prefix + cipher
    }

    static func open(_ sealed: Data) throws -> Data {
        guard isSealed(sealed) else { return sealed }
        guard let key = existingKey() else { throw VaultError.unavailable }
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(key, algorithm, sealed.dropFirst(prefix.count) as CFData, &error) as Data? else {
            throw VaultError.failed(error?.takeRetainedValue().localizedDescription ?? "Decryption failed")
        }
        return plain
    }

    static func deleteKey() {
        SecItemDelete([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag] as CFDictionary)
    }
}
