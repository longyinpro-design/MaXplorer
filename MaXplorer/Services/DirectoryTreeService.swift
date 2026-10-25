import Foundation

nonisolated struct DirectoryTreeNode: Identifiable, Hashable, Sendable {
    let id: URL
    let name: String
    let isExpandable: Bool

    init(url: URL, name: String? = nil, isExpandable: Bool = true) {
        self.id = DirectoryTreeService.normalized(url)
        self.name = name ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
        self.isExpandable = isExpandable
    }
}

/// A single-level directory listing. Packages are navigable leaves; links and aliases are omitted.
nonisolated enum DirectoryTreeService {
    private static let worker = DirectoryTreeListingWorker()

    static func normalized(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }

    static func children(of url: URL, showHiddenFiles: Bool) async throws -> [DirectoryTreeNode] {
        let worker = Task.detached(priority: .userInitiated) {
            try await Self.worker.listChildren(of: url, showHiddenFiles: showHiddenFiles)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func contains(_ target: URL, in root: URL) -> Bool {
        guard target.isFileURL, root.isFileURL else { return false }
        let ancestor = root.standardizedFileURL.pathComponents
        let descendant = target.standardizedFileURL.pathComponents
        return descendant.starts(with: ancestor)
    }

}

/// System calls can block until the volume responds; cancellation prevents later work/results.
/// One worker bounds simultaneous filesystem enumerations even across multiple model instances.
private actor DirectoryTreeListingWorker {
    private let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey
    ]

    func listChildren(of url: URL, showHiddenFiles: Bool) throws -> [DirectoryTreeNode] {
        try Task.checkCancellation()
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let directory = url.standardizedFileURL
        // Validate every lexical ancestor without resolving symlinks. Otherwise a caller could
        // bypass the leaf policy by supplying /root/link/subdirectory directly.
        var ancestor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directory.pathComponents.dropFirst() {
            try Task.checkCancellation()
            ancestor.appendPathComponent(component, isDirectory: true)
            let values = try ancestor.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isAliasFile != true,
                  values.isDirectory == true, values.isPackage != true else {
                throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: ancestor.path])
            }
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys),
            options: showHiddenFiles ? [] : [.skipsHiddenFiles]
        )
        var result: [DirectoryTreeNode] = []
        for child in urls {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  values.isAliasFile != true else { continue }
            if !showHiddenFiles && (values.isHidden == true || child.lastPathComponent.hasPrefix(".")) {
                continue
            }
            result.append(DirectoryTreeNode(url: child, isExpandable: values.isPackage != true))
        }
        try Task.checkCancellation()
        return result.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.path < $1.id.path : order == .orderedAscending
        }
    }
}
