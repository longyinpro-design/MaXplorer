import Foundation

extension FileOperationTests {
    static func spotlightSearchTests() async {
        await test("Spotlight rejects invalid scopes and empty content without creating driver") { dir in
            let probe = SpotlightDriverProbe()
            let service = SpotlightSearchService(timeout: 1, maximumResults: 10, makeDriver: { probe.markFactory(); return probe })
            for (url, text) in [(URL(string: "https://example.com/a")!, "text"), (URL(string: "file://remote/a")!, "text"), (dir, " \n ")] {
                try await mustFail { for try await _ in service.search(root: url, contentQuery: text) {} }
            }
            try expect(probe.factoryCount == 0, "invalid input constructed a driver")
        }
        await test("Spotlight configures exact root and literal query before start") { dir in
            let probe = SpotlightDriverProbe(events: [.snapshot([], finished: true, exceededLimit: false)])
            let service = SpotlightSearchService(timeout: 1, maximumResults: 10, makeDriver: { probe })
            let query = "a' OR TRUEPREDICATE OR '"
            for try await _ in service.search(root: dir.appendingPathComponent("child/.."), contentQuery: query) {}
            try expect(probe.configuration?.0.path == dir.standardizedFileURL.path, "scope wasn't explicit normalized root")
            try expect(probe.configuration?.1 == query, "literal query changed")
            try expect(probe.wasOffMain && probe.wasOnQueue, "driver ran outside private operation queue")
            try expect(probe.stopCount == 1, "completion did not stop driver once")
        }
        await test("Spotlight explicit volume scope remains supported without native query") { _ in
            let probe = SpotlightDriverProbe(events: [.snapshot([URL(fileURLWithPath: "/fixture.txt")], finished: true, exceededLimit: false)])
            let service = SpotlightSearchService(timeout: 1, maximumResults: 10, makeDriver: { probe })
            var count = 0
            for try await batch in service.search(root: URL(fileURLWithPath: "/"), contentQuery: "fixture") { count += batch.count }
            try expect(probe.configuration?.0.path == "/" && count == 1, "explicit root volume scope rejected")
        }
        await test("Spotlight candidates are deduplicated and strictly lexically scoped") { dir in
            let child = dir.appendingPathComponent("a.txt")
            let probe = SpotlightDriverProbe(events: [
                .snapshot([child, dir, dir.appendingPathComponent("../escape"), URL(fileURLWithPath: dir.path + "-other/a"), URL(string: "https://example.com/a")!], finished: false, exceededLimit: false),
                .snapshot([child, dir.appendingPathComponent("sub/../a.txt"), dir.appendingPathComponent("b.txt")], finished: true, exceededLimit: false)
            ])
            let service = SpotlightSearchService(timeout: 1, maximumResults: 10, makeDriver: { probe })
            var values: [URL] = []
            for try await batch in service.search(root: dir, contentQuery: "value") { values += batch }
            try expect(values == [child, dir.appendingPathComponent("b.txt")], "duplicate or escaped candidate published")
        }
        await test("Spotlight bounds emitted batch size") { dir in
            let urls = (0..<600).map { dir.appendingPathComponent("\($0).txt") }
            let probe = SpotlightDriverProbe(events: [.snapshot(urls, finished: true, exceededLimit: false)])
            let service = SpotlightSearchService(timeout: 1, maximumResults: 1000, makeDriver: { probe })
            var sizes: [Int] = []
            for try await batch in service.search(root: dir, contentQuery: "value") { sizes.append(batch.count) }
            try expect(sizes == [256, 256, 88], "batch bounds changed: \(sizes)")
        }
        await test("Spotlight limit error preserves already yielded candidates") { dir in
            let urls = (0..<4).map { dir.appendingPathComponent("\($0).txt") }
            let probe = SpotlightDriverProbe(events: [.snapshot(urls, finished: true, exceededLimit: false)])
            let service = SpotlightSearchService(timeout: 1, maximumResults: 3, makeDriver: { probe })
            var count = 0
            do {
                for try await batch in service.search(root: dir, contentQuery: "value") { count += batch.count }
                throw TestFailure.assertion("missing limit error")
            } catch SpotlightSearchError.resultLimitExceeded {}
            try expect(count == 3 && probe.stopCount == 1, "limit lost valid candidates or failed cleanup")
        }
        await test("Spotlight native limit signal reports incomplete results") { dir in
            let probe = SpotlightDriverProbe(events: [.snapshot([dir.appendingPathComponent("a")], finished: true, exceededLimit: true)])
            let service = SpotlightSearchService(timeout: 1, maximumResults: 3, makeDriver: { probe })
            do {
                for try await _ in service.search(root: dir, contentQuery: "value") {}
                throw TestFailure.assertion("missing native limit error")
            } catch SpotlightSearchError.resultLimitExceeded {}
            try expect(probe.stopCount == 1, "native limit failed cleanup")
        }
        await test("Spotlight failed start and driver error clean up once") { dir in
            for failedStart in [true, false] {
                let probe = SpotlightDriverProbe(events: failedStart ? [] : [.failed], starts: !failedStart)
                let service = SpotlightSearchService(timeout: 1, maximumResults: 10, makeDriver: { probe })
                do {
                    for try await _ in service.search(root: dir, contentQuery: "value") {}
                    throw TestFailure.assertion("failed driver finished successfully")
                } catch SpotlightSearchError.startFailed {}
                try expect(probe.stopCount == 1, "failed driver stop count wrong")
            }
        }
        await test("Spotlight timeout terminates a stalled query") { dir in
            let probe = SpotlightDriverProbe()
            let service = SpotlightSearchService(timeout: 0.02, maximumResults: 10, makeDriver: { probe })
            do {
                for try await _ in service.search(root: dir, contentQuery: "value") {}
                throw TestFailure.assertion("stalled query finished successfully")
            } catch SpotlightSearchError.timedOut {}
            try expect(probe.stopCount == 1, "timeout did not stop query")
        }
        await test("Spotlight consumer cancellation stops driver and ignores late notifications") { dir in
            let probe = SpotlightDriverProbe()
            let service = SpotlightSearchService(timeout: 5, maximumResults: 10, makeDriver: { probe })
            let consumer = Task { for try await _ in service.search(root: dir, contentQuery: "value") {} }
            for _ in 0..<1000 {
                if probe.configuration != nil { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try expect(probe.configuration != nil, "driver never started")
            consumer.cancel()
            _ = try? await consumer.value
            for _ in 0..<1000 {
                if probe.stopCount == 1 { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            probe.emit(.snapshot([dir.appendingPathComponent("late")], finished: true, exceededLimit: false))
            try await Task.sleep(nanoseconds: 10_000_000)
            try expect(probe.stopCount == 1, "late notification restarted cleanup")
        }
    }
}

nonisolated private final class SpotlightDriverProbe: SpotlightQueryDriver, @unchecked Sendable {
    private let lock = NSLock()
    private let events: [SpotlightQueryEvent]
    private let starts: Bool
    private var config: (URL, String)?
    private var stops = 0
    private var factories = 0
    private var offMain = false
    private var onQueue = false
    private var handler: (@Sendable (SpotlightQueryEvent) -> Void)?
    init(events: [SpotlightQueryEvent] = [], starts: Bool = true) { self.events = events; self.starts = starts }
    var configuration: (URL, String)? { lock.withLock { config } }
    var stopCount: Int { lock.withLock { stops } }
    var factoryCount: Int { lock.withLock { factories } }
    var wasOffMain: Bool { lock.withLock { offMain } }
    var wasOnQueue: Bool { lock.withLock { onQueue } }
    func markFactory() { lock.withLock { factories += 1 } }
    func start(root: URL, text: String, maximumResults: Int, queue: OperationQueue,
               receive: @escaping @Sendable (SpotlightQueryEvent) -> Void) -> Bool {
        lock.withLock {
            config = (root, text)
            offMain = !Thread.isMainThread
            onQueue = OperationQueue.current === queue
            handler = receive
        }
        for event in events { receive(event) }
        return starts
    }
    func stop() { lock.withLock { stops += 1 } }
    func emit(_ event: SpotlightQueryEvent) { lock.withLock { handler }?(event) }
}
