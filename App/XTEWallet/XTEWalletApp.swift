// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import SwiftUI
import XTEWalletCore

@main
struct XTEWalletApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var prefs = SecurityPrefs.shared
    @StateObject private var router = AppRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // BGProcessingTask handler for long background catch-up (BGAppRefreshTask is the
        // .backgroundTask modifier below). Registration must happen before launch completes.
        BackgroundSync.register()
        // Payment notification actions ("Show transactions", "Show receive QR").
        NotificationRouter.shared.install()
        WatchBridge.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(prefs)
                .environmentObject(router)
                .overlay {
                    // Hides balances and keys in the app switcher snapshot.
                    if prefs.screenProtection && scenePhase != .active { PrivacyCover() }
                }
                .onOpenURL { url in
                    // Payment URIs (xte:// / xtcash://) and internal links from widgets and Siri.
                    _ = router.handle(url: url)
                }
                .onContinueUserActivity(SharedConfig.receiveActivityType) { Handoff.continueActivity($0) }
                .onContinueUserActivity(SharedConfig.sendActivityType) { Handoff.continueActivity($0) }
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
    case wallet, send, receive, transactions, addressBook, node, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .wallet: return "Wallet"
        case .send: return "Send"
        case .receive: return "Receive"
        case .transactions: return "Transactions"
        case .addressBook: return "Address book"
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
        case .addressBook: return "person.crop.rectangle.stack"
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
    @EnvironmentObject var router: AppRouter
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
                case .addressBook: AddressBookView()
                case .node: NodeView()
                case .settings: SettingsView()
                }
            }
        }
        .onChange(of: model.pendingURI) { uri in
            if uri != nil { selection = .send }
        }
        .onAppear { if let r = router.pending { route(r) } }
        .onChange(of: router.pending) { r in if let r { route(r) } }
        .sheet(isPresented: $model.offerSecuritySetup) {
            NavigationStack { SecurityView(setup: true) }
                .interactiveDismissDisabled()
        }
    }
}

extension MainSplitView {
    func route(_ r: AppRoute) {
        router.pending = nil
        switch r {
        case .wallet: selection = .wallet
        case .receive: selection = .receive
        case .transactions: selection = .transactions
        case .addressBook: selection = .addressBook
        case let .send(amount, address):
            if let address, let uri = try? PaymentURI.parse(address) {
                var u = uri
                if u.amount == nil, let amount, let a = Amount.parse(amount) { u.amount = a }
                model.pendingURI = u
            } else {
                model.sendDraft = SendDraft(address: address, amount: amount)
            }
            selection = .send
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
