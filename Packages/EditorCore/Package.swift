// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EditorCore",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "EditorCore", targets: ["EditorCore"]),
    ],
    targets: [
        .target(
            name: "EditorCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "EditorCoreTests",
            dependencies: ["EditorCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
