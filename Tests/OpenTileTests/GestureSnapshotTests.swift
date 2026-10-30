import AppKit
import Common
import Testing
@testable import AppBundle
@testable import OpenTile

// These tests and swap tests share the engine's process-global focus state.
extension DirectSwapTests {
    @Suite(.serialized)
    @MainActor struct GestureSnapshotTests {
        private final class App: AbstractApp {
            let pid: Int32 = 1234
            var rawAppBundleId: String? { nil }
            var name: String? { nil }
            var execPath: String? { nil }
            var bundlePath: String? { nil }
            func getFocusedWindow(_ cm: CancellationMode) async throws -> Window? { nil }
        }
        private final class TestWindow: Window {
            override var isHiddenInCorner: Bool { false }
        }
        @MainActor private struct Fixture {
            let workspace = Workspace.get(byName: UUID().uuidString)
            let app = App()
            let windows: [TestWindow]
            init() {
                workspace.rootTilingContainer.layout = .tiles
                let workspace = self.workspace
                let app = self.app
                windows = (1...3).map {
                    TestWindow(id: UInt32($0), app, lastFloatingSize: nil, parent: workspace.rootTilingContainer,
                               adaptiveWeight: CGFloat($0), index: INDEX_BIND_LAST)
                }
                _ = windows[0].focusWindow()
            }
            func cleanup() { windows.forEach { if $0.isBound { $0.unbindFromParent() } } }
            func read(_ windowInfo: [[String: Any]]) -> OpenTileGestureSnapshot? {
                makeOpenTileGestureSnapshot(source: windows[0], windowInfo: windowInfo, discoverablePIDs: [app.pid],
                                            resolve: { id in windows.first { $0.windowId == id && $0.isBound } })
            }
            func info(_ id: UInt32, pid: Int32 = 1234, x: CGFloat = 0) -> [String: Any] {
                [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
                 kCGWindowLayer as String: 0,
                 kCGWindowBounds as String: CGRect(x: x, y: 0, width: 100, height: 100).dictionaryRepresentation]
            }
        }

        @Test func readsFreshFramesWithoutChangingTreeWeightsOrFocus() async throws {
            let f = Fixture()
            defer { f.cleanup() }
            let order = f.workspace.allLeafWindowsRecursive.map(\.windowId)
            let weights = f.windows.map { $0.getWeight(f.workspace.rootTilingContainer.orientation) }
            let result = try #require(f.read([f.info(1, x: 12), f.info(2, x: 200), f.info(3, x: 400)]))
            #expect(result.source.endpoint.id == 1)
            #expect(result.source.frame.minX == 12)
            #expect(result.targets.map(\.endpoint.id) == [2, 3])
            #expect(result.targets.map(\.frame.minX) == [200, 400])
            #expect(f.workspace.allLeafWindowsRecursive.map(\.windowId) == order)
            #expect(f.windows.map { $0.getWeight(f.workspace.rootTilingContainer.orientation) } == weights)
            #expect(focus.windowOrNil === f.windows[0])
        }

        @Test(arguments: ["unknown", "source-missing", "source-pid", "source-bounds", "floating", "accordion", "ancestor-accordion", "fullscreen", "unbound", "focus-changed"])
        func uncertainReadsRequestTheExistingQueryPath(kind: String) {
            let f = Fixture()
            defer { f.cleanup() }
            var infos = f.windows.map { f.info($0.windowId) }
            switch kind {
            case "unknown": infos.append(f.info(999))
            case "source-missing": infos.removeFirst()
            case "source-pid": infos[0] = f.info(1, pid: 999)
            case "source-bounds": infos[0][kCGWindowBounds as String] = CGRect.zero.dictionaryRepresentation
            case "floating": f.windows[0].bindAsFloatingWindow(to: f.workspace)
            case "accordion": f.workspace.rootTilingContainer.layout = .accordion
            case "ancestor-accordion":
                let child = TilingContainer.newVTiles(parent: f.workspace.rootTilingContainer, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                f.windows[0].bind(to: child, adaptiveWeight: 1, index: INDEX_BIND_LAST)
                f.workspace.rootTilingContainer.layout = .accordion
            case "fullscreen": f.windows[0].isFullscreen = true
            case "unbound": f.windows[0].unbindFromParent()
            case "focus-changed": _ = f.windows[1].focusWindow()
            default: break
            }
            #expect(f.read(infos) == nil)
        }

        @Test func omitsClosedTargetsAndRequiresADestination() throws {
            let f = Fixture()
            defer { f.cleanup() }
            #expect(f.read([f.info(1), f.info(2, pid: 999), f.info(3)]) == nil)
            let result = try #require(f.read([f.info(1), f.info(3)]))
            #expect(result.targets.map(\.endpoint.id) == [3])
            #expect(f.read([f.info(1)]) == nil)
        }

        @Test func ignoresOverlayWindowsAndFiltersOtherWorkspaces() throws {
            let f = Fixture()
            defer { f.cleanup() }
            var overlay = f.info(999)
            overlay[kCGWindowLayer as String] = 3
            f.windows[2].bind(to: Workspace.get(byName: "other-\(f.workspace.name)").rootTilingContainer,
                              adaptiveWeight: 1, index: INDEX_BIND_LAST)
            let result = try #require(f.read([f.info(1), f.info(2), f.info(3), overlay, f.info(998, pid: 999)]))
            #expect(result.targets.map(\.endpoint.id) == [2])
        }

        @Test func aSuspendedDiscoveryOrSessionCannotExposeItsPartialTree() async throws {
            let f = Fixture()
            defer { f.cleanup() }
            let info = f.windows.map { f.info($0.windowId) }
            #expect(f.read(info) != nil)
            func simulateDiscoveryCallback() async {
                openTileSnapshotMutationCount += 1
                defer { openTileSnapshotMutationCount -= 1 }
                await Task.yield()
                #expect(f.read(info) == nil)
                f.windows[2].bind(to: Workspace.get(byName: "callback-\(f.workspace.name)").rootTilingContainer,
                                  adaptiveWeight: 1, index: INDEX_BIND_LAST)
                #expect(f.read(info) == nil)
            }
            openTileSnapshotMutationCount += 1
            await simulateDiscoveryCallback()
            #expect(f.read(info) == nil) // The outer session has not finished yet.
            openTileSnapshotMutationCount -= 1
            let result = try #require(f.read(info))
            #expect(result.targets.map(\.endpoint.id) == [2])
        }

        @Test func cancellationAfterAnEmbeddedReadNeverFallsBack() async {
            let engine = AeroSpace(execute: { _ in throw AeroSpace.Failure(message: "fallback reached") })
            let task = Task { @MainActor in
                try await engine.snapshot(read: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return nil
                })
            }
            do { _ = try await task.value; Issue.record("Cancelled read fell back") }
            catch { #expect(error is CancellationError) }
        }

        @Test func cancelledReadNeverStartsDiscovery() async {
            let engine = AeroSpace(execute: { _ in throw AeroSpace.Failure(message: "fallback reached") })
            var reads = 0
            let task = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await engine.snapshot(read: {
                    reads += 1
                    return nil
                })
            }
            do { _ = try await task.value; Issue.record("Cancelled snapshot accepted") }
            catch { #expect(error is CancellationError) }
            #expect(reads == 0)
        }

        @Test func embeddedSnapshotSkipsCommandDiscovery() async throws {
            let f = Fixture()
            defer { f.cleanup() }
            let snapshot = try #require(f.read(f.windows.map { f.info($0.windowId) }))
            let result = try await AeroSpace(execute: { _ in throw AeroSpace.Failure(message: "fallback reached") })
                .snapshot(read: { snapshot })
            #expect(result.source.tile.id == 1)
            #expect(result.targets.map(\.tile.id) == [2, 3])
        }

        @Test func unavailableEmbeddedSnapshotFallsBackToEngineCommands() async throws {
            var commands: [[String]] = []
            do {
                _ = try await AeroSpace(execute: { commands.append($0); throw AeroSpace.Failure(message: "snapshot fallback reached") })
                    .snapshot(read: { nil })
                Issue.record("Failed fallback accepted")
            } catch let error as AeroSpace.Failure {
                #expect(error.message == "snapshot fallback reached")
            }
            #expect(commands.first?.prefix(2) == ["list-windows", "--focused"])
        }
    }
}
