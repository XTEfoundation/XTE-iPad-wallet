// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import XTEWalletCore

final class WalletBackupTests: XCTestCase {
    private let secrets = BackupSecrets(spendKey: String(repeating: "1", count: 64),
                                        viewKey: String(repeating: "2", count: 64),
                                        scanHeight: 2_000_000,
                                        createdAt: "2026-11-14T00:00:00.000Z")

    /// Vector produced by the React Native wallets (src/__tests__/backup.test.js, Node crypto).
    private let vectorTag = "0QeGbx+8ub3o/HzTecmslA=="
    private let vectorData = "Jk6XYrfgip1yGdHgvsq6SNPL7C5d5K0LkX05d558Jhz13FKmFjiJfFKmsfEXZaSN5fQ5q6FlFu7hVoTVPHiFkKrixvkpAuGgH+C5XOUBJFWtCuMSHCi1j2TzQzW21z/OiGcFh3w8/11vG9ZOLbbTqk7u6HOBOovLgH0Zt7ak+h58WXwEhgCLaGd4IP8kGTQt6mOH8W4ymnYvejF1hcGwr2OChL0ABpwKFyVeJ7399o4A0SdbmZSWp5sToL4TOcMZ/VXuqLkZ59sJgvojKJPhAuBEVOURvL/m"
    private let vectorKeyHex = "132b32271fe8ece4f027b0f8dec5ea9de5ea27795cfa71c1303060422c5a5340"

    func testPBKDF2MatchesNode() {
        let key = WalletBackup.pbkdf2SHA256(password: "vector password 1", salt: Data(repeating: 7, count: 16),
                                            iterations: 1000, keyLength: 32)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(), vectorKeyHex)
        let portable = WalletBackup.pbkdf2Portable(password: Data("vector password 1".utf8), salt: Data(repeating: 7, count: 16),
                                                   iterations: 1000, keyLength: 32)
        XCTAssertEqual(portable, key)
    }

    func testEncryptMatchesReactNativeVector() throws {
        let text = try WalletBackup.encrypt(secrets, address: "cashVECTOR", password: "vector password 1", coin: "XTCASH",
                                            iterations: 1000, salt: Data(repeating: 7, count: 16), iv: Data(repeating: 9, count: 12))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let cipher = try XCTUnwrap(json["cipher"] as? [String: Any])
        XCTAssertEqual(cipher["tag"] as? String, vectorTag)
        XCTAssertEqual(json["data"] as? String, vectorData)
        XCTAssertFalse(text.contains(secrets.spendKey))
    }

    func testDecryptReactNativeVector() throws {
        let text = """
        Backup from a phone:
        {"format":"traaitt-wallet-backup","version":1,"coin":"XTCASH","address":"cashVECTOR",\
        "kdf":{"name":"PBKDF2-HMAC-SHA256","iterations":1000,"salt":"BwcHBwcHBwcHBwcHBwcHBw=="},\
        "cipher":{"name":"AES-256-GCM","iv":"CQkJCQkJCQkJCQkJ","tag":"\(vectorTag)"},"data":"\(vectorData)"}
        """
        let out = try WalletBackup.decrypt(text, password: "vector password 1", expectedCoin: "XTCASH")
        XCTAssertEqual(out.address, "cashVECTOR")
        XCTAssertEqual(out.secrets, secrets)
        XCTAssertThrowsError(try WalletBackup.decrypt(text, password: "wrong password 1", expectedCoin: "XTCASH")) {
            XCTAssertEqual($0 as? WalletBackupError, .wrongPassword)
        }
        XCTAssertThrowsError(try WalletBackup.decrypt(text.replacingOccurrences(of: "cashVECTOR", with: "cashVECTOS"),
                                                      password: "vector password 1", expectedCoin: "XTCASH"))
        XCTAssertThrowsError(try WalletBackup.decrypt(text, password: "vector password 1", expectedCoin: "OTHER"))
    }

    func testRoundTripAndWeakPassword() throws {
        let text = try WalletBackup.encrypt(secrets, address: "addr", password: "correct horse battery", iterations: 2000)
        XCTAssertEqual(try WalletBackup.decrypt(text, password: "correct horse battery").secrets, secrets)
        XCTAssertThrowsError(try WalletBackup.encrypt(secrets, address: "addr", password: "short"))
        XCTAssertNotNil(WalletBackup.passwordProblem("long enough pw", confirm: "other"))
    }
}

final class ScanHeightTests: XCTestCase {
    func testInterpolatesBetweenCheckpoints() {
        let cps: [(height: UInt64, timestamp: UInt64)] = [(1, 1000), (101, 2000)]
        XCTAssertEqual(ScanHeight.approximateHeight(at: Date(timeIntervalSince1970: 500), checkpoints: cps), 0)
        XCTAssertEqual(ScanHeight.approximateHeight(at: Date(timeIntervalSince1970: 1500), checkpoints: cps), 51)
    }

    func testNeverPastTheTip() {
        let last = XTEConfig.scanHeightCheckpoints.last!
        let atLast = Date(timeIntervalSince1970: TimeInterval(last.timestamp))
        XCTAssertLessThanOrEqual(ScanHeight.scanHeight(forWalletCreatedAt: atLast, now: atLast), last.height)
        // A wallet "created" a week ago is a week of real blocks back, minus a day of margin.
        let weekAgo = atLast.addingTimeInterval(-7 * 86400)
        let h = ScanHeight.scanHeight(forWalletCreatedAt: weekAgo, now: atLast)
        XCTAssertLessThan(h, last.height)
        XCTAssertGreaterThan(h, last.height - 7 * 86400 / 20)
    }

    func testCheckpointsAreIncreasing() {
        let cps = XTEConfig.scanHeightCheckpoints
        XCTAssertGreaterThan(cps.count, 10)
        for i in 1..<cps.count {
            XCTAssertGreaterThan(cps[i].height, cps[i - 1].height)
            XCTAssertGreaterThan(cps[i].timestamp, cps[i - 1].timestamp)
        }
    }
}

private struct FakeLedger: LedgerTransport {
    let keys: WalletKeys
    func exchange(_ apdu: [UInt8]) async throws -> [UInt8] {
        XCTAssertEqual(apdu[0], 0xE0)
        switch apdu[1] {
        case 0x01: return [1, 2, 3, 0x90, 0x00]
        case 0x30: XCTAssertEqual(apdu[2], 1); return Array(keys.address.encoded().utf8) + [0x90, 0x00]
        case 0x11: XCTAssertEqual(apdu[2], 1); return keys.privateViewKey.bytes + [0x90, 0x00]
        default: return [0x6D, 0x00]
        }
    }
}

final class HardwareWalletTests: XCTestCase {
    func testWatchOnlyPayloadRoundTrip() throws {
        let keys = WalletKeys.generate()
        let p = WatchOnlyPayload(address: keys.address.encoded(), viewKey: keys.privateViewKey.hex, scanHeight: 42)
        let parsed = try WatchOnlyPayload.parse(p.encoded())
        XCTAssertEqual(parsed, p)
        let view = try parsed.keys()
        XCTAssertEqual(view.address.encoded(), keys.address.encoded())
        XCTAssertNil(view.scanner.privateSpendKey)
        XCTAssertThrowsError(try WatchOnlyPayload.parse(p.encoded(coin: "OTHER")))
        let other = WalletKeys.generate()
        XCTAssertThrowsError(try WatchOnlyPayload(address: keys.address.encoded(), viewKey: other.privateViewKey.hex, scanHeight: 0).keys())
    }

    func testLedgerClientOverFakeTransport() async throws {
        let keys = WalletKeys.generate()
        let client = LedgerClient(transport: FakeLedger(keys: keys))
        let version = try await client.version()
        XCTAssertEqual(version, "1.2.3")
        let view = try await client.watchOnlyKeys()
        XCTAssertEqual(view, ViewOnlyKeys(keys: keys))
        XCTAssertThrowsError(try LedgerClient.unwrap([0x69, 0x85])) { XCTAssertEqual($0 as? LedgerError, .rejected) }
        XCTAssertEqual(LedgerClient.apdu(.publicKeys), [0xE0, 0x10, 0, 0, 0])
    }

    func testSwapNotFaked() {
        XCTAssertTrue(SwapCatalog.providers.isEmpty)
        XCTAssertFalse(SwapCatalog.candidates.isEmpty)
        XCTAssertFalse(HardwareWalletProvider.all().first { $0.id == "ledger" }!.available)
    }
}

final class CancellationTests: XCTestCase {
    func testURLSessionCancellationIsNotAnError() {
        XCTAssertTrue(isCancellation(CancellationError()))
        XCTAssertTrue(isCancellation(URLError(.cancelled)))
        XCTAssertTrue(isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        XCTAssertFalse(isCancellation(URLError(.timedOut)))
        XCTAssertFalse(isCancellation(DaemonError.http(500)))
    }
}
