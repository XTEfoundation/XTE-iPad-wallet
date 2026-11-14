// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import XTEWalletCore

private func h(_ n: UInt64) -> Hash32 {
    var bytes = [UInt8](repeating: 0, count: 32)
    var v = n &+ 1
    for i in 0..<8 { bytes[i] = UInt8(v & 0xff); v >>= 8 }
    return Hash32(bytes: bytes)!
}

private func block(_ height: UInt64) -> SyncBlock {
    SyncBlock(blockHeight: height, blockHash: h(height), blockTimestamp: 1_700_000_000 + height, coinbaseTX: nil, transactions: [])
}

private struct MockDaemon: DaemonAPI {
    let tip: UInt64
    func info() async throws -> DaemonInfo { throw DaemonError.transport("unused") }
    func fee() async throws -> FeeInfo { throw DaemonError.transport("unused") }
    func walletSyncData(checkpoints: [Hash32], startHeight: UInt64, startTimestamp: UInt64, blockCount: UInt64, skipCoinbase: Bool) async throws -> WalletSyncResponse {
        // Resume after the newest checkpoint, like the daemon.
        var start = startHeight
        if let c = checkpoints.first, let height = (0...tip).first(where: { h($0) == c }) { start = height + 1 }
        let end = min(tip, start + blockCount - 1)
        let items = start > tip ? [] : (start...end).map(block)
        return WalletSyncResponse(status: "OK", items: items, synced: end >= tip, topBlock: nil)
    }
    func globalIndexes(startHeight: UInt64, endHeight: UInt64) async throws -> [Hash32: [UInt64]] { [:] }
    func randomOutputs(amounts: [UInt64], count: UInt64) async throws -> [RandomOutputs] { [] }
    func sendRawTransaction(hex: String) async throws {}
    func transactionsStatus(hashes: [Hash32]) async throws -> TransactionsStatus {
        TransactionsStatus(status: "OK", transactionsInPool: [], transactionsInBlock: [], transactionsUnknown: [])
    }
}

final class GatewayTests: XCTestCase {
    func testEndpointIgnoresProxyPathAndKeepsCustomPort() {
        XCTAssertEqual(Gateway.endpoint(for: XTEConfig.defaultNode).absoluteString,
                       "https://main.trrxitte.com/rpc/" + XTEConfig.gatewayNamespace)
        let plain = NodeInfo(name: "n", host: "10.0.0.1", port: 14485, ssl: false)
        XCTAssertEqual(Gateway.endpoint(for: plain).absoluteString, "http://10.0.0.1:14485/rpc/" + XTEConfig.gatewayNamespace)
    }

    func testSyncRequestBody() throws {
        let body = Gateway.syncRequestBody(checkpoints: [h(5)], startHeight: 0, startTimestamp: 0, blockCount: 1000, skipCoinbase: false)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(obj["method"] as? String, XTEConfig.gatewayNamespace + "_syncBlocks")
        let p = try XCTUnwrap((obj["params"] as? [[String: Any]])?.first)
        XCTAssertEqual(p["checkpoints"] as? [String], [h(5).hex])
        XCTAssertEqual((p["blockCount"] as? NSNumber)?.intValue, 1000)
        XCTAssertNil(p["startTimestamp"])
    }

    func testDecodeSyncResultAndError() throws {
        let ok = """
        {"jsonrpc":"2.0","id":1,"result":{"items":[{"blockHash":"\(h(7).hex)","blockHeight":7,"blockTimestamp":1,
        "coinbaseTX":{"hash":"\(h(70).hex)","outputs":[{"amount":5,"key":"\(h(71).hex)"}],"txPublicKey":"\(h(72).hex)","unlockTime":47},
        "transactions":[]}],"startHeight":7,"endHeight":7,"nextHeight":8,"blockCount":1,"topHeight":9,
        "topBlock":{"height":9,"hash":"\(h(9).hex)"},"synced":false}}
        """
        let r = try Gateway.decodeSync(Data(ok.utf8))
        XCTAssertEqual(r.items.map(\.blockHeight), [7])
        XCTAssertEqual(r.items[0].coinbaseTX?.outputs.first?.amount, 5)
        XCTAssertEqual(r.topBlock?.height, 9)
        XCTAssertEqual(r.synced, false)
        let err = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32005,"message":"rate limit exceeded"}}"#
        XCTAssertThrowsError(try Gateway.decodeSync(Data(err.utf8))) { e in
            XCTAssertEqual(e as? GatewayError, .rpc(-32005, "rate limit exceeded"))
        }
    }

    func testHealthAcceptance() throws {
        let good = #"{"status":"ok","gateway":"xte-rpc-gateway","coin":"\#(XTEConfig.gatewayNamespace)","apiVersion":1,"topHeight":5}"#
        XCTAssertTrue(try JSONDecoder().decode(GatewayHealth.self, from: Data(good.utf8)).isUsable)
        let wrongCoin = #"{"status":"ok","gateway":"xte-rpc-gateway","coin":"other","apiVersion":1}"#
        XCTAssertFalse(try JSONDecoder().decode(GatewayHealth.self, from: Data(wrongCoin.utf8)).isUsable)
        let degraded = #"{"status":"degraded","gateway":"xte-rpc-gateway","coin":"\#(XTEConfig.gatewayNamespace)","apiVersion":1}"#
        XCTAssertFalse(try JSONDecoder().decode(GatewayHealth.self, from: Data(degraded.utf8)).isUsable)
    }

    func testRegistryRemembersUnavailableNodes() async {
        let registry = GatewayRegistry()
        // Nothing listens on this port: probing fails fast and the node is marked REST-only.
        let node = NodeInfo(name: "n", host: "127.0.0.1", port: 9, ssl: false)
        let first = await registry.endpoint(for: node, session: .shared)
        XCTAssertNil(first)
        let active = await registry.isActive(for: node)
        XCTAssertFalse(active)
    }

    /// Live check against main.trrxitte.com (set XTE_LIVE_GATEWAY=1): the gateway returns the
    /// same blocks as the daemon's REST API.
    func testLiveGatewayMatchesREST() async throws {
        guard ProcessInfo.processInfo.environment["XTE_LIVE_GATEWAY"] == "1" else { throw XCTSkip("live test") }
        let client = DaemonClient(node: XTEConfig.defaultNode, timeout: 60)
        let start: UInt64 = 1_000_000
        let viaGateway = try await client.walletSyncData(checkpoints: [], startHeight: start, startTimestamp: 0, blockCount: 100, skipCoinbase: false)
        let isActive = await GatewayRegistry.shared.isActive(for: XTEConfig.defaultNode)
        XCTAssertTrue(isActive, "gateway not detected")
        XCTAssertEqual(viaGateway.items.count, 1000)
        let rest = try await client.restWalletSyncData(checkpoints: [], startHeight: start, startTimestamp: 0, blockCount: 100, skipCoinbase: false)
        XCTAssertFalse(rest.items.isEmpty)
        XCTAssertEqual(Array(viaGateway.items.prefix(rest.items.count)), rest.items)
    }
}

final class BlockCacheTests: XCTestCase {
    private func makeCache(capacity: Int = 10_000) -> BlockCache {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bc-\(UUID().uuidString)")
        return BlockCache(directory: dir, capacity: capacity)
    }

    func testAppendIsContiguousAndBounded() {
        let c = makeCache(capacity: 25)
        XCTAssertEqual(c.append((10...19).map(block)), 10)
        XCTAssertEqual(c.append((20...39).map(block)), 15)   // capacity
        XCTAssertEqual(c.count, 25)
        XCTAssertEqual(c.lastHeight, 34)
        XCTAssertTrue(c.isFull)
        // A gap resets the cache to the new run.
        let d = makeCache()
        d.append((10...19).map(block))
        d.append((30...31).map(block))
        XCTAssertEqual(d.count, 2)
        XCTAssertEqual(d.lastHeight, 31)
        // An overlap (re-fetched tip) replaces the overlapping blocks.
        d.append((31...33).map(block))
        XCTAssertEqual(d.count, 4)
    }

    func testBlocksAfterHashAnchorAndPersistence() {
        let c = makeCache()
        c.setAnchor(BlockCacheAnchor(height: 9, hash: h(9)))
        c.append((10...29).map(block))
        XCTAssertEqual(c.blocks(after: h(9), limit: 5).map(\.blockHeight), [10, 11, 12, 13, 14])
        XCTAssertEqual(c.blocks(after: h(14), limit: 100).first?.blockHeight, 15)
        XCTAssertEqual(c.blocks(after: h(29), limit: 100), [])
        XCTAssertEqual(c.blocks(after: h(500), limit: 100), [])
        // Reloaded from disk.
        let again = BlockCache(directory: c.directory)
        XCTAssertEqual(again.count, 20)
        // Foreground progress drops consumed blocks.
        again.setAnchor(BlockCacheAnchor(height: 19, hash: h(19)))
        XCTAssertEqual(again.count, 10)
        XCTAssertEqual(again.blocks(after: h(19), limit: 3).map(\.blockHeight), [20, 21, 22])
        again.clear()
        XCTAssertEqual(again.count, 0)
        XCTAssertNil(again.anchor)
    }

    func testPrefetchedDaemonServesCacheThenNode() async throws {
        let c = makeCache()
        c.setAnchor(BlockCacheAnchor(height: 99, hash: h(99)))
        c.append((100...149).map(block))
        let d = PrefetchedDaemon(base: MockDaemon(tip: 200), cache: c)
        var state = WalletState(startHeight: 0)
        state.recordBlockHash(h(99), height: 99)
        let sync = WalletSynchronizer(scanner: BlockScanner(publicSpendKey: h(1), privateViewKey: h(2), privateSpendKey: nil))
        var rounds = 0
        while try await !sync.syncOnce(daemon: d, state: &state) {
            rounds += 1
            if rounds > 20 { XCTFail("did not finish"); break }
        }
        XCTAssertEqual(state.lastKnownBlockHeight, 200)
        XCTAssertEqual(state.lastKnownBlockHashes.first, h(200))
        // Skip-coinbase requests (not used by the wallet) always go to the node.
        let r = try await d.walletSyncData(checkpoints: [h(99)], startHeight: 0, startTimestamp: 0, blockCount: 10, skipCoinbase: true)
        XCTAssertEqual(r.items.first?.blockHeight, 100)
    }
}
