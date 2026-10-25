import AppKit

@MainActor
final class RecordingFileRow: TableCellClickTargetNSView {
    var starts: [([NSDraggingItem], NSEvent)] = []
    var acceptsStart = true

    override func beginFileDrag(with items: [NSDraggingItem], event: NSEvent) -> Bool {
        starts.append((items, event))
        return acceptsStart
    }
}

@main
struct NativeInteractionTests {
    @MainActor
    static func main() throws {
        var passed = 0
        var failed = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw DragTestFailure.assertion(message) }
        }
        func test(_ name: String, _ body: () throws -> Void) {
            do { try body(); passed += 1; print("PASS \(name)") }
            catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        func event(_ type: NSEvent.EventType, _ point: NSPoint,
                   flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                              timestamp: 1, windowNumber: 0, context: nil,
                              eventNumber: 1, clickCount: clicks, pressure: 1)!
        }
        let down = event(.leftMouseDown, NSPoint(x: 10, y: 10))
        let dragged = event(.leftMouseDragged, NSPoint(x: 30, y: 10))
        let up = event(.leftMouseUp, NSPoint(x: 30, y: 10))
        let urls = (1...3).map { URL(fileURLWithPath: "/missing/\($0).txt") }
        func view() -> RecordingFileRow {
            let row = RecordingFileRow(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
            row.isSelected = true
            row.dragURLs = { urls }
            return row
        }

        test("native collection source requests focus before selecting") {
            let row = view()
            row.isSelected = false
            var events: [String] = []
            row.onFocus = { events.append("focus") }
            row.onSelect = { _ in events.append("select") }
            row.mouseDown(with: down)
            row.mouseUp(with: up)
            try expect(events == ["focus", "select"], "collection click did not request focus before selection")
        }
        test("native source passes the original mouse-down event to AppKit") {
            let row = view()
            row.mouseDown(with: down)
            row.mouseDragged(with: dragged)
            try expect(row.starts.count == 1, "no drag start")
            try expect(row.starts[0].1 === down, "AppKit received a mouseDragged event instead of the original mouseDown")
            row.finishFileDrag(operation: [])
        }
        test("native source freezes selected URLs for the gesture") {
            let row = view()
            row.mouseDown(with: down)
            row.dragURLs = { [urls[0]] }
            row.mouseDragged(with: dragged)
            try expect(row.starts.count == 1 && row.starts[0].0.count == 3,
                       "SwiftUI update replaced the pressed selection before the drag started")
            row.finishFileDrag(operation: [])
        }
        test("native source does not drag on the second half of a double click") {
            let row = view()
            var opened = 0
            row.onOpen = { opened += 1 }
            row.mouseDown(with: event(.leftMouseDown, NSPoint(x: 10, y: 10), clicks: 2))
            row.mouseDragged(with: dragged)
            try expect(opened == 1 && row.starts.isEmpty, "double click opened and started a drag")
        }
        test("native multi-selection stays selected until mouse-up") {
            let row = view()
            var selections = 0
            row.onSelect = { _ in selections += 1 }
            row.mouseDown(with: down)
            try expect(selections == 0, "selection collapsed on press")
            row.mouseUp(with: up)
            try expect(selections == 1, "click did not select one item on release")
        }
        test("native source starts once and can drag again after cancellation") {
            let row = view()
            row.mouseDown(with: down)
            row.mouseDragged(with: dragged)
            row.mouseDragged(with: dragged)
            try expect(row.starts.count == 1, "duplicate system drag start")
            row.finishFileDrag(operation: [])
            row.mouseDown(with: down)
            row.mouseDragged(with: dragged)
            try expect(row.starts.count == 2, "cancelled drag left the row stuck")
            row.finishFileDrag(operation: [])
        }
        test("native source ignores motion below the drag threshold") {
            let row = view()
            row.mouseDown(with: down)
            row.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 12, y: 10)))
            try expect(row.starts.isEmpty, "small motion started a system drag")
            row.mouseUp(with: up)
        }
        test("native source uses window coordinates after a layout change") {
            let row = view()
            row.mouseDown(with: down)
            row.setFrameOrigin(NSPoint(x: 100, y: 0))
            row.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 12, y: 10)))
            try expect(row.starts.isEmpty, "cell relayout turned a small pointer movement into a drag")
            row.mouseUp(with: up)
        }
        test("native source preserves modifier selection before its snapshot") {
            let row = view()
            var selection = [urls[0]]
            var ranged = false
            row.dragURLs = { selection }
            row.onSelect = { mode in
                if case .range = mode { ranged = true; selection = urls }
            }
            row.mouseDown(with: event(.leftMouseDown, NSPoint(x: 10, y: 10), flags: .shift))
            selection = []
            row.mouseDragged(with: dragged)
            try expect(ranged && row.starts.count == 1 && row.starts[0].0.count == 3,
                       "range selection was not captured before a later update")
            row.finishFileDrag(operation: [])
        }
        test("native source ignores another press while its session is active") {
            let row = view()
            var selections = 0
            row.onSelect = { _ in selections += 1 }
            row.mouseDown(with: down)
            row.mouseDragged(with: dragged)
            row.isSelected = false
            row.mouseDown(with: down)
            row.mouseDragged(with: dragged)
            row.mouseUp(with: up)
            try expect(row.starts.count == 1 && selections == 0,
                       "a second press replaced an active system drag")
            row.finishFileDrag(operation: [])
        }
        test("native source recovers after a rejected start without using stale press data") {
            let row = view()
            row.acceptsStart = false
            row.mouseDown(with: down)
            row.mouseDragged(with: dragged)
            row.acceptsStart = true
            row.mouseDragged(with: dragged)
            try expect(row.starts.count == 1, "rejected start kept stale press data")
            row.mouseDown(with: down)
            row.mouseDragged(with: dragged)
            try expect(row.starts.count == 2, "rejected start permanently blocked the row")
            row.finishFileDrag(operation: [])
        }
        test("native source does not shrink the selection on drag mouse-up") {
            let row = view()
            var selections = 0
            row.onSelect = { _ in selections += 1 }
            row.mouseDown(with: down)
            row.mouseDragged(with: dragged)
            row.mouseUp(with: up)
            row.finishFileDrag(operation: .copy)
            try expect(selections == 0, "mouse-up from a drag collapsed the selection")
        }
        test("native source rejects empty, non-file and unpressed drags") {
            let row = view()
            row.mouseDragged(with: dragged)
            row.dragURLs = { [] }
            row.mouseDown(with: down)
            row.mouseDragged(with: dragged)
            row.mouseUp(with: up)
            row.dragURLs = { [URL(string: "smb://server/share")!] }
            row.mouseDown(with: down)
            row.mouseDragged(with: dragged)
            row.mouseUp(with: up)
            try expect(row.starts.isEmpty, "invalid selection reached the system drag boundary")
        }
        test("native source cancels press after mouse-up") {
            let row = view()
            row.mouseDown(with: down)
            row.mouseUp(with: up)
            row.mouseDragged(with: dragged)
            try expect(row.starts.isEmpty, "released gesture started a system drag")
        }
        print("RESULT native passed=\(passed) failed=\(failed)")
        if failed != 0 { exit(1) }
    }
}

enum DragTestFailure: Error { case assertion(String) }
