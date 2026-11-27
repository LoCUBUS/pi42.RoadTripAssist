// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoadTripAssist",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "RoadTripAssist", targets: ["RoadTripAssist"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.21")
    ],
    targets: [
        .executableTarget(
            name: "RoadTripAssist",
            dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")],
            path: "Sources/RoadTripAssist",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RoadTripAssistTests",
            dependencies: ["RoadTripAssist"],
            path: "Tests/RoadTripAssistTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
