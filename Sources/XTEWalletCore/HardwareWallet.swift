// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.
//
// Hardware wallet and watch-only support, shared with the React Native wallets
// (src/HardwareWallet.js).
//
// 1. Ledger: the TurtleCoin Ledger app protocol (CLA 0xE0), which a XTE/XTE
//    build of the app (address prefix changed) would speak. No such app is in
//    Ledger Live yet and this build has no Bluetooth transport, so the Ledger
//    provider reports itself unavailable.
// 2. Offline phone / iPad (air-gapped QR signer): the spend key stays on an
//    offline device; this device imports a watch-only wallet (address + private
//    view key) from its "xtewatch:" code and shows incoming payments.

import Foundation

/// Keys of a watch-only wallet: sees incoming payments, cannot spend or see spends.
public struct ViewOnlyKeys: Codable, Equatable, Sendable {
    public let publicSpendKey: PublicKey
    public let privateViewKey: SecretKey

    public init(address: String, privateViewKey: SecretKey) throws {
        let decoded = try XTEAddress.decode(address)
        guard decoded.paymentID == nil else { throw WatchOnlyError.integratedAddress }
        guard let derivedView = try? CNCrypto.secretKeyToPublicKey(privateViewKey),
              derivedView == decoded.publicViewKey else { throw WatchOnlyError.viewKeyMismatch }
        self.publicSpendKey = decoded.publicSpendKey
        self.privateViewKey = privateViewKey
    }

    public init(keys: WalletKeys) {
        publicSpendKey = keys.publicSpendKey
        privateViewKey = keys.privateViewKey
    }

    public var address: XTEAddress {
        // Valid: the view key was checked against the address at init.
        XTEAddress(publicSpendKey: publicSpendKey, publicViewKey: try! CNCrypto.secretKeyToPublicKey(privateViewKey))
    }

    public var scanner: BlockScanner {
        BlockScanner(publicSpendKey: publicSpendKey, privateViewKey: privateViewKey, privateSpendKey: nil)
    }
}

public enum WatchOnlyError: LocalizedError, Equatable {
    case notWatchOnlyCode, wrongCoin(String), damaged, integratedAddress, viewKeyMismatch

    public var errorDescription: String? {
        switch self {
        case .notWatchOnlyCode: return "This is not a watch-only wallet code."
        case .wrongCoin(let c): return "This code is for \(c), not \(XTEConfig.ticker)."
        case .damaged: return "The watch-only code is damaged."
        case .integratedAddress: return "Use the standard wallet address, not an integrated one."
        case .viewKeyMismatch: return "The private view key does not belong to this address."
        }
    }
}

public struct WatchOnlyPayload: Equatable, Sendable {
    public static let prefix = "xtewatch:"

    public var address: String
    public var viewKey: String
    public var scanHeight: UInt64

    public init(address: String, viewKey: String, scanHeight: UInt64) {
        self.address = address
        self.viewKey = viewKey
        self.scanHeight = scanHeight
    }

    private struct Body: Codable { var coin: String; var address: String; var viewKey: String; var scanHeight: UInt64 }

    /// Same text as the React Native wallets produce (JSON.stringify field order).
    public func encoded(coin: String = XTEConfig.ticker) -> String {
        Self.prefix + "{\"coin\":\"\(coin)\",\"address\":\"\(address)\",\"viewKey\":\"\(viewKey)\",\"scanHeight\":\(scanHeight)}"
    }

    public static func parse(_ text: String, expectedCoin: String = XTEConfig.ticker) throws -> WatchOnlyPayload {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix(prefix) else { throw WatchOnlyError.notWatchOnlyCode }
        guard let body = try? JSONDecoder().decode(Body.self, from: Data(t.dropFirst(prefix.count).utf8)) else {
            throw WatchOnlyError.damaged
        }
        guard body.coin == expectedCoin else { throw WatchOnlyError.wrongCoin(body.coin) }
        guard body.viewKey.count == 64, SecretKey(hex: body.viewKey) != nil else { throw WatchOnlyError.damaged }
        return WatchOnlyPayload(address: body.address, viewKey: body.viewKey, scanHeight: body.scanHeight)
    }

    public func keys() throws -> ViewOnlyKeys {
        guard let vk = SecretKey(hex: viewKey) else { throw WatchOnlyError.damaged }
        return try ViewOnlyKeys(address: address, privateViewKey: vk)
    }
}

// MARK: Ledger

public enum LedgerError: LocalizedError, Equatable {
    case badResponse, appNotOpen, rejected, device(UInt16), noTransport

    public var errorDescription: String? {
        switch self {
        case .badResponse: return "Empty response from the Ledger."
        case .appNotOpen: return "Open the \(XTEConfig.ticker) app on your Ledger."
        case .rejected: return "Rejected on the Ledger."
        case .device(let sw): return "Ledger error 0x\(String(sw, radix: 16))."
        case .noTransport: return "Ledger support is not included in this build."
        }
    }
}

/// Anything that can exchange APDUs with a Ledger (Bluetooth, USB, a test double).
public protocol LedgerTransport: Sendable {
    func exchange(_ apdu: [UInt8]) async throws -> [UInt8]
}

public struct LedgerClient: Sendable {
    public static let cla: UInt8 = 0xE0
    public enum Ins: UInt8 {
        case version = 0x01, ident = 0x05, publicKeys = 0x10, viewSecretKey = 0x11, address = 0x30
        case txState = 0x70, txStart = 0x71, txStartInputLoad = 0x72, txLoadInput = 0x73
        case txStartOutputLoad = 0x74, txLoadOutput = 0x75, txFinalizePrefix = 0x76, txSign = 0x77
        case txDump = 0x78, txReset = 0x79
    }

    public let transport: LedgerTransport
    public init(transport: LedgerTransport) { self.transport = transport }

    public static func apdu(_ ins: Ins, confirm: Bool = false, p2: UInt8 = 0, data: [UInt8] = []) -> [UInt8] {
        [cla, ins.rawValue, confirm ? 1 : 0, p2, UInt8(data.count)] + data
    }

    public static func unwrap(_ response: [UInt8]) throws -> [UInt8] {
        guard response.count >= 2 else { throw LedgerError.badResponse }
        let sw = UInt16(response[response.count - 2]) << 8 | UInt16(response[response.count - 1])
        switch sw {
        case 0x9000: return Array(response.dropLast(2))
        case 0x6E00, 0x6D00: throw LedgerError.appNotOpen
        case 0x6985: throw LedgerError.rejected
        default: throw LedgerError.device(sw)
        }
    }

    func send(_ ins: Ins, confirm: Bool = false) async throws -> [UInt8] {
        try Self.unwrap(try await transport.exchange(Self.apdu(ins, confirm: confirm)))
    }

    public func version() async throws -> String {
        let v = try await send(.version)
        guard v.count >= 3 else { throw LedgerError.badResponse }
        return "\(v[0]).\(v[1]).\(v[2])"
    }

    public func address(confirm: Bool = true) async throws -> String {
        String(decoding: try await send(.address, confirm: confirm), as: UTF8.self)
    }

    /// Always asks for confirmation on the device.
    public func privateViewKey() async throws -> SecretKey {
        let r = try await send(.viewSecretKey, confirm: true)
        guard r.count >= 32, let k = SecretKey(bytes: Array(r.prefix(32))) else { throw LedgerError.badResponse }
        return k
    }

    /// Reads address + view key (both confirmed on the device) for a watch-only wallet.
    public func watchOnlyKeys() async throws -> ViewOnlyKeys {
        _ = try await version()
        let address = try await address(confirm: true)
        return try ViewOnlyKeys(address: address, privateViewKey: try await privateViewKey())
    }
}

public struct HardwareWalletProvider: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let available: Bool
    public let unavailableReason: String?

    public static func all(ledgerTransportAvailable: Bool = false) -> [HardwareWalletProvider] {
        [
            HardwareWalletProvider(
                id: "ledger", name: "Ledger",
                detail: "Nano X, Stax and Flex over Bluetooth.",
                available: ledgerTransportAvailable,
                unavailableReason: ledgerTransportAvailable ? nil :
                    "The \(XTEConfig.ticker) Ledger app is not in Ledger Live (it must be side-loaded from the XTE Foundation build of the TurtleCoin Ledger app), and this build has no Bluetooth transport for it yet."),
            HardwareWalletProvider(
                id: "qr-signer", name: "Offline phone or iPad (QR)",
                detail: "Keep the spend key on a device that stays offline. This device imports a watch-only wallet from its code and shows incoming payments.",
                available: true, unavailableReason: nil),
        ]
    }
}
