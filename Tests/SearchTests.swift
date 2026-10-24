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
