// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pliable",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PliableCore"),
        .executableTarget(name: "Pliable", dependencies: ["PliableCore"]),
        .executableTarget(name: "pliable-verify", dependencies: ["PliableCore"]),
        .testTarget(name: "PliableCoreTests", dependencies: ["PliableCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
