import AppKit
import Testing
@testable import OpenTile

struct MusicArtworkTests {
    private func song(_ title: String = "Song", artwork: Data? = nil) -> MusicTrack {
        MusicTrack(title: title, artist: "Artist", artwork: artwork, available: true, album: "Album")
    }

    @Test func missingArtworkRetriesAreBoundedAndResetForNextTrack() {
        var state = MusicArtworkState()
        _ = state.accept(song())
        for delay in [1.0, 3.0, 6.0] {
            #expect(state.nextRetryDelay() == delay)
            _ = state.accept(song())
        }
        #expect(state.nextRetryDelay() == nil)
        let firstLookup = state.beginCatalogLookup()
        let repeatedLookup = state.beginCatalogLookup()
        #expect(firstLookup)
        #expect(!repeatedLookup)
        _ = state.accept(song("Next"))
        #expect(state.nextRetryDelay() == 1)
    }

    @Test func validArtworkSurvivesTransientFailureButNeverLeaksToNextSong() {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        let data = image.representation(using: .png, properties: [:])!
        var state = MusicArtworkState()
        #expect(state.accept(song(artwork: data)).artwork == data)
        #expect(state.accept(song(artwork: Data([0, 1, 2]))).artwork == data)
        #expect(state.nextRetryDelay() == nil)
        #expect(state.accept(song("Next")).artwork == nil)
        #expect(state.accept(MusicTrack()).artwork == nil)
        #expect(state.nextRetryDelay() == nil)
    }

    @Test func catalogRequiresMatchingRecordingAndTrustedArtworkURL() {
        let url = URL(string: "https://is1-ssl.mzstatic.com/image/cover.jpg")!
        let wrongAlbum = MusicArtworkCatalog.Entry(trackName: "Song", artistName: "Artist", collectionName: "Live", artworkUrl100: url)
        let wrongArtist = MusicArtworkCatalog.Entry(trackName: "Song", artistName: "Other", collectionName: "Album", artworkUrl100: url)
        let match = MusicArtworkCatalog.Entry(trackName: " SONG ", artistName: "artist", collectionName: "Album", artworkUrl100: url)
        #expect(MusicArtworkCatalog.artworkURL(in: [wrongAlbum, wrongArtist], for: song()) == nil)
        #expect(MusicArtworkCatalog.artworkURL(in: [wrongAlbum, match], for: song()) == url)
        let unsafe = MusicArtworkCatalog.Entry(trackName: "Song", artistName: "Artist", collectionName: "Album", artworkUrl100: URL(string: "https://other.example/cover"))
        #expect(MusicArtworkCatalog.artworkURL(in: [unsafe], for: song()) == nil)
    }
}
