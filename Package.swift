// swift-tools-version: 6.2
import Foundation
import PackageDescription

let package = Package(
    name: "PrintableView",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "PrintableView", targets: ["PrintableView"])
    ],
    targets: [
        .target(
            name: "PrintableView",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances")
            ]
        ),
        .testTarget(
            name: "PrintableViewTests",
            dependencies: ["PrintableView"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances")
            ]
        )
    ]
)

// Pull in swift-docc-plugin only for the GitHub Pages documentation workflow,
// so consumers do not resolve it during normal package use.
if ProcessInfo.processInfo.environment["PRINTABLEVIEW_BUILD_DOCS"] != nil {
    package.dependencies.append(
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0")
    )
}
