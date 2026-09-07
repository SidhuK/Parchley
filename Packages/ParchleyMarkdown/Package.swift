// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ParchleyMarkdown",
    platforms: [.macOS("26.0")],
    products: [.library(name: "ParchleyMarkdown", targets: ["ParchleyMarkdown"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", exact: "0.4.0")
    ],
    targets: [
        .target(name: "ParchleyMarkdown", dependencies: [.product(name: "Markdown", package: "swift-markdown")], swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("NonisolatedNonsendingByDefault")]),
        .testTarget(name: "ParchleyMarkdownTests", dependencies: ["ParchleyMarkdown"], swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("NonisolatedNonsendingByDefault")])
    ]
)
