import AppKit

// Engine work suspends on AX/callbacks; a different task must not snapshot its partial model.
@MainActor var openTileSnapshotMutationCount = 0

public struct OpenTileSnapshotWindow {
    public let endpoint: OpenTileSwapEndpoint
    public let frame: CGRect
}

public struct OpenTileGestureSnapshot {
    public let source: OpenTileSnapshotWindow
    public let targets: [OpenTileSnapshotWindow]
}

/// A nil result asks the caller to use its normal session for discovery or reconciliation.
@MainActor public func readOpenTileGestureSnapshot() async throws -> OpenTileGestureSnapshot? {
    try Task.checkCancellation()
    guard RunSessionGuard.isServerEnabled != nil, openTileSnapshotMutationCount == 0, isOpenTileFocusSettled,
          let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
          let app = MacApp.allAppsMap[pid] else { return nil }
    let source: Window?
    do { source = try await app.getKnownFocusedWindow(.cancellable) }
    catch is CancellationError { throw CancellationError() }
    catch { return nil }
    try Task.checkCancellation()
    guard RunSessionGuard.isServerEnabled != nil, openTileSnapshotMutationCount == 0, isOpenTileFocusSettled,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
          let source, source.app === app,
          let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
    let discoverablePIDs = Set(NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular
    }.map(\.processIdentifier)).union(MacApp.allAppsMap.keys)
    return makeOpenTileGestureSnapshot(source: source, windowInfo: info, discoverablePIDs: discoverablePIDs)
}

@MainActor func makeOpenTileGestureSnapshot(
    source: Window, windowInfo: [[String: Any]], discoverablePIDs: Set<Int32>,
    resolve: (UInt32) -> Window? = { Window.get(byId: $0) }
) -> OpenTileGestureSnapshot? {
    guard openTileSnapshotMutationCount == 0, source === focus.windowOrNil, resolve(source.windowId) === source,
          let workspace = source.nodeWorkspace else { return nil }
    var frames: [UInt32: (pid: Int32, frame: CGRect)] = [:]
    for info in windowInfo {
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              let id = info[kCGWindowNumber as String] as? UInt32,
              let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != myPid else { continue }
        // A newly visible window may still be awaiting normal engine discovery.
        if let window = resolve(id) {
            guard window.app.pid == pid else { return nil }
        } else {
            if discoverablePIDs.contains(pid) { return nil }
            continue
        }
        guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else { continue }
        frames[id] = (pid, frame)
    }
    func snapshot(_ window: Window) -> OpenTileSnapshotWindow? {
        guard window.nodeWorkspace === workspace, !window.isFullscreen, !window.isHiddenInCorner,
              window.layoutReason == .standard,
              let parent = window.parent as? TilingContainer, parent.layout == .tiles,
              window.parents.compactMap({ $0 as? TilingContainer }).allSatisfy({ $0.layout == .tiles }),
              let entry = frames[window.windowId], entry.pid == window.app.pid else { return nil }
        return OpenTileSnapshotWindow(endpoint: OpenTileSwapEndpoint(
            id: Int(window.windowId), pid: window.app.pid, workspace: workspace.name,
            layout: parent.orientation == .h ? "h_tiles" : "v_tiles"), frame: entry.frame)
    }
    guard let sourceSnapshot = snapshot(source) else { return nil }
    let targets = workspace.allLeafWindowsRecursive.filter { $0 !== source }.compactMap(snapshot)
    guard !targets.isEmpty else { return nil }
    return OpenTileGestureSnapshot(source: sourceSnapshot, targets: targets)
}
