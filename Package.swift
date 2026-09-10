// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenTile",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OpenTile", targets: ["OpenTile"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .target(name: "OpenTileCore"),
        .target(name: "OpenTileC", publicHeadersPath: "include"),
        .executableTarget(name: "OpenTile", dependencies: ["OpenTileCore", "OpenTileC", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "MultitouchSupport", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "OpenTileCoreTests", dependencies: ["OpenTileCore"]),
        .testTarget(name: "OpenTileTests", dependencies: ["OpenTile"])
    ],
    swiftLanguageModes: [.v5]
)
