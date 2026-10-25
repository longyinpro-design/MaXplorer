import Foundation

nonisolated struct FileSearchService {
    let fileSystem: any FileSystemService

    func search(
        root: URL,
        query: String,
        mode: SearchMatchMode,
        showHiddenFiles: Bool,
        options: DirectoryListingOptions
    ) -> AsyncThrowingStream<SearchEvent, Error> {
        let root = root.standardizedFileURL
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileSystem = self.fileSystem

        return AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                guard !query.isEmpty else {
                    continuation.yield(.finished(SearchSummary(scannedCount: 0, skippedCount: 0)))
                    continuation.finish()
                    return
                }

                do {
                    let summary = try await Self.run(
                        root: root,
                        query: query,
                        mode: mode,
                        showHiddenFiles: showHiddenFiles,
                        options: options,
                        fileSystem: fileSystem,
                        continuation: continuation
                    )
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
        fileSystem: any FileSystemService,
        continuation: AsyncThrowingStream<SearchEvent, Error>.Continuation
    ) async throws -> SearchSummary {
        guard let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey]),
            rootValues.isDirectory == true,
            FileManager.default.isReadableFile(atPath: root.path) else {
            throw SearchError.unreadableRoot(root)
        }

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
            guard !items.isEmpty else { return }
            hasPublishedResults = true
            continuation.yield(.batch(items))
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
                if mode.matches(url.lastPathComponent, query: query) {
                    pendingURLs.append(url)
                }
                enumerator.skipDescendants()
            } else if mode.matches(url.lastPathComponent, query: query) {
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
