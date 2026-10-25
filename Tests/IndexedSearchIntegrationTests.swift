import Foundation
import Darwin

extension FileOperationTests {
    static func indexedSearchIntegrationTests() async {
        func collect(_ stream: AsyncThrowingStream<SearchEvent, Error>) async throws -> ([FileItem], SearchSummary?) {
            var items: [FileItem] = []
            var summary: SearchSummary?
            for try await event in stream {
                switch event {
                case .batch(let batch): items += batch
                case .finished(let result): summary = result
                case .progress: break
                }
            }
            return (items, summary)
        }
        func service(_ urls: [URL]) -> FileSearchService {
            FileSearchService(fileSystem: LocalFileSystemService(), indexedCandidates: { _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(urls)
                    continuation.finish()
                }
            })
        }
        await test("search conditions alone scan without invoking index") { dir in
            _ = try file(dir, "small.txt", "abc")
            _ = try file(dir, "large.txt", "abcdef")
            _ = try file(dir, "large.log", "abcdef")
            var filters = SearchFilters()
            filters.extensions = ["TXT"]
            filters.minimumSize = 4
            let search = FileSearchService(fileSystem: LocalFileSystemService(), indexedCandidates: { _, _ in
                preconditionFailure("metadata-only search invoked index")
            })
            let (items, summary) = try await collect(search.search(root: dir, query: "", mode: .contains,
                showHiddenFiles: false, options: DirectoryListingOptions(), filters: filters))
            try expect(items.map(\.name) == ["large.txt"], "filter-only AND search failed")
            try expect(summary?.scannedCount == 3, "scan count changed")
        }
        await test("indexed search rejects stale outside hidden package and linked descendants") { dir in
            let scope = dir.appendingPathComponent("scope", isDirectory: true)
            let hidden = scope.appendingPathComponent(".hidden", isDirectory: true)
            let package = scope.appendingPathComponent("Fixture.app", isDirectory: true)
            let outside = dir.appendingPathComponent("scope-other", isDirectory: true)
            for folder in [scope, hidden, package, outside] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            let good = try file(scope, "report.txt", "abc")
            let otherName = try file(scope, "other.txt", "abc")
            let otherExtension = try file(scope, "report.log", "abc")
            let hiddenFile = try file(hidden, "report.txt")
            let packageFile = try file(package, "report.txt")
            let outsideFile = try file(outside, "report.txt")
            let link = scope.appendingPathComponent("link")
            try fm.createSymbolicLink(at: link, withDestinationURL: outside)
            let privateFile = try file(scope, "report-private.txt")
            chmod(privateFile.path, 0)
            defer { chmod(privateFile.path, 0o600) }
            var candidates = [good, good, otherName, otherExtension, hiddenFile, packageFile, outsideFile,
                              link.appendingPathComponent("report.txt"), scope.appendingPathComponent("missing.txt"), scope]
            if geteuid() != 0 { candidates.append(privateFile) }
            var filters = SearchFilters()
            filters.extensions = ["txt"]
            let (items, summary) = try await collect(service(candidates).search(root: scope, query: "report", mode: .contains,
                showHiddenFiles: false, options: DirectoryListingOptions(), filters: filters, contentQuery: "needle"))
            try expect(items.map(\.url) == [good], "index leaked excluded or duplicate path")
            try expect((summary?.skippedCount ?? 0) >= 6, "excluded paths not counted")
        }
        await test("indexed search hidden preference keeps package and symlink boundaries") { dir in
            let hidden = dir.appendingPathComponent(".hidden", isDirectory: true)
            let package = dir.appendingPathComponent("Fixture.app", isDirectory: true)
            for folder in [hidden, package] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            let good = try file(hidden, "match.txt")
            let internalFile = try file(package, "match.txt")
            let link = dir.appendingPathComponent("link")
            try fm.createSymbolicLink(at: link, withDestinationURL: hidden)
            let (items, _) = try await collect(service([good, internalFile, link.appendingPathComponent("match.txt")]).search(
                root: dir, query: "", mode: .contains, showHiddenFiles: true,
                options: DirectoryListingOptions(), contentQuery: "needle"))
            try expect(items.map(\.url) == [good], "hidden preference opened package or linked descendants")
        }
        await test("indexed search uses canonical explicit root and does not query empty criteria") { dir in
            let actual = dir.appendingPathComponent("actual", isDirectory: true)
            try fm.createDirectory(at: actual, withIntermediateDirectories: true)
            let alias = dir.appendingPathComponent("root-link")
            try fm.createSymbolicLink(at: alias, withDestinationURL: actual)
            let file = try file(actual, "match.txt")
            let search = FileSearchService(fileSystem: LocalFileSystemService(), indexedCandidates: { root, query in
                AsyncThrowingStream { continuation in
                    if root.path != actual.path || query != "needle" || Thread.isMainThread {
                        continuation.finish(throwing: TestFailure.assertion("wrong scope/query or main-thread index startup"))
                    } else {
                        continuation.yield([file]); continuation.finish()
                    }
                }
            })
            let (items, _) = try await collect(search.search(root: alias, query: "", mode: .contains,
                showHiddenFiles: false, options: DirectoryListingOptions(), contentQuery: " needle "))
            try expect(items.map(\.url) == [file], "explicit symlink scope did not resolve once")
            let (empty, summary) = try await collect(search.search(root: alias, query: " ", mode: .contains,
                showHiddenFiles: false, options: DirectoryListingOptions()))
            try expect(empty.isEmpty && summary?.scannedCount == 0, "empty criteria performed a scan")
        }
        await test("indexed search reports partial error without replacing delivered results") { dir in
            let good = try file(dir, "match.txt")
            let search = FileSearchService(fileSystem: LocalFileSystemService(), indexedCandidates: { _, _ in
                AsyncThrowingStream { continuation in
                    continuation.yield([good])
                    continuation.finish(throwing: SpotlightSearchError.timedOut)
                }
            })
            var received: [FileItem] = []
            do {
                for try await event in search.search(root: dir, query: "", mode: .contains,
                    showHiddenFiles: false, options: DirectoryListingOptions(), contentQuery: "needle") {
                    if case .batch(let batch) = event { received += batch }
                }
                throw TestFailure.assertion("partial index failure was swallowed")
            } catch SpotlightSearchError.timedOut { }
            try expect(received.map(\.url) == [good], "delivered result was discarded")
        }
        await test("invalid search filters fail before any index request") { dir in
            var filters = SearchFilters()
            filters.minimumSize = -1
            let search = FileSearchService(fileSystem: LocalFileSystemService(), indexedCandidates: { _, _ in
                preconditionFailure("invalid filter reached index")
            })
            try await mustFail {
                _ = try await collect(search.search(root: dir, query: "", mode: .contains,
                    showHiddenFiles: false, options: DirectoryListingOptions(), filters: filters, contentQuery: "needle"))
            }
        }
    }
}
