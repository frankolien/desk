// swift-tools-version: 6.2
import PackageDescription

// DeskKit: everything that is not a screen. Module boundaries are load-bearing —
// DeskMoney has no dependencies and therefore cannot reach the network, and nothing
// outside it does arithmetic on a price or a size.
let package = Package(
    name: "DeskKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "DeskMoney", targets: ["DeskMoney"]),
        .library(name: "DeskNet", targets: ["DeskNet"]),
        .library(name: "DeskAuth", targets: ["DeskAuth"]),
        .library(name: "DeskPerpl", targets: ["DeskPerpl"]),
        .library(name: "DeskChain", targets: ["DeskChain"]),
        .library(name: "DeskFlow", targets: ["DeskFlow"]),
        .library(name: "DeskUI", targets: ["DeskUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift", exact: "1.10.0"),
    ],
    targets: [
        .target(
            name: "DeskMoney",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DeskMoneyTests",
            dependencies: ["DeskMoney"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DeskNet",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DeskNetTests",
            dependencies: ["DeskNet"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DeskAuth",
            dependencies: [
                .product(name: "P256K", package: "swift-secp256k1"),
                .product(name: "CryptoSwift", package: "CryptoSwift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DeskAuthTests",
            dependencies: ["DeskAuth"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DeskChain",
            dependencies: ["DeskAuth", "DeskMoney", "DeskNet"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DeskChainTests",
            dependencies: ["DeskChain"],
            resources: [.process("EnrolmentPayload.json"), .process("EIP712Vectors.json"), .process("TransactionVectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DeskPerpl",
            dependencies: ["DeskAuth", "DeskMoney", "DeskNet"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DeskPerplTests",
            dependencies: ["DeskPerpl", "DeskNet"],
            resources: [.process("CanonicalVectors.json"), .process("Context-testnet.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DeskUI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DeskUITests",
            dependencies: ["DeskUI"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DeskFlow",
            dependencies: ["DeskAuth", "DeskChain", "DeskMoney", "DeskNet", "DeskPerpl"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DeskFlowTests",
            dependencies: ["DeskFlow", "DeskNet"],
            // The venue context is shared with DeskPerplTests rather than hand-built:
            // an order is validated against the real market's decimals and margin
            // fractions, and a market invented for a test proves nothing about those.
            resources: [.process("EnrolmentPayload.json"), .process("Context-testnet.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
