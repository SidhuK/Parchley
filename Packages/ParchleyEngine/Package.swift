// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParchleyEngine",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ParchleyEngine", targets: ["ParchleyEngine"])],
    dependencies: [.package(path: "../ParchleyDomain")],
    targets: [
        .target(name: "ParchleyEngine", dependencies: [.product(name: "ParchleyDomain", package: "ParchleyDomain")], swiftSettings: [
            .swiftLanguageMode(.v6),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ]),
        .testTarget(name: "ParchleyEngineTests", dependencies: ["ParchleyEngine"], swiftSettings: [
            .swiftLanguageMode(.v6),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ])
    ]
)
