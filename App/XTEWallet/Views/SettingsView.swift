// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import SwiftUI
import XTEWalletCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var backupKeys: WalletKeys?
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var rescanHeight = ""

    var body: some View {
        Form {
            Section("Node") {
                NavigationLink { NodeView() } label: { LabeledContent("Node", value: model.node.name) }
            }
            Section("Display") {
                LabeledContent("Currency", value: "XTE only (no fiat prices)")
                LabeledContent("Decimals", value: "\(XTEConfig.decimalPlaces)")
            }
            Section("Security") {
                NavigationLink { SecurityView() } label: { Label("Security & Backup", systemImage: "lock.shield") }
                NavigationLink { HardwareWalletView() } label: { Label("Hardware wallet / watch-only", systemImage: "cpu") }
                Button("Show backup (seed & keys)") {
                    Task {
                        do { backupKeys = try await model.keysForBackup() } catch { self.error = error.localizedDescription }
                    }
                }
                Button("Lock wallet") { model.lock() }
            }
            Section("Exchange") {
                NavigationLink { SwapView() } label: { Label("Swap from XMR", systemImage: "arrow.left.arrow.right") }
            }
            Section("Sync") {
                TextField("Rescan from height", text: $rescanHeight).keyboardType(.numberPad)
                Button("Rescan") { model.rescan(from: UInt64(rescanHeight) ?? 0) }
            }
            Section {
                Button("Delete wallet from this iPad", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("Make sure you have your 25-word seed or private keys before deleting.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                LabeledContent("License", value: "AGPL-3.0")
                Text("© TRRXITTE Int., incorporate. Includes CryptoNote, Bytecoin, Monero and TurtleCoin code.").font(.footnote)
            }
        }
        .navigationTitle("Settings")
        .sheet(item: Binding(get: { backupKeys.map { BackupBox(keys: $0) } }, set: { backupKeys = $0?.keys })) { box in
            BackupView(keys: box.keys) { backupKeys = nil }
        }
        .confirmationDialog("Delete this wallet?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do { try model.deleteWallet() } catch { self.error = error.localizedDescription }
            }
        }
    }
}

private struct BackupBox: Identifiable {
    let keys: WalletKeys
    var id: String { keys.publicSpendKey.hex }
}

struct BackupView: View {
    let keys: WalletKeys
    let done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Anyone with this information can spend your XTE. Never share it or enter it on a website.")
                        .foregroundStyle(.red)
                }
                if let words = try? keys.mnemonic() {
                    Section("Mnemonic seed (25 words)") {
                        Text(words.joined(separator: " ")).font(.body.monospaced()).textSelection(.enabled)
                    }
                } else {
                    Section("Mnemonic seed") {
                        Text("This wallet was imported from non-deterministic keys and has no mnemonic seed. Back up both private keys.")
                    }
                }
                Section("Private spend key") { Text(keys.privateSpendKey.hex).font(.caption.monospaced()).textSelection(.enabled) }
                Section("Private view key") { Text(keys.privateViewKey.hex).font(.caption.monospaced()).textSelection(.enabled) }
                Section("Address") { Text(keys.address.encoded()).font(.caption.monospaced()).textSelection(.enabled) }
            }
            .privacySensitive()
            .navigationTitle("Backup")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) } }
        }
    }
}
