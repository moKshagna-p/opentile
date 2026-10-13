import Foundation

struct NetworkProcessUsage: Equatable {
    let name: String
    let bytesPerSecond: Double
}

/// `nettop -d` starts with cumulative totals; only later CSV blocks describe current traffic.
struct NetworkProcessSampleParser {
    private var sampleNumber = 0
    private var totals: [String: Double] = [:]

    mutating func consume(_ line: String) -> [NetworkProcessUsage]? {
        if line.hasPrefix(",bytes_in,bytes_out,") {
            defer {
                sampleNumber += 1
                totals.removeAll(keepingCapacity: true)
            }
            guard sampleNumber > 1 else { return nil }
            return ranked()
        }

        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 4,
              let dot = fields[0].lastIndex(of: "."),
              !fields[0][fields[0].index(after: dot)...].isEmpty,
              fields[0][fields[0].index(after: dot)...].allSatisfy(\.isNumber),
              let received = UInt64(fields[1]), let sent = UInt64(fields[2]) else { return nil }
        let name = String(fields[0][..<dot])
        guard !name.isEmpty, received > 0 || sent > 0 else { return nil }
        totals[name, default: 0] += Double(received) + Double(sent)
        return nil
    }

    func finish() -> [NetworkProcessUsage]? {
        guard sampleNumber > 1 else { return nil }
        return ranked()
    }

    private func ranked() -> [NetworkProcessUsage] {
        let samples = totals.map { NetworkProcessUsage(name: $0.key, bytesPerSecond: $0.value) }
        let sorted = samples.sorted { left, right in
            if left.bytesPerSecond == right.bytesPerSecond {
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            return left.bytesPerSecond > right.bytesPerSecond
        }
        return Array(sorted.prefix(3))
    }
}

/// Run the system sampler only while the network dropdown is visible.
@MainActor final class NetworkProcessTraffic {
    private var process: Process?
    private var nextSample: Timer?
    private var generation = 0

    func start(onSample: @escaping @MainActor ([NetworkProcessUsage]?) -> Void) {
        stop()
        sample(version: generation, onSample: onSample)
    }

    private func sample(version: Int, onSample: @escaping @MainActor ([NetworkProcessUsage]?) -> Void) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-n", "-P", "-L", "2", "-x", "-d", "-s", "1",
                             "-t", "external", "-t", "undefined", "-J", "bytes_in,bytes_out"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            onSample(nil)
            return
        }
        self.process = process
        let reader = output.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var parser = NetworkProcessSampleParser()
            let data = reader.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
                _ = parser.consume(String(line))
            }
            let result = process.terminationStatus == 0 ? parser.finish() : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == version else { return }
                self.process = nil
                onSample(result)
                let timer = Timer(timeInterval: result == nil ? 2 : 0.3, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.generation == version else { return }
                        self.nextSample = nil
                        self.sample(version: version, onSample: onSample)
                    }
                }
                self.nextSample = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }

    func stop() {
        generation += 1
        nextSample?.invalidate()
        nextSample = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}
