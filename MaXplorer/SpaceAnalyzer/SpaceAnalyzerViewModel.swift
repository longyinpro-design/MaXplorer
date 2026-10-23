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
    @Published private(set) var volumeStats: VolumeCapacityStats?
    @Published var rootPath: String
    let categories = FileCategoryService()
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0
    private var volumeStatsTask: Task<Void, Never>?

    init(rootURL: URL = FileManager.default.homeDirectoryForCurrentUser) {
        rootPath = rootURL.path(percentEncoded: false)
        refreshVolumeStats()
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
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        scanState = .idle
    }

    private func beginScan() {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        let url = URL(fileURLWithPath: rootPath)
        refreshVolumeStats()
        scanState = .scanning(scannedCount: 0)
        scanTask = Task {
            do {
                // The enclosing Task already holds self strongly until the scan
                // finishes, so a weak capture here would buy nothing.
                let root = try await SpaceScanner.scan(url: url) { count in
                    await self.updateScanProgress(count, generation: generation)
                }
                if !Task.isCancelled, generation == scanGeneration {
                    scanState = .ready(root: root)
                    scanTask = nil
                    refreshVolumeStats()
                }
            } catch is CancellationError {
                guard generation == scanGeneration else { return }
                scanState = .idle
                scanTask = nil
            } catch {
                guard generation == scanGeneration else { return }
                scanState = .failed(error.localizedDescription)
                scanTask = nil
            }
        }
    }

    private func refreshVolumeStats() {
        let path = rootPath
        volumeStatsTask?.cancel()
        volumeStatsTask = Task { [weak self] in
            let stats = await Task.detached(priority: .utility) {
                VolumeCapacityReader.stats(for: URL(fileURLWithPath: path))
            }.value
            guard !Task.isCancelled, let self, self.rootPath == path else { return }
            self.volumeStats = stats
        }
    }

    private func updateScanProgress(_ count: Int, generation: Int) {
        guard generation == scanGeneration else { return }
        if case .scanning = scanState {
            scanState = .scanning(scannedCount: count)
        }
    }
}
