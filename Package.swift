// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenTile",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenTile",
            path: "Sources/OpenTile",
            linkerSettings: [
                // MultitouchSupport is a private framework: point the linker at it.
                .unsafeFlags([
                    "-F/System/Library/PrivateFrameworks/",
                    "-framework", "MultitouchSupport",
                ])
            ]
        ),
    ]
)
