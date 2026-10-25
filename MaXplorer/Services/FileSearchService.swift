import Foundation

nonisolated struct FileSearchService {
    typealias IndexedCandidates = @Sendable (URL, String) -> AsyncThrowingStream<[URL], Error>
    let fileSystem: any FileSystemService
    let indexedCandidates: IndexedCandidates

    init(fileSystem: any FileSystemService,
         indexedCandidates: @escaping IndexedCandidates = { SpotlightSearchService().search(root: $0, contentQuery: $1) }) {
        self.fileSystem = fileSystem
        self.indexedCandidates = indexedCandidates
    }

    func search(
        root: URL,
        query: String,
        mode: SearchMatchMode,
        showHiddenFiles: Bool,
        options: DirectoryListingOptions,
        filters: SearchFilters = SearchFilters(),
        contentQuery: String = ""
    ) -> AsyncThrowingStream<SearchEvent, Error> {
        let root = root.standardizedFileURL
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileSystem = self.fileSystem
        let indexedCandidates = self.indexedCandidates
        let contentQuery = contentQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        return AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                guard !query.isEmpty || !contentQuery.isEmpty || filters.isActive else {
                    continuation.yield(.finished(SearchSummary(scannedCount: 0, skippedCount: 0)))
                    continuation.finish()
                    return
                }

                do {
                    try filters.validate()
                    try Task.checkCancellation()
                    let root = try Self.validatedRoot(root)
                    let summary: SearchSummary
                    if contentQuery.isEmpty {
                        summary = try await Self.run(
                            root: root, query: query, mode: mode,
                            showHiddenFiles: showHiddenFiles, options: options,
                            filters: filters, fileSystem: fileSystem, continuation: continuation
                        )
                    } else {
                        summary = try await Self.runIndexed(
                            root: root, query: query, contentQuery: contentQuery, mode: mode,
                            showHiddenFiles: showHiddenFiles, options: options,
                            filters: filters, fileSystem: fileSystem,
                            indexedCandidates: indexedCandidates, continuation: continuation
                        )
                    }
                    continuation.yield(.finished(summary))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                worker.cancel()
            }
        }
    }

    private static func run(
        root: URL,
        query: String,
        mode: SearchMatchMode,
        showHiddenFiles: Bool,
        options: DirectoryListingOptions,
        filters: SearchFilters,
        fileSystem: any FileSystemService,
        continuation: AsyncThrowingStream<SearchEvent, Error>.Continuation
    ) async throws -> SearchSummary {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .isHiddenKey
        ]
        var enumerationOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showHiddenFiles {
            enumerationOptions.insert(.skipsHiddenFiles)
        }

        var skippedCount = 0
        let errorHandler: (URL, Error) -> Bool = { _, _ in
            skippedCount += 1
            return true
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: enumerationOptions,
            errorHandler: errorHandler
        ) else {
            throw SearchError.unreadableRoot(root)
        }

        var scannedCount = 0
        var pendingURLs: [URL] = []
        pendingURLs.reserveCapacity(128)
        var lastProgress = DispatchTime.now().uptimeNanoseconds
        var lastBatch = lastProgress
        var hasPublishedResults = false

        func flush() async throws {
            guard !pendingURLs.isEmpty else { return }
            try Task.checkCancellation()
            let urls = pendingURLs
            pendingURLs.removeAll(keepingCapacity: true)
            let (items, failedCount) = try await buildItems(urls: urls, fileSystem: fileSystem, options: options)
            skippedCount += failedCount
            try Task.checkCancellation()
            let matches = filters.isActive ? items.filter(filters.matches) : items
            guard !matches.isEmpty else { return }
            hasPublishedResults = true
            continuation.yield(.batch(matches))
            lastBatch = DispatchTime.now().uptimeNanoseconds
        }

        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            scannedCount += 1

            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true, values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }

            if values?.isPackage == true {
                if query.isEmpty || mode.matches(url.lastPathComponent, query: query) {
                    pendingURLs.append(url)
                }
                enumerator.skipDescendants()
            } else if query.isEmpty || mode.matches(url.lastPathComponent, query: query) {
                pendingURLs.append(url)
            }

            let now = DispatchTime.now().uptimeNanoseconds
            if (!hasPublishedResults && !pendingURLs.isEmpty)
                || pendingURLs.count >= 512
                || (!pendingURLs.isEmpty && now &- lastBatch >= 150_000_000) {
                try await flush()
            }
            if now &- lastProgress >= 150_000_000 {
                continuation.yield(.progress(SearchProgress(
                    scannedCount: scannedCount,
                    skippedCount: skippedCount
                )))
                lastProgress = now
            }
        }

        try await flush()
        continuation.yield(.progress(SearchProgress(
            scannedCount: scannedCount,
            skippedCount: skippedCount
        )))
        return SearchSummary(scannedCount: scannedCount, skippedCount: skippedCount)
    }

    /// Canonicalize the explicit scope once, off-main. Returned candidates must
    /// stay lexically below this root; symlink ancestors below it are never followed.
    private static func validatedRoot(_ root: URL) throws -> URL {
        guard root.isFileURL, root.host == nil || root.host == "" || root.host == "localhost",
              !root.path.contains("\0") else { throw SearchError.unreadableRoot(root) }
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let values = try resolved.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true, FileManager.default.isReadableFile(atPath: resolved.path) else {
            throw SearchError.unreadableRoot(root)
        }
        return resolved
    }

    private static func runIndexed(
        root: URL, query: String, contentQuery: String, mode: SearchMatchMode,
        showHiddenFiles: Bool, options: DirectoryListingOptions, filters: SearchFilters,
        fileSystem: any FileSystemService, indexedCandidates: IndexedCandidates,
        continuation: AsyncThrowingStream<SearchEvent, Error>.Continuation
    ) async throws -> SearchSummary {
        var scanned = 0
        var skipped = 0
        var seen = Set<URL>()
        for try await candidates in indexedCandidates(root, contentQuery) {
            try Task.checkCancellation()
            var accepted: [URL] = []
            for candidate in candidates {
                try Task.checkCancellation()
                let url = candidate.standardizedFileURL
                guard seen.insert(url).inserted else { continue }
                scanned += 1
                guard try indexedCandidateIsVisible(url, root: root, showHiddenFiles: showHiddenFiles) else {
                    skipped += 1
                    continue
                }
                if query.isEmpty || mode.matches(url.lastPathComponent, query: query) { accepted.append(url) }
            }
            let (items, failures) = try await buildItems(urls: accepted, fileSystem: fileSystem, options: options)
            skipped += failures
            try Task.checkCancellation()
            let matches = filters.isActive ? items.filter(filters.matches) : items
            if !matches.isEmpty { continuation.yield(.batch(matches)) }
            continuation.yield(.progress(SearchProgress(scannedCount: scanned, skippedCount: skipped)))
        }
        return SearchSummary(scannedCount: scanned, skippedCount: skipped)
    }

    private static func indexedCandidateIsVisible(_ url: URL, root: URL, showHiddenFiles: Bool) throws -> Bool {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.contains("\0") else { return false }
        let rootParts = root.pathComponents
        let parts = url.pathComponents
        guard parts.count > rootParts.count, parts.starts(with: rootParts) else { return false }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey]
        var ancestor = root
        for (index, component) in parts.dropFirst(rootParts.count).enumerated() {
            try Task.checkCancellation()
            ancestor.appendPathComponent(component, isDirectory: false)
            guard let values = try? ancestor.resourceValues(forKeys: keys),
                  FileManager.default.isReadableFile(atPath: ancestor.path) else { return false }
            let isLeaf = index == parts.count - rootParts.count - 1
            if !showHiddenFiles && (component.hasPrefix(".") || values.isHidden == true) { return false }
            if !isLeaf {
                guard values.isDirectory == true, values.isSymbolicLink != true,
                      values.isAliasFile != true, values.isPackage != true else { return false }
            } else if values.isDirectory == true && values.isSymbolicLink == true {
                return false
            }
        }
        return true
    }

    private static func buildItems(
        urls: [URL],
        fileSystem: any FileSystemService,
        options: DirectoryListingOptions
    ) async throws -> ([FileItem], Int) {
        var items: [FileItem] = []
        items.reserveCapacity(urls.count)

        var failedCount = 0
        try await withThrowingTaskGroup(of: FileItem?.self) { group in
            var iterator = urls.makeIterator()
            let maximumConcurrency = 6
            for _ in 0..<min(maximumConcurrency, urls.count) {
                guard let url = iterator.next() else { break }
                group.addTask { try await readItem(url, fileSystem: fileSystem, options: options) }
            }

            for try await item in group {
                try Task.checkCancellation()
                if let item {
                    items.append(item)
                } else {
                    failedCount += 1
                }
                if let url = iterator.next() {
                    group.addTask { try await readItem(url, fileSystem: fileSystem, options: options) }
                }
            }
        }

        return (items, failedCount)
    }

    private static func readItem(
        _ url: URL, fileSystem: any FileSystemService, options: DirectoryListingOptions
    ) async throws -> FileItem? {
        try Task.checkCancellation()
        do {
            return try await fileSystem.fileItem(at: url, options: options)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }
}

nonisolated enum SearchError: LocalizedError {
    case unreadableRoot(URL)

    var errorDescription: String? {
        switch self {
        case .unreadableRoot(let url):
            return "无法读取搜索位置：\(url.path)"
        }
    }
}
