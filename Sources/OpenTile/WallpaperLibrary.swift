import Foundation
import ImageIO
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers

struct WallpaperEntry: Equatable, Sendable {
    let url: URL
    let name: String
    let source: String
    var isVideo: Bool { WallpaperLibrary.videoExtensions.contains(url.pathExtension.lowercased()) }
    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            "\(name) \(source)".localizedStandardContains(String($0))
        }
    }
}

/// Reads local files only. Apple asset descriptors and remote catalog URLs are not wallpapers.
enum WallpaperLibrary {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "bmp", "gif"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let aerialRoot = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true)

    static func roots(additional: [URL] = []) -> [(URL, String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return settingsFiles().map { ($0, "macOS Settings") } + [
            (home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos"), "macOS aerial"),
            (home.appendingPathComponent("Downloads"), "Downloads"),
            (home.appendingPathComponent("Pictures/Wallpapers"), "Wallpapers"),
            (URL(fileURLWithPath: "/System/Library/Desktop Pictures"), "macOS"),
            (URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture"), "macOS"),
            (aerialRoot, "macOS aerial")
        ] + additional.map { ($0, $0.lastPathComponent) }
    }

    static func scan(roots: [(URL, String)], cancelled: () -> Bool = { false }) -> [WallpaperEntry] {
        let fm = FileManager.default
        var entries: [WallpaperEntry] = []
        var seen = Set<URL>()
        let names = aerialNames()
        for (root, source) in roots {
            guard !cancelled() else { return [] }
            let files: AnySequence<URL>
            if (try? root.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files = AnySequence([root])
            } else if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                files = AnySequence { AnyIterator { enumerator.nextObject() as? URL } }
            } else { continue }
            for url in files {
                guard !cancelled() else { return [] }
                guard imageExtensions.contains(url.pathExtension.lowercased()) || videoExtensions.contains(url.pathExtension.lowercased()),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                guard seen.insert(canonical).inserted else { continue }
                entries.append(WallpaperEntry(url: canonical, name: names[url.deletingPathExtension().lastPathComponent] ?? url.deletingPathExtension().lastPathComponent, source: source))
            }
        }
        return entries.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.url.path < $1.url.path : comparison == .orderedAscending
        }
    }

    /// Best-effort, read-only discovery; this private store may change between macOS versions.
    static func settingsFiles(data: Data? = nil) -> [URL] {
        let store = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = data ?? (try? Data(contentsOf: store)),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return [] }
        var urls = Set<URL>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 24 else { return }
            if let dictionary = value as? [String: Any] {
                for child in dictionary.values { visit(child, depth: depth + 1) }
            } else if let array = value as? [Any] {
                for child in array { visit(child, depth: depth + 1) }
            } else if let data = value as? Data,
                      let child = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                visit(child, depth: depth + 1)
            } else if let string = value as? String, let url = URL(string: string), url.isFileURL,
                      url.host == nil || url.host == "" || url.host == "localhost" {
                urls.insert(url.resolvingSymlinksInPath().standardizedFileURL)
            }
        }
        visit(value, depth: 0)
        return urls.sorted { $0.path < $1.path }
    }

    private static func aerialNames() -> [String: String] {
        let catalogs = [aerialRoot.appendingPathComponent("entries.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json")]
        var names: [String: String] = [:]
        for url in catalogs {
            guard let data = try? Data(contentsOf: url),
                  let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = catalog["assets"] as? [[String: Any]] else { continue }
            for asset in assets {
                if let id = asset["id"] as? String, let label = asset["accessibilityLabel"] as? String { names[id] = label }
            }
        }
        return names
    }

    static func image(at url: URL, maxPixels: Int) throws -> CGImage {
        if videoExtensions.contains(url.pathExtension.lowercased()) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            return try generator.copyCGImage(at: .zero, actualTime: nil)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw WallpaperError.unreadable }
        return image
    }

    /// Persist aerial frames outside caches: macOS retains this URL after OpenTile quits.
    static func prepare(_ entry: WallpaperEntry, maxPixels: Int) throws -> (URL, CGImage) {
        let image = try image(at: entry.url, maxPixels: maxPixels)
        guard entry.isVideo else { return (entry.url, image) }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("OpenTile/Wallpaper Stills", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let modified = try entry.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = SHA256.hash(data: Data("\(entry.url.path)|\(modified)|\(maxPixels)".utf8)).map { String(format: "%02x", $0) }.joined()
        let url = root.appendingPathComponent(key).appendingPathExtension("png")
        if !FileManager.default.fileExists(atPath: url.path) {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw WallpaperError.unreadable }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw WallpaperError.unreadable }
            try (data as Data).write(to: url, options: .atomic)
        }
        return (url, image)
    }
}

enum WallpaperError: LocalizedError {
    case unreadable
    var errorDescription: String? { "This wallpaper could not be read. Choose another local image or video." }
}
