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
        var artistId: Int? = nil
    }

    static func normalized(_ value: String?) -> String {
        (value ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func trusted(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host?.hasSuffix(".mzstatic.com") == true
    }

    // Require the album as well as title/artist: search rank alone can pick a cover
    // from a compilation, live performance, or a different recording.
    static func artworkURL(in entries: [Entry], for track: MusicTrack) -> URL? {
        guard !track.album.isEmpty, !track.artist.isEmpty else { return nil }
        return entries.first {
            normalized($0.trackName) == normalized(track.title) &&
            normalized($0.artistName) == normalized(track.artist) &&
            normalized($0.collectionName) == normalized(track.album) &&
            trusted($0.artworkUrl100)
        }?.artworkUrl100
    }

    /// An album's cover is its tracks' cover. The catalog lists singles and EPs with a suffix Music omits.
    static func albumArtworkURL(in albums: [Entry], for track: MusicTrack) -> URL? {
        let album = normalized(track.album)
        guard !album.isEmpty else { return nil }
        return albums.first { entry in
            let name = normalized(entry.collectionName)
            return [name, name.replacingOccurrences(of: " - single", with: ""),
                    name.replacingOccurrences(of: " - ep", with: "")].contains(album) && trusted(entry.artworkUrl100)
        }?.artworkUrl100
    }

    /// "Future, Metro Boomin & Travis Scott" -> "Future"; the catalog files collaborations under the lead artist.
    static func leadArtist(_ artist: String) -> String {
        artist.split(whereSeparator: { ",&".contains($0) }).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? artist
    }

    private static func entries(_ path: String, _ items: [String: String]) async throws -> [Entry] {
        var components = URLComponents(string: "https://itunes.apple.com/\(path)")!
        components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "US")]
        guard let url = components.url else { return [] }
        let (json, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8))
        guard !Task.isCancelled, (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode(Response.self, from: json))?.results ?? []
    }

    static func fetch(for track: MusicTrack) async -> Data? {
        guard !track.album.isEmpty, !track.artist.isEmpty else { return nil }
        do {
            var artwork = artworkURL(in: try await entries("search", [
                "term": "\(track.title) \(track.artist) \(track.album)", "entity": "song", "limit": "20"]), for: track)
            // Search ranking misses some albums entirely; the artist's own album list does not.
            if artwork == nil {
                let lead = leadArtist(track.artist)
                let artists = try await entries("search", ["term": lead, "entity": "musicArtist", "limit": "5"])
                if let id = artists.first(where: { normalized($0.artistName) == normalized(lead) })?.artistId {
                    artwork = albumArtworkURL(in: try await entries("lookup", [
                        "id": "\(id)", "entity": "album", "limit": "200"]), for: track)
                }
            }
            guard let artwork else { return nil }
            // Ask for a sharper rendition than the 100px thumbnail; fall back to it if the size is refused.
            let sharp = URL(string: artwork.absoluteString.replacingOccurrences(of: "100x100bb", with: "300x300bb")) ?? artwork
            for url in [sharp, artwork] {
                let (data, imageResponse) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 8))
                if !Task.isCancelled, (imageResponse as? HTTPURLResponse)?.statusCode == 200,
                   data.count <= 5_000_000, NSImage(data: data) != nil { return data }
            }
            return nil
        } catch { return nil }
    }
}
