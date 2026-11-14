// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import Foundation

/// User-chosen security options. All optional; offered once after create/restore
/// and always available in Settings > Security & Backup.
final class SecurityPrefs: ObservableObject {
    static let shared = SecurityPrefs()

    private let defaults = UserDefaults.standard

    /// Wrap the Keychain item with a Secure Enclave key (hardware-bound, cannot leave this iPad).
    @Published var hardwareVault: Bool { didSet { defaults.set(hardwareVault, forKey: "sec.hardwareVault") } }
    /// 0 = lock as soon as the app leaves the screen.
    @Published var autoLockSeconds: Int { didSet { defaults.set(autoLockSeconds, forKey: "sec.autoLockSeconds") } }
    /// Cover the app in the app switcher and while inactive.
    @Published var screenProtection: Bool { didSet { defaults.set(screenProtection, forKey: "sec.screenProtection") } }
    /// Local "payment received" notifications from background refresh.
    @Published var notifications: Bool { didSet { defaults.set(notifications, forKey: "sec.notifications") } }
    /// Download and scan new blocks in the background with the view-only key (BackgroundSync).
    @Published var backgroundSync: Bool { didSet { defaults.set(backgroundSync, forKey: "sec.backgroundSync") } }
    /// Long background catch-up (BGProcessingTask) only while the iPad is charging.
    @Published var backgroundSyncChargingOnly: Bool { didSet { defaults.set(backgroundSyncChargingOnly, forKey: "sec.backgroundSyncCharging") } }
    @Published var setupOffered: Bool { didSet { defaults.set(setupOffered, forKey: "sec.setupOffered") } }
    @Published var compromisedAcknowledged: Bool { didSet { defaults.set(compromisedAcknowledged, forKey: "sec.compromisedAck") } }
    @Published var lastCloudBackup: Date? { didSet { defaults.set(lastCloudBackup, forKey: "sec.lastCloudBackup") } }
    @Published var lastFileBackup: Date? { didSet { defaults.set(lastFileBackup, forKey: "sec.lastFileBackup") } }

    struct AutoLockChoice: Hashable {
        let seconds: Int
        let title: String
    }

    static let autoLockChoices: [AutoLockChoice] = [
        AutoLockChoice(seconds: 0, title: "Immediately"),
        AutoLockChoice(seconds: 60, title: "After 1 minute"),
        AutoLockChoice(seconds: 300, title: "After 5 minutes"),
        AutoLockChoice(seconds: 900, title: "After 15 minutes"),
    ]

    private init() {
        hardwareVault = defaults.bool(forKey: "sec.hardwareVault")
        autoLockSeconds = defaults.integer(forKey: "sec.autoLockSeconds")
        screenProtection = defaults.object(forKey: "sec.screenProtection") as? Bool ?? true
        notifications = defaults.bool(forKey: "sec.notifications")
        // Off unless chosen; on by default only when payment notifications already store the
        // view-only key (then background sync adds no new exposure).
        backgroundSync = defaults.object(forKey: "sec.backgroundSync") as? Bool ?? defaults.bool(forKey: "sec.notifications")
        backgroundSyncChargingOnly = defaults.object(forKey: "sec.backgroundSyncCharging") as? Bool ?? true
        setupOffered = defaults.bool(forKey: "sec.setupOffered")
        compromisedAcknowledged = defaults.bool(forKey: "sec.compromisedAck")
        lastCloudBackup = defaults.object(forKey: "sec.lastCloudBackup") as? Date
        lastFileBackup = defaults.object(forKey: "sec.lastFileBackup") as? Date
    }

    /// Clears per-wallet choices when the wallet is deleted.
    func resetForNewWallet() {
        setupOffered = false
        lastCloudBackup = nil
        lastFileBackup = nil
        notifications = false
        backgroundSync = false
    }
}
