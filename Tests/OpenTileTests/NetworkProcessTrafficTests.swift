import Testing
@testable import OpenTile

struct NetworkProcessTrafficTests {
    @Test func ranksOnlyCurrentTrafficAndCombinesMatchingProcessNames() {
        var parser = NetworkProcessSampleParser()
        #expect(parser.consume(",bytes_in,bytes_out,") == nil)
        #expect(parser.consume("Old.app.11,1000000,1000000,") == nil)
        #expect(parser.consume(",bytes_in,bytes_out,") == nil)
        for line in ["Browser.12,10,20,", "Browser.13,2,3,", "Sync.14,100,0,",
                     "Chat.15,0,2,", "Idle.16,0,0,", "Bad row"] {
            #expect(parser.consume(line) == nil)
        }
        let first = parser.consume(",bytes_in,bytes_out,")
        #expect(first?.map(\.name) == ["Sync", "Browser", "Chat"])
        #expect(first?.map(\.bytesPerSecond) == [100, 35, 2])

        for line in ["Fresh.17,1,0,", "Broken.18,nope,2,"] {
            #expect(parser.consume(line) == nil)
        }
        #expect(parser.consume(",bytes_in,bytes_out,") == [
            NetworkProcessUsage(name: "Fresh", bytesPerSecond: 1)
        ])
    }

    @Test func emptyCurrentSampleShowsNoProcesses() {
        var parser = NetworkProcessSampleParser()
        #expect(parser.consume(",bytes_in,bytes_out,") == nil)
        #expect(parser.consume(",bytes_in,bytes_out,") == nil)
        #expect(parser.consume("Idle.10,0,0,") == nil)
        #expect(parser.consume(",bytes_in,bytes_out,") == [])
    }

    @Test func completedTwoSampleOutputUsesOnlyTheDeltaSample() {
        var parser = NetworkProcessSampleParser()
        for line in [",bytes_in,bytes_out,", "Browser.1,900000,0,",
                     ",bytes_in,bytes_out,", "Browser.1,200,100,"] {
            _ = parser.consume(line)
        }
        #expect(parser.finish() == [NetworkProcessUsage(name: "Browser", bytesPerSecond: 300)])
    }
}
