// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.
//
// "Swap from XMR" through an external instant-swap service. Mirrors
// src/Swap.js in the React Native wallets.
//
// Checked 2026-11-14: no instant-swap service lists XTE or XTE (ChangeNOW,
// Exolix, FixedFloat: XMR only; SimpleSwap, StealthEX, Trocador: no traaitt
// coins / partner key needed; NonKYC lists both but marks them "No longer
// supported"). The screen therefore shows "not available yet" until a
// provider is configured; nothing is faked.

import Foundation

public struct SwapQuote: Equatable, Sendable {
    public var fromAmount: Decimal
    public var estimatedToAmount: Decimal
    public var provider: String
}

public struct SwapOrder: Equatable, Sendable {
    public var id: String
    public var depositAddress: String
    public var depositAmount: Decimal
    public var status: String
}

/// An external exchange that can swap XMR into this coin. Implementations must
/// never receive wallet keys: only the payout address.
public protocol SwapProvider: Sendable {
    var name: String { get }
    func quote(fromXMR amount: Decimal) async throws -> SwapQuote
    func createOrder(fromXMR amount: Decimal, payoutAddress: String, refundAddress: String?) async throws -> SwapOrder
    func status(of orderID: String) async throws -> String
}

public enum SwapCatalog {
    /// Configured providers. Empty until an exchange lists the coin and its API terms are accepted.
    public static let providers: [any SwapProvider] = []

    public struct Candidate: Sendable, Identifiable {
        public let name: String
        public let needs: String
        public let url: String
        public var id: String { name }
    }

    public static let candidates: [Candidate] = [
        Candidate(name: "ChangeNOW", needs: "List \(XTEConfig.ticker) (has XMR)", url: "https://changenow.io"),
        Candidate(name: "Exolix", needs: "List \(XTEConfig.ticker) (has XMR)", url: "https://exolix.com"),
        Candidate(name: "FixedFloat", needs: "List \(XTEConfig.ticker) (has XMR)", url: "https://ff.io"),
        Candidate(name: "SimpleSwap", needs: "List \(XTEConfig.ticker); partner API key", url: "https://simpleswap.io"),
        Candidate(name: "StealthEX", needs: "List \(XTEConfig.ticker); partner API key", url: "https://stealthex.io"),
        Candidate(name: "Trocador", needs: "A listed exchange behind it; API key", url: "https://trocador.app"),
        Candidate(name: "NonKYC (exchange)", needs: "Re-activate the XTE / XTE markets", url: "https://nonkyc.io"),
    ]
}
