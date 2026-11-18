// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoadTripAssist",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "RoadTripAssist", targets: ["RoadTripAssist"])
    ],
    targets: [
        .executableTarget(
            name: "RoadTripAssist",
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
