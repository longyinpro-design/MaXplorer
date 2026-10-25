import Foundation

extension FileOperationTests {
    static func searchTests() async {
        await test("search match modes are case-insensitive and glob-aware") { _ in
            try expect(SearchMatchMode.contains.matches("Report.PDF", query: "report"), "contains must be case-insensitive")
            try expect(SearchMatchMode.contains.matches("中文报告.txt", query: "报告"), "contains must handle unicode")
            try expect(SearchMatchMode.glob.matches("photo.JPG", query: "*.jpg"), "glob must be case-insensitive")
            try expect(SearchMatchMode.glob.matches("report-01.pdf", query: "report-??.pdf"), "glob ? must match one character")
            try expect(!SearchMatchMode.glob.matches("report-1.pdf", query: "report-??.pdf"), "glob ? must not match zero characters")
            try expect(!SearchMatchMode.glob.matches("photo.jpg", query: "*.png"), "glob must reject non-matches")
        }

        await test("search matcher normalizes composed and decomposed Unicode") { _ in
            for mode in SearchMatchMode.allCases {
                try expect(mode.matches("CAFÉ.txt", query: "cafe\u{301}.txt"), "Unicode normalization failed for \(mode)")
            }
        }

        await test("search glob keeps Unicode character boundaries and native bracket classes") { _ in
            for name in ["ß.txt", "ﬃ.txt", "İ.txt"] {
                try expect(SearchMatchMode.glob.matches(name, query: "?.txt"), "? must match one original Unicode character: \(name)")
                try expect(!SearchMatchMode.glob.matches(name, query: "??.txt"), "case folding expanded the character: \(name)")
            }
            try expect(!SearchMatchMode.glob.matches("ß.txt", query: "ss.txt"), "literal case comparison must not expand ß")
            try expect(!SearchMatchMode.glob.matches("ﬃ.txt", query: "ffi.txt"), "literal case comparison must not expand ﬃ")
            try expect(SearchMatchMode.glob.matches("É.txt", query: "é.txt"), "Unicode case comparison regressed")
            try expect(SearchMatchMode.glob.matches("É.txt", query: "[É].txt"), "Unicode bracket literal failed")
            try expect(SearchMatchMode.glob.matches("é.txt", query: "[É].txt"), "Unicode bracket case comparison failed")

            guard let locale = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil) else {
                throw TestFailure.assertion("UTF-8 locale unavailable")
            }
            defer { freelocale(locale) }
            let previous = uselocale(locale)
            defer { uselocale(previous) }
            for pattern in ["[[:upper:]].txt", "[[:lower:]].txt", "[[:alpha:]].txt", "[A-Z].txt", "[!A-Z].txt"] {
                for name in ["A.txt", "a.txt", "É.txt", "ß.txt", "ﬃ.txt", "İ.txt", "3.txt"] {
                    let expected = pattern.withCString { p in name.withCString { n in fnmatch(p, n, FNM_CASEFOLD) == 0 } }
                    try expect(SearchMatchMode.glob.matches(name, query: pattern) == expected, "native bracket class changed: \(pattern) / \(name)")
                }
            }
            try expect(uselocale(nil) == locale, "glob matching leaked a thread-local locale change")
        }

        await test("recursive search skips and counts unreadable directories") { dir in
            let blocked = dir.appendingPathComponent("blocked", isDirectory: true)
            try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
            _ = try file(blocked, "secret.txt")
            _ = try file(dir, "visible.txt")
            try expect(chmod(blocked.path, 0) == 0, "chmod failed")
            defer { chmod(blocked.path, 0o700) }
            let (items, summary) = try await collectSearch(root: dir, query: "*.txt", mode: .glob, showHiddenFiles: false)
            try expect(items.map(\.name) == ["visible.txt"], "unreadable directory leaked")
            try expect(summary.skippedCount == 1, "unreadable directory must be counted exactly once")
        }

        await test("recursive search cancellation stops metadata scheduling") { dir in
            for index in 0..<1024 { _ = try file(dir, "file-\(index).txt") }
            let probe = SearchMetadataProbe()
            let stream = FileSearchService(fileSystem: probe).search(root: dir, query: "txt", mode: .contains,
                showHiddenFiles: false, options: DirectoryListingOptions())
            let consumer = Task {
                for try await _ in stream { }
            }
            while await probe.startedCount() < 1 { try await Task.sleep(nanoseconds: 1_000_000) }
            let (activeStarted, activeFinished, _, _) = await probe.snapshot()
            try expect(activeStarted > activeFinished, "metadata fixture finished before cancellation")
            let start = DispatchTime.now().uptimeNanoseconds
            consumer.cancel()
            _ = try? await consumer.value
            await probe.waitUntilIdle()
            // Observe quiescence without charging the observation task's wake-up
            // delay to worker cancellation latency on busy CI runners.
            try await Task.sleep(nanoseconds: 20_000_000)
            let (started, finished, onMain, lastFinished) = await probe.snapshot()
            try expect(lastFinished >= start, "metadata worker completed before cancellation; invalid fixture")
            let elapsed = Double(lastFinished - start) / 1_000_000
            print("SEARCH_CANCELLATION worker_stop_ms=\(elapsed) started=\(started) finished=\(finished)")
            try expect(started == finished, "cancelled metadata workers are still active")
            try expect(started <= 6, "cancellation scheduled extra metadata work: \(started)")
            try expect(!onMain, "metadata work ran on the main thread")
            try expect(elapsed < 200, "cancellation exceeded 200ms: \(elapsed)")
        }

        await test("search display pipeline keeps Unicode natural order and alias filter") { dir in
            for name in ["中文10.txt", "中文2.txt", "CAFÉ.txt"] { _ = try file(dir, name) }
            let items = try await LocalFileSystemService().listDirectory(at: dir, showHiddenFiles: false, options: DirectoryListingOptions())
            let sorted = FileDisplayPipeline.displayedItems(from: items, descriptor: .fallback, query: "中文", showAliases: true)
            try expect(sorted.map(\.name) == ["中文2.txt", "中文10.txt"], "natural numeric ordering failed")
            let normalized = FileDisplayPipeline.displayedItems(from: items, descriptor: .fallback, query: "cafe\u{301}", showAliases: false)
            try expect(normalized.count == 1, "display query Unicode normalization failed")
        }

        if ProcessInfo.processInfo.environment["MAXPLORER_SEARCH_PERFORMANCE"] == "1" {
            await test("search display pipeline 10k real entries filter responsiveness") { dir in
                for index in 0..<10_000 {
                    let descriptor = open(dir.appendingPathComponent("报告-\(index).txt").path, O_CREAT | O_WRONLY, 0o600)
                    try expect(descriptor >= 0, "fixture creation failed")
                    close(descriptor)
                }
                let items = try await LocalFileSystemService().listDirectory(at: dir, showHiddenFiles: false, options: DirectoryListingOptions())
                var maximumMS = 0.0
                for query in ["报告-999", "报告", "unmatched"] {
                    let start = DispatchTime.now().uptimeNanoseconds
                    let descriptor = FileSortDescriptor.fallback
                    let result = await Task.detached {
                        FileDisplayPipeline.displayedItems(from: items, descriptor: descriptor, query: query, showAliases: true)
                    }.value
                    let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    maximumMS = max(maximumMS, elapsedMS)
                    print("FILTER_BENCHMARK entries=10000 query=\(query) result_count=\(result.count) elapsed_ms=\(elapsedMS)")
                }
                try expect(maximumMS < 100, "filter compute left insufficient room for 50ms debounce: \(maximumMS)ms")
            }

            await test("recursive search 100k real entries first result and progress") { dir in
                for index in 0..<100_000 {
                    let url = dir.appendingPathComponent("entry-\(index).txt")
                    let descriptor = open(url.path, O_CREAT | O_WRONLY, 0o600)
                    try expect(descriptor >= 0, "fixture creation failed")
                    close(descriptor)
                }
                let start = DispatchTime.now().uptimeNanoseconds
                let heartbeat = Task { @MainActor in
                    var maximumGapMS = 0.0
                    while !Task.isCancelled {
                        let before = DispatchTime.now().uptimeNanoseconds
                        try? await Task.sleep(nanoseconds: 20_000_000)
                        maximumGapMS = max(maximumGapMS, Double(DispatchTime.now().uptimeNanoseconds - before) / 1_000_000)
                    }
                    return maximumGapMS
                }
                var firstResultMS: Double?
                var progressCount = 0
                var itemCount = 0
                var scannedCount = 0
                let stream = FileSearchService(fileSystem: LocalFileSystemService()).search(root: dir,
                    query: "*.txt", mode: .glob, showHiddenFiles: false, options: DirectoryListingOptions())
                for try await event in stream {
                    switch event {
                    case .batch(let batch):
                        if firstResultMS == nil { firstResultMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
                        itemCount += batch.count
                    case .progress: progressCount += 1
                    case .finished(let summary): scannedCount = summary.scannedCount
                    }
                }
                heartbeat.cancel()
                let maximumGapMS = await heartbeat.value
                let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                print("SEARCH_MAIN_ACTOR maximum_gap_ms=\(maximumGapMS)")
                try expect(maximumGapMS < 200, "MainActor heartbeat stalled during scan")
                print("SEARCH_BENCHMARK entries=100000 first_result_ms=\(firstResultMS ?? -1) total_ms=\(elapsedMS) progress_events=\(progressCount)")
                try expect((firstResultMS ?? .infinity) < 1000, "first result exceeded 1s")
                try expect(itemCount == 100_000 && scannedCount == 100_000, "100k scan was incomplete")
                try expect(progressCount > 1, "100k scan must publish intermediate progress")
            }
        }

        await test("recursive search returns nested files") { dir in
            let root = dir.appendingPathComponent("root", isDirectory: true)
            let nested = root.appendingPathComponent("a/b", isDirectory: true)
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            _ = try file(root, "top.txt")
            _ = try file(nested, "deep.txt")

            let (items, summary) = try await collectSearch(
                root: root,
                query: "*.txt",
                mode: .glob,
                showHiddenFiles: false
            )
            let names = Set(items.map(\.name))
            try expect(names == ["top.txt", "deep.txt"], "unexpected search results: \(names)")
            try expect(summary.scannedCount >= 3, "scan count should include directories")
        }

        await test("recursive search respects hidden files and package boundaries") { dir in
            let root = dir.appendingPathComponent("root", isDirectory: true)
            let package = root.appendingPathComponent("Sample.app", isDirectory: true)
            try fm.createDirectory(at: package, withIntermediateDirectories: true)
            _ = try file(root, "visible.txt")
            _ = try file(root, ".hidden.txt")
            _ = try file(package, "inside.txt")

            let (visibleItems, _) = try await collectSearch(
                root: root,
                query: "*.txt",
                mode: .glob,
                showHiddenFiles: false
            )
            let visibleNames = Set(visibleItems.map(\.name))
            try expect(visibleNames == ["visible.txt"], "hidden/package contents leaked: \(visibleNames)")

            let (allItems, _) = try await collectSearch(
                root: root,
                query: "*.txt",
                mode: .glob,
                showHiddenFiles: true
            )
            let allNames = Set(allItems.map(\.name))
            try expect(allNames == ["visible.txt", ".hidden.txt"], "hidden toggle failed: \(allNames)")

            let (packageItems, _) = try await collectSearch(
                root: root,
                query: "Sample.app",
                mode: .glob,
                showHiddenFiles: false
            )
            try expect(packageItems.map(\.name) == ["Sample.app"], "package itself must be searchable")
        }

        await test("recursive search does not follow symbolic link loops") { dir in
            let root = dir.appendingPathComponent("root", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try file(root, "real.txt")
            try fm.createSymbolicLink(
                at: root.appendingPathComponent("loop"),
                withDestinationURL: root
            )

            let (items, _) = try await collectSearch(
                root: root,
                query: "*.txt",
                mode: .glob,
                showHiddenFiles: false
            )
            try expect(items.map(\.name) == ["real.txt"], "symlink loop was followed or duplicated")
        }

        await test("recursive search missing root reports an error") { dir in
            try await mustFail {
                _ = try await collectSearch(root: dir.appendingPathComponent("missing"), query: "txt", mode: .contains, showHiddenFiles: false)
            }
        }

        await test("empty search query finishes without scanning") { dir in
            let root = dir.appendingPathComponent("root", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try file(root, "file.txt")

            let (items, summary) = try await collectSearch(
                root: root,
                query: "   ",
                mode: .contains,
                showHiddenFiles: false
            )
            try expect(items.isEmpty, "empty query must not return results")
            try expect(summary.scannedCount == 0, "empty query must not scan")
        }
    }

    static func collectSearch(
        root: URL,
        query: String,
        mode: SearchMatchMode,
        showHiddenFiles: Bool
    ) async throws -> ([FileItem], SearchSummary) {
        var items: [FileItem] = []
        var summary = SearchSummary(scannedCount: 0, skippedCount: 0)
        let service = FileSearchService(fileSystem: LocalFileSystemService())
        let stream = service.search(
            root: root,
            query: query,
            mode: mode,
            showHiddenFiles: showHiddenFiles,
            options: DirectoryListingOptions()
        )
        for try await event in stream {
            switch event {
            case .batch(let batch):
                items.append(contentsOf: batch)
            case .progress:
                break
            case .finished(let value):
                summary = value
            }
        }
        return (items, summary)
    }
}

// Delays only metadata resolution, after real filesystem traversal has matched URLs.
// Its counters prove worker cancellation, rather than merely cancelling the consumer.
private actor SearchMetadataProbe: FileSystemService {
    var started = 0
    var finished = 0
    var onMain = false
    var lastFinished: UInt64 = 0
    private var idleWaiter: CheckedContinuation<Void, Never>?
    func startedCount() -> Int { started }
    func snapshot() -> (Int, Int, Bool, UInt64) { (started, finished, onMain, lastFinished) }
    func waitUntilIdle() async {
        guard started != finished else { return }
        await withCheckedContinuation { idleWaiter = $0 }
    }
    func fileItem(at url: URL, options: DirectoryListingOptions) async throws -> FileItem {
        started += 1
        onMain = onMain || Thread.isMainThread
        defer {
            finished += 1
            lastFinished = DispatchTime.now().uptimeNanoseconds
            if started == finished {
                let waiter = idleWaiter
                idleWaiter = nil
                waiter?.resume()
            }
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return try await LocalFileSystemService().fileItem(at: url, options: options)
    }
    func listDirectory(at url: URL, showHiddenFiles: Bool, options: DirectoryListingOptions,
        onPartial: (@Sendable ([FileItem]) async -> Void)?) async throws -> [FileItem] { throw CancellationError() }
    func createFolder(named name: String, in directory: URL) async throws -> URL { throw CancellationError() }
    func renameItem(at url: URL, to newName: String) async throws -> URL { throw CancellationError() }
    func moveItems(_ resolvedItems: [(source: URL, shouldOverwrite: Bool)], to directory: URL) async throws -> [URL] { throw CancellationError() }
    func moveToTrash(_ url: URL) async throws { throw CancellationError() }
    func deletePermanently(_ url: URL) async throws { throw CancellationError() }
    func quickViewContent(for url: URL) async throws -> QuickViewContent { throw CancellationError() }
}
