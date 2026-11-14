// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import SwiftUI
import XTEWalletCore

struct SendView: View {
    @EnvironmentObject var model: AppModel
    @State private var addressText = ""
    @State private var amountText = ""
    @State private var paymentID = ""
    @State private var feeText = Amount.format(XTEConfig.minimumFee, withTicker: false)
    @State private var mixin: Double = -1
    @State private var working = false
    @State private var error: String?
    @State private var prepared: PreparedTransaction?
    @State private var sentHash: String?

    private var limits: (minimum: UInt64, maximum: UInt64, defaultMixin: UInt64) {
        XTEConfig.mixinLimits(height: model.networkHeight)
    }

    private var effectiveMixin: UInt64 { mixin < 0 ? limits.defaultMixin : UInt64(mixin) }

    private var parsedAddress: XTEAddress? {
        try? XTEAddress.decode(addressText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var body: some View {
        Form {
            if model.isViewOnly {
                Section {
                    Label("Watch-only wallet: sign and send from the offline device that holds the spend key.", systemImage: "eye")
                }
            }
            Section("Recipient") {
                TextField("XTE address or xte:// link", text: $addressText, axis: .vertical)
                    .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onChange(of: addressText) { text in applyURIIfNeeded(text) }
                if !addressText.isEmpty && parsedAddress == nil {
                    Text("Not a valid XTE address").foregroundStyle(.red).font(.footnote)
                }
                Button { if let s = UIPasteboard.general.string { addressText = s } } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
            }
            Section("Amount") {
                TextField("Amount in XTE", text: $amountText).keyboardType(.decimalPad)
                Text("Available: \(Amount.format(model.balance.unlocked))").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Options") {
                if parsedAddress?.isIntegrated != true {
                    TextField("Payment ID (optional, 64 hex)", text: $paymentID).font(.body.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                HStack {
                    Text("Network fee")
                    TextField("Fee", text: $feeText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    Text(XTEConfig.ticker)
                }
                if limits.maximum != UInt64.max {
                    Stepper("Privacy (mixin): \(effectiveMixin)",
                            value: Binding(get: { Double(effectiveMixin) }, set: { mixin = $0 }),
                            in: Double(limits.minimum)...Double(limits.maximum))
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            if let sentHash {
                Section("Sent") {
                    Label("Transaction broadcast", systemImage: "checkmark.seal").foregroundStyle(.green)
                    Text(sentHash).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Section {
                Button(action: review) {
                    HStack { Spacer(); if working { ProgressView() } else { Text("Review transaction") }; Spacer() }
                }
                .disabled(working || parsedAddress == nil || Amount.parse(amountText) == nil || !model.isWalletSynced)
                if !model.isWalletSynced {
                    Text("Wait until the wallet is fully synced before sending.").font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Transactions are built and ring-signed on this iPad with the CryptoNote primitives from traaitt and relayed to the selected node. Private keys never leave the device.")
            }
        }
        .navigationTitle("Send")
        .onAppear { if let uri = model.pendingURI { apply(uri) } }
        .onChange(of: model.pendingURI) { uri in if let uri { apply(uri) } }
        .sheet(item: Binding(get: { prepared.map { PreparedBox(tx: $0) } }, set: { prepared = $0?.tx })) { box in
            ConfirmSendView(tx: box.tx, destination: addressText) { confirmed in
                prepared = nil
                if confirmed { Task { await broadcast(box.tx) } }
            }
        }
    }

    private func applyURIIfNeeded(_ text: String) {
        let lower = text.lowercased()
        guard lower.hasPrefix("xte:") || lower.hasPrefix("traaitt:"), let uri = try? PaymentURI.parse(text) else { return }
        apply(uri)
    }

    private func apply(_ uri: PaymentURI) {
        addressText = uri.address
        if let a = uri.amount { amountText = Amount.format(a, withTicker: false).replacingOccurrences(of: ",", with: "") }
        if let p = uri.paymentID { paymentID = p }
        model.pendingURI = nil
    }

    private func review() {
        error = nil
        sentHash = nil
        guard let dest = parsedAddress else { error = "Invalid address"; return }
        guard let amount = Amount.parse(amountText), amount > 0 else { error = "Invalid amount"; return }
        guard let fee = Amount.parse(feeText) else { error = "Invalid fee"; return }
        let pid = paymentID.trimmingCharacters(in: .whitespaces)
        if !pid.isEmpty && !isHex64(pid) { error = "Payment ID must be 64 hex characters"; return }
        working = true
        Task {
            defer { working = false }
            do {
                prepared = try await model.prepare(.init(destination: dest, amount: amount, paymentID: pid.isEmpty ? nil : pid,
                                                         fee: fee, mixin: effectiveMixin))
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func broadcast(_ tx: PreparedTransaction) async {
        working = true
        defer { working = false }
        do {
            try await KeychainStore.authenticate(reason: "Confirm sending \(Amount.format(tx.amount))")
            try await model.broadcast(tx)
            sentHash = tx.hash.hex
            amountText = ""
            paymentID = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PreparedBox: Identifiable {
    let tx: PreparedTransaction
    var id: String { tx.hash.hex }
}

struct ConfirmSendView: View {
    let tx: PreparedTransaction
    let destination: String
    let completion: (Bool) -> Void

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("To") { Text(destination).font(.caption.monospaced()) }
                LabeledContent("Amount", value: Amount.format(tx.amount))
                LabeledContent("Network fee", value: Amount.format(tx.fee))
                if tx.nodeFee > 0 { LabeledContent("Node fee", value: Amount.format(tx.nodeFee)) }
                LabeledContent("Total", value: Amount.format(tx.amount + tx.fee + tx.nodeFee)).bold()
                if let pid = tx.paymentID { LabeledContent("Payment ID") { Text(pid).font(.caption.monospaced()) } }
                LabeledContent("Inputs / outputs", value: "\(tx.transaction.inputs.count) / \(tx.transaction.outputs.count)")
                LabeledContent("Ring size", value: "\(tx.transaction.inputs.first?.keyOffsets.count ?? 0)")
                LabeledContent("Size", value: "\(tx.hex.count / 2) bytes")
                Section {
                    Button("Send") { completion(true) }.bold()
                    Button("Cancel", role: .cancel) { completion(false) }
                }
            }
            .navigationTitle("Confirm")
        }
    }
}
