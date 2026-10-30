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

extension Tile {
    var endpoint: OpenTileSwapEndpoint { OpenTileSwapEndpoint(id: id, pid: pid, workspace: workspace, layout: layout) }
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
    /// Defaults to the embedded engine; tests substitute recorded command output.
    var execute: @MainActor ([String]) async throws -> String = { try await AeroSpace.command($0) }

    @discardableResult @MainActor func run(_ arguments: [String]) async throws -> Data {
        Data(try await execute(arguments).utf8)
    }

    /// Runs in the embedded engine without a CLI launch or socket round trip.
    /// The timeout releases callers while asynchronous AX work is stalled.
    @MainActor static func command(
        _ arguments: [String], timeout: Duration = .seconds(4),
        run: @escaping @MainActor ([String]) async throws -> String = runOpenTileCommand
    ) async throws -> String {
        try Task.checkCancellation()
        let (results, continuation) = AsyncThrowingStream<String, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let work = Task { @MainActor in
            do {
                try Task.checkCancellation()
                continuation.yield(try await run(arguments))
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        let expiry = Task { @MainActor in
            try await Task.sleep(for: timeout)
            work.cancel()
            continuation.finish(throwing: Failure(message: "AeroSpace timed out. Check that it is running."))
        }
        defer { work.cancel(); expiry.cancel() }
        for try await result in results {
            try Task.checkCancellation()
            return result
        }
        throw CancellationError()
    }

    @MainActor func tiles(_ filter: [String]) async throws -> [Tile] {
        let data = try await run(["list-windows"] + filter + ["--format", "%{window-id} %{app-pid} %{workspace} %{window-parent-container-layout}", "--json"])
        return try JSONDecoder().decode([Tile].self, from: data)
    }

    @MainActor func snapshot(
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
        let snapshot = try await discoverSnapshot()
        try Task.checkCancellation()
        return snapshot
    }

    @MainActor private func discoverSnapshot() async throws -> DesktopSnapshot {
        guard let source = try await tiles(["--focused"]).first else { throw Failure(message: "Focus a tiled window first.") }
        guard ["h_tiles", "v_tiles"].contains(source.layout) else { throw Failure(message: "Use a tiled window; floating and accordion layouts are not supported yet.") }
        guard let frame = Self.frame(source) else { throw Failure(message: "Cannot read the focused window. Check Accessibility permission.") }
        let targets = try await tiles(["--workspace", source.workspace]).filter { $0.id != source.id && ["h_tiles", "v_tiles"].contains($0.layout) }.compactMap { tile -> WindowTile? in
            guard let frame = Self.frame(tile) else { return nil }
            return WindowTile(tile: tile, frame: frame)
        }
        guard !targets.isEmpty else { throw Failure(message: "Open another tiled window in this workspace to choose a destination.") }
        return DesktopSnapshot(source: WindowTile(tile: source, frame: frame), targets: targets)
    }

    @MainActor func resize(source: Tile, plan: ResizePlan) async throws {
        guard let command = plan.command(windowID: source.id) else { return }
        let current = try await tiles(["--workspace", source.workspace])
        guard current.contains(where: {
            $0.id == source.id && $0.pid == source.pid && $0.workspace == source.workspace
                && $0.layout == source.layout && ["h_tiles", "v_tiles"].contains($0.layout)
        }) else { throw Failure(message: "The window or layout changed. Start the resize again.") }
        try await run(command)
    }

    @MainActor func swap(source: Tile, target: Tile) async throws {
        try await swapOpenTileWindows(source: source.endpoint, target: target.endpoint)
    }

    @MainActor func insert(source: Tile, target: Tile, edge: Edge) async throws {
        try await insertOpenTileWindow(source: source.endpoint, target: target.endpoint,
                                       horizontal: edge.horizontal, before: edge.before)
    }

    private static func frame(_ tile: Tile) -> CGRect? {
        // CGWindow IDs are the IDs exposed by AeroSpace; avoids ambiguous title matching.
        guard let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(tile.id)) as? [[String: Any]],
              let window = windows.first, (window[kCGWindowOwnerPID as String] as? Int32) == tile.pid,
              let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
}
