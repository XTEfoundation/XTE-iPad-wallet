// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import SwiftUI
import XTEWalletCore

/// Settings > Security & Backup. Also shown once after create/restore (setup: true).
struct SecurityView: View {
    var setup = false

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: SecurityPrefs
    @State private var password = ""
    @State private var confirm = ""
    @State private var backupText: String?
    @State private var working = false
    @State private var message: String?
    @State private var error: String?
    @State private var integrity: [String] = []
    @State private var cloudBackupExists = false

    var body: some View {
        Form {
            if setup {
                Section {
                    Text("Your wallet is ready. These options are optional; you can change them any time in Settings > Security & Backup.")
                    Button("Use the highest protection (recommended)") { useHighest() }
                        .bold()
                }
            }

            Section {
                LabeledContent("Keys stored in", value: "Keychain, this iPad only")
                LabeledContent("Unlock", value: "Face ID / Touch ID / passcode")
                Toggle("Secure Enclave protection", isOn: Binding(get: { prefs.hardwareVault }, set: { setVault($0) }))
                if prefs.hardwareVault, let level = SecureEnclaveVault.level {
                    LabeledContent("Hardware key", value: level)
                }
            } header: {
                Text("Hardware security")
            } footer: {
                Text("Encrypts the stored keys a second time with a key that is generated inside the Secure Enclave and can never leave this iPad.")
            }

            Section("Lock") {
                Picker("Auto-lock", selection: $prefs.autoLockSeconds) {
                    ForEach(SecurityPrefs.autoLockChoices, id: \.seconds) { Text($0.title).tag($0.seconds) }
                }
                Toggle("Hide wallet in the app switcher", isOn: $prefs.screenProtection)
                LabeledContent("Confirm sends", value: "Face ID / passcode (always on)")
            }

            Section {
                Toggle("Notify me about incoming payments", isOn: Binding(get: { prefs.notifications }, set: { setNotifications($0) }))
                    .disabled(model.phase != .unlocked)
            } header: {
                Text("Notifications")
            } footer: {
                Text("iOS wakes the app from time to time to check for new payments. This stores your view-only key (it cannot spend) so the check can run while the wallet is locked.")
            }

            if !model.isViewOnly {
                backupSection
            }

            if !integrity.isEmpty {
                Section("Device check") {
                    Label("This iPad looks jailbroken. Other apps may be able to read your keys.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    ForEach(integrity, id: \.self) { Text($0).font(.caption) }
                }
            }

            if let message { Section { Text(message).foregroundStyle(.green) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(setup ? "Protect your wallet" : "Security & Backup")
        .toolbar {
            if setup {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        prefs.setupOffered = true
                        model.offerSecuritySetup = false
                    }
                }
            }
        }
        .onAppear {
            integrity = DeviceIntegrity.indicators()
            cloudBackupExists = (try? CloudBackup.load()) != nil
        }
        .disabled(working)
    }

    @ViewBuilder private var backupSection: some View {
        Section {
            SecureField("Backup password (min. \(WalletBackup.minimumPasswordLength) characters)", text: $password)
            SecureField("Repeat password", text: $confirm)
            Button("Create encrypted backup") { createBackup() }
                .disabled(WalletBackup.passwordProblem(password, confirm: confirm) != nil)
            if let backupText {
                Button("Save to iCloud Keychain") { saveToCloud(backupText) }
                ShareLink(item: backupText,
                          subject: Text("\(XTEConfig.ticker) encrypted wallet backup"),
                          message: Text("\(XTEConfig.ticker) encrypted wallet backup. Restore it in the \(XTEConfig.ticker) wallet with your backup password.")) {
                    Label("Send by email / Gmail / Drive / Files", systemImage: "square.and.arrow.up")
                }
                .simultaneousGesture(TapGesture().onEnded { prefs.lastFileBackup = Date() })
            }
            if let d = prefs.lastCloudBackup { LabeledContent("Last iCloud backup", value: d.formatted(date: .abbreviated, time: .shortened)) }
            if let d = prefs.lastFileBackup { LabeledContent("Last shared backup", value: d.formatted(date: .abbreviated, time: .shortened)) }
            if cloudBackupExists {
                Button("Delete iCloud backup", role: .destructive) {
                    CloudBackup.delete()
                    cloudBackupExists = false
                    prefs.lastCloudBackup = nil
                }
            }
        } header: {
            Text("Encrypted backup")
        } footer: {
            Text("Your keys are encrypted on this iPad (PBKDF2-SHA256, 310,000 rounds + AES-256-GCM) before they go anywhere. Without the password nobody, including Apple or Google, can open the backup. The password cannot be recovered. Backups also restore in the \(XTEConfig.ticker) phone wallet.")
        }
    }

    private func run(_ body: @escaping @MainActor () async throws -> String?) {
        working = true
        error = nil
        message = nil
        Task {
            defer { working = false }
            do { message = try await body() } catch { self.error = error.localizedDescription }
        }
    }

    private func setVault(_ on: Bool) {
        run {
            try model.setHardwareVault(on)
            return on ? "Keys are now sealed by the Secure Enclave." : "Secure Enclave protection turned off."
        }
    }

    private func setNotifications(_ on: Bool) {
        run {
            try await model.setNotifications(on)
            return on ? "Payment notifications are on." : nil
        }
    }

    private func useHighest() {
        prefs.autoLockSeconds = 0
        prefs.screenProtection = true
        run {
            if !prefs.hardwareVault { try model.setHardwareVault(true) }
            return "Secure Enclave protection on, lock immediately, hidden in the app switcher. Add an encrypted backup below."
        }
    }

    private func createBackup() {
        let pw = password
        run {
            backupText = try await model.encryptedBackup(password: pw)
            password = ""
            confirm = ""
            return "Backup encrypted. Save it to iCloud Keychain or send it to yourself."
        }
    }

    private func saveToCloud(_ text: String) {
        run {
            try CloudBackup.save(text)
            prefs.lastCloudBackup = Date()
            cloudBackupExists = true
            return "Saved to iCloud Keychain. It syncs to your other devices with iCloud Keychain turned on."
        }
    }
}
