import AppKit
import Testing
@testable import OpenTile

struct AppleMusicPlayerTests {
    @Test func emptyResponseMeansNoPlayback() {
        let track = MusicTrack.decode(.list())
        #expect(!track.available)
        #expect(!track.playing)
        #expect(track.artwork == nil)
    }

    @Test func trackMetadataAndArtworkArePreserved() {
        let result = NSAppleEventDescriptor.list()
        result.insert(NSAppleEventDescriptor(string: "A Song"), at: 1)
        result.insert(NSAppleEventDescriptor(string: "An Artist"), at: 2)
        result.insert(NSAppleEventDescriptor(boolean: true), at: 3)
        let bytes = Data([137, 80, 78, 71])
        result.insert(NSAppleEventDescriptor(descriptorType: 0x504e4766, data: bytes)!, at: 4)
        let track = MusicTrack.decode(result)
        #expect(track.available)
        #expect(track.playing)
        #expect(track.title == "A Song")
        #expect(track.artist == "An Artist")
        #expect(track.artwork == bytes)
        result.insert(NSAppleEventDescriptor(string: ""), at: 4)
        // A missing artwork payload must not prevent displaying the track.
        #expect(MusicTrack.decode(result).available)
    }

    @Test @MainActor func scriptsCompileWithoutExecutingOrLaunchingMusic() {
        for command: AppleMusicPlayer.Command? in [nil, .toggle, .previous, .next] {
            var error: NSDictionary?
            let script = NSAppleScript(source: AppleMusicPlayer.script(command))
            #expect(script?.compileAndReturnError(&error) == true, "\(String(describing: error))")
        }
    }

    @Test @MainActor func stoppedPlayerIgnoresRequests() {
        let player = AppleMusicPlayer()
        player.stop()
        player.refresh()
        player.control(.toggle)
        #expect(!player.busy)
        #expect(!player.track.available)
    }
}
