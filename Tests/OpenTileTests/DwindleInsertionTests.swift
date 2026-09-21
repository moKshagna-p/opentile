import Foundation
import Testing
@testable import AppBundle

@MainActor
struct DwindleInsertionTests {
    private final class App: AbstractApp {
        let pid: Int32 = -901
        let rawAppBundleId: String? = nil
        let name: String? = nil
        let execPath: String? = nil
        let bundlePath: String? = nil
        func getFocusedWindow(_ cm: CancellationMode) async throws -> Window? { nil }
    }

    private func add(_ id: UInt32, app: App, parent: TilingContainer, after anchor: Window? = nil) -> Window {
        let index = anchor.flatMap { parent.children.firstIndex(of: $0) }.map { $0 + 1 } ?? INDEX_BIND_LAST
        let binding = dwindleBindingForNewWindow(BindingData(parent: parent, adaptiveWeight: WEIGHT_AUTO, index: index))
        return Window(id: id, app, lastFloatingSize: nil, parent: binding.parent,
                      adaptiveWeight: binding.adaptiveWeight, index: binding.index)
    }

    @Test func repeatedOpeningsSplitOnlyTheFocusedTile() throws {
        let app = App()
        let root = TilingContainer.newHTiles(parent: NilTreeNode.instance, adaptiveWeight: 1, index: 0)
        let first = add(1, app: app, parent: root)
        let second = add(2, app: app, parent: root, after: first)
        #expect(root.children == [first, second])
        #expect(first.getWeight(.h) == second.getWeight(.h))
        let third = add(3, app: app, parent: root, after: second)
        let vertical = try #require(second.parent as? TilingContainer)
        #expect(root.children == [first, vertical])
        #expect(vertical.orientation == .v)
        #expect(vertical.children == [second, third])
        #expect(vertical.getWeight(.h) == first.getWeight(.h))
        let fourth = add(4, app: app, parent: vertical, after: third)
        let horizontal = try #require(third.parent as? TilingContainer)
        #expect(horizontal.orientation == .h)
        #expect(horizontal.children == [third, fourth])
        #expect(vertical.children == [second, horizontal])
        #expect(second.getWeight(.v) == horizontal.getWeight(.v))
        // Refocusing the first tile splits that tile, not the newest branch.
        let fifth = add(5, app: app, parent: root, after: first)
        #expect(first.parent === fifth.parent)
        #expect(root.children.count == 2)
        #expect(vertical.children == [second, horizontal])
    }

    @Test func closeAndReopenPreservesSpaceAndNormalizesTree() throws {
        let app = App()
        let workspace = Workspace.get(byName: "dwindle-test-\(UUID().uuidString)")
        let root = workspace.rootTilingContainer
        let first = add(11, app: app, parent: root)
        let second = add(12, app: app, parent: root, after: first)
        let third = add(13, app: app, parent: root, after: second)
        third.unbindFromParent()
        workspace.normalizeContainers()
        #expect(root.children == [first, second])
        let fourth = add(14, app: app, parent: root, after: second)
        let split = try #require(second.parent as? TilingContainer)
        #expect(split.children == [second, fourth])
        #expect(split.getWeight(root.orientation) == first.getWeight(root.orientation))
        for window in [first, second, fourth] { window.unbindFromParent() }
        workspace.normalizeContainers()
    }

    @Test func accordionAndNonTilingBindingsAreUnchanged() {
        let app = App()
        let accordion = TilingContainer(parent: NilTreeNode.instance, adaptiveWeight: 1, .h, .accordion, index: 0)
        let first = add(21, app: app, parent: accordion)
        let second = add(22, app: app, parent: accordion, after: first)
        let third = add(23, app: app, parent: accordion, after: second)
        #expect(accordion.children == [first, second, third])
        let binding = BindingData(parent: NilTreeNode.instance, adaptiveWeight: 7, index: 0)
        let result = dwindleBindingForNewWindow(binding)
        #expect(result.parent === binding.parent)
        #expect(result.adaptiveWeight == 7)
        #expect(result.index == 0)
    }
}
