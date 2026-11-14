// swift-tools-version:5.9
// Copyright (c) 2026, TRRXITTE Int., incorporate. Licensed under AGPL-3.0.

import PackageDescription

let package = Package(
    name: "XTEWalletCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "XTEWalletCore", targets: ["XTEWalletCore"]),
    ],
    dependencies: [
        // CryptoKit API on Linux (CI core tests); on Apple platforms CryptoKit itself is used.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"4.0.0"),
    ],
    targets: [
        // Vendored CryptoNote ed25519 + Keccak from TRRXITTE/traaitt (src/crypto),
        // plus a C port of crypto.cpp exposed through include/xte_crypto.h.
        .target(
            name: "CXTECrypto",
            path: "Sources/CXTECrypto",
            exclude: ["LICENSE-traaitt-GPL3.txt"]
        ),
        .target(
            name: "XTEWalletCore",
            dependencies: [
                "CXTECrypto",
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/XTEWalletCore"
        ),
        .testTarget(
            name: "XTEWalletCoreTests",
            dependencies: ["XTEWalletCore"],
            path: "Tests/XTEWalletCoreTests",
            resources: [.copy("Vectors")]
        ),
    ]
)
