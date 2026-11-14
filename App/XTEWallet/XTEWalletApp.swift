// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import SwiftUI
import XTEWalletCore

@main
struct XTEWalletApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var prefs = SecurityPrefs.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // BGProcessingTask handler for long background catch-up (BGAppRefreshTask is the
        // .backgroundTask modifier below). Registration must happen before launch completes.
        BackgroundSync.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(prefs)
                .overlay {
                    // Hides balances and keys in the app switcher snapshot.
                    if prefs.screenProtection && scenePhase != .active { PrivacyCover() }
                }
                .onOpenURL { url in
                    if let uri = try? PaymentURI.parse(url.absoluteString) {
                        model.pendingURI = uri
                    }
                }
        }
        .onChange(of: scenePhase) { phase in
            // Drop keys from memory when the app leaves the foreground (or after the
            // auto-lock delay chosen in Security & Backup).
            switch phase {
            case .background: model.didEnterBackground()
            case .active: model.didBecomeActive()
            default: break
            }
        }
        .backgroundTask(.appRefresh(PaymentNotifier.taskIdentifier)) {
            await PaymentNotifier.checkForPayments()
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case wallet, send, receive, transactions, node, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wallet: return "Wallet"
        case .send: return "Send"
        case .receive: return "Receive"
        case .transactions: return "Transactions"
        case .node: return "Node"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .wallet: return "creditcard"
        case .send: return "arrow.up.circle"
        case .receive: return "qrcode"
        case .transactions: return "list.bullet.rectangle"
        case .node: return "server.rack"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: SecurityPrefs
    @State private var integrityWarnings: [String] = []

    var body: some View {
        Group {
            switch model.phase {
            case .onboarding: OnboardingView()
            case .locked: LockedView()
            case .unlocked: MainSplitView()
            }
        }
        .onAppear { integrityWarnings = DeviceIntegrity.indicators() }
        .alert("This iPad looks jailbroken", isPresented: Binding(
            get: { !integrityWarnings.isEmpty && !prefs.compromisedAcknowledged },
            set: { if !$0 { prefs.compromisedAcknowledged = true } })) {
            Button("I understand the risk") { prefs.compromisedAcknowledged = true }
        } message: {
            Text("Other apps may be able to read your wallet keys. Use a device that is not jailbroken for real funds.\n\n"
                 + integrityWarnings.joined(separator: "\n"))
        }
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial)
            Image(systemName: "lock.shield").font(.system(size: 64)).foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
    }
}

struct MainSplitView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: SidebarItem? = .wallet

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                NavigationLink(value: item) { Label(item.title, systemImage: item.icon) }
            }
            .navigationTitle("XTE")
        } detail: {
            NavigationStack {
                switch selection ?? .wallet {
                case .wallet: WalletView(selection: $selection)
                case .send: SendView()
                case .receive: ReceiveView()
                case .transactions: TransactionsView()
                case .node: NodeView()
                case .settings: SettingsView()
                }
            }
        }
        .onChange(of: model.pendingURI) { uri in
            if uri != nil { selection = .send }
        }
        .sheet(isPresented: $model.offerSecuritySetup) {
            NavigationStack { SecurityView(setup: true) }
                .interactiveDismissDisabled()
        }
    }
}

struct LockedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.shield").font(.system(size: 72)).foregroundStyle(.tint)
            Text("XTE Wallet is locked").font(.title)
            Text(model.address).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 420)
            Button("Unlock") { model.unlock() }
                .buttonStyle(.borderedProminent).controlSize(.large)
            if let e = model.lastError { Text(e).foregroundStyle(.red) }
        }
        .padding()
        .onAppear { model.unlock() }
    }
}
