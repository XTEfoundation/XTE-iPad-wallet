// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import BackgroundTasks
import Foundation
import UserNotifications
import XTEWalletCore

/// Local "payment received" notifications. When enabled (or with background sync on), iOS
/// wakes the app now and then (BGAppRefreshTask, timing chosen by iOS). BackgroundSync scans
/// only the blocks since the last check with the opt-in view-only keys (cannot spend) and
/// posts a local notification.
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
        guard BackgroundSync.isWanted else { return }
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

    /// The background refresh body: scans new blocks with the view-only key, announces
    /// payments and (with background sync on) caches the blocks. See BackgroundSync.
    static func checkForPayments(deadline: Date = Date(timeIntervalSinceNow: 25)) async {
        schedule()   // keep the chain of refreshes going
        await BackgroundSync.run(deadline: deadline)
    }
}
