// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FancyMacZones",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Tests only (snapshot tests need XCTest, i.e. Xcode: run them with scripts/test.sh).
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.6"),
    ],
    targets: [
        .executableTarget(
            name: "FancyMacZones",
            path: "Sources/FancyMacZones",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FancyMacZonesTests",
            dependencies: ["FancyMacZones", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")],
            path: "Tests/FancyMacZonesTests",
            exclude: ["__Snapshots__"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
