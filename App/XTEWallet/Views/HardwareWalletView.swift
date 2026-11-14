// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import SwiftUI
import XTEWalletCore

struct HardwareWalletView: View {
    @EnvironmentObject var model: AppModel
    @State private var code: String?
    @State private var error: String?

    var body: some View {
        Form {
            ForEach(HardwareWalletProvider.all()) { p in
                Section(p.name) {
                    Text(p.detail)
                    if let reason = p.unavailableReason {
                        Label(reason, systemImage: "info.circle").foregroundStyle(.secondary).font(.footnote)
                    }
                }
            }
            if model.isViewOnly {
                Section {
                    Label("This is a watch-only wallet. It shows incoming payments; spend from the offline device.", systemImage: "eye")
                }
            }
            Section {
                Button("Show this wallet's watch-only code") {
                    Task {
                        do { code = try await model.watchOnlyCode() } catch { self.error = error.localizedDescription }
                    }
                }
                if let code {
                    if let image = QRCode.image(for: code) {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 320)
                            .privacySensitive()
                    }
                    Text(code).font(.caption2.monospaced()).textSelection(.enabled).privacySensitive()
                }
            } header: {
                Text("Pair an online device")
            } footer: {
                Text("On the device that should only watch, choose Watch-only when creating the wallet and paste or scan this code. The code contains your private view key: it cannot spend, but it reveals your incoming payments.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Hardware wallet")
    }
}

struct SwapView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Label("Not available yet", systemImage: "clock").font(.headline)
                Text("No instant-swap service lists \(XTEConfig.ticker) yet, so swapping XMR to \(XTEConfig.ticker) inside the wallet is switched off. Nothing here is simulated. As soon as an exchange lists \(XTEConfig.ticker), the swap appears here: you send XMR to the exchange's deposit address and it pays out to your wallet address. Your keys are never shared.")
                    .font(.callout)
            }
            Section("Your payout address") {
                Text(model.address).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section("Services checked (November 2026)") {
                ForEach(SwapCatalog.candidates) { c in
                    if let url = URL(string: c.url) {
                        Link(destination: url) {
                            VStack(alignment: .leading) {
                                Text(c.name)
                                Text(c.needs).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Swap from XMR")
    }
}
