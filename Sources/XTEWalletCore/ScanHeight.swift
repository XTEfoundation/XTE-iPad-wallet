// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import Foundation

/// Converts dates to block heights using real-chain checkpoints (same algorithm as the
/// React Native wallets' Utilities.getApproximateBlockHeight / dateToScanHeight).
public enum ScanHeight {
    /// One day of blocks at the target block time, subtracted as a safety margin.
    public static var margin: UInt64 {
        UInt64((24.0 * 60 * 60 / Double(XTEConfig.blockTargetSeconds)).rounded(.up))
    }

    public static func approximateHeight(at date: Date,
                                         checkpoints: [(height: UInt64, timestamp: UInt64)] = XTEConfig.scanHeightCheckpoints) -> UInt64 {
        let time = date.timeIntervalSince1970
        guard let first = checkpoints.first else {
            let elapsed = max(0, time - Double(XTEConfig.genesisBlockTimestamp))
            return UInt64(elapsed / Double(XTEConfig.blockTargetSeconds * 3))
        }
        if time <= Double(first.timestamp) { return 0 }
        for i in 0..<(checkpoints.count - 1) {
            let a = checkpoints[i], b = checkpoints[i + 1]
            if time < Double(b.timestamp) {
                let fraction = (time - Double(a.timestamp)) / Double(b.timestamp - a.timestamp)
                return a.height + UInt64((Double(b.height - a.height) * fraction).rounded(.down))
            }
        }
        let last = checkpoints[checkpoints.count - 1]
        // Past the last checkpoint: extrapolate conservatively (3x target) so we never overshoot the tip.
        return last.height + UInt64((time - Double(last.timestamp)) / Double(XTEConfig.blockTargetSeconds * 3))
    }

    /// Height to start scanning for a wallet created at `date` (clamped to now, minus one day of margin).
    public static func scanHeight(forWalletCreatedAt date: Date, now: Date = Date()) -> UInt64 {
        let h = approximateHeight(at: min(date, now))
        return h > margin ? h - margin : 0
    }
}
