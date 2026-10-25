import Foundation
import Combine

@MainActor
final class ArchiveBrowserModel: ObservableObject {
    typealias Loader = @Sendable (URL) async throws -> ArchiveCatalog
    @Published private(set) var catalog: ArchiveCatalog?
    @Published private(set) var visibleEntries: [ArchiveCatalogEntry] = []
    @Published private(set) var currentPath = ""
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var selectedIDs: Set<String> = []
    let archiveURL: URL
    private let loader: Loader
    private var children: [String: [ArchiveCatalogEntry]] = [:]
    private var entries: [String: ArchiveCatalogEntry] = [:]
    private var generation = 0
    private var task: Task<Void, Never>?

    init(archiveURL: URL, loader: @escaping Loader = { try await ArchiveCatalogService.catalog(archive: $0) }) {
        self.archiveURL = archiveURL
        self.loader = loader
    }

    deinit { task?.cancel() }

    var canGoUp: Bool { !currentPath.isEmpty }
    var canExtractSelection: Bool {
        !isLoading && !selectedIDs.isEmpty && selectedIDs.allSatisfy { entries[$0]?.isExtractable == true }
    }

    func load() {
        cancel()
        let expected = generation
        let archive = archiveURL
        let loader = loader
        isLoading = true
        errorMessage = nil
        catalog = nil
        children = [:]
        entries = [:]
        visibleEntries = []
        currentPath = ""
        selectedIDs = []
        task = Task { [weak self] in
            do {
                let catalog = try await loader(archive)
                let worker = Task.detached(priority: .utility) { () throws -> (children: [String: [ArchiveCatalogEntry]], entries: [String: ArchiveCatalogEntry]) in
                    var result: [String: [ArchiveCatalogEntry]] = [:]
                    for entry in catalog.entries {
                        try Task.checkCancellation()
                        let parent = Self.parent(of: entry.path)
                        result[parent, default: []].append(entry)
                    }
                    for key in Array(result.keys) {
                        try Task.checkCancellation()
                        result[key]?.sort { lhs, rhs in
                            if (lhs.kind == .directory) != (rhs.kind == .directory) { return lhs.kind == .directory }
                            let comparison = Self.name(of: lhs.path).localizedStandardCompare(Self.name(of: rhs.path))
                            return comparison == .orderedSame ? lhs.path < rhs.path : comparison == .orderedAscending
                        }
                    }
                    return (result, Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.id, $0) }))
                }
                let index = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled, let self, expected == self.generation else { return }
                self.catalog = catalog
                self.children = index.children
                self.entries = index.entries
                self.visibleEntries = index.children[""] ?? []
                self.isLoading = false
            } catch is CancellationError {
            } catch {
                guard let self, expected == self.generation else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func enter(_ entry: ArchiveCatalogEntry) {
        guard entry.kind == .directory else { return }
        currentPath = entry.path
        visibleEntries = children[currentPath] ?? []
        selectedIDs = []
    }

    func goUp() {
        guard canGoUp else { return }
        currentPath = Self.parent(of: currentPath)
        visibleEntries = children[currentPath] ?? []
        selectedIDs = []
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isLoading = false
    }

    nonisolated static func parent(of path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    nonisolated static func name(of path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }
}
