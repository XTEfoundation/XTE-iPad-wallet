// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import SwiftUI
import XTEWalletCore

struct WalletView: View {
    @EnvironmentObject var model: AppModel
    @Binding var selection: SidebarItem?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Available").font(.headline).foregroundStyle(.secondary)
                    Text(Amount.format(model.balance.unlocked)).font(.system(size: 44, weight: .bold, design: .rounded))
                    if model.balance.locked > 0 {
                        Text("Locked: \(Amount.format(model.balance.locked))").foregroundStyle(.secondary)
                    }
                    if model.state.pendingOutgoing > 0 {
                        Text("Outgoing (unconfirmed): \(Amount.format(model.state.pendingOutgoing))").foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 8)
            }
            Section("Sync") {
                SyncStatusView()
            }
            Section {
                HStack {
                    Button { selection = .send } label: { Label("Send", systemImage: "arrow.up") }
                        .buttonStyle(.borderedProminent)
                    Button { selection = .receive } label: { Label("Receive", systemImage: "arrow.down") }
                        .buttonStyle(.bordered)
                }
            }
            Section("Recent transactions") {
                if model.state.transactions.isEmpty {
                    Text("No transactions yet").foregroundStyle(.secondary)
                }
                ForEach(model.state.transactions.prefix(5)) { TransactionRow(tx: $0) }
            }
        }
        .navigationTitle("Wallet")
        .refreshable { await model.syncNow() }
    }
}

struct SyncStatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: model.syncProgress)
            HStack {
                Text("Wallet \(model.state.lastKnownBlockHeight)")
                Spacer()
                if let info = model.daemonInfo {
                    Text("Network \(info.networkTopHeight)")
                } else {
                    Text("Node offline").foregroundStyle(.red)
                }
            }
            .font(.footnote.monospacedDigit())
            HStack {
                if let e = model.syncError ?? model.nodeError {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else if model.isWalletSynced {
                    Label("Synced", systemImage: "checkmark.circle").foregroundStyle(.green)
                } else {
                    Label("Syncing… \(model.syncPercentText)", systemImage: "arrow.triangle.2.circlepath")
                }
                Spacer()
                if let at = model.lastSyncedAt {
                    Text("Last synced \(at.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                }
            }
            .font(.footnote.monospacedDigit())
            Text(model.fastPathActive ? "RPC gateway" : "Node REST API")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct TransactionRow: View {
    let tx: WalletTransaction

    var body: some View {
        HStack {
            Image(systemName: tx.amount >= 0 ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .foregroundStyle(tx.amount >= 0 ? .green : .orange)
            VStack(alignment: .leading) {
                Text(tx.hash.hex).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(tx.isConfirmed
                     ? Date(timeIntervalSince1970: TimeInterval(tx.timestamp)).formatted(date: .abbreviated, time: .shortened) + " · block \(tx.blockHeight)"
                     : "Unconfirmed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text((tx.amount >= 0 ? "+" : "−") + Amount.format(UInt64(tx.amount.magnitude)))
                .font(.body.monospacedDigit())
                .foregroundStyle(tx.amount >= 0 ? .green : .primary)
        }
    }
}

struct TransactionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(model.state.transactions) { tx in
            NavigationLink {
                TransactionDetailView(tx: tx)
            } label: {
                TransactionRow(tx: tx)
            }
        }
        .overlay { if model.state.transactions.isEmpty { Text("No transactions yet").foregroundStyle(.secondary) } }
        .refreshable { await model.syncNow() }
        .navigationTitle("Transactions")
    }
}

struct TransactionDetailView: View {
    let tx: WalletTransaction

    var body: some View {
        Form {
            LabeledContent("Amount", value: (tx.amount >= 0 ? "+" : "−") + Amount.format(UInt64(tx.amount.magnitude)))
            if tx.fee > 0 { LabeledContent("Fee", value: Amount.format(tx.fee)) }
            LabeledContent("Status", value: tx.isConfirmed ? "Confirmed in block \(tx.blockHeight)" : "Unconfirmed")
            if tx.isConfirmed {
                LabeledContent("Time", value: Date(timeIntervalSince1970: TimeInterval(tx.timestamp)).formatted())
            }
            if !tx.paymentID.isEmpty {
                LabeledContent("Payment ID") { Text(tx.paymentID).font(.caption.monospaced()).textSelection(.enabled) }
            }
            if tx.unlockTime > 0 { LabeledContent("Unlock time", value: "\(tx.unlockTime)") }
            if tx.isCoinbase { LabeledContent("Type", value: "Mined (coinbase)") }
            LabeledContent("Hash") { Text(tx.hash.hex).font(.caption.monospaced()).textSelection(.enabled) }
        }
        .navigationTitle("Transaction")
    }
}
