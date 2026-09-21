import AppKit

/// Split only the most recently focused tile. Startup discovery and explicit
/// moves keep their existing insertion path; dialogs and accordion stay intact.
@MainActor
func dwindleBindingForNewWindow(_ binding: BindingData) -> BindingData {
    guard let parent = binding.parent as? TilingContainer,
          parent.layout == .tiles,
          binding.index > 0, binding.index <= parent.children.count,
          let anchor = parent.children[binding.index - 1] as? Window else { return binding }

    TileResizeAnimator.shared.prepare([anchor])
    if parent.children.count == 1 {
        // Reuse a single-child container, including one left after a close.
        return BindingData(parent: parent, adaptiveWeight: anchor.getWeight(parent.orientation), index: 1)
    }

    let previous = anchor.unbindFromParent()
    let split = TilingContainer(parent: parent, adaptiveWeight: previous.adaptiveWeight,
                                parent.orientation.opposite, .tiles, index: previous.index)
    anchor.bind(to: split, adaptiveWeight: 1, index: 0)
    return BindingData(parent: split, adaptiveWeight: 1, index: 1)
}
