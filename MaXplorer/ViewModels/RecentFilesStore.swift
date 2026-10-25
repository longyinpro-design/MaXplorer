import Combine
import Foundation
import Darwin

/// Only explicitly opened file URLs enter this list. Recording never queries the
/// filesystem. Availability is advisory and is refreshed off the main actor.
@MainActor
final class RecentFilesStore: ObservableObject {
    static let shared = RecentFilesStore()
    nonisolated static let storageKey = "RecentFiles.v1"
    nonisolated static let limit = 50

    @Published private(set) var entries: [RecentFile]
    private let defaults: UserDefaults
    private let key: String
    private let probe: @Sendable (URL) -> RecentFile.Availability
    private var revision: UInt64 = 0
    private var refreshTask: Task<[RecentFile], Never>?

    init(defaults: UserDefaults = .standard, storageKey: String = RecentFilesStore.storageKey,
         probe: @escaping @Sendable (URL) -> RecentFile.Availability = { RecentFilesStore.probeAvailability($0) }) {
        self.defaults = defaults
        self.key = storageKey
        self.probe = probe
        var seen = Set<URL>()
        let decoded = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([RecentFile].self, from: $0) } ?? []
        entries = decoded.compactMap { entry in
            guard let url = Self.normalized(entry.url), seen.insert(url).inserted else { return nil }
            // Persisted availability can be stale after restart.
            return RecentFile(url: url, lastOpened: entry.lastOpened)
        }.prefix(Self.limit).map { $0 }
    }

    func record(_ url: URL, date: Date = Date()) {
        guard let url = Self.normalized(url) else { return }
        invalidateRefresh()
        entries.removeAll { $0.url == url }
        entries.insert(RecentFile(url: url, lastOpened: date), at: 0)
        entries = Array(entries.prefix(Self.limit))
        persist()
    }

    func remove(_ url: URL) {
        guard let url = Self.normalized(url) else { return }
        invalidateRefresh()
        entries.removeAll { $0.url == url }
        persist()
    }

    func clear() {
        invalidateRefresh()
        entries = []
        defaults.removeObject(forKey: key)
    }

    func refreshAvailability() async {
        invalidateRefresh()
        let expectedRevision = revision
        let snapshot = entries
        let probe = self.probe
        let task = Task.detached(priority: .utility) {
            var result = snapshot
            for index in result.indices {
                guard !Task.isCancelled else { return result }
                result[index].status = probe(result[index].url)
            }
            return result
        }
        refreshTask = task
        let updated = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard revision == expectedRevision else { return }
        refreshTask = nil
        guard !Task.isCancelled, !task.isCancelled else { return }
        entries = updated
        // Availability is transient; the persisted record is still the same MRU.
    }

    private func invalidateRefresh() {
        revision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    private nonisolated static func normalized(_ url: URL) -> URL? {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.contains("\0"), url.path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: url.standardized.path, isDirectory: false)
    }

    /// Do not resolve symlinks or Finder aliases. A symlink (including a dangling
    /// link) is unavailable; an ordinary alias file is only checked as a file.
    /// lstat performs one metadata query for the known path, never traverses a
    /// directory tree, and cannot enter an alias/symlink resolution loop.
    nonisolated static func probeAvailability(_ url: URL) -> RecentFile.Availability {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .unavailable
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return .unavailable }
        return access(url.path, R_OK) == 0 ? .available : .unavailable
    }
}
