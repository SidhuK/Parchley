// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParchleyEngine",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ParchleyEngine", targets: ["ParchleyEngine"])],
    dependencies: [
        .package(path: "../ParchleyDomain"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.32.3")),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.4.0")
    ],
    targets: [
        .target(
            name: "ParchleyEngine",
            dependencies: [
                .product(name: "ParchleyDomain", package: "ParchleyDomain"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault")
            ]),
        .testTarget(name: "ParchleyEngineTests", dependencies: ["ParchleyEngine"], swiftSettings: [
            .swiftLanguageMode(.v6),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ])
    ]
)
