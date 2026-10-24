import AppKit
import Common

public struct OpenTileSwapEndpoint {
    public let id: Int
    public let pid: Int32
    public let workspace: String
    public let layout: String

    public init(id: Int, pid: Int32, workspace: String, layout: String) {
        self.id = id
        self.pid = pid
        self.workspace = workspace
        self.layout = layout
    }
}

struct OpenTileSwapFailure: LocalizedError {
    var errorDescription: String? { "The windows or workspace changed. Start the gesture again." }
}

@MainActor public func swapOpenTileWindows(source: OpenTileSwapEndpoint, target: OpenTileSwapEndpoint) async throws {
    try Task.checkCancellation()
    guard let token = RunSessionGuard.isServerEnabled else { throw OpenTileSwapFailure() }
    try await runLightSession(.globalObserver("OpenTile swap"), token) {
        try await performOpenTileSwap(source: source, target: target)
    }
}

@MainActor func performOpenTileSwap(
    source: OpenTileSwapEndpoint,
    target: OpenTileSwapEndpoint,
    resolve: @MainActor (UInt32) -> Window? = { Window.get(byId: $0) },
    isLive: @MainActor (Window) -> Bool = isLiveOpenTileSwapWindow,
) async throws {
    try Task.checkCancellation()
    guard source.id != target.id, source.workspace == target.workspace,
          let sourceID = UInt32(exactly: source.id), let targetID = UInt32(exactly: target.id),
          let sourceWindow = resolve(sourceID), let targetWindow = resolve(targetID) else { throw OpenTileSwapFailure() }

    func matches(_ window: Window, _ endpoint: OpenTileSwapEndpoint) -> Bool {
        guard window.windowId == UInt32(exactly: endpoint.id), window.app.pid == endpoint.pid,
              window.nodeWorkspace?.name == endpoint.workspace, !window.isFullscreen,
              window.layoutReason == .standard,
              let parent = window.parent as? TilingContainer,
              parent.layout == .tiles,
              endpoint.layout == "\(parent.orientation == .h ? "h" : "v")_tiles" else { return false }
        return window.parents.compactMap { $0 as? TilingContainer }.allSatisfy { $0.layout == .tiles }
    }
    guard matches(sourceWindow, source), matches(targetWindow, target) else { throw OpenTileSwapFailure() }
    let nodes: [TreeNode] = [sourceWindow, targetWindow]
        + sourceWindow.parents.compactMap { $0 as? TilingContainer }
        + targetWindow.parents.compactMap { $0 as? TilingContainer }
    let bindings = nodes.map { node in
        (node: node, parent: node.parent, index: node.ownIndex,
         orientation: (node as? TilingContainer)?.orientation,
         weight: (node.parent as? TilingContainer).map { node.getWeight($0.orientation) })
    }

    for window in [sourceWindow, targetWindow] {
        guard try await window.getAxRect(.cancellable) != nil,
              !(try await window.isMacosFullscreen(.cancellable)),
              !(try await window.isMacosMinimized(.cancellable)) else { throw OpenTileSwapFailure() }
    }
    // AX reads suspend: validate identities and bindings again before the synchronous mutation.
    try Task.checkCancellation()
    guard RunSessionGuard.isServerEnabled != nil,
          resolve(sourceID) === sourceWindow, resolve(targetID) === targetWindow,
          matches(sourceWindow, source), matches(targetWindow, target),
          bindings.allSatisfy({ binding in
              binding.node.parent === binding.parent && binding.node.ownIndex == binding.index
                  && (binding.node as? TilingContainer)?.orientation == binding.orientation
                  && (binding.node.parent as? TilingContainer).map { binding.node.getWeight($0.orientation) } == binding.weight
          }),
          isLive(sourceWindow), isLive(targetWindow) else { throw OpenTileSwapFailure() }

    guard sourceWindow.focusWindow() else { throw OpenTileSwapFailure() }
    resetClosedWindowsCache()
    swapWindows(mruDominant: sourceWindow, targetWindow)
}

@MainActor private func isLiveOpenTileSwapWindow(_ window: Window) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: window.app.pid), !app.isTerminated, !app.isHidden,
          let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, window.windowId) as? [[String: Any]],
          let info = windows.first else { return false }
    return (info[kCGWindowNumber as String] as? UInt32) == window.windowId
        && (info[kCGWindowOwnerPID as String] as? Int32) == window.app.pid
}

public struct OpenTileCommandFailure: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

/// Runs a CLI command in-process exactly as the socket server would, so OpenTile
/// skips launching the bundled client and never trusts the shared /tmp socket.
@MainActor public func runOpenTileCommand(_ args: [String]) async throws -> String {
    try Task.checkCancellation()
    let command: any Command
    switch parseCommand(args) {
        case .cmd(let parsed): command = parsed
        case .help(let help): return help
        case .failure(let err): throw OpenTileCommandFailure(message: err.msg)
    }
    guard let token = RunSessionGuard.isServerEnabled(orIsEnableCommand: command) else {
        throw OpenTileCommandFailure(message: "The window manager is disabled. Enable it to switch workspaces.")
    }
    let result = try await runLightSession(.socketServer(command.args), token) {
        await command.run(.defaultEnv, .emptyStdin)
    }
    guard result.exitCode.rawValue == 0 else {
        throw OpenTileCommandFailure(message: result.stderr.joined(separator: "\n"))
    }
    return result.stdout.joined(separator: "\n")
}

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
