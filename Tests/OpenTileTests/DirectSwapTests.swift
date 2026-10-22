import AppKit
import Common
import Testing
@testable import AppBundle

@Suite(.serialized)
@MainActor struct DirectSwapTests {
    private final class App: AbstractApp {
        let pid: Int32 = 1234
        var rawAppBundleId: String? { nil }
        var name: String? { nil }
        var execPath: String? { nil }
        var bundlePath: String? { nil }
        func getFocusedWindow(_ cm: CancellationMode) async throws -> Window? { nil }
    }

    private final class TestWindow: Window {
        var read: () async throws -> Void = {}
        var closed = false
        var fullscreen = false
        var minimized = false
        override func getAxRect(_ cm: CancellationMode) async throws -> Rect? {
            try await read()
            return closed ? nil : Rect(topLeftX: 0, topLeftY: 0, width: 100, height: 100)
        }
        override func isMacosFullscreen(_ cm: CancellationMode) async throws -> Bool { fullscreen }
        override func isMacosMinimized(_ cm: CancellationMode) async throws -> Bool { minimized }
    }

    @MainActor private struct Fixture {
        let workspace = Workspace.get(byName: UUID().uuidString)
        let app = App()
        var windows: [TestWindow] = []
        init(nested: Bool = false, count: Int = 6) {
            let root = workspace.rootTilingContainer
            root.layout = .tiles
            for index in 0..<count {
                let parent: TilingContainer
                if nested && index % 2 == 1 {
                    parent = TilingContainer.newVTiles(parent: root, adaptiveWeight: CGFloat(index + 10), index: INDEX_BIND_LAST)
                } else { parent = root }
                windows.append(TestWindow(id: UInt32(index + 1), app, lastFloatingSize: nil,
                                          parent: parent, adaptiveWeight: CGFloat(index + 1), index: INDEX_BIND_LAST))
            }
        }
        func endpoint(_ index: Int, id: Int? = nil, pid: Int32? = nil,
                      workspace name: String? = nil, layout: String? = nil) -> OpenTileSwapEndpoint {
            let window = windows[index]
            let parent = window.parent as! TilingContainer
            return OpenTileSwapEndpoint(id: id ?? Int(window.windowId), pid: pid ?? app.pid,
                                        workspace: name ?? workspace.name,
                                        layout: layout ?? (parent.orientation == .h ? "h_tiles" : "v_tiles"))
        }
        func resolve(_ id: UInt32) -> Window? { windows.first { $0.windowId == id && $0.isBound } }
        func cleanup() {
            windows.forEach { if $0.isBound { $0.unbindFromParent() } }
        }
    }

    @Test(arguments: [false, true])
    func everyEndpointPairPreservesSlotsWeightsAndSourceFocus(nested: Bool) async throws {
        for count in 2...8 {
            for source in 0..<count {
                for target in 0..<count where source != target {
                    let f = Fixture(nested: nested, count: count)
                    defer { f.cleanup() }
                    let parents = f.windows.map { $0.parent as! TilingContainer }
                    let indices = f.windows.map(\.ownIndex)
                    let weights = f.windows.enumerated().map { $0.element.getWeight(parents[$0.offset].orientation) }
                    let sourceEndpoint = f.endpoint(source)
                    let targetEndpoint = f.endpoint(target)
                    _ = f.windows[target].focusWindow()
                    var liveChecks = 0
                    try await performOpenTileSwap(source: sourceEndpoint, target: targetEndpoint, resolve: { f.resolve($0) }) { _ in
                        liveChecks += 1
                        return true
                    }
                    #expect(liveChecks == 2)
                    for index in 0..<count {
                        let slot = index == source ? target : index == target ? source : index
                        #expect(f.windows[index].parent === parents[slot])
                        #expect(f.windows[index].ownIndex == indices[slot])
                        #expect(f.windows[index].getWeight(parents[slot].orientation) == weights[slot])
                    }
                    #expect(focus.windowOrNil === f.windows[source])
                    #expect(f.workspace.mostRecentWindowRecursive === f.windows[source])
                    try await performOpenTileSwap(source: f.endpoint(source), target: f.endpoint(target),
                                                  resolve: { f.resolve($0) }, isLive: { _ in true })
                    for index in 0..<count {
                        #expect(f.windows[index].parent === parents[index])
                        #expect(f.windows[index].ownIndex == indices[index])
                        #expect(f.windows[index].getWeight(parents[index].orientation) == weights[index])
                    }
                }
            }
        }
    }

    @Test(arguments: ["same", "negative", "overflow", "stale-id", "source-pid", "target-pid", "workspace", "layout", "floating", "accordion", "ancestor-accordion", "fullscreen", "minimized", "closed", "native-fullscreen", "not-live"])
    func rejectsInvalidEndpointsWithoutSwapping(kind: String) async {
        let f = Fixture(nested: true)
        defer { f.cleanup() }
        var source = f.endpoint(0)
        var target = f.endpoint(1)
        switch kind {
        case "same": target = source
        case "negative": source = f.endpoint(0, id: -1)
        case "overflow": target = f.endpoint(1, id: Int.max)
        case "stale-id": target = f.endpoint(1, id: 999)
        case "source-pid": source = f.endpoint(0, pid: 999)
        case "target-pid": target = f.endpoint(1, pid: 999)
        case "workspace": target = f.endpoint(1, workspace: "other")
        case "layout": target = f.endpoint(1, layout: "h_accordion")
        case "floating": f.windows[1].bindAsFloatingWindow(to: f.workspace)
        case "accordion": (f.windows[1].parent as! TilingContainer).layout = .accordion
        case "ancestor-accordion": f.workspace.rootTilingContainer.layout = .accordion
        case "fullscreen": f.windows[1].isFullscreen = true
        case "minimized": f.windows[1].minimized = true
        case "closed": f.windows[1].closed = true
        case "native-fullscreen": f.windows[1].fullscreen = true
        default: break
        }
        let order = f.workspace.allLeafWindowsRecursive.map(\.windowId)
        do {
            try await performOpenTileSwap(source: source, target: target, resolve: { f.resolve($0) },
                                          isLive: { _ in kind != "not-live" })
            Issue.record("Invalid endpoint accepted: \(kind)")
        } catch { #expect(error is OpenTileSwapFailure) }
        #expect(f.workspace.allLeafWindowsRecursive.map(\.windowId) == order)
    }

    @Test(arguments: ["moved", "closed", "replacement", "layout", "reordered", "weight", "ancestor-orientation", "ancestor-order", "ancestor-weight", "ancestor-parent", "disabled", "cancelled", "AX-error"])
    func revalidatesAfterSuspendingReads(kind: String) async {
        let f = Fixture(nested: kind.hasPrefix("ancestor-"))
        defer { f.cleanup() }
        let source = f.endpoint(kind.hasPrefix("ancestor-") ? 3 : 0)
        let target = f.endpoint(1)
        let initialFocus = focus.windowOrNil
        var resolvable = true
        var orderAfterRace: [UInt32] = []
        f.windows[1].read = {
            switch kind {
            case "moved":
                f.windows[0].bind(to: Workspace.get(byName: "moved-\(f.workspace.name)").rootTilingContainer,
                                  adaptiveWeight: 1, index: INDEX_BIND_LAST)
            case "closed": f.windows[0].unbindFromParent()
            case "replacement": resolvable = false
            case "layout": f.workspace.rootTilingContainer.changeOrientation(.v)
            case "reordered": swapWindows(mruDominant: f.windows[0], f.windows[2])
            case "weight": f.windows[0].setWeight(f.workspace.rootTilingContainer.orientation, 42)
            case "ancestor-orientation": f.workspace.rootTilingContainer.changeOrientation(.v)
            case "ancestor-order":
                let parent = f.windows[1].parent as! TilingContainer
                parent.bind(to: f.workspace.rootTilingContainer, adaptiveWeight: 11, index: 0)
            case "ancestor-weight":
                (f.windows[1].parent as! TilingContainer).setWeight(f.workspace.rootTilingContainer.orientation, 42)
            case "ancestor-parent":
                let parent = f.windows[1].parent as! TilingContainer
                let container = TilingContainer.newHTiles(parent: f.workspace.rootTilingContainer,
                                                          adaptiveWeight: 1, index: INDEX_BIND_LAST)
                parent.bind(to: container, adaptiveWeight: 11, index: INDEX_BIND_LAST)
            case "disabled": TrayMenuModel.shared.isEnabled = false
            case "cancelled": withUnsafeCurrentTask { $0?.cancel() }
            case "AX-error": throw CocoaError(.fileReadUnknown)
            default: break
            }
            orderAfterRace = f.workspace.allLeafWindowsRecursive.map(\.windowId)
            await Task.yield()
        }
        defer { TrayMenuModel.shared.isEnabled = true }
        // Cancellation is scoped to a child task so other parameterized cases remain runnable.
        let task = Task { @MainActor in
            try await performOpenTileSwap(source: source, target: target,
                                          resolve: { resolvable ? f.resolve($0) : nil }, isLive: { _ in true })
        }
        do { try await task.value; Issue.record("Race accepted: \(kind)") }
        catch {
            if kind == "cancelled" { #expect(error is CancellationError) }
            else if kind == "AX-error" { #expect(error is CocoaError) }
            else { #expect(error is OpenTileSwapFailure) }
        }
        if kind != "AX-error" { #expect(f.workspace.allLeafWindowsRecursive.map(\.windowId) == orderAfterRace) }
        #expect(focus.windowOrNil === initialFocus)
    }

    @Test func cancelledBeforeSessionDoesNotResolveOrMutate() async {
        let f = Fixture()
        defer { f.cleanup() }
        let order = f.workspace.allLeafWindowsRecursive.map(\.windowId)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await swapOpenTileWindows(source: f.endpoint(0), target: f.endpoint(1))
        }
        do { try await task.value; Issue.record("Cancelled session accepted") }
        catch { #expect(error is CancellationError) }
        #expect(f.workspace.allLeafWindowsRecursive.map(\.windowId) == order)
    }
}
