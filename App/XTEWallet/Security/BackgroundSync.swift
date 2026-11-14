// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import BackgroundTasks
import Foundation
import Network
import UIKit
import UserNotifications
import XTEWalletCore

/// Opt-in background sync with the view-only key (it cannot spend).
///
/// * BGAppRefreshTask (`<bundle id>.refresh`, ~30 s, timing chosen by iOS) and
///   BGProcessingTask (`<bundle id>.sync`, minutes, usually while charging) download new
///   blocks (through the node's fast RPC gateway when it has one), scan them with the view
///   key for incoming payments and keep them in a local `BlockCache`.
/// * The next foreground sync reads those blocks from disk (`PrefetchedDaemon`) instead of
///   the network. Key images still need the spend key, so the wallet state itself is only
///   ever updated by the foreground sync - background work never touches `AppModel`, the
///   auto-lock or the sync loop, so it cannot cancel a running sync.
/// * Skipped in Low Power Mode, on low battery and on Low Data Mode networks; on cellular
///   it fetches at most `cellularBlockLimit` blocks per run.
enum BackgroundSync {
    static var refreshIdentifier: String { PaymentNotifier.taskIdentifier }
    static var processingIdentifier: String { (Bundle.main.bundleIdentifier ?? "io.traaitt.wallet") + ".sync" }

    static let cache: BlockCache = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BackgroundSync", isDirectory: true)
        return BlockCache(directory: dir, capacity: 10_000)
    }()

    /// Blocks this deep are cached; shallower ones may still be re-organised.
    static let cacheConfirmations: UInt64 = 10
    static let cellularBlockLimit: UInt64 = 3_000

    /// Runs when either feature needs the background scan.
    static var isWanted: Bool { SecurityPrefs.shared.backgroundSync || SecurityPrefs.shared.notifications }

    // MARK: Scheduling

    /// Must be called before the app finishes launching (App.init).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            scheduleProcessing()
            let work = Task { await run(deadline: Date(timeIntervalSinceNow: 10 * 60)) }
            task.expirationHandler = { work.cancel() }
            Task { task.setTaskCompleted(success: await work.value) }
        }
    }

    static func scheduleAll() {
        PaymentNotifier.schedule()
        scheduleProcessing()
    }

    static func scheduleProcessing() {
        guard SecurityPrefs.shared.backgroundSync else { return }
        let request = BGProcessingTaskRequest(identifier: processingIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = SecurityPrefs.shared.backgroundSyncChargingOnly
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancelAll() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: processingIdentifier)
        if !SecurityPrefs.shared.notifications { PaymentNotifier.cancel() }
    }

    // MARK: Conditions

    struct Conditions {
        var allowed: Bool
        var maxBlocks: UInt64
        var reason: String?
    }

    static func currentConditions() async -> Conditions {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return Conditions(allowed: false, maxBlocks: 0, reason: "Low Power Mode") }
        let battery: (level: Float, state: UIDevice.BatteryState) = await MainActor.run {
            UIDevice.current.isBatteryMonitoringEnabled = true
            return (UIDevice.current.batteryLevel, UIDevice.current.batteryState)
        }
        if battery.level >= 0, battery.level < 0.2, battery.state == .unplugged {
            return Conditions(allowed: false, maxBlocks: 0, reason: "Battery below 20 %")
        }
        let path = await currentPath()
        guard let path, path.status == .satisfied else { return Conditions(allowed: false, maxBlocks: 0, reason: "Offline") }
        if path.isConstrained { return Conditions(allowed: false, maxBlocks: 0, reason: "Low Data Mode") }
        return Conditions(allowed: true, maxBlocks: path.isExpensive ? cellularBlockLimit : .max, reason: nil)
    }

    private final class PathProbe: @unchecked Sendable {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "bgsync.path")
        private var continuation: CheckedContinuation<NWPath?, Never>?

        func run() async -> NWPath? {
            await withCheckedContinuation { (cont: CheckedContinuation<NWPath?, Never>) in
                queue.async {
                    self.continuation = cont
                    self.monitor.pathUpdateHandler = { path in self.finish(path) }   // cycle broken in finish
                    self.monitor.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + 2) { self.finish(nil) }
                }
            }
        }

        /// Always called on `queue`.
        private func finish(_ path: NWPath?) {
            guard let c = continuation else { return }
            continuation = nil
            monitor.pathUpdateHandler = nil
            monitor.cancel()
            c.resume(returning: path)
        }
    }

    private static func currentPath() async -> NWPath? {
        await PathProbe().run()
    }

    // MARK: Work

    /// Downloads and scans new blocks until `deadline`. Returns false only on failure.
    /// Cancellation (task expired) is a normal, quiet stop.
    @discardableResult
    static func run(deadline: Date) async -> Bool {
        guard isWanted, let keys = KeychainStore.loadNotificationKeys() else { return true }
        let conditions = await currentConditions()
        guard conditions.allowed else { return true }
        let client = DaemonClient(node: Settings.selectedNode, timeout: 25)
        guard let info = try? await client.info() else { return false }
        let tip = info.networkTopHeight
        let caching = SecurityPrefs.shared.backgroundSync

        // Where to continue: after the cached blocks, else after the wallet's last foreground sync.
        var next: UInt64
        if let last = cache.lastHeight {
            next = last + 1
        } else if let anchor = cache.anchor {
            next = anchor.height + 1
        } else {
            next = PaymentNotifier.nextHeight
        }
        if PaymentNotifier.nextHeight == 0 || PaymentNotifier.nextHeight > tip + 1 {
            PaymentNotifier.nextHeight = tip   // first run: only announce what arrives from now on
        }
        if !caching || cache.isFull { next = max(next, PaymentNotifier.nextHeight) }
        if next == 0 { next = tip }

        let scanner = keys.scanner
        var received: UInt64 = 0
        var fetched: UInt64 = 0
        do {
            while next <= tip, Date() < deadline, fetched < conditions.maxBlocks {
                try Task.checkCancellation()
                let r = try await client.walletSyncData(checkpoints: [], startHeight: next, startTimestamp: 0,
                                                        blockCount: XTEConfig.blocksPerSyncRequest, skipCoinbase: false)
                let blocks = r.items.filter { $0.blockHeight >= next }
                guard let last = blocks.last else { break }
                for b in blocks where b.blockHeight >= PaymentNotifier.nextHeight {
                    var txs = b.transactions
                    if let cb = b.coinbaseTX { txs.append(cb) }
                    for tx in txs {
                        received += scanner.ownedOutputs(of: tx, blockHeight: b.blockHeight).reduce(UInt64(0)) { $0 + $1.amount }
                    }
                }
                if caching && !cache.isFull {
                    cache.append(blocks.filter { $0.blockHeight + cacheConfirmations <= tip })
                }
                PaymentNotifier.markSeen(height: last.blockHeight)
                fetched += UInt64(blocks.count)
                next = last.blockHeight + 1
            }
        } catch {
            if isCancellation(error) || Task.isCancelled {
                await announce(received)
                return true
            }
            await announce(received)
            return false
        }
        await announce(received)
        return true
    }

    private static func announce(_ amount: UInt64) async {
        guard amount > 0, SecurityPrefs.shared.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(XTEConfig.ticker) received"
        content.body = "\(Amount.format(amount)) arrived in your wallet."
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
