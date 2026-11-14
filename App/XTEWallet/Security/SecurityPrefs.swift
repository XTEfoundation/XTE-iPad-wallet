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
    @Published var setupOffered: Bool { didSet { defaults.set(setupOffered, forKey: "sec.setupOffered") } }
    @Published var compromisedAcknowledged: Bool { didSet { defaults.set(compromisedAcknowledged, forKey: "sec.compromisedAck") } }
    @Published var lastCloudBackup: Date? { didSet { defaults.set(lastCloudBackup, forKey: "sec.lastCloudBackup") } }
    @Published var lastFileBackup: Date? { didSet { defaults.set(lastFileBackup, forKey: "sec.lastFileBackup") } }

    static let autoLockChoices: [(seconds: Int, title: String)] = [
        (0, "Immediately"), (60, "After 1 minute"), (300, "After 5 minutes"), (900, "After 15 minutes"),
    ]

    private init() {
        hardwareVault = defaults.bool(forKey: "sec.hardwareVault")
        autoLockSeconds = defaults.integer(forKey: "sec.autoLockSeconds")
        screenProtection = defaults.object(forKey: "sec.screenProtection") as? Bool ?? true
        notifications = defaults.bool(forKey: "sec.notifications")
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
    }
}
