import AppKit

enum DragTestFailure: Error { case assertion(String) }

@main
struct FileDragTests {
    @MainActor
    static func main() throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw DragTestFailure.assertion(message) }
        }

        let urls = ["/missing/alpha.txt", "/missing/中文 空格 #%.txt", "/missing/dangling-link"]
            .map { URL(fileURLWithPath: $0) }
        // This child publishes eager bytes and exits before the parent reads.
        // No running drag source or data-provider callback can service a read.
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--publish" {
            let board = NSPasteboard.withUniqueName()
            let writers = FileDragPayload.items(for: urls, origin: .zero)
                .compactMap { $0.item as? NSPasteboardItem }
            guard board.writeObjects(writers) else { throw DragTestFailure.assertion("child write failed") }
            try board.name.rawValue.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
            return
        }
        let items = FileDragPayload.items(for: urls, origin: NSPoint(x: 10, y: 20))
        let writers = items.compactMap { $0.item as? NSPasteboardItem }
        try expect(writers.count == urls.count, "selection was truncated")
        try expect(writers.map { $0.string(forType: .fileURL) } == urls.map(\.absoluteString),
                   "URL bytes changed or require a deferred provider")
        print("PASS all selected URLs eagerly encoded, including Unicode and missing paths")

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try expect(pasteboard.writeObjects(writers), "pasteboard write failed")
        let received = pasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL]
        try expect(received == urls, "external NSURL reader did not receive every file URL in order")
        print("PASS native file URL pasteboard round trip for three files")

        let start = Date()
        let large = FileDragPayload.items(
            for: (0..<10_000).map { URL(fileURLWithPath: "/missing/\($0).txt") },
            origin: .zero
        )
        let extent = large.reduce(NSRect.null) { $0.union($1.draggingFrame) }
        try expect(large.count == 10_000, "large selection was truncated")
        try expect(extent.width <= 40 && extent.height <= 40, "unbounded drag surface")
        print("PASS 10000 file payloads retain every URL with bounded 40x40 geometry (\(Date().timeIntervalSince(start))s)")

        try expect(FileDragPayload.items(for: [], origin: .zero).isEmpty, "empty drag")
        try expect(FileDragPayload.items(for: [URL(string: "smb://server/share")!], origin: .zero).isEmpty,
                   "unmounted network location exported as a file")
        print("PASS empty and non-file selections do not start file drags")

        let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("pasteboard-name.txt")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--publish", output.path]
        try child.run()
        child.waitUntilExit()
        try expect(child.terminationStatus == 0, "publisher failed")
        let name = try String(contentsOf: output, encoding: .utf8)
        let inherited = NSPasteboard(name: NSPasteboard.Name(name))
        defer { inherited.releaseGlobally() }
        let afterExit = inherited.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL]
        try expect(afterExit == urls, "a dead source process blocked or changed the receiver data")
        print("PASS independent receiver reads every URL after the publisher exits")
        print("RESULT passed=5 failed=0")
    }
}
