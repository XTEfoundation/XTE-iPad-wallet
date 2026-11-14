// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.
//
// Live check against the real node's xte-rpc-gateway. Opt-in: LIVE_GATEWAY=1 swift test --filter LiveGatewayTests
// (CI runs it in the "Live node check" workflow).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import XTEWalletCore

final class LiveGatewayTests: XCTestCase {
    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_GATEWAY"] == "1", "set LIVE_GATEWAY=1")
        await GatewayRegistry.shared.reset()
    }

    func testGatewayDecodesFullChunkWithCoinbase() async throws {
        let node = XTEConfig.defaultNode
        let client = DaemonClient(node: node)
        let info = try await client.info()
        let start = info.networkTopHeight > 5000 ? info.networkTopHeight - 5000 : 0
        let r = try await client.walletSyncData(checkpoints: [], startHeight: start, startTimestamp: 0,
                                                blockCount: XTEConfig.blocksPerSyncRequest, skipCoinbase: false)
        let active = await GatewayRegistry.shared.isActive(for: node)
        XCTAssertTrue(active, "gateway must stay active (no REST fallback)")
        XCTAssertEqual(r.items.first?.blockHeight, start)
        XCTAssertEqual(UInt64(r.items.count), XTEConfig.gatewayBlocksPerRequest)
    }

    func testWalletHeightAdvancesThroughGateway() async throws {
        let node = XTEConfig.defaultNode
        let client = DaemonClient(node: node)
        let info = try await client.info()
        let top = info.networkTopHeight
        var state = WalletState(startHeight: top - 2500)
        let sync = WalletSynchronizer(scanner: BlockScanner(keys: WalletKeys.generate()))
        var caughtUp = false
        for _ in 0..<10 where !caughtUp {
            caughtUp = try await sync.syncOnce(daemon: client, state: &state)
        }
        let active = await GatewayRegistry.shared.isActive(for: node)
        XCTAssertTrue(active, "gateway must stay active (no REST fallback)")
        XCTAssertTrue(caughtUp)
        XCTAssertGreaterThanOrEqual(state.lastKnownBlockHeight + 2, top)
    }

    /// A brand-new wallet syncs from a timestamp: must not hang on the gateway or disable it.
    func testTimestampStartDoesNotDisableGateway() async throws {
        let node = XTEConfig.defaultNode
        let client = DaemonClient(node: node)
        let started = Date()
        var state = WalletState(startHeight: 0, startTimestamp: UInt64(Date().timeIntervalSince1970) - 600)
        let sync = WalletSynchronizer(scanner: BlockScanner(keys: WalletKeys.generate()))
        for _ in 0..<3 { if try await sync.syncOnce(daemon: client, state: &state) { break } }
        XCTAssertLessThan(Date().timeIntervalSince(started), 25)
        XCTAssertGreaterThan(state.lastKnownBlockHeight, 0)
        let active = await GatewayRegistry.shared.isActive(for: node)
        XCTAssertTrue(active)
    }
}
