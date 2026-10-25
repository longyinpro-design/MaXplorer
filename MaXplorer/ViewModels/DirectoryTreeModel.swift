import Foundation
import Combine

nonisolated struct DirectoryTreeState: Sendable {
    var children: [DirectoryTreeNode] = []
    var isExpanded = false
    var isLoading = false
    var error: String?
    var hasLoaded = false
}

@MainActor final class DirectoryTreeModel: ObservableObject {
    typealias Loader = @Sendable (URL, Bool) async throws -> [DirectoryTreeNode]

    @Published private(set) var roots: [DirectoryTreeNode]
    @Published private(set) var states: [URL: DirectoryTreeState] = [:]
    private var showHiddenFiles = false
    private let loader: Loader
    private var requests: [URL: Task<Void, Never>] = [:]
    private var generations: [URL: UUID] = [:]
    private var revealGeneration = UUID()

    init(roots: [URL], loader: @escaping Loader = { url, hidden in
        try await DirectoryTreeService.children(of: url, showHiddenFiles: hidden)
    }) {
        var seen = Set<URL>()
        self.roots = roots.filter { $0.isFileURL && seen.insert(DirectoryTreeService.normalized($0)).inserted }
            .map { DirectoryTreeNode(url: $0) }
        self.loader = loader
    }

    deinit { requests.values.forEach { $0.cancel() } }

    func children(for url: URL) -> [DirectoryTreeNode] { states[DirectoryTreeService.normalized(url)]?.children ?? [] }
    func isExpanded(_ url: URL) -> Bool { states[DirectoryTreeService.normalized(url)]?.isExpanded ?? false }
    func isLoading(_ url: URL) -> Bool { states[DirectoryTreeService.normalized(url)]?.isLoading ?? false }
    func error(for url: URL) -> String? { states[DirectoryTreeService.normalized(url)]?.error }

    func setShowHiddenFiles(_ value: Bool) {
        guard value != showHiddenFiles else { return }
        showHiddenFiles = value
        cancelAll()
        // Descendant nodes may disappear when hidden files are disabled. Rebuild lazily from roots.
        let expandedRoots = roots.filter { isExpanded($0.id) }.map(\.id)
        states = [:]
        for root in expandedRoots { setExpanded(root, true, showHiddenFiles: value) }
    }

    func setExpanded(_ url: URL, _ expanded: Bool, showHiddenFiles: Bool) {
        guard url.isFileURL else { return }
        setShowHiddenFiles(showHiddenFiles)
        let key = DirectoryTreeService.normalized(url)
        guard node(for: key)?.isExpandable == true else { return }
        var state = states[key] ?? DirectoryTreeState()
        state.isExpanded = expanded
        states[key] = state
        if !expanded {
            revealGeneration = UUID()
            // Cancel descendants too: an offscreen slow mount must not keep publishing changes.
            for pending in Array(requests.keys) where DirectoryTreeService.contains(pending, in: key) {
                cancel(pending)
            }
            for descendant in Array(states.keys) where descendant != key && DirectoryTreeService.contains(descendant, in: key) {
                states[descendant]?.isExpanded = false
            }
        } else if !state.hasLoaded && !state.isLoading {
            startLoading(key)
        }
    }

    func retry(_ url: URL) {
        guard url.isFileURL else { return }
        let key = DirectoryTreeService.normalized(url)
        guard node(for: key)?.isExpandable == true, isExpanded(key) else { return }
        cancel(key)
        // A refreshed child list may contain removed-and-recreated paths. Their old expanded
        // states and contents must not survive merely because the lexical URL is unchanged.
        for descendant in Array(states.keys) where descendant != key && DirectoryTreeService.contains(descendant, in: key) {
            cancel(descendant)
            states[descendant] = nil
        }
        startLoading(key)
    }

    func cancelAll() {
        revealGeneration = UUID()
        for key in Array(requests.keys) { cancel(key) }
    }

    /// Loads only the ancestor chain, never siblings' descendants or the whole disk.
    @discardableResult
    func reveal(_ url: URL, showHiddenFiles: Bool) async -> Bool {
        setShowHiddenFiles(showHiddenFiles)
        let target = DirectoryTreeService.normalized(url)
        guard url.isFileURL,
              let root = roots.filter({ DirectoryTreeService.contains(target, in: $0.id) })
                .max(by: { $0.id.pathComponents.count < $1.id.pathComponents.count }) else { return false }
        let token = UUID()
        revealGeneration = token
        var current = root.id
        let components = target.pathComponents.dropFirst(current.pathComponents.count)
        for component in components {
            guard !Task.isCancelled, revealGeneration == token, node(for: current)?.isExpandable == true else {
                return false
            }
            let usedCache = states[current]?.hasLoaded == true && !isLoading(current)
            setExpanded(current, true, showHiddenFiles: showHiddenFiles)
            if let request = requests[current] { await request.value }
            guard !Task.isCancelled, revealGeneration == token,
                  states[current]?.hasLoaded == true, isExpanded(current) else { return false }
            let child = DirectoryTreeService.normalized(current.appendingPathComponent(component, isDirectory: true))
            if usedCache && !children(for: current).contains(where: { $0.id == child }) {
                // A folder may have been created since this level was cached. Refresh this
                // ancestor once; a missing item in a fresh response remains a normal failure.
                retry(current)
                if let request = requests[current] { await request.value }
                guard !Task.isCancelled, revealGeneration == token,
                      states[current]?.hasLoaded == true, isExpanded(current) else { return false }
            }
            guard children(for: current).contains(where: { $0.id == child }) else { return false }
            current = child
        }
        return !Task.isCancelled && revealGeneration == token
    }

    private func node(for url: URL) -> DirectoryTreeNode? {
        roots.first(where: { $0.id == url }) ?? states.values.lazy.flatMap(\.children).first(where: { $0.id == url })
    }

    private func cancel(_ key: URL) {
        generations[key] = nil
        requests.removeValue(forKey: key)?.cancel()
        if var state = states[key] {
            state.isLoading = false
            states[key] = state
        }
    }

    private func startLoading(_ key: URL) {
        let generation = UUID()
        generations[key] = generation
        var state = states[key] ?? DirectoryTreeState()
        state.isLoading = true
        state.hasLoaded = false
        state.error = nil
        states[key] = state
        let loader = self.loader
        let hidden = showHiddenFiles
        requests[key] = Task { [weak self] in
            do {
                let children = try await loader(key, hidden)
                guard !Task.isCancelled, let self, self.generations[key] == generation else { return }
                var loaded = self.states[key] ?? DirectoryTreeState()
                // Keep injected loaders within the same immediate-child contract as the real service.
                var seen = Set<URL>()
                loaded.children = children.filter {
                    $0.id.isFileURL && DirectoryTreeService.normalized($0.id.deletingLastPathComponent()) == key &&
                    seen.insert($0.id).inserted
                }
                loaded.isLoading = false
                loaded.hasLoaded = true
                self.states[key] = loaded
                self.requests[key] = nil
            } catch {
                guard let self, self.generations[key] == generation else { return }
                var failed = self.states[key] ?? DirectoryTreeState()
                failed.isLoading = false
                if !Task.isCancelled && !(error is CancellationError) { failed.error = error.localizedDescription }
                self.states[key] = failed
                self.requests[key] = nil
            }
        }
    }
}
