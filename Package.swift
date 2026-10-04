// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FancyMacZones",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "FancyMacZones",
            path: "Sources/FancyMacZones",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
