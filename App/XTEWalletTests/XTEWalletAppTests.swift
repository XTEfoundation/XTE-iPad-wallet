import XCTest
import XTEWalletCore
@testable import XTEWallet

final class XTEWalletAppTests: XCTestCase {
    func testQRCodeForAddress() throws {
        let keys = WalletKeys.generate()
        let image = try XCTUnwrap(QRCode.image(for: keys.address.encoded()))
        XCTAssertGreaterThan(image.size.width, 100)
    }

    func testSidebarHasAllScreens() {
        XCTAssertEqual(SidebarItem.allCases.map(\.title), ["Wallet", "Send", "Receive", "Transactions", "Node", "Settings"])
    }

    func testWalletFileRoundTripHasNoSecrets() throws {
        let keys = WalletKeys.generate()
        let file = WalletFile(address: keys.address.encoded(), state: WalletState(startHeight: 5))
        let data = try JSONEncoder().encode(file)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains(keys.privateSpendKey.hex))
        XCTAssertFalse(json.contains(keys.privateViewKey.hex))
        XCTAssertEqual(try JSONDecoder().decode(WalletFile.self, from: data).state.startHeight, 5)
    }

    func testInfoPlist() {
        let info = Bundle.main.infoDictionary ?? [:]
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "1.0.1")
        XCTAssertNotNil(info["NSFaceIDUsageDescription"])
        let types = info["CFBundleURLTypes"] as? [[String: Any]]
        let schemes = types?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } ?? []
        XCTAssertTrue(schemes.contains("xte"))
        XCTAssertTrue(schemes.contains("traaitt"))
    }

    func testBackgroundRefreshIsDeclared() {
        let info = Bundle.main.infoDictionary ?? [:]
        let ids = info["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        XCTAssertTrue(ids.contains(PaymentNotifier.taskIdentifier))
        XCTAssertEqual(info["UIBackgroundModes"] as? [String], ["fetch"])
    }

    func testWatchOnlyWalletFileFlag() throws {
        let file = WalletFile(address: "a", state: WalletState(), viewOnly: true)
        let back = try JSONDecoder().decode(WalletFile.self, from: try JSONEncoder().encode(file))
        XCTAssertEqual(back.viewOnly, true)
    }

    func testSecurityDefaults() {
        XCTAssertTrue(SecurityPrefs.autoLockChoices.contains { $0.seconds == 0 })
    }
}
