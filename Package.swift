// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pliable",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PliableCore"),
        .executableTarget(name: "Pliable", dependencies: ["PliableCore"]),
        .executableTarget(name: "pliable-verify", dependencies: ["PliableCore"]),
        // Quick Look extension binary; build.sh wraps it in Pliable.app/Contents/PlugIns as an .appex.
        .executableTarget(
            name: "PliableQuickLook", dependencies: ["PliableCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .testTarget(name: "PliableCoreTests", dependencies: ["PliableCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
