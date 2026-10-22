import AppKit
import AppBundle
import OpenTileCore

struct Tile: Decodable {
    let id: Int
    let pid: Int32
    let workspace: String
    let layout: String
    enum CodingKeys: String, CodingKey {
        case id = "window-id", pid = "app-pid", workspace, layout = "window-parent-container-layout"
    }
}

struct WindowTile {
    let tile: Tile
    let frame: CGRect
}

struct DesktopSnapshot {
    let source: WindowTile
    let targets: [WindowTile]
}

struct AeroSpace {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    let executable: URL
    static func locate(executableURL: URL? = Bundle.main.executableURL) -> AeroSpace? {
        let paths = [executableURL?.deletingLastPathComponent().appendingPathComponent("aerospace").path].compactMap { $0 }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { AeroSpace(executable: URL(fileURLWithPath: $0)) }
    }

    /// Called only on the worker queue. Output goes to a file to avoid pipe deadlocks.
    @discardableResult func run(_ arguments: [String]) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw Failure(message: "Cannot create command output file.") }
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        if completion.wait(timeout: .now() + 4) == .timedOut, process.isRunning {
            process.terminate()
            if completion.wait(timeout: .now() + .milliseconds(250)) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw Failure(message: "AeroSpace timed out. Check that it is running.")
        }
        let data = try Data(contentsOf: url)
        guard process.terminationStatus == 0 else {
            throw Failure(message: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "AeroSpace command failed.")
        }
        return data
    }

    func tiles(_ filter: [String]) throws -> [Tile] {
        let data = try run(["list-windows"] + filter + ["--format", "%{window-id} %{app-pid} %{workspace} %{window-parent-container-layout}", "--json"])
        return try JSONDecoder().decode([Tile].self, from: data)
    }

    @MainActor func snapshot(
        on worker: DispatchQueue,
        read: @MainActor () async throws -> OpenTileGestureSnapshot? = readOpenTileGestureSnapshot
    ) async throws -> DesktopSnapshot {
        try Task.checkCancellation()
        if let snapshot = try await read() {
            try Task.checkCancellation()
            func convert(_ window: OpenTileSnapshotWindow) -> WindowTile {
                let endpoint = window.endpoint
                return WindowTile(tile: Tile(id: endpoint.id, pid: endpoint.pid, workspace: endpoint.workspace,
                                             layout: endpoint.layout), frame: window.frame)
            }
            return DesktopSnapshot(source: convert(snapshot.source), targets: snapshot.targets.map(convert))
        }
        try Task.checkCancellation()
        let snapshot: DesktopSnapshot = try await withCheckedThrowingContinuation { continuation in
            worker.async {
                continuation.resume(with: Result { try self.snapshot() })
            }
        }
        try Task.checkCancellation()
        return snapshot
    }

    func snapshot() throws -> DesktopSnapshot {
        guard let source = try tiles(["--focused"]).first else { throw Failure(message: "Focus a tiled window first.") }
        guard ["h_tiles", "v_tiles"].contains(source.layout) else { throw Failure(message: "Use a tiled window; floating and accordion layouts are not supported yet.") }
        guard let frame = Self.frame(source) else { throw Failure(message: "Cannot read the focused window. Check Accessibility permission.") }
        let targets = try tiles(["--workspace", source.workspace]).filter { $0.id != source.id && ["h_tiles", "v_tiles"].contains($0.layout) }.compactMap { tile -> WindowTile? in
            guard let frame = Self.frame(tile) else { return nil }
            return WindowTile(tile: tile, frame: frame)
        }
        guard !targets.isEmpty else { throw Failure(message: "Open another tiled window in this workspace to choose a destination.") }
        return DesktopSnapshot(source: WindowTile(tile: source, frame: frame), targets: targets)
    }

    func resize(source: Tile, plan: ResizePlan) throws {
        guard let command = plan.command(windowID: source.id) else { return }
        let current = try tiles(["--workspace", source.workspace])
        guard current.contains(where: {
            $0.id == source.id && $0.pid == source.pid && $0.workspace == source.workspace
                && $0.layout == source.layout && ["h_tiles", "v_tiles"].contains($0.layout)
        }) else { throw Failure(message: "The window or layout changed. Start the resize again.") }
        try run(command)
    }

    @MainActor func swap(source: Tile, target: Tile) async throws {
        try await swapOpenTileWindows(
            source: OpenTileSwapEndpoint(id: source.id, pid: source.pid, workspace: source.workspace, layout: source.layout),
            target: OpenTileSwapEndpoint(id: target.id, pid: target.pid, workspace: target.workspace, layout: target.layout))
    }

    func insert(source: Tile, target: Tile, edge: Edge) throws {
        let current = try tiles(["--workspace", source.workspace])
        guard current.contains(where: { $0.id == source.id && ["h_tiles", "v_tiles"].contains($0.layout) }),
              current.contains(where: { $0.id == target.id && ["h_tiles", "v_tiles"].contains($0.layout) }) else {
            throw Failure(message: "The workspace changed. Start the gesture again.")
        }
        do {
            try run(["layout", "--window-id", "\(source.id)", "floating"])
            // Removing the source can normalize the tree and change the target's orientation.
            guard let updated = try tiles(["--workspace", source.workspace]).first(where: { $0.id == target.id }), ["h_tiles", "v_tiles"].contains(updated.layout) else {
                throw Failure(message: "The destination is no longer tiled.")
            }
            for command in InsertionPlan(source: source.id, target: target.id, targetLayout: updated.layout, edge: edge).commands.dropFirst() { try run(command) }
        } catch {
            // Best effort recovery: never silently leave the window floating after a failed insertion.
            do {
                let existing = try tiles(["--workspace", source.workspace]).first(where: { $0.id == source.id })
                if existing?.layout == "floating" {
                    try run(["layout", "--window-id", "\(source.id)", "tiling"])
                } else if existing == nil {
                    throw Failure(message: "The source window is no longer in its workspace.")
                }
            }
            catch { throw Failure(message: "Insertion and recovery failed. In AeroSpace, focus the window and run ‘layout tiling’. Original tile order may have changed.") }
            throw Failure(message: "Insertion failed; the window was returned to tiling. Original tile order may have changed. \(error.localizedDescription)")
        }
    }

    private static func frame(_ tile: Tile) -> CGRect? {
        // CGWindow IDs are the IDs exposed by AeroSpace; avoids ambiguous title matching.
        guard let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(tile.id)) as? [[String: Any]],
              let window = windows.first, (window[kCGWindowOwnerPID as String] as? Int32) == tile.pid,
              let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
}
