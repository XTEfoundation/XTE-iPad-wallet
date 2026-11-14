// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import BackgroundTasks
import Foundation
import UserNotifications
import XTEWalletCore

/// Local "payment received" notifications. When enabled, iOS wakes the app now and then
/// (BGAppRefreshTask, timing chosen by iOS). It scans only the blocks since the last check
/// with the opt-in view-only keys (cannot spend) and posts a local notification.
/// Remote push (APNs) would need a server that watches the chain with the view key,
/// so it is not used.
enum PaymentNotifier {
    static var taskIdentifier: String { (Bundle.main.bundleIdentifier ?? "io.traaitt.wallet") + ".refresh" }
    private static let heightKey = "notify.nextHeight"

    static var nextHeight: UInt64 {
        get { UInt64(UserDefaults.standard.integer(forKey: heightKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: heightKey) }
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func schedule() {
        guard SecurityPrefs.shared.notifications else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    /// Called by the app's foreground sync so the background check does not re-announce
    /// payments the user has already seen.
    static func markSeen(height: UInt64) {
        if height + 1 > nextHeight { nextHeight = height + 1 }
    }

    /// The background refresh body. Returns the amount found (for tests / logging).
    @discardableResult
    static func checkForPayments(deadline: Date = Date(timeIntervalSinceNow: 25)) async -> UInt64 {
        schedule()   // keep the chain of refreshes going
        guard SecurityPrefs.shared.notifications, let keys = KeychainStore.loadNotificationKeys() else { return 0 }
        let client = DaemonClient(node: Settings.selectedNode, timeout: 20)
        guard let info = try? await client.info() else { return 0 }
        let tip = info.networkTopHeight
        if nextHeight == 0 || nextHeight > tip + 1 {
            nextHeight = tip
            return 0
        }
        var state = WalletState(startHeight: nextHeight)
        let synchronizer = WalletSynchronizer(scanner: keys.scanner)
        do {
            while Date() < deadline {
                if try await synchronizer.syncOnce(daemon: client, state: &state) { break }
            }
        } catch {
            // Keep what was scanned so far.
        }
        let received = state.transactions.filter { $0.amount > 0 }.reduce(UInt64(0)) { $0 + UInt64($1.amount) }
        if state.lastKnownBlockHeight >= nextHeight { nextHeight = state.lastKnownBlockHeight + 1 }
        if received > 0 {
            let content = UNMutableNotificationContent()
            content.title = "\(XTEConfig.ticker) received"
            content.body = "\(Amount.format(received)) arrived in your wallet."
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        return received
    }
}
