// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import Foundation
import XTEWalletCore

/// Non-secret wallet data (address, sync state, history) persisted in Application Support
/// with complete file protection. Private keys never go here; they live in the Keychain.
struct WalletFile: Codable {
    var address: String
    var state: WalletState
    /// true for a watch-only (offline signer / hardware) wallet; nil for older files.
    var viewOnly: Bool?
}

enum WalletStore {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("wallet.json")
    }

    static func load() -> WalletFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WalletFile.self, from: data)
    }

    static func save(_ file: WalletFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var u = url
        let data = try JSONEncoder().encode(file)
        try data.write(to: u, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum Settings {
    private static let nodeKey = "selectedNode"
    private static let mixinKey = "mixin"

    static var selectedNode: NodeInfo {
        get {
            guard let d = UserDefaults.standard.data(forKey: nodeKey),
                  let n = try? JSONDecoder().decode(NodeInfo.self, from: d) else { return XTEConfig.defaultNode }
            return n
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: nodeKey) }
    }
}
