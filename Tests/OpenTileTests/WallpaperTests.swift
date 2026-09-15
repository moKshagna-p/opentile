import AppKit
import Testing
@testable import OpenTile

struct WallpaperTests {
    @Test func wallpaperSearchMatchesEveryTokenAcrossNameAndSource() {
        let entry = WallpaperEntry(url: URL(fileURLWithPath: "/tmp/sea.MOV"), name: "Côte at Dawn", source: "macOS aerial")
        #expect(entry.isVideo)
        #expect(entry.matches("  COTE   aerial  "))
        #expect(entry.matches(""))
        #expect(!entry.matches("cote sunset"))
    }

    @Test func wallpaperScanFiltersDeduplicatesAndCancels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Zebra.PNG", "nested/Alpine.heic", "clip.mov", ".hidden.jpg", "Dome.madesktop", "notes.txt"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let entries = WallpaperLibrary.scan(roots: [(root, "Downloads"), (root.appendingPathComponent("nested"), "Other"), (root.appendingPathComponent("absent"), "Missing")])
        #expect(entries.map(\.name) == ["Alpine", "clip", "Zebra"])
        #expect(entries.allSatisfy { $0.source == "Downloads" })
        #expect(WallpaperLibrary.scan(roots: [(root, "Downloads")], cancelled: { true }).isEmpty)
    }

    @Test func wallpaperFolderIsCreatedAndPreservesExistingFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = try WallpaperLibrary.ensureFolder(home: home)
        #expect(folder.path == home.appendingPathComponent("Pictures/Wallpapers").path)
        let photo = folder.appendingPathComponent("Keep.png")
        try Data("original".utf8).write(to: photo)
        try WallpaperLibrary.ensureFolder(home: home)
        #expect(try Data(contentsOf: photo) == Data("original".utf8))
        let outside = home.appendingPathComponent("Outside.jpg")
        try Data().write(to: outside)
        #expect(WallpaperLibrary.scan(roots: [(folder, "Wallpapers")]).map(\.url) == [photo.resolvingSymlinksInPath()])
    }

    @Test func wallpaperFolderReportsConflictingFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Pictures"), withIntermediateDirectories: true)
        try Data().write(to: WallpaperLibrary.folder(home: home))
        #expect(throws: (any Error).self) { try WallpaperLibrary.ensureFolder(home: home) }
    }

    @Test func wallpaperDecodeReportsUnreadableFile() {
        #expect(throws: WallpaperError.self) {
            try WallpaperLibrary.image(at: URL(fileURLWithPath: "/nonexistent/opentile-wallpaper.png"), maxPixels: 100)
        }
    }

    @Test func wallpaperDecodeBoundsResolutionAndPreservesStaticURL() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        let entry = WallpaperEntry(url: url, name: "Test", source: "Test")
        let (prepared, image) = try WallpaperLibrary.prepare(entry, maxPixels: 50)
        #expect(prepared == url)
        #expect(image.width == 50)
        #expect(image.height == 25)
    }

    @Test func wallpaperRevealCoversDisplayOnlyWhenExpanded() {
        for size in [CGSize(width: 1920, height: 1080), CGSize(width: 900, height: 1600)] {
            let collapsed = WallpaperReveal.path(size: size, progress: 0)
            #expect(!collapsed.contains(CGPoint(x: 10, y: 10)))
            let expanded = WallpaperReveal.path(size: size, progress: 1)
            for point in [CGPoint(x: 1, y: 1), CGPoint(x: size.width - 1, y: 1), CGPoint(x: 1, y: size.height - 1), CGPoint(x: size.width - 1, y: size.height - 1)] {
                #expect(expanded.contains(point))
            }
            #expect(WallpaperReveal.path(size: size, progress: -1) == collapsed)
            #expect(WallpaperReveal.path(size: size, progress: 2) == expanded)
        }
    }
}
