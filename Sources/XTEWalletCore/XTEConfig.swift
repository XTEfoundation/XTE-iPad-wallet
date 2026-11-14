// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.
//
// Network parameters for traaitt [XTE]. Values are taken from
// https://github.com/TRRXITTE/traaitt/blob/master/src/config/CryptoNoteConfig.h
// and https://github.com/trrxitte/xte-wallet-backend-js/blob/master/lib/Config.ts

import Foundation

public enum XTEConfig {
    public static let ticker = "XTE"
    public static let coinName = "traaitt"

    /// CRYPTONOTE_PUBLIC_ADDRESS_BASE58_PREFIX
    public static let addressPrefix: UInt64 = 1334

    /// CRYPTONOTE_DISPLAY_DECIMAL_POINT
    public static let decimalPlaces = 2

    /// MINIMUM_FEE (atomic units)
    public static let minimumFee: UInt64 = 100

    /// DIFFICULTY_TARGET (seconds)
    public static let blockTargetSeconds: UInt64 = 45

    /// CRYPTONOTE_MINED_MONEY_UNLOCK_WINDOW
    public static let minedMoneyUnlockWindow: UInt64 = 40

    /// CRYPTONOTE_MAX_BLOCK_NUMBER - unlockTime below this is a block height, otherwise a unix timestamp.
    public static let maxBlockNumber: UInt64 = 500_000_000

    /// CRYPTONOTE_LOCKED_TX_ALLOWED_DELTA_BLOCKS / _SECONDS
    public static let lockedTxAllowedDeltaBlocks: UInt64 = 1
    public static let lockedTxAllowedDeltaSeconds: UInt64 = 45

    /// GENESIS_BLOCK_TIMESTAMP
    public static let genesisBlockTimestamp: UInt64 = 1_686_748_487

    /// MAX_OUTPUT_SIZE_CLIENT
    public static let maxOutputSizeClient: UInt64 = 100_000_000_000_00

    /// MAX_EXTRA_SIZE_V2 / MAX_EXTRA_SIZE_V2_HEIGHT
    public static let maxExtraSizeV2: Int = 1024
    public static let maxExtraSizeV2Height: UInt64 = 1_300_000

    /// Mixin limits by height (MIXIN_LIMITS_V1/V2/V3_HEIGHT).
    public static func mixinLimits(height: UInt64) -> (minimum: UInt64, maximum: UInt64, defaultMixin: UInt64) {
        if height >= 1_000_000 { return (0, 8, 8) }
        if height >= 800_000 { return (0, 5, 5) }
        if height >= 440_000 { return (0, 4, 4) }
        return (0, UInt64.max, 3)
    }

    /// WalletConfig.h standardAddressLength: varint(1334) + 32 + 32 + 4-byte checksum -> 97 base58 chars.
    public static let standardAddressLength = 97
    /// integratedAddressLength = standard + (64 * 11) / 8 = 185.
    public static let integratedAddressLength = 185

    public static let uriSchemes = ["xte", "traaitt"]

    /// Default node (TLS) and the public node list used by the official wallets.
    public static let defaultNode = NodeInfo(name: "XTE main (SSL)", host: "main.trrxitte.com", port: 443, ssl: true)
    public static let nodeListURL = URL(string: "https://raw.githubusercontent.com/TRRXITTE/XTEnetworkserver/refs/heads/main/traaitt.json")!

    /// BLOCKS_SYNCHRONIZING_DEFAULT_COUNT used by the wallet backend.
    public static let blocksPerSyncRequest: UInt64 = 100

    /// JSON-RPC namespace of xte-rpc-gateway (https://<host>/rpc/xte, xte_syncBlocks).
    public static let gatewayNamespace = "xte"
    /// Blocks per xte_syncBlocks call (the gateway's maxSyncBlocks).
    public static let gatewayBlocksPerRequest: UInt64 = 1000
}
