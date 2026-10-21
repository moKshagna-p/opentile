import Darwin
import Foundation
import Testing
@testable import OpenTile

@Suite(.serialized)
struct AeroSpaceTransportTests {
    private func withCLI(_ script: String, test: (AeroSpace, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("aerospace")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try test(AeroSpace(executable: executable), directory)
    }

    @Test func immediateExitPreservesOutputAndArguments() throws {
        try withCLI("printf '%s' \"$1\"; printf ' stderr' >&2") { cli, _ in
            for _ in 0..<20 {
                let output = try cli.run(["hello world"])
                #expect(String(decoding: output, as: UTF8.self) == "hello world stderr")
            }
        }
    }

    @Test func waitsForDelayedOutput() throws {
        try withCLI("/bin/sleep 0.05\nprintf 'finished'") { cli, _ in
            let output = try cli.run([])
            #expect(String(decoding: output, as: UTF8.self) == "finished")
        }
    }

    @Test func nonzeroExitPreservesError() throws {
        try withCLI("printf 'command failed\\n' >&2\nexit 7") { cli, _ in
            do {
                try cli.run([])
                Issue.record("A failed command must throw")
            } catch let error as AeroSpace.Failure {
                #expect(error.message == "command failed")
            }
        }
    }

    @Test func largeOutputDoesNotBlockCompletion() throws {
        try withCLI("exec /usr/bin/head -c 262144 /dev/zero") { cli, _ in
            let output = try cli.run([])
            #expect(output == Data(repeating: 0, count: 262144))
        }
    }

    @Test func launchFailureThrows() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: (any Error).self) { try AeroSpace(executable: missing).run([]) }
    }

    @Test(arguments: [false, true])
    func timeoutStopsAndReapsProcess(ignoresTermination: Bool) throws {
        let script = """
        \(ignoresTermination ? "trap '' TERM" : "")
        printf '%s' "$$" > "$1"
        exec /bin/sleep 30
        """
        try withCLI(script) { cli, directory in
            let pidFile = directory.appendingPathComponent("pid")
            defer {
                if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                   let pid = Int32(text), kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
            do {
                try cli.run([pidFile.path])
                Issue.record("A timed-out command must throw")
            } catch let error as AeroSpace.Failure {
                #expect(error.message == "AeroSpace timed out. Check that it is running.")
            }
            let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
            let result = kill(pid, 0)
            let error = errno
            #expect(result == -1)
            #expect(error == ESRCH)
        }
    }
}
