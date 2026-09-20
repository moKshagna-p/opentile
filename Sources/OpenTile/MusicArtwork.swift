import AppKit

/// Keeps retries bounded per track and retains a valid cover during transient failures.
struct MusicArtworkState {
    private var current = MusicTrack()
    private var retries = 0
    private var catalogRequested = false

    mutating func accept(_ value: MusicTrack) -> MusicTrack {
        let sameTrack = current.available && value.available && current.identity == value.identity
        if !sameTrack { retries = 0; catalogRequested = false }
        var value = value
        if value.artwork.flatMap(NSImage.init(data:)) == nil {
            value.artwork = sameTrack ? current.artwork : nil
        }
        current = value
        return value
    }

    mutating func nextRetryDelay() -> Double? {
        guard current.available, current.artwork == nil, retries < 3 else { return nil }
        let delay = [1.0, 3.0, 6.0][retries]
        retries += 1
        return delay
    }

    mutating func beginCatalogLookup() -> Bool {
        guard current.available, current.artwork == nil, !catalogRequested else { return false }
        catalogRequested = true
        return true
    }
}

enum MusicArtworkCatalog {
    struct Response: Decodable { let results: [Entry] }
    struct Entry: Decodable {
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let artworkUrl100: URL?
    }

    // Require the album as well as title/artist: search rank alone can pick a cover
    // from a compilation, live performance, or a different recording.
    static func artworkURL(in entries: [Entry], for track: MusicTrack) -> URL? {
        guard !track.album.isEmpty, !track.artist.isEmpty else { return nil }
        func normalized(_ value: String?) -> String {
            (value ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        return entries.first {
            normalized($0.trackName) == normalized(track.title) &&
            normalized($0.artistName) == normalized(track.artist) &&
            normalized($0.collectionName) == normalized(track.album) &&
            $0.artworkUrl100?.scheme == "https" &&
            $0.artworkUrl100?.host?.hasSuffix(".mzstatic.com") == true
        }?.artworkUrl100
    }

    static func fetch(for track: MusicTrack) async -> Data? {
        guard !track.album.isEmpty, !track.artist.isEmpty else { return nil }
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(track.title) \(track.artist) \(track.album)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US")
        ]
        guard let url = components.url else { return nil }
        do {
            let (json, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8))
            guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200,
                  let results = try? JSONDecoder().decode(Response.self, from: json),
                  let artwork = artworkURL(in: results.results, for: track) else { return nil }
            let (data, imageResponse) = try await URLSession.shared.data(for: URLRequest(url: artwork, timeoutInterval: 8))
            guard !Task.isCancelled, (imageResponse as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 5_000_000, NSImage(data: data) != nil else { return nil }
            return data
        } catch { return nil }
    }
}
