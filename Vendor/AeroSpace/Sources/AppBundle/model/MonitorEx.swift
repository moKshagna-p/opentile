extension Monitor {
    @MainActor
    var visibleRectPaddedByOuterGaps: Rect {
        let topLeft = visibleRect.topLeftCorner
        let barInset = openTileAdditionalTopInset(barHeight: openTileBarHeight, existingInset: visibleRect.minY - rect.minY)
        let gaps = ResolvedGaps(gaps: config.gaps, monitor: self)
        return Rect(
            topLeftX: topLeft.x + gaps.outer.left.toDouble(),
            topLeftY: topLeft.y + gaps.outer.top.toDouble() + barInset,
            width: visibleRect.width - gaps.outer.left.toDouble() - gaps.outer.right.toDouble(),
            height: visibleRect.height - barInset - gaps.outer.top.toDouble() - gaps.outer.bottom.toDouble(),
        )
    }

    var monitorId_oneBased: Int? {
        let sorted = sortedMonitors
        let origin = self.rect.topLeftCorner
        return sorted.firstIndex { $0.rect.topLeftCorner == origin }.map { $0 + 1 }
    }
}
