import AppKit

class TableCellClickTargetNSView: NSView {
    var onSelect: (SelectionMode) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onLongPress: () -> Void = {}
    var isSelected = false
    var dragURLs: () -> [URL] = { [] }
    var onFocus: () -> Void = {}

    private var longPressTimer: Timer?
    private var mouseDownEvent: NSEvent?
    private var pendingDragURLs: [URL] = []
    private var isDragSessionActive = false
    private var selectsOnMouseUp = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !isDragSessionActive else { return }
        mouseDownEvent = event
        selectsOnMouseUp = false
        // This overlay handles selection itself, so native table mouseDown never
        // gets a chance to transfer focus away from a text field or terminal.
        onFocus()
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView {
                window?.makeFirstResponder(table)
                break
            }
            ancestor = view.superview
        }

        if event.modifierFlags.contains(.shift) {
            onSelect(.range)
        } else if event.modifierFlags.contains(.command) {
            onSelect(.toggle)
        } else if !isSelected || event.clickCount >= 2 {
            onSelect(.single)
        } else {
            // Keep a multi-selection alive until we know this is a click.
            // Updating it here can rebuild the SwiftUI row before mouseDragged.
            selectsOnMouseUp = true
        }

        if event.clickCount >= 2 {
            clearPress()
            onOpen()
        } else {
            // Resolve once after modifier selection, before SwiftUI can reuse
            // this cell or replace its callbacks during the gesture.
            pendingDragURLs = dragURLs()
            if event.modifierFlags.intersection([.shift, .command]).isEmpty {
                scheduleLongPress()
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        cancelLongPress()
        guard !isDragSessionActive else { return }
        if selectsOnMouseUp {
            selectsOnMouseUp = false
            onSelect(.single)
        }
        clearPress()
    }

    override func mouseDragged(with event: NSEvent) {
        cancelLongPress()

        guard !isDragSessionActive, let press = mouseDownEvent else { return }
        // Compare window coordinates: layout can change the cell's local
        // origin between the press and the first drag event.
        let origin = press.locationInWindow
        let point = event.locationInWindow
        guard hypot(point.x - origin.x, point.y - origin.y) > 3 else { return }

        beginDragSession(with: press)
    }

    /// Starts a native dragging session instead of SwiftUI's drag machinery.
    /// SwiftUI builds its drag image by snapshotting the row, which raises
    /// `CALayerInvalidGeometry` for these table rows and cancels the drag.
    private func beginDragSession(with event: NSEvent) {
        let items = FileDragPayload.items(
            for: pendingDragURLs,
            origin: convert(event.locationInWindow, from: nil)
        )
        guard !items.isEmpty else { return }
        NSLog("MaXplorer file drag: request count=%ld event=%lu", items.count, event.type.rawValue)
        isDragSessionActive = true
        selectsOnMouseUp = false
        if !beginFileDrag(with: items, event: event) {
            finishFileDrag(operation: [])
        }
    }

    /// The only boundary that starts a system drag; isolated tests override it.
    func beginFileDrag(with items: [NSDraggingItem], event: NSEvent) -> Bool {
        guard window != nil else {
            NSLog("MaXplorer file drag: rejected detached source")
            return false
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.draggingFormation = .pile
        NSLog("MaXplorer file drag: created sequence=%ld count=%ld", session.draggingSequenceNumber, items.count)
        return true
    }

    func finishFileDrag(operation: NSDragOperation, sequence: Int? = nil) {
        if let sequence {
            NSLog("MaXplorer file drag: ended sequence=%ld operation=%lu", sequence, operation.rawValue)
        } else {
            NSLog("MaXplorer file drag: reset operation=%lu", operation.rawValue)
        }
        isDragSessionActive = false
        clearPress()
    }

    deinit { longPressTimer?.invalidate() }

    private func scheduleLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.clearPress()
            self.onLongPress()
        }
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    private func clearPress() {
        cancelLongPress()
        mouseDownEvent = nil
        pendingDragURLs = []
        selectsOnMouseUp = false
    }
}

extension TableCellClickTargetNSView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        NSLog("MaXplorer file drag: began sequence=%ld count=%ld", session.draggingSequenceNumber, pendingDragURLs.count)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        [.copy, .move]
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        finishFileDrag(operation: operation, sequence: session.draggingSequenceNumber)
    }
}
