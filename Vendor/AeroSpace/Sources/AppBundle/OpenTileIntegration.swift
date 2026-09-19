import AppKit
import Common

@MainActor public func stopOpenTileEngine() {
    terminationHandler?.beforeTermination()
}

@MainActor public func openTileConfigURL() throws -> URL {
    switch findCustomConfigUrl() {
    case .file(let url): return url
    case .ambiguousConfigError(let urls): return urls[0]
    case .noCustomConfigExists:
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opentile.toml")
        try FileManager.default.copyItem(at: defaultConfigUrl, to: url)
        return url
    }
}

public struct OpenTileWorkspaceSummary: Equatable {
    public let name: String
    public let applications: [String]
    public let applicationBundlePaths: [String]
    public let windowCount: Int
    public let isFocused: Bool
}

@MainActor public func openTileWorkspaces() -> [OpenTileWorkspaceSummary] {
    Workspace.all.map { workspace in
        let windows = workspace.allLeafWindowsRecursive
        return OpenTileWorkspaceSummary(
            name: workspace.name,
            applications: Set(windows.map { $0.app.name ?? "Unknown application" }).sorted(),
            applicationBundlePaths: Set(windows.compactMap { $0.app.bundlePath }).sorted(),
            windowCount: windows.count,
            isFocused: workspace == focus.workspace)
    }
}

/// Event-driven presentation state for OpenTile's optional split bar.
public struct OpenTileBarState: Equatable {
    public let workspaces: [OpenTileWorkspaceSummary]
    public let fullscreenScreenIndices: [Int]
}

@MainActor func openTileBarState() -> OpenTileBarState {
    OpenTileBarState(workspaces: openTileWorkspaces(), fullscreenScreenIndices: monitors.filter {
        $0.activeWorkspace.allLeafWindowsRecursive.contains { $0.isFullscreen }
    }.map { $0.monitorAppKitNsScreenScreensId })
}

@MainActor var openTileBarHeight: CGFloat = 0

public func openTileAdditionalTopInset(barHeight: CGFloat, existingInset: CGFloat) -> CGFloat {
    max(0, barHeight - max(0, existingInset))
}

@MainActor public func setOpenTileBarHeight(_ height: CGFloat) {
    let height = max(0, height)
    guard openTileBarHeight != height else { return }
    openTileBarHeight = height
    scheduleCancellableCompleteRefreshSession(.menuBarButton)
}
