// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import Foundation

/// Best-effort jailbreak indicators. A determined attacker can hide these; the wallet
/// only warns, it does not refuse to run.
enum DeviceIntegrity {
    static func indicators() -> [String] {
        #if targetEnvironment(simulator)
        return []
        #else
        var reasons: [String] = []
        let paths = [
            "/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app",
            "/Library/MobileSubstrate/MobileSubstrate.dylib", "/usr/sbin/sshd", "/bin/bash",
            "/etc/apt", "/private/var/lib/apt/", "/var/jb", "/var/binpack",
            "/usr/lib/libsubstitute.dylib", "/usr/lib/TweakInject",
        ]
        for p in paths where FileManager.default.fileExists(atPath: p) { reasons.append("Found \(p)") }
        let probe = "/private/xte-jailbreak-probe.txt"
        if (try? "x".write(toFile: probe, atomically: true, encoding: .utf8)) != nil {
            try? FileManager.default.removeItem(atPath: probe)
            reasons.append("App can write outside its sandbox")
        }
        return reasons
        #endif
    }
}
