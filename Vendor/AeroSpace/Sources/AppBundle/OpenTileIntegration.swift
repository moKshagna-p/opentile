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

public struct OpenTileWorkspaceSummary {
    public let name: String
    public let applications: [String]
    public let windowCount: Int
    public let isFocused: Bool
}

@MainActor public func openTileWorkspaces() -> [OpenTileWorkspaceSummary] {
    Workspace.all.map { workspace in
        let windows = workspace.allLeafWindowsRecursive
        return OpenTileWorkspaceSummary(
            name: workspace.name,
            applications: Set(windows.map { $0.app.name ?? "Unknown application" }).sorted(),
            windowCount: windows.count,
            isFocused: workspace == focus.workspace)
    }
}
