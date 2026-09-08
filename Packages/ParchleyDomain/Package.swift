// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ParchleyDomain",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ParchleyDomain", targets: ["ParchleyDomain"])],
    targets: [
        .target(name: "ParchleyDomain", swiftSettings: [
            .swiftLanguageMode(.v6),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ]),
        .testTarget(name: "ParchleyDomainTests", dependencies: ["ParchleyDomain"], swiftSettings: [
            .swiftLanguageMode(.v6),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault")
        ])
    ]
)
