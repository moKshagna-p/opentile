import OpenTileCore

func processGesturePreviewBatch(_ events: some Sequence<GestureEvent>, handle: (GestureEvent) -> Void) {
    var pending: GestureEvent?
    func flush() {
        guard let event = pending else { return }
        pending = nil
        handle(event)
    }
    for event in events {
        switch event {
        case .moved, .resized:
            pending = event
        case .cancelled:
            pending = nil
            handle(event)
        default:
            // Release must see the final destination/size before it commits and clears the preview.
            flush()
            handle(event)
        }
    }
    flush()
}
