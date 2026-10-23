import Foundation

// `nonisolated` is essential: this project uses MainActor-default isolation, so
// without it these methods would be @MainActor and run on the main thread even
// inside Task.detached — freezing the UI during a scan.
nonisolated enum SpaceScanner {
    private static let resourceKeys: Set<URLResourceKey> = [
        .fileSizeKey, .isDirectoryKey, .isPackageKey,
        .isSymbolicLinkKey, .isAliasFileKey
    ]

    static func scan(url: URL, progressHandler: @escaping @Sendable (Int) async -> Void) async throws -> SpaceNode {
        let gate = ScanGate(limit: max(2, min(6, ProcessInfo.processInfo.activeProcessorCount)))
        let progress = ScanProgress(handler: progressHandler)
        // Task.detached is unstructured, so cancellation of the caller does not
        // automatically propagate. withTaskCancellationHandler bridges the gap.
        let detached = Task.detached(priority: .utility) {
            try await scanDirectory(url: url, gate: gate, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await detached.value
        } onCancel: {
            detached.cancel()
        }
    }

    /// Directory scans run concurrently up to the gate limit. Sibling tasks are
    /// also chunked so a directory with thousands of subfolders does not create
    /// a task per child at once.
    private static func scanDirectory(url: URL, gate: ScanGate, progress: ScanProgress) async throws -> SpaceNode {
        try Task.checkCancellation()
        let listing = try await gate.withSlot {
            try listDirectory(url: url)
        }
        try Task.checkCancellation()
        await progress.add(listing.itemCount)

        var children = listing.files
        var total = listing.fileBytes
        let chunkSize = gate.limit

        for start in stride(from: 0, to: listing.subdirectories.count, by: chunkSize) {
            let end = min(start + chunkSize, listing.subdirectories.count)
            let chunk = listing.subdirectories[start..<end]
            try await withThrowingTaskGroup(of: SpaceNode.self) { group in
                for subdirectoryURL in chunk {
                    group.addTask {
                        try await scanDirectory(url: subdirectoryURL, gate: gate, progress: progress)
                    }
                }

                for try await child in group {
                    children.append(child)
                    total += child.size
                }
            }
        }

        children.sort { $0.size > $1.size }
        return SpaceNode(url: url, name: url.lastPathComponent, size: total, isDirectory: true, children: children)
    }

    private struct DirectoryListing: Sendable {
        let files: [SpaceNode]
        let subdirectories: [URL]
        let fileBytes: UInt64
        let itemCount: Int
    }

    private static func listDirectory(url: URL) throws -> DirectoryListing {
        try Task.checkCancellation()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )) ?? []

        var files: [SpaceNode] = []
        var subdirectories: [URL] = []
        var fileBytes: UInt64 = 0

        for childURL in contents {
            try Task.checkCancellation()
            let res = try? childURL.resourceValues(forKeys: resourceKeys)

            // Skip symlinks and Finder aliases so only physical items under the
            // selected path are measured — avoids double-counting and following
            // links out of the scanned subtree.
            if res?.isSymbolicLink == true || res?.isAliasFile == true {
                continue
            }

            if res?.isDirectory == true && res?.isPackage != true {
                subdirectories.append(childURL)
            } else {
                let size = UInt64(max(0, res?.fileSize ?? 0))
                files.append(SpaceNode(
                    url: childURL,
                    name: childURL.lastPathComponent,
                    size: size,
                    isDirectory: false
                ))
                fileBytes += size
            }
        }

        return DirectoryListing(
            files: files,
            subdirectories: subdirectories,
            fileBytes: fileBytes,
            itemCount: files.count + subdirectories.count
        )
    }
}

/// Limits concurrent directory scans globally. A slot is held only for the
/// listing and metadata phase, never while recursing into children, so a parent
/// waiting on child directories cannot deadlock the gate.
private actor ScanGate {
    nonisolated let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func withSlot<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        if active < limit {
            active += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Serializes progress delivery so a slower update cannot overwrite a newer
/// count, which the previous fire-and-forget tasks allowed.
private actor ScanProgress {
    private let handler: @Sendable (Int) async -> Void
    private var count = 0
    private var reported = 0
    private let step = 300

    init(handler: @escaping @Sendable (Int) async -> Void) {
        self.handler = handler
    }

    func add(_ amount: Int) async {
        guard amount > 0 else { return }
        count += amount
        guard count - reported >= step else { return }
        reported = count
        await handler(count)
    }
}
