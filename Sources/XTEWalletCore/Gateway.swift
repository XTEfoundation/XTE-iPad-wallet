// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.
//
// Fast sync path through xte-rpc-gateway (XTEfoundation/xte-rpc-gateway): an
// Ethereum-style JSON-RPC 2.0 API at https://<node host>/rpc/<coin>. Its
// <coin>_syncBlocks returns up to 1000 blocks per call from a server-side cache.
// The wallet detects it with GET /rpc/<coin>/health and falls back to the daemon's
// REST API (/getwalletsyncdata) when the node has no gateway or a call fails.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GatewayHealth: Decodable, Equatable, Sendable {
    public let status: String
    public let gateway: String
    public let coin: String
    public let apiVersion: Int
    public let topHeight: UInt64?
    public let maxSyncBlocks: UInt64?

    /// True when this is a compatible, healthy gateway for our coin.
    public var isUsable: Bool {
        gateway == "xte-rpc-gateway" && coin == XTEConfig.gatewayNamespace && apiVersion == 1 && status == "ok"
    }
}

public enum GatewayError: Error, Equatable, LocalizedError {
    case rpc(Int, String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .rpc(let code, let message): return "Gateway error \(code): \(message)"
        case .badResponse: return "Unexpected gateway response"
        }
    }
}

public enum Gateway {
    /// https://host[:port]/rpc/<coin> for a node (any proxy path on the node is ignored:
    /// the gateway lives at the host root).
    public static func endpoint(for node: NodeInfo) -> URL {
        var c = URLComponents()
        c.scheme = node.ssl ? "https" : "http"
        c.host = node.host
        if !((node.ssl && node.port == 443) || (!node.ssl && node.port == 80)) { c.port = node.port }
        c.path = "/rpc/" + XTEConfig.gatewayNamespace
        return c.url!
    }

    public static func syncRequestBody(checkpoints: [Hash32], startHeight: UInt64, startTimestamp: UInt64,
                                       blockCount: UInt64, skipCoinbase: Bool) -> Data {
        var p: [String: Any] = ["blockCount": blockCount, "skipCoinbase": skipCoinbase]
        if !checkpoints.isEmpty { p["checkpoints"] = checkpoints.map(\.hex) }
        p["startHeight"] = startHeight
        // startTimestamp is never sent: the gateway cannot resolve it (the call hangs ~30 s and ends
        // with -32000 "daemon read failed"). Timestamp-only requests go to REST, see isTimestampOnly.
        let body: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": XTEConfig.gatewayNamespace + "_syncBlocks", "params": [p]]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    /// A fresh wallet that only knows its creation time (no block scanned yet).
    public static func isTimestampOnly(checkpoints: [Hash32], startHeight: UInt64, startTimestamp: UInt64) -> Bool {
        startTimestamp > 0 && startHeight == 0 && checkpoints.isEmpty
    }

    /// Cold 1000-block ranges with coinbase take 10-15 s on the server, more on mobile data.
    public static let syncTimeout: TimeInterval = 90

    struct RPCErrorBody: Decodable { let code: Int; let message: String }
    struct SyncResult: Decodable {
        let items: [SyncBlock]
        let synced: Bool
        let topBlock: SyncTopBlock?
        let nextHeight: UInt64?
    }
    struct Envelope<T: Decodable>: Decodable { let result: T?; let error: RPCErrorBody? }

    /// Decodes a syncBlocks response into the same shape as /getwalletsyncdata.
    public static func decodeSync(_ data: Data) throws -> WalletSyncResponse {
        let env: Envelope<SyncResult>
        do { env = try JSONDecoder().decode(Envelope<SyncResult>.self, from: data) } catch {
            throw DaemonError.decoding(String(describing: error))
        }
        if let e = env.error { throw GatewayError.rpc(e.code, e.message) }
        guard let r = env.result else { throw GatewayError.badResponse }
        return WalletSyncResponse(status: "OK", items: r.items, synced: r.synced, topBlock: r.topBlock)
    }
}

/// Remembers per node whether it has a usable gateway (shared by all DaemonClients).
public actor GatewayRegistry {
    public static let shared = GatewayRegistry()

    enum Entry {
        case available(URL, Date)
        case unavailable(Date)
    }
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<URL?, Never>] = [:]
    private var failures: [String: Int] = [:]
    public var recheckAvailable: TimeInterval = 30 * 60
    /// Short: one slow answer on a mobile link must not keep the wallet on the slow REST path.
    public var retryUnavailable: TimeInterval = 2 * 60
    /// Consecutive transport failures before the gateway is skipped for retryUnavailable.
    public var failuresBeforeDisable = 2

    public init() {}

    private func key(_ node: NodeInfo) -> String { Gateway.endpoint(for: node).absoluteString }

    /// The gateway URL when the node has a healthy gateway, otherwise nil (use REST).
    public func endpoint(for node: NodeInfo, session: URLSession) async -> URL? {
        let k = key(node)
        switch entries[k] {
        case .available(let url, let at) where Date().timeIntervalSince(at) < recheckAvailable: return url
        case .unavailable(let until) where Date() < until: return nil
        default: break
        }
        if let t = inFlight[k] { return await t.value }
        let url = Gateway.endpoint(for: node)
        let t = Task<URL?, Never> { await Self.probe(url, session: session) ? url : nil }
        inFlight[k] = t
        let result = await t.value
        inFlight[k] = nil
        entries[k] = result.map { .available($0, Date()) } ?? .unavailable(Date().addingTimeInterval(retryUnavailable))
        return result
    }

    /// Called after a transport/HTTP failure of a gateway call. That call falls back to REST;
    /// only repeated failures make the wallet skip the gateway, and only for retryUnavailable.
    /// (A JSON-RPC error means the gateway is up: callers fall back for that call only.)
    public func markFailed(_ node: NodeInfo) {
        let k = key(node)
        let n = (failures[k] ?? 0) + 1
        if n >= failuresBeforeDisable {
            entries[k] = .unavailable(Date().addingTimeInterval(retryUnavailable))
            failures[k] = 0
        } else {
            failures[k] = n
        }
    }

    public func markSucceeded(_ node: NodeInfo, url: URL) {
        let k = key(node)
        failures[k] = 0
        entries[k] = .available(url, Date())
    }

    public func isActive(for node: NodeInfo) -> Bool {
        if case .available = entries[key(node)] { return true }
        return false
    }

    public func reset() { entries = [:]; failures = [:] }

    static func probe(_ url: URL, session: URLSession) async -> Bool {
        var req = URLRequest(url: url.appendingPathComponent("health"))
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let h = try? JSONDecoder().decode(GatewayHealth.self, from: data) else { return false }
        return h.isUsable
    }
}
