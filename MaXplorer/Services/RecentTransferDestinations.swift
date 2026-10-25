import Foundation

/// Bounded recovery search roots. This stores strings only; it never inspects disks
/// or resolves symlinks, so recording a slow or disconnected destination is cheap.
@MainActor
final class RecentTransferDestinations {
    static let shared = RecentTransferDestinations(defaults: .standard)
    static let storageKey = "RecentTransferDestinations"
    private let defaults: UserDefaults
    private let limit: Int

    init(defaults: UserDefaults, limit: Int = 20) {
        self.defaults = defaults
        self.limit = max(1, min(limit, 100))
    }

    var directories: [URL] {
        unique((defaults.stringArray(forKey: Self.storageKey) ?? []).compactMap(URL.init(string:)))
    }

    func record(_ directories: [URL]) {
        let recent = unique(directories + self.directories)
        defaults.set(recent.map(\.absoluteString), forKey: Self.storageKey)
    }

    func recoveryRoots(including directories: [URL]) -> [URL] {
        var roots = directories + self.directories
        if let path = defaults.string(forKey: "LastTransferDestination"), path.hasPrefix("/") {
            roots.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        // Explicit roots and the legacy entry are additive, outside the MRU limit.
        return unique(roots, bounded: false)
    }

    private func unique(_ urls: [URL], bounded: Bool = true) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls where url.isFileURL {
            // URL.standardized is lexical; do not call resolvingSymlinksInPath or
            // query resource values while running on the main actor.
            let normalized = URL(fileURLWithPath: url.standardized.path, isDirectory: true)
            guard seen.insert(normalized.absoluteString).inserted else { continue }
            result.append(normalized)
            if bounded && result.count == limit { break }
        }
        return result
    }
}
