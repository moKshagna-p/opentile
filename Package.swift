// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenTile",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OpenTile", targets: ["OpenTile"])],
    targets: [
        .target(name: "OpenTileCore"),
        .target(name: "OpenTileC", publicHeadersPath: "include"),
        .executableTarget(name: "OpenTile", dependencies: ["OpenTileCore", "OpenTileC"],
            linkerSettings: [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "MultitouchSupport"])]),
        .testTarget(name: "OpenTileCoreTests", dependencies: ["OpenTileCore"])
    ],
    swiftLanguageModes: [.v5]
)
