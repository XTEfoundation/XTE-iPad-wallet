// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.
//
// Optional, password-encrypted wallet backups. Same format as the React Native
// wallets (src/Backup.js), so a backup made on a phone restores on an iPad and
// vice versa:
// {
//   "format": "traaitt-wallet-backup", "version": 1, "coin": "...", "address": "...",
//   "kdf": { "name": "PBKDF2-HMAC-SHA256", "iterations": 310000, "salt": base64(16) },
//   "cipher": { "name": "AES-256-GCM", "iv": base64(12), "tag": base64(16) },
//   "data": base64(ciphertext)
// }
// AAD = "traaitt-wallet-backup:v1:<coin>:<address>". Plaintext JSON
// { spendKey, viewKey, scanHeight, createdAt }.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

public struct BackupSecrets: Equatable, Sendable {
    public var spendKey: String
    public var viewKey: String
    public var scanHeight: UInt64
    public var createdAt: String

    public init(spendKey: String, viewKey: String, scanHeight: UInt64, createdAt: String) {
        self.spendKey = spendKey
        self.viewKey = viewKey
        self.scanHeight = scanHeight
        self.createdAt = createdAt
    }
}

public enum WalletBackupError: LocalizedError, Equatable {
    case notABackup, unsupportedVersion(Int), wrongCoin(String), unsupportedEncryption
    case weakPassword, wrongPassword, corrupt

    public var errorDescription: String? {
        switch self {
        case .notABackup: return "This is not a wallet backup."
        case .unsupportedVersion(let v): return "Unsupported backup version \(v)."
        case .wrongCoin(let c): return "This backup is for \(c), not \(XTEConfig.ticker)."
        case .unsupportedEncryption: return "Unsupported backup encryption."
        case .weakPassword: return "Use at least \(WalletBackup.minimumPasswordLength) characters."
        case .wrongPassword: return "Wrong password, or the backup was changed."
        case .corrupt: return "The backup is damaged."
        }
    }
}

public enum WalletBackup {
    public static let format = "traaitt-wallet-backup"
    public static let version = 1
    public static let iterations = 310_000
    public static let minimumPasswordLength = 10

    struct KDF: Codable { var name: String; var iterations: Int; var salt: String }
    struct Cipher: Codable { var name: String; var iv: String; var tag: String }
    struct Envelope: Codable {
        var format: String
        var version: Int
        var coin: String
        var address: String
        var kdf: KDF
        var cipher: Cipher
        var data: String
    }
    struct Plain: Codable { var spendKey: String; var viewKey: String; var scanHeight: UInt64; var createdAt: String }

    static func aad(coin: String, address: String) -> Data {
        Data("\(format):v\(version):\(coin):\(address)".utf8)
    }

    public static func passwordProblem(_ password: String, confirm: String? = nil) -> String? {
        if password.count < minimumPasswordLength { return WalletBackupError.weakPassword.errorDescription }
        if let confirm, confirm != password { return "The passwords do not match." }
        return nil
    }

    public static func encrypt(_ secrets: BackupSecrets, address: String, password: String,
                               coin: String = XTEConfig.ticker,
                               iterations: Int = iterations,
                               salt: Data? = nil, iv: Data? = nil) throws -> String {
        guard passwordProblem(password) == nil else { throw WalletBackupError.weakPassword }
        let salt = salt ?? randomBytes(16)
        let ivData = iv ?? randomBytes(12)
        let key = pbkdf2SHA256(password: password, salt: salt, iterations: iterations, keyLength: 32)
        // Field order matches JSON.stringify in the React Native wallets.
        let plaintext = "{\"spendKey\":\(jsonString(secrets.spendKey)),\"viewKey\":\(jsonString(secrets.viewKey)),"
            + "\"scanHeight\":\(secrets.scanHeight),\"createdAt\":\(jsonString(secrets.createdAt))}"
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: SymmetricKey(data: key),
                                      nonce: AES.GCM.Nonce(data: ivData),
                                      authenticating: aad(coin: coin, address: address))
        let envelope = Envelope(format: format, version: version, coin: coin, address: address,
                                kdf: KDF(name: "PBKDF2-HMAC-SHA256", iterations: iterations, salt: salt.base64EncodedString()),
                                cipher: Cipher(name: "AES-256-GCM", iv: ivData.base64EncodedString(),
                                               tag: sealed.tag.base64EncodedString()),
                                data: sealed.ciphertext.base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(envelope), as: UTF8.self)
    }

    /// Finds the backup JSON inside a shared message (mail body, note, file).
    public static func extract(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end])
    }

    /// Parses without decrypting: returns (coin, address).
    public static func inspect(_ text: String, expectedCoin: String = XTEConfig.ticker) throws -> (coin: String, address: String) {
        let e = try envelope(text, expectedCoin: expectedCoin)
        return (e.coin, e.address)
    }

    static func envelope(_ text: String, expectedCoin: String) throws -> Envelope {
        guard let json = extract(from: text),
              let e = try? JSONDecoder().decode(Envelope.self, from: Data(json.utf8)),
              e.format == format else { throw WalletBackupError.notABackup }
        guard e.version == version else { throw WalletBackupError.unsupportedVersion(e.version) }
        guard e.coin == expectedCoin else { throw WalletBackupError.wrongCoin(e.coin) }
        guard e.kdf.name == "PBKDF2-HMAC-SHA256", e.cipher.name == "AES-256-GCM",
              e.kdf.iterations > 0, e.kdf.iterations <= 10_000_000 else { throw WalletBackupError.unsupportedEncryption }
        return e
    }

    public static func decrypt(_ text: String, password: String,
                               expectedCoin: String = XTEConfig.ticker) throws -> (address: String, secrets: BackupSecrets) {
        let e = try envelope(text, expectedCoin: expectedCoin)
        guard let salt = Data(base64Encoded: e.kdf.salt), let iv = Data(base64Encoded: e.cipher.iv),
              let tag = Data(base64Encoded: e.cipher.tag), let data = Data(base64Encoded: e.data) else {
            throw WalletBackupError.corrupt
        }
        let key = pbkdf2SHA256(password: password, salt: salt, iterations: e.kdf.iterations, keyLength: 32)
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: data, tag: tag)
            plain = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad(coin: e.coin, address: e.address))
        } catch {
            throw WalletBackupError.wrongPassword
        }
        guard let p = try? JSONDecoder().decode(Plain.self, from: plain) else { throw WalletBackupError.corrupt }
        return (e.address, BackupSecrets(spendKey: p.spendKey, viewKey: p.viewKey, scanHeight: p.scanHeight, createdAt: p.createdAt))
    }

    // MARK: Primitives

    public static func pbkdf2SHA256(password: String, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let pass = Data(password.utf8)
        #if canImport(CommonCrypto)
        var out = Data(count: keyLength)
        let rc = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                pass.withUnsafeBytes { passPtr in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passPtr.baseAddress?.assumingMemoryBound(to: Int8.self), pass.count,
                                         saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                         outPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength)
                }
            }
        }
        if rc == kCCSuccess { return out }
        #endif
        return pbkdf2Portable(password: pass, salt: salt, iterations: iterations, keyLength: keyLength)
    }

    /// RFC 8018 PBKDF2 with HMAC-SHA256 (used where CommonCrypto is unavailable, and in tests).
    public static func pbkdf2Portable(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let key = SymmetricKey(data: password)
        var derived = Data()
        var block: UInt32 = 1
        while derived.count < keyLength {
            var input = salt
            withUnsafeBytes(of: block.bigEndian) { input.append(contentsOf: $0) }
            var u = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
            var t = [UInt8](u)
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    u.withUnsafeBytes { bytes in
                        for i in 0..<t.count { t[i] ^= bytes[i] }
                    }
                }
            }
            derived.append(contentsOf: t)
            block += 1
        }
        return derived.prefix(keyLength)
    }

    static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    static func jsonString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}
