// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import Foundation
import SwiftUI
import XTEWalletCore

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable { case onboarding, locked, unlocked }

    @Published private(set) var phase: Phase
    @Published private(set) var address: String = ""
    @Published private(set) var state = WalletState()
    @Published private(set) var daemonInfo: DaemonInfo?
    @Published private(set) var nodeError: String?
    @Published private(set) var syncError: String?
    @Published private(set) var isSyncing = false
    /// The node's fast RPC gateway is in use for sync (otherwise the REST API).
    @Published private(set) var fastPathActive = false
    @Published var node: NodeInfo {
        didSet {
            Settings.selectedNode = node
            // Failover inside the running sync loop switches nodes without cancelling it.
            if node != oldValue && !switchingNodeInSync { restartSync() }
        }
    }
    private var switchingNodeInSync = false
    /// Incremented per restart; a superseded sync loop never touches the UI state.
    private var syncGeneration = 0
    @Published var nodes: [NodeInfo] = [XTEConfig.defaultNode]
    @Published var pendingURI: PaymentURI?
    /// Pre-filled Send screen from Siri, widgets, Handoff or a notification.
    @Published var sendDraft: SendDraft?
    @Published var lastError: String?
    /// Set after create/restore so the UI can offer Security & Backup once.
    @Published var offerSecuritySetup = false
    @Published private(set) var isViewOnly = false

    private var keys: WalletKeys?
    private var viewKeys: ViewOnlyKeys?
    private var syncTask: Task<Void, Never>?
    private var backgroundedAt: Date?
    let prefs = SecurityPrefs.shared

    init() {
        node = Settings.selectedNode
        if let file = WalletStore.load() {
            address = file.address
            state = file.state
            isViewOnly = file.viewOnly ?? false
            phase = .locked
        } else {
            phase = .onboarding
        }
    }

    var daemon: DaemonClient { DaemonClient(node: node) }

    var networkHeight: UInt64 { daemonInfo?.networkTopHeight ?? state.lastKnownBlockHeight }

    var balance: (unlocked: UInt64, locked: UInt64) { state.balance(currentHeight: networkHeight) }

    var syncProgress: Double {
        guard let top = daemonInfo?.networkTopHeight, top > 0 else { return 0 }
        return min(1, Double(state.lastKnownBlockHeight) / Double(top))
    }

    var isWalletSynced: Bool {
        guard let top = daemonInfo?.networkTopHeight else { return false }
        return state.lastKnownBlockHeight + 1 >= top
    }

    // MARK: Wallet lifecycle

    func createWallet(_ newKeys: WalletKeys, scanHeight: UInt64?) throws {
        try KeychainStore.save(newKeys)
        viewKeys = nil
        isViewOnly = false
        var s = WalletState()
        if let h = scanHeight {
            s.startHeight = h
        } else {
            // Brand new wallet: nothing can exist before now.
            s.startTimestamp = UInt64(Date().timeIntervalSince1970) - 600
        }
        keys = newKeys
        address = newKeys.address.encoded()
        state = s
        try persist()
        phase = .unlocked
        offerSecuritySetup = !prefs.setupOffered
        restartSync()
    }

    /// Watch-only wallet (offline signer / hardware wallet): sees incoming payments, cannot spend.
    func createWatchOnlyWallet(_ view: ViewOnlyKeys, scanHeight: UInt64) throws {
        try KeychainStore.save(viewOnly: view)
        keys = nil
        viewKeys = view
        isViewOnly = true
        address = view.address.encoded()
        state = WalletState(startHeight: scanHeight)
        try persist()
        phase = .unlocked
        offerSecuritySetup = !prefs.setupOffered
        restartSync()
    }

    /// Restores from an encrypted backup (phone or iPad format).
    func restoreBackup(_ text: String, password: String) throws {
        let (backupAddress, secrets) = try WalletBackup.decrypt(text, password: password)
        let restored = try WalletKeys.fromKeys(privateSpendKeyHex: secrets.spendKey, privateViewKeyHex: secrets.viewKey)
        guard restored.address.encoded() == backupAddress else { throw WalletBackupError.corrupt }
        try createWallet(restored, scanHeight: secrets.scanHeight)
    }

    func unlock() {
        do {
            let stored = try KeychainStore.loadWallet(reason: "Unlock your \(XTEConfig.ticker) wallet")
            guard stored.address == address else {
                lastError = "Keychain keys do not match this wallet."
                return
            }
            switch stored {
            case .full(let k): keys = k; viewKeys = nil
            case .viewOnly(let v): keys = nil; viewKeys = v
            }
            lastError = nil
            phase = .unlocked
            restartSync()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func lock() {
        LiveActivities.endSync()
        AddressBook.shared.lock()
        syncTask?.cancel()
        syncTask = nil
        keys = nil
        viewKeys = nil
        if phase == .unlocked { phase = .locked }
    }

    // MARK: Auto-lock

    func didEnterBackground() {
        backgroundedAt = Date()
        try? persist()
        if prefs.autoLockSeconds == 0 { lock() }
        BackgroundSync.scheduleAll()
    }

    func didBecomeActive() {
        defer { backgroundedAt = nil }
        // With "lock immediately" the wallet was already locked when it went to the background;
        // locking again here would cancel the sync the user just unlocked (shown as "cancelled").
        guard prefs.autoLockSeconds > 0, phase == .unlocked, let t = backgroundedAt else { return }
        if Date().timeIntervalSince(t) >= TimeInterval(prefs.autoLockSeconds) { lock() }
    }

    // MARK: Security settings

    /// Re-writes the Keychain item with or without the Secure Enclave wrap.
    func setHardwareVault(_ on: Bool) throws {
        let stored: StoredWallet
        if let keys { stored = .full(keys) } else if let viewKeys { stored = .viewOnly(viewKeys) } else {
            throw TransferError.viewOnlyWallet
        }
        let previous = prefs.hardwareVault
        prefs.hardwareVault = on
        do {
            try KeychainStore.save(stored)
        } catch {
            prefs.hardwareVault = previous
            throw error
        }
    }

    /// Opt-in background sync. Stores the view-only key (cannot spend) like notifications.
    func setBackgroundSync(_ on: Bool) throws {
        if on {
            if KeychainStore.loadNotificationKeys() == nil {
                let view = keys.map(ViewOnlyKeys.init(keys:)) ?? viewKeys
                guard let view else { throw TransferError.viewOnlyWallet }
                try KeychainStore.saveNotificationKeys(view)
            }
            if PaymentNotifier.nextHeight == 0 { PaymentNotifier.markSeen(height: state.lastKnownBlockHeight) }
            prefs.backgroundSync = true
            updateSyncAnchor()
            BackgroundSync.scheduleAll()
        } else {
            prefs.backgroundSync = false
            BackgroundSync.cache.clear()
            BackgroundSync.cancelAll()
            if !prefs.notifications { KeychainStore.deleteNotificationKeys() }
        }
    }

    /// Tells background sync where the wallet stands (it cannot read the protected wallet file).
    private func updateSyncAnchor() {
        guard prefs.backgroundSync else { return }
        BackgroundSync.cache.setAnchor(BlockCacheAnchor(height: state.lastKnownBlockHeight, hash: state.lastKnownBlockHashes.first))
    }

    func setNotifications(_ on: Bool) async throws {
        if on {
            guard await PaymentNotifier.requestPermission() else {
                throw NSError(domain: "Notifications", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Allow notifications for this app in iOS Settings."])
            }
            let view = keys.map(ViewOnlyKeys.init(keys:)) ?? viewKeys
            guard let view else { throw TransferError.viewOnlyWallet }
            try KeychainStore.saveNotificationKeys(view)
            PaymentNotifier.markSeen(height: state.lastKnownBlockHeight)
            prefs.notifications = true
            PaymentNotifier.schedule()
        } else {
            prefs.notifications = false
            if !prefs.backgroundSync {
                KeychainStore.deleteNotificationKeys()
                PaymentNotifier.cancel()
            }
        }
    }

    /// Encrypted backup text; asks for Face ID / passcode first.
    func encryptedBackup(password: String) async throws -> String {
        let k = try await keysForBackup()
        let height = state.startHeight > 0 ? state.startHeight
            : (state.startTimestamp > 0 ? ScanHeight.scanHeight(forWalletCreatedAt: Date(timeIntervalSince1970: TimeInterval(state.startTimestamp))) : 0)
        let secrets = BackupSecrets(spendKey: k.privateSpendKey.hex, viewKey: k.privateViewKey.hex, scanHeight: height,
                                    createdAt: ISO8601DateFormatter().string(from: Date()))
        let address = self.address
        return try await Task.detached(priority: .userInitiated) {
            try WalletBackup.encrypt(secrets, address: address, password: password)
        }.value
    }

    /// Watch-only code for this wallet (view key + address); asks for Face ID / passcode first.
    func watchOnlyCode() async throws -> String {
        try await KeychainStore.authenticate(reason: "Show the watch-only code")
        let view = keys.map(ViewOnlyKeys.init(keys:)) ?? viewKeys
        guard let view else { throw TransferError.viewOnlyWallet }
        return WatchOnlyPayload(address: address, viewKey: view.privateViewKey.hex, scanHeight: state.startHeight).encoded()
    }

    func deleteWallet() throws {
        lock()
        try KeychainStore.delete()
        KeychainStore.deleteNotificationKeys()
        PaymentNotifier.cancel()
        BackgroundSync.cancelAll()
        BackgroundSync.cache.clear()
        prefs.resetForNewWallet()
        WalletStore.delete()
        WidgetPublisher.clear()
        state = WalletState()
        address = ""
        phase = .onboarding
    }

    /// Requires a fresh Face ID / Touch ID / passcode check, then returns the keys for display.
    func keysForBackup() async throws -> WalletKeys {
        if isViewOnly { throw TransferError.viewOnlyWallet }
        try await KeychainStore.authenticate(reason: "Show your private keys and mnemonic seed")
        if let keys { return keys }
        return try KeychainStore.load(reason: "Show your private keys and mnemonic seed")
    }

    func rescan(from height: UInt64) {
        BackgroundSync.cache.clear()
        state = WalletState(startHeight: height)
        try? persist()
        restartSync()
    }

    private func persist() throws {
        try WalletStore.save(WalletFile(address: address, state: state, viewOnly: isViewOnly ? true : nil))
        updateSyncAnchor()
    }

    // MARK: Node

    func refreshNodeList() async {
        do {
            var list = try await DaemonClient.fetchNodeList()
            if !list.contains(XTEConfig.defaultNode) { list.insert(XTEConfig.defaultNode, at: 0) }
            nodes = list
        } catch {
            nodeError = "Could not load node list: \(error.localizedDescription)"
        }
    }

    func refreshInfo() async {
        do {
            daemonInfo = try await daemon.info()
            nodeError = nil
            fastPathActive = await GatewayRegistry.shared.isActive(for: node)
        } catch {
            daemonInfo = nil
            nodeError = error.localizedDescription
            // The built-in default node is unreachable: fail over once to the first public
            // node from the official list that answers. A node the user picked is never replaced.
            if node == XTEConfig.defaultNode, let alternative = await firstReachablePublicNode() {
                nodeError = nil
                switchingNodeInSync = true
                node = alternative   // persisted; the running sync loop picks it up
                switchingNodeInSync = false
            }
        }
    }

    private func firstReachablePublicNode() async -> NodeInfo? {
        if nodes.count <= 1 { await refreshNodeList() }
        for candidate in nodes where candidate != XTEConfig.defaultNode {
            if (try? await DaemonClient(node: candidate, timeout: 10).info()) != nil { return candidate }
        }
        return nil
    }

    // MARK: Sync

    func restartSync() {
        syncTask?.cancel()
        syncTask = nil
        syncGeneration += 1
        isSyncing = false
        syncError = nil
        guard phase == .unlocked else { return }
        let scanner: BlockScanner
        if let keys { scanner = BlockScanner(keys: keys) } else if let viewKeys { scanner = viewKeys.scanner } else { return }
        let synchronizer = WalletSynchronizer(scanner: scanner)
        let generation = syncGeneration
        syncTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.syncGeneration == generation else { return }
                await self.refreshInfo()
                guard !Task.isCancelled, self.syncGeneration == generation else { return }
                // After a failover this is the new node. Blocks prefetched by background sync
                // are read from disk first; the node (fast gateway or REST) supplies the rest.
                let client = PrefetchedDaemon(base: self.daemon, cache: BackgroundSync.cache)
                var caughtUp = false
                var failed = false
                do {
                    self.isSyncing = true
                    var rounds = 0
                    while !Task.isCancelled && rounds < 50 {
                        var working = self.state
                        caughtUp = try await synchronizer.syncOnce(daemon: client, state: &working)
                        rounds += 1
                        guard !Task.isCancelled, self.syncGeneration == generation else { return }
                        self.merge(working)
                        self.publishPlatformState()
                        failures = 0
                        self.syncError = nil
                        if !self.fastPathActive, await GatewayRegistry.shared.isActive(for: self.node) { self.fastPathActive = true }
                        if caughtUp { break }
                        if rounds % 5 == 0 { try? self.persist() }
                    }
                    let pending = self.state.pendingTransactionHashes
                    if !pending.isEmpty, let status = try? await client.transactionsStatus(hashes: pending), !Task.isCancelled {
                        var s = self.state
                        s.applyStatus(status)
                        self.state = s
                    }
                    self.publishPlatformState()
                    try? self.persist()
                    if caughtUp { PaymentNotifier.markSeen(height: self.state.lastKnownBlockHeight) }
                } catch {
                    // A cancelled request is a restart/lock, not a failure: never show it.
                    if Task.isCancelled || isCancellation(error) || self.syncGeneration != generation { return }
                    failures += 1
                    failed = true
                    // Retry transient errors quietly; only report a problem that persists.
                    if failures >= 3 { self.syncError = error.localizedDescription }
                }
                self.isSyncing = false
                if caughtUp {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                } else if failed {
                    try? await Task.sleep(nanoseconds: UInt64(min(failures, 6)) * 2_500_000_000)
                }
            }
        }
    }

    /// Adopts a freshly synced state while keeping sends that were broadcast during the network call.
    private func merge(_ synced: WalletState) {
        var s = synced
        for t in state.transactions where !t.isConfirmed && !s.transactions.contains(where: { $0.hash == t.hash }) {
            s.transactions.insert(t, at: 0)
        }
        for o in state.outputs where o.pendingSpendTxHash != nil {
            if let i = s.outputs.firstIndex(where: { $0.key == o.key }), s.outputs[i].spendHeight == nil {
                s.outputs[i].pendingSpendTxHash = o.pendingSpendTxHash
            }
        }
        state = s
    }

    // MARK: Send

    struct SendRequest {
        var destination: XTEAddress
        var amount: UInt64
        var paymentID: String?
        var fee: UInt64
        var mixin: UInt64
    }

    /// Builds and signs; does not broadcast. Shown to the user for confirmation.
    func prepare(_ request: SendRequest) async throws -> PreparedTransaction {
        guard let keys else { throw TransferError.viewOnlyWallet }
        let client = daemon
        let info = try await client.info()
        daemonInfo = info
        var nodeFee: (address: XTEAddress, amount: UInt64)?
        if let fee = try? await client.fee(), fee.amount > 0, let addr = try? XTEAddress.decode(fee.address) {
            nodeFee = (address: addr, amount: fee.amount)
        }
        return try await TransactionBuilder.build(
            keys: keys,
            destinations: [Destination(address: request.destination, amount: request.amount)],
            paymentID: request.paymentID, fee: request.fee, mixin: request.mixin,
            nodeFee: nodeFee,
            spendable: state.spendableOutputs(currentHeight: info.networkTopHeight),
            networkHeight: info.networkTopHeight,
            decoys: DaemonDecoySource(daemon: client))
    }

    func broadcast(_ tx: PreparedTransaction, destination: String = "") async throws {
        try await daemon.sendRawTransaction(hex: tx.hex)
        state.recordSent(tx)
        try? persist()
        LiveActivities.startSend(hash: tx.hash.hex, amountText: Amount.format(tx.amount), destination: destination,
                                 networkHeight: networkHeight)
        publishPlatformState()
    }

    // MARK: Widgets, Live Activities, watch

    /// Public data only (address, balance, last payment); never keys.
    func publishPlatformState() {
        guard phase == .unlocked, !address.isEmpty else { return }
        WidgetPublisher.publish(address: address, state: state, networkHeight: networkHeight)
        if let top = daemonInfo?.networkTopHeight {
            LiveActivities.updateSync(walletHeight: state.lastKnownBlockHeight, networkHeight: top)
            LiveActivities.updateSends(state.transactions, networkHeight: top)
        }
    }
}

/// Values for the Send screen (address may be a payment URI).
struct SendDraft: Equatable {
    var address: String?
    var amount: String?
}
