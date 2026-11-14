// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import SwiftUI
import XTEWalletCore

struct OnboardingView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case create = "Create", seed = "Seed", keys = "Keys", backup = "Encrypted backup", watch = "Watch-only"
        var id: String { rawValue }
    }

    @EnvironmentObject var model: AppModel
    @State private var mode: Mode = .create
    @State private var generated = WalletKeys.generate()
    @State private var confirmedBackup = false
    @State private var seedText = ""
    @State private var spendKey = ""
    @State private var viewKey = ""
    @State private var scanHeight = ""
    @State private var scanFrom: ScanFrom = .date
    @State private var createdDate = Date(timeIntervalSince1970: TimeInterval(XTEConfig.scanHeightCheckpoints.first?.timestamp ?? 0))
    @State private var backupText = ""
    @State private var backupPassword = ""
    @State private var watchCode = ""
    @State private var working = false
    @State private var error: String?

    enum ScanFrom: String, CaseIterable, Identifiable {
        case date = "Creation date", height = "Block height"
        var id: String { rawValue }
    }

    private var chosenScanHeight: UInt64 {
        switch scanFrom {
        case .date: return ScanHeight.scanHeight(forWalletCreatedAt: createdDate)
        case .height: return UInt64(scanHeight.trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .feedback(on: mode)
                    .pickerStyle(.segmented)
                }
                switch mode {
                case .create: createSection
                case .seed: seedSection
                case .keys: keysSection
                case .backup: backupSection
                case .watch: watchSection
                }
                if mode == .seed || mode == .keys {
                    Section {
                        Picker("Start scanning from", selection: $scanFrom) {
                            ForEach(ScanFrom.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .feedback(on: scanFrom)
                        .pickerStyle(.segmented)
                        if scanFrom == .date {
                            DatePicker("Wallet created around", selection: $createdDate, in: ...Date(), displayedComponents: .date)
                        } else {
                            TextField("0 (scan whole chain)", text: $scanHeight).keyboardType(.numberPad)
                        }
                        LabeledContent("Scan starts at block", value: "\(chosenScanHeight)")
                    } header: {
                        Text("Restore from")
                    } footer: {
                        Text("Pick the day the wallet was created (or earlier) to sync much faster. The oldest date scans the whole chain. Starting after your first payment hides it until you rescan.")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button(action: submit) {
                        Text(mode == .create ? "Create wallet" : mode == .watch ? "Add watch-only wallet" : "Restore wallet")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled((mode == .create && !confirmedBackup) || working)
                }
            }
            .navigationTitle("XTE Wallet")
        }
    }

    private var createSection: some View {
        Section {
            let words = (try? generated.mnemonic()) ?? []
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), alignment: .leading) {
                ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                    Text("\(i + 1). \(w)").font(.body.monospaced())
                }
            }
            .padding(.vertical, 4)
            .privacySensitive()
            Text(generated.address.encoded()).font(.caption.monospaced()).textSelection(.enabled)
            Toggle("I wrote down these 25 words. Anyone with them can spend my XTE.", isOn: $confirmedBackup)
                .feedback(on: confirmedBackup)
            Button("Generate another") { generated = WalletKeys.generate(); confirmedBackup = false }
        } header: {
            Text("Your mnemonic seed")
        }
    }

    private var seedSection: some View {
        Section("25-word mnemonic seed") {
            TextEditor(text: $seedText)
                .frame(minHeight: 120)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private var keysSection: some View {
        Section("Private keys") {
            SecureField("Private spend key (64 hex)", text: $spendKey)
                .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Private view key (64 hex)", text: $viewKey)
                .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }

    private var backupSection: some View {
        Section {
            TextEditor(text: $backupText)
                .frame(minHeight: 120)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Load from iCloud Keychain") {
                do {
                    if let text = try CloudBackup.load() { backupText = text } else { error = "No iCloud backup found for \(XTEConfig.ticker)." }
                } catch { self.error = error.localizedDescription }
            }
            Button("Paste") { backupText = UIPasteboard.general.string ?? "" }
            SecureField("Backup password", text: $backupPassword)
        } header: {
            Text("Encrypted backup")
        } footer: {
            Text("Paste the backup you emailed or saved (from this iPad or the \(XTEConfig.ticker) phone wallet), or load the one in iCloud Keychain.")
        }
    }

    private var watchSection: some View {
        Section {
            TextEditor(text: $watchCode)
                .frame(minHeight: 100)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Paste") { watchCode = UIPasteboard.general.string ?? "" }
        } header: {
            Text("Watch-only code (xtewatch:…)")
        } footer: {
            Text("From the offline device: Settings > Hardware wallet > Show this wallet's watch-only code. This iPad will see incoming payments but cannot spend.")
        }
    }

    private func submit() {
        error = nil
        if mode == .backup {
            let text = backupText, pw = backupPassword
            working = true
            Task {
                defer { working = false }
                do {
                    try model.restoreBackup(text, password: pw)
                } catch {
                    self.error = error.localizedDescription
                }
            }
            return
        }
        do {
            let height = chosenScanHeight
            switch mode {
            case .backup:
                break
            case .watch:
                let payload = try WatchOnlyPayload.parse(watchCode)
                try model.createWatchOnlyWallet(try payload.keys(), scanHeight: payload.scanHeight)
            case .create:
                try model.createWallet(generated, scanHeight: nil)
            case .seed:
                try model.createWallet(try WalletKeys.fromMnemonic(seedText), scanHeight: height)
            case .keys:
                try model.createWallet(try WalletKeys.fromKeys(privateSpendKeyHex: spendKey.trimmingCharacters(in: .whitespaces),
                                                               privateViewKeyHex: viewKey.trimmingCharacters(in: .whitespaces)),
                                       scanHeight: height)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
