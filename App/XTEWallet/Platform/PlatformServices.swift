// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.
//
// System integration: widgets (shared snapshot), Live Activities, notification actions,
// deep-link routing (widgets, Siri, Handoff, notifications).

import ActivityKit
import Foundation
import SwiftUI
import UserNotifications
import WidgetKit
import XTEWalletCore

/// Where the UI should go next (set by deep links, Siri, notifications and Handoff).
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var pending: AppRoute?

    func open(_ route: AppRoute) { pending = route }

    /// Handles <routeScheme>:// links and payment URIs (xte:// / xtcash://).
    func handle(url: URL) -> Bool {
        if let route = AppRoute(url: url) { open(route); return true }
        if let uri = try? PaymentURI.parse(url.absoluteString) {
            open(.send(amount: uri.amount.map(Handoff.amountText), address: url.absoluteString))
            return true
        }
        return false
    }
}

// MARK: Widgets

/// Writes the public snapshot (address, balance, last payment) for widgets and Siri.
@MainActor
enum WidgetPublisher {
    private static var last: WalletSnapshot?
    private static var lastReload = Date.distantPast

    static func publish(address: String, state: WalletState, networkHeight: UInt64) {
        guard !address.isEmpty else { return }
        let balance = state.balance(currentHeight: networkHeight)
        let payment = state.transactions.first.map { tx in
            WalletSnapshot.Payment(incoming: tx.amount >= 0,
                                   amountText: (tx.amount >= 0 ? "+" : "−") + Amount.format(UInt64(tx.amount.magnitude)),
                                   date: tx.isConfirmed ? Date(timeIntervalSince1970: TimeInterval(tx.timestamp)) : Date(),
                                   confirmed: tx.isConfirmed)
        }
        var snapshot = WalletSnapshot(ticker: XTEConfig.ticker, address: address,
                                      balanceText: Amount.format(balance.unlocked),
                                      lockedText: balance.locked > 0 ? Amount.format(balance.locked) : nil,
                                      lastPayment: payment, walletHeight: state.lastKnownBlockHeight,
                                      networkHeight: networkHeight, updatedAt: Date())
        // Compare without the timestamp so a steady wallet does not reload widgets every 15 s.
        var cmp = snapshot; cmp.updatedAt = .distantPast
        var prev = last; prev?.updatedAt = .distantPast
        if cmp == prev, Date().timeIntervalSince(lastReload) < 15 * 60 { return }
        snapshot.pendingIncomingText = nil
        SnapshotStore.save(snapshot)
        last = snapshot
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
        WatchBridge.shared.send(snapshot)
    }

    /// Background check found a payment the wallet has not counted yet.
    nonisolated static func notePendingIncoming(_ text: String) {
        guard var s = SnapshotStore.load() else { return }
        s.pendingIncomingText = text
        s.lastPayment = .init(incoming: true, amountText: text, date: Date(), confirmed: false)
        SnapshotStore.save(s)
        WidgetCenter.shared.reloadAllTimelines()
    }

    static func clear() {
        SnapshotStore.clear()
        last = nil
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// No-op on iPad (Apple Watch pairs with iPhone only); the iPhone apps have a real bridge.
final class WatchBridge {
    static let shared = WatchBridge()
    func activate() {}
    func send(_ snapshot: WalletSnapshot) {}
}

// MARK: Live Activities

@MainActor
enum LiveActivities {
    /// Show a sync activity only for a real catch-up, not for the next block.
    static let syncThreshold: UInt64 = 500

    private static var syncActivityID: String?
    private static var sendActivities: [String: String] = [:]   // tx hash -> activity id

    static var enabled: Bool {
        guard #available(iOS 16.1, *) else { return false }
        return ActivityAuthorizationInfo().areActivitiesEnabled
    }

    static func updateSync(walletHeight: UInt64, networkHeight: UInt64) {
        guard #available(iOS 16.1, *), enabled, networkHeight > 0 else { return }
        let behind = networkHeight > walletHeight + 1 ? networkHeight - walletHeight - 1 : 0
        let progress = min(1, Double(walletHeight) / Double(networkHeight))
        let state = WalletActivityAttributes.ContentState(progress: progress, walletHeight: walletHeight,
                                                          networkHeight: networkHeight, status: "", done: behind == 0)
        if let id = syncActivityID, let activity = Activity<WalletActivityAttributes>.activities.first(where: { $0.id == id }) {
            Task {
                if behind == 0 {
                    await activity.end(using: state, dismissalPolicy: .after(Date(timeIntervalSinceNow: 60)))
                } else {
                    await activity.update(using: state)
                }
            }
            if behind == 0 { syncActivityID = nil }
            return
        }
        guard behind >= syncThreshold else { return }
        if let activity = try? Activity.request(attributes: WalletActivityAttributes(kind: .sync, ticker: XTEConfig.ticker),
                                                contentState: state, pushType: nil) {
            syncActivityID = activity.id
        }
    }

    static func endSync() {
        guard #available(iOS 16.1, *), let id = syncActivityID else { return }
        syncActivityID = nil
        for a in Activity<WalletActivityAttributes>.activities where a.id == id {
            Task { await a.end(dismissalPolicy: .immediate) }
        }
    }

    static func startSend(hash: String, amountText: String, destination: String, networkHeight: UInt64) {
        guard #available(iOS 16.1, *), enabled else { return }
        let attrs = WalletActivityAttributes(kind: .send, ticker: XTEConfig.ticker, amountText: amountText,
                                             destinationShort: destination.walletShortened, txHashShort: hash.walletShortened)
        let state = WalletActivityAttributes.ContentState(progress: 0.2, walletHeight: 0, networkHeight: networkHeight,
                                                          status: "Broadcast, waiting for a block", done: false)
        if let a = try? Activity.request(attributes: attrs, contentState: state, pushType: nil) {
            sendActivities[hash] = a.id
        }
    }

    /// Called after each sync with the wallet's transactions.
    static func updateSends(_ transactions: [WalletTransaction], networkHeight: UInt64) {
        guard #available(iOS 16.1, *), !sendActivities.isEmpty else { return }
        for (hash, id) in sendActivities {
            guard let activity = Activity<WalletActivityAttributes>.activities.first(where: { $0.id == id }) else {
                sendActivities[hash] = nil; continue
            }
            guard let tx = transactions.first(where: { $0.hash.hex == hash }) else { continue }
            if tx.isConfirmed {
                let confirmations = networkHeight > tx.blockHeight ? networkHeight - tx.blockHeight : 0
                let done = confirmations >= 3
                let state = WalletActivityAttributes.ContentState(
                    progress: done ? 1 : 0.5 + 0.5 * Double(confirmations) / 3, walletHeight: tx.blockHeight,
                    networkHeight: networkHeight,
                    status: done ? "Confirmed in block \(tx.blockHeight)" : "In block \(tx.blockHeight) · \(confirmations) confirmations",
                    done: done)
                Task {
                    if done { await activity.end(using: state, dismissalPolicy: .after(Date(timeIntervalSinceNow: 15 * 60))) }
                    else { await activity.update(using: state) }
                }
                if done { sendActivities[hash] = nil }
            }
        }
    }
}

// MARK: Notifications

/// Payment notification category with actions, and routing when the user taps one.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    static let paymentCategory = "WALLET_PAYMENT"
    static let actionShowTransactions = "SHOW_TRANSACTIONS"
    static let actionShowReceive = "SHOW_RECEIVE"

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let show = UNNotificationAction(identifier: Self.actionShowTransactions, title: "Show transactions", options: [.foreground])
        let receive = UNNotificationAction(identifier: Self.actionShowReceive, title: "Show receive QR", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.paymentCategory, actions: [show, receive], intentIdentifiers: [],
                                   options: [.hiddenPreviewsShowTitle]),
        ])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let route: AppRoute = response.actionIdentifier == Self.actionShowReceive ? .receive : .transactions
        Task { @MainActor in
            AppRouter.shared.open(route)
            completionHandler()
        }
    }
}

// MARK: Handoff

enum Handoff {
    /// Fills an NSUserActivity for a receive address / payment request.
    static func receive(_ activity: NSUserActivity, uri: String) {
        activity.title = "Receive \(XTEConfig.ticker)"
        activity.userInfo = ["uri": uri]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = true
        activity.requiredUserInfoKeys = ["uri"]
    }

    static func send(_ activity: NSUserActivity, uri: String) {
        activity.title = "Send \(XTEConfig.ticker)"
        activity.userInfo = ["uri": uri]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = false
    }

    @MainActor
    static func continueActivity(_ activity: NSUserActivity) {
        if activity.activityType == SharedConfig.receiveActivityType {
            AppRouter.shared.open(.receive)
            return
        }
        guard let uri = activity.userInfo?["uri"] as? String, let parsed = try? PaymentURI.parse(uri) else {
            AppRouter.shared.open(.send(amount: nil, address: nil))
            return
        }
        AppRouter.shared.open(.send(amount: parsed.amount.map(Handoff.amountText), address: uri))
    }

    static func amountText(_ atomic: UInt64) -> String {
        Amount.format(atomic, withTicker: false).replacingOccurrences(of: ",", with: "")
    }
}
