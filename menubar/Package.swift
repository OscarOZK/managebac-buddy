// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MBMenuBar",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "MBMenuBar",
            path: "Sources/MBMenuBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
