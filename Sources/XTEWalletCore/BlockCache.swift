// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.
//
// Blocks downloaded by background sync (with the view key only), kept on disk so the
// next foreground sync - which needs the spend key for key images - processes them
// locally instead of downloading them again. Only public chain data is stored.

import Foundation

public struct BlockCacheAnchor: Codable, Equatable, Sendable {
    /// Height and hash of the newest block the wallet has fully processed.
    public var height: UInt64
    public var hash: Hash32?
    public init(height: UInt64, hash: Hash32?) { self.height = height; self.hash = hash }
}

public final class BlockCache: @unchecked Sendable {
    public let directory: URL
    public let capacity: Int
    private let lock = NSLock()
    private var loaded: [SyncBlock]?

    public init(directory: URL, capacity: Int = 10_000) {
        self.directory = directory
        self.capacity = capacity
    }

    private var anchorURL: URL { directory.appendingPathComponent("anchor.json") }
    private var blocksURL: URL { directory.appendingPathComponent("blocks.json") }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        // Readable by background tasks while the device is locked (after the first unlock).
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }

    private func loadBlocksLocked() -> [SyncBlock] {
        if let loaded { return loaded }
        let blocks = (try? Data(contentsOf: blocksURL)).flatMap { try? JSONDecoder().decode([SyncBlock].self, from: $0) } ?? []
        loaded = blocks
        return blocks
    }

    public var anchor: BlockCacheAnchor? {
        lock.lock(); defer { lock.unlock() }
        guard let d = try? Data(contentsOf: anchorURL) else { return nil }
        return try? JSONDecoder().decode(BlockCacheAnchor.self, from: d)
    }

    /// Foreground sync progress. Drops cached blocks the wallet has now processed.
    public func setAnchor(_ a: BlockCacheAnchor) {
        lock.lock(); defer { lock.unlock() }
        try? write(try JSONEncoder().encode(a), to: anchorURL)
        var blocks = loadBlocksLocked()
        let before = blocks.count
        blocks.removeAll { $0.blockHeight <= a.height }
        if blocks.count != before { saveLocked(blocks) }
    }

    private func saveLocked(_ blocks: [SyncBlock]) {
        loaded = blocks
        if blocks.isEmpty {
            try? FileManager.default.removeItem(at: blocksURL)
        } else if let d = try? JSONEncoder().encode(blocks) {
            try? write(d, to: blocksURL)
        }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return loadBlocksLocked().count }
    public var isFull: Bool { count >= capacity }

    /// Height of the newest cached block, or nil when empty.
    public var lastHeight: UInt64? { lock.lock(); defer { lock.unlock() }; return loadBlocksLocked().last?.blockHeight }

    /// Appends contiguous blocks; a gap or overlap that does not line up resets the cache
    /// to the new run. Returns how many blocks were stored.
    @discardableResult
    public func append(_ new: [SyncBlock]) -> Int {
        guard let first = new.first else { return 0 }
        lock.lock(); defer { lock.unlock() }
        var blocks = loadBlocksLocked()
        if let last = blocks.last {
            if first.blockHeight <= last.blockHeight {
                blocks.removeAll { $0.blockHeight >= first.blockHeight }
            }
            if let l = blocks.last, first.blockHeight != l.blockHeight + 1 { blocks = [] }
        }
        let room = max(0, capacity - blocks.count)
        let take = Array(new.prefix(room))
        // Only contiguous runs.
        var expected = first.blockHeight
        var accepted: [SyncBlock] = []
        for b in take {
            guard b.blockHeight == expected else { break }
            accepted.append(b)
            expected += 1
        }
        blocks += accepted
        saveLocked(blocks)
        return accepted.count
    }

    /// Cached blocks that follow the block with this hash (the wallet's newest known block),
    /// or that follow the anchor when `hash` is the anchor's hash.
    public func blocks(after hash: Hash32, limit: Int) -> [SyncBlock] {
        lock.lock(); defer { lock.unlock() }
        let blocks = loadBlocksLocked()
        guard !blocks.isEmpty else { return [] }
        if let i = blocks.firstIndex(where: { $0.blockHash == hash }) {
            return Array(blocks[(i + 1)...].prefix(limit))
        }
        if let d = try? Data(contentsOf: anchorURL), let a = try? JSONDecoder().decode(BlockCacheAnchor.self, from: d),
           a.hash == hash, blocks.first?.blockHeight == a.height + 1 {
            return Array(blocks.prefix(limit))
        }
        return []
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        loaded = []
        try? FileManager.default.removeItem(at: blocksURL)
        try? FileManager.default.removeItem(at: anchorURL)
    }
}

/// Serves wallet sync from the background-sync cache when it continues exactly where the
/// wallet stopped; everything else goes to the node.
public struct PrefetchedDaemon: DaemonAPI {
    public let base: DaemonAPI
    public let cache: BlockCache

    public init(base: DaemonAPI, cache: BlockCache) {
        self.base = base
        self.cache = cache
    }

    public func info() async throws -> DaemonInfo { try await base.info() }
    public func fee() async throws -> FeeInfo { try await base.fee() }

    public func walletSyncData(checkpoints: [Hash32], startHeight: UInt64, startTimestamp: UInt64, blockCount: UInt64, skipCoinbase: Bool) async throws -> WalletSyncResponse {
        if !skipCoinbase, let newest = checkpoints.first {
            let cached = cache.blocks(after: newest, limit: Int(max(blockCount, XTEConfig.gatewayBlocksPerRequest)))
            if !cached.isEmpty {
                return WalletSyncResponse(status: "OK", items: cached, synced: false, topBlock: nil)
            }
        }
        return try await base.walletSyncData(checkpoints: checkpoints, startHeight: startHeight, startTimestamp: startTimestamp,
                                             blockCount: blockCount, skipCoinbase: skipCoinbase)
    }

    public func globalIndexes(startHeight: UInt64, endHeight: UInt64) async throws -> [Hash32: [UInt64]] {
        try await base.globalIndexes(startHeight: startHeight, endHeight: endHeight)
    }
    public func randomOutputs(amounts: [UInt64], count: UInt64) async throws -> [RandomOutputs] {
        try await base.randomOutputs(amounts: amounts, count: count)
    }
    public func sendRawTransaction(hex: String) async throws { try await base.sendRawTransaction(hex: hex) }
    public func transactionsStatus(hashes: [Hash32]) async throws -> TransactionsStatus {
        try await base.transactionsStatus(hashes: hashes)
    }
}
