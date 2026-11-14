// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.
//
// HTTP/JSON client for the traaitt daemon (XTEnetwork). Endpoints and payloads
// mirror traaitt/src/nigel/Nigel.cpp (the C++ wallet backend's node client) and
// traaitt/src/rpc/RpcServer.cpp.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct NodeInfo: Codable, Hashable, Identifiable, Sendable {
    public var name: String
    public var host: String
    public var port: Int
    public var ssl: Bool

    public var id: String { "\(host):\(port)" }

    public init(name: String, host: String, port: Int, ssl: Bool) {
        self.name = name
        self.host = host
        self.port = port
        self.ssl = ssl
    }

    public var baseURL: URL {
        var c = URLComponents()
        c.scheme = ssl ? "https" : "http"
        c.host = host
        if !((ssl && port == 443) || (!ssl && port == 80)) { c.port = port }
        return c.url!
    }

    enum CodingKeys: String, CodingKey { case name, url, host, port, ssl }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        if let h = try c.decodeIfPresent(String.self, forKey: .host) {
            host = h
        } else {
            host = try c.decode(String.self, forKey: .url)
        }
        port = try c.decode(Int.self, forKey: .port)
        ssl = try c.decodeIfPresent(Bool.self, forKey: .ssl) ?? false
        if name.isEmpty { name = host }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .url)
        try c.encode(port, forKey: .port)
        try c.encode(ssl, forKey: .ssl)
    }
}

public struct NodeList: Decodable {
    public let nodes: [NodeInfo]

    public static func parse(_ data: Data) throws -> [NodeInfo] {
        try JSONDecoder().decode(NodeList.self, from: data).nodes
    }
}

public struct DaemonInfo: Decodable, Equatable, Sendable {
    public let height: UInt64
    public let networkHeight: UInt64
    public let synced: Bool?
    public let incomingConnections: UInt64?
    public let outgoingConnections: UInt64?
    public let difficulty: UInt64?
    public let version: String?
    public let hashrate: UInt64?

    enum CodingKeys: String, CodingKey {
        case height
        case networkHeight = "network_height"
        case synced
        case incomingConnections = "incoming_connections_count"
        case outgoingConnections = "outgoing_connections_count"
        case difficulty
        case version
        case hashrate
    }

    /// The daemon reports block *count*; the top block height is one less (Nigel.cpp does the same).
    public var localHeight: UInt64 { height > 0 ? height - 1 : 0 }
    public var networkTopHeight: UInt64 { networkHeight > 0 ? networkHeight - 1 : 0 }
    public var peers: UInt64 { (incomingConnections ?? 0) + (outgoingConnections ?? 0) }
}

public struct FeeInfo: Decodable, Equatable, Sendable {
    public let address: String
    public let amount: UInt64
    public let status: String?
}

// MARK: - getwalletsyncdata

public struct SyncKeyOutput: Codable, Equatable, Sendable {
    public let key: PublicKey
    public let amount: UInt64
    public let globalIndex: UInt64?
}

public struct SyncKeyInput: Codable, Equatable, Sendable {
    public let amount: UInt64
    public let keyImage: KeyImage

    enum CodingKeys: String, CodingKey {
        case amount
        case keyImage = "k_image"
    }
}

public struct SyncTransaction: Codable, Equatable, Sendable {
    public let hash: Hash32
    public let txPublicKey: PublicKey
    public let unlockTime: UInt64
    public let outputs: [SyncKeyOutput]
    public let inputs: [SyncKeyInput]
    public let paymentID: String

    enum CodingKeys: String, CodingKey { case hash, txPublicKey, unlockTime, outputs, inputs, paymentID }

    public init(hash: Hash32, txPublicKey: PublicKey, unlockTime: UInt64, outputs: [SyncKeyOutput], inputs: [SyncKeyInput], paymentID: String) {
        self.hash = hash
        self.txPublicKey = txPublicKey
        self.unlockTime = unlockTime
        self.outputs = outputs
        self.inputs = inputs
        self.paymentID = paymentID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hash = try c.decode(Hash32.self, forKey: .hash)
        txPublicKey = try c.decode(PublicKey.self, forKey: .txPublicKey)
        if let u = try? c.decode(UInt64.self, forKey: .unlockTime) {
            unlockTime = u
        } else {
            unlockTime = UInt64(try c.decode(String.self, forKey: .unlockTime)) ?? 0
        }
        outputs = try c.decode([SyncKeyOutput].self, forKey: .outputs)
        inputs = try c.decodeIfPresent([SyncKeyInput].self, forKey: .inputs) ?? []
        paymentID = try c.decodeIfPresent(String.self, forKey: .paymentID) ?? ""
    }
}

public struct SyncBlock: Codable, Equatable, Sendable {
    public let blockHeight: UInt64
    public let blockHash: Hash32
    public let blockTimestamp: UInt64
    public let coinbaseTX: SyncTransaction?
    public let transactions: [SyncTransaction]
}

public struct SyncTopBlock: Codable, Equatable, Sendable {
    public let hash: Hash32
    public let height: UInt64
}

public struct WalletSyncResponse: Decodable, Sendable {
    public let status: String
    public let items: [SyncBlock]
    public let synced: Bool?
    public let topBlock: SyncTopBlock?
}

public struct RandomOutputEntry: Decodable, Equatable, Sendable {
    public let globalAmountIndex: UInt64
    public let outKey: PublicKey

    enum CodingKeys: String, CodingKey {
        case globalAmountIndex = "global_amount_index"
        case outKey = "out_key"
    }
}

public struct RandomOutputs: Decodable, Equatable, Sendable {
    public let amount: UInt64
    public let outs: [RandomOutputEntry]
}

public enum DaemonError: Error, Equatable, LocalizedError {
    case http(Int)
    case badStatus(String)
    case decoding(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code): return "Node returned HTTP \(code)"
        case .badStatus(let s): return "Node returned status: \(s)"
        case .decoding(let s): return "Unexpected node response: \(s)"
        case .transport(let s): return s
        }
    }
}

/// Abstraction over the daemon so the sync engine and transaction builder can be unit tested.
public protocol DaemonAPI: Sendable {
    func info() async throws -> DaemonInfo
    func fee() async throws -> FeeInfo
    func walletSyncData(checkpoints: [Hash32], startHeight: UInt64, startTimestamp: UInt64, blockCount: UInt64, skipCoinbase: Bool) async throws -> WalletSyncResponse
    func globalIndexes(startHeight: UInt64, endHeight: UInt64) async throws -> [Hash32: [UInt64]]
    func randomOutputs(amounts: [UInt64], count: UInt64) async throws -> [RandomOutputs]
    func sendRawTransaction(hex: String) async throws
    func transactionsStatus(hashes: [Hash32]) async throws -> TransactionsStatus
}

public struct TransactionsStatus: Decodable, Equatable, Sendable {
    public let status: String
    public let transactionsInPool: [Hash32]
    public let transactionsInBlock: [Hash32]
    public let transactionsUnknown: [Hash32]
}

public final class DaemonClient: DaemonAPI, @unchecked Sendable {
    public let node: NodeInfo
    let session: URLSession
    let timeout: TimeInterval

    public init(node: NodeInfo, session: URLSession = .shared, timeout: TimeInterval = 20) {
        self.node = node
        self.session = session
        self.timeout = timeout
    }

    func request(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: node.baseURL.appendingPathComponent(path))
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            // URLSession reports a cancelled task as URLError.cancelled ("cancelled"). Keep it a
            // cancellation so callers can tell a restart/lock apart from a network failure.
            if Task.isCancelled || isCancellation(error) { throw CancellationError() }
            throw DaemonError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DaemonError.http(http.statusCode)
        }
        return data
    }

    func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw DaemonError.decoding(String(describing: error))
        }
    }

    public func info() async throws -> DaemonInfo {
        try decode(DaemonInfo.self, try await request("info"))
    }

    public func fee() async throws -> FeeInfo {
        try decode(FeeInfo.self, try await request("fee"))
    }

    public func walletSyncData(checkpoints: [Hash32], startHeight: UInt64, startTimestamp: UInt64, blockCount: UInt64, skipCoinbase: Bool) async throws -> WalletSyncResponse {
        let body: [String: Any] = [
            "blockHashCheckpoints": checkpoints.map(\.hex),
            "startHeight": startHeight,
            "startTimestamp": startTimestamp,
            "blockCount": blockCount,
            "skipCoinbaseTransactions": skipCoinbase,
        ]
        let r = try decode(WalletSyncResponse.self, try await request("getwalletsyncdata", body: body))
        guard r.status == "OK" else { throw DaemonError.badStatus(r.status) }
        return r
    }

    struct IndexesResponse: Decodable {
        struct Entry: Decodable { let key: Hash32; let value: [UInt64] }
        let status: String
        let indexes: [Entry]
    }

    public func globalIndexes(startHeight: UInt64, endHeight: UInt64) async throws -> [Hash32: [UInt64]] {
        let r = try decode(IndexesResponse.self, try await request("get_global_indexes_for_range", body: ["startHeight": startHeight, "endHeight": endHeight]))
        guard r.status == "OK" else { throw DaemonError.badStatus(r.status) }
        var out: [Hash32: [UInt64]] = [:]
        for e in r.indexes { out[e.key] = e.value }
        return out
    }

    struct RandomOutsResponse: Decodable { let status: String; let outs: [RandomOutputs] }

    public func randomOutputs(amounts: [UInt64], count: UInt64) async throws -> [RandomOutputs] {
        let r = try decode(RandomOutsResponse.self, try await request("getrandom_outs", body: ["amounts": amounts, "outs_count": count]))
        guard r.status == "OK" else { throw DaemonError.badStatus(r.status) }
        return r.outs
    }

    struct SendResponse: Decodable { let status: String; let error: String? }

    public func sendRawTransaction(hex: String) async throws {
        let data = try await request("sendrawtransaction", body: ["tx_as_hex": hex])
        let r = try decode(SendResponse.self, data)
        guard r.status == "OK" else { throw DaemonError.badStatus(r.error ?? r.status) }
    }

    public func transactionsStatus(hashes: [Hash32]) async throws -> TransactionsStatus {
        let r = try decode(TransactionsStatus.self, try await request("get_transactions_status", body: ["transactionHashes": hashes.map(\.hex)]))
        guard r.status == "OK" else { throw DaemonError.badStatus(r.status) }
        return r
    }

    /// Downloads the public XTE node list (TRRXITTE/XTEnetworkserver/traaitt.json).
    public static func fetchNodeList(session: URLSession = .shared, url: URL = XTEConfig.nodeListURL) async throws -> [NodeInfo] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, _) = try await session.data(for: req)
        return try NodeList.parse(data)
    }
}
