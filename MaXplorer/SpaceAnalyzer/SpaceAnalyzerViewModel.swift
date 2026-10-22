import Combine
import Foundation

enum SpaceAnalyzerMode: String, CaseIterable, Identifiable {
    case allFiles
    case drillDown

    var id: Self { self }

    var displayName: String {
        switch self {
        case .allFiles: "全部文件模式"
        case .drillDown: "逐层浏览模式"
        }
    }
}

@MainActor
final class SpaceAnalyzerViewModel: ObservableObject {
    enum ScanState {
        case idle
        case scanning(scannedCount: Int)
        case ready(root: SpaceNode)
        case failed(String)
    }

    @Published private(set) var scanState: ScanState = .idle
    @Published var rootPath: String
    let categories = FileCategoryService()
    private var scanTask: Task<Void, Never>?

    init(rootURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        rootPath = rootURL.path(percentEncoded: false)
    }

    var isScanning: Bool {
        if case .scanning = scanState { return true }
        return false
    }

    func startScan(url: URL) {
        rootPath = url.path(percentEncoded: false)
        beginScan()
    }

    func refresh() {
        beginScan()
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanState = .idle
    }

    var volumeStats: VolumeCapacityStats? {
        VolumeCapacityReader.stats(for: URL(fileURLWithPath: rootPath))
    }

    private func beginScan() {
        scanTask?.cancel()
        let url = URL(fileURLWithPath: rootPath)
        scanState = .scanning(scannedCount: 0)
        scanTask = Task {
            do {
                // The enclosing Task already holds self strongly until the scan
                // finishes, so a weak capture here would buy nothing.
                let root = try await SpaceScanner.scan(url: url) { count in
                    await self.updateScanProgress(count)
                }
                if !Task.isCancelled {
                    scanState = .ready(root: root)
                    scanTask = nil
                }
            } catch is CancellationError {
                scanState = .idle
                scanTask = nil
            } catch {
                scanState = .failed(error.localizedDescription)
                scanTask = nil
            }
        }
    }

    private func updateScanProgress(_ count: Int) {
        if case .scanning = scanState {
            scanState = .scanning(scannedCount: count)
        }
    }
}

// MARK: – Background scanner

// `nonisolated` is essential: this project uses MainActor-default isolation, so
// without it these methods would be @MainActor and run on the main thread even
// inside Task.detached — freezing the UI during a scan.
nonisolated enum SpaceScanner {
    static func scan(url: URL, progressHandler: @escaping @Sendable (Int) async -> Void) async throws -> SpaceNode {
        // Task.detached is unstructured, so cancellation of the caller does not
        // automatically propagate. withTaskCancellationHandler bridges the gap.
        let detached = Task.detached(priority: .utility) {
            var count = 0
            return try scanSync(url: url, count: &count, progressHandler: progressHandler)
        }
        return try await withTaskCancellationHandler {
            try await detached.value
        } onCancel: {
            detached.cancel()
        }
    }

    private static func scanSync(
        url: URL,
        count: inout Int,
        progressHandler: @escaping @Sendable (Int) async -> Void
    ) throws -> SpaceNode {
        try Task.checkCancellation()
        let fm = FileManager.default
        let resKeys: Set<URLResourceKey> = [
            .fileSizeKey, .isDirectoryKey, .isPackageKey,
            .isSymbolicLinkKey, .isAliasFileKey
        ]
        var children: [SpaceNode] = []
        var total: UInt64 = 0

        let contents = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(resKeys),
            options: [.skipsHiddenFiles]
        )) ?? []

        for childURL in contents {
            try Task.checkCancellation()
            let res = try? childURL.resourceValues(forKeys: resKeys)

            // Skip symlinks and Finder aliases so only physical items under the
            // selected path are measured — avoids double-counting and following
            // links out of the scanned subtree.
            if res?.isSymbolicLink == true || res?.isAliasFile == true {
                continue
            }

            let isDir = res?.isDirectory ?? false
            let isPkg = res?.isPackage ?? false

            if isDir && !isPkg {
                let child = try scanSync(url: childURL, count: &count, progressHandler: progressHandler)
                children.append(child)
                total += child.size
            } else {
                let size = UInt64(max(0, res?.fileSize ?? 0))
                children.append(SpaceNode(url: childURL, name: childURL.lastPathComponent, size: size, isDirectory: false))
                total += size
            }

            count += 1
            if count % 300 == 0 {
                let c = count
                Task { await progressHandler(c) }
            }
        }

        children.sort { $0.size > $1.size }
        return SpaceNode(url: url, name: url.lastPathComponent, size: total, isDirectory: true, children: children)
    }
}
