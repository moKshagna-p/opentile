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
    static func folder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Pictures/Wallpapers", isDirectory: true)
    }

    @discardableResult
    static func ensureFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let url = folder(home: home)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func scan(roots: [(URL, String)], cancelled: () -> Bool = { false }) -> [WallpaperEntry] {
        let fm = FileManager.default
        var entries: [WallpaperEntry] = []
        var seen = Set<URL>()
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
                entries.append(WallpaperEntry(url: canonical, name: url.deletingPathExtension().lastPathComponent, source: source))
            }
        }
        return entries.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.url.path < $1.url.path : comparison == .orderedAscending
        }
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
