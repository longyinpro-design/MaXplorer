import Foundation

nonisolated struct BatchRenameOutcome: Sendable {
    let renamed: [UndoMovePair]
    let failures: [String]
    let cancelled: Bool

    var isEmpty: Bool {
        renamed.isEmpty && failures.isEmpty && !cancelled
    }
}

/// Builds batch-rename previews and executes them through
/// `SafeFileOperations`, so a rename never overwrites an existing item and is
/// always staged when it would collide with another item of the batch.
nonisolated enum BatchRenameService {
    static func preview(
        urls: [URL],
        options: BatchRenameOptions,
        date: Date = Date()
    ) -> [BatchRenamePreviewItem] {
        let names = urls.enumerated().map { index, url in
            (url: url, proposed: BatchRenameName.expandedName(for: url, index: index, options: options, date: date))
        }

        let changing = names.filter { $0.proposed != $0.url.lastPathComponent }
        let changingSources = Set(changing.map { key($0.url) })
        var duplicateCounts: [String: Int] = [:]
        for item in changing {
            duplicateCounts[duplicateKey(parent: item.url.deletingLastPathComponent(), name: item.proposed), default: 0] += 1
        }

        return names.enumerated().map { index, entry in
            let originalName = entry.url.lastPathComponent
            let target = entry.url.deletingLastPathComponent().appendingPathComponent(entry.proposed)
            var issue: String?

            if entry.proposed != originalName {
                issue = validate(name: entry.proposed)
                if issue == nil {
                    let duplicate = duplicateKey(parent: entry.url.deletingLastPathComponent(), name: entry.proposed)
                    if (duplicateCounts[duplicate] ?? 0) > 1 {
                        issue = "与同批次的其他项目重名"
                    } else if SafeFileOperations.entryExists(at: target) {
                        let targetKey = key(target)
                        // A case-only rename on a case-insensitive volume still
                        // "exists" as the source itself, and a swap target is
                        // occupied by another item that is about to move away.
                        if targetKey != key(entry.url), !changingSources.contains(targetKey) {
                            issue = "目标名称已存在"
                        }
                    }
                }
            }

            return BatchRenamePreviewItem(
                id: index,
                source: entry.url,
                originalName: originalName,
                proposedName: entry.proposed,
                issue: issue
            )
        }
    }

    /// Names that depend on each other form one group. Cancellation is honored
    /// before publication; once a group starts publishing, it finishes or rolls
    /// back before the next cancellation check. Independent groups may succeed
    /// even when another group fails.
    static func execute(
        _ items: [BatchRenamePreviewItem],
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> BatchRenameOutcome {
        guard !items.contains(where: { $0.issue != nil }) else {
            return BatchRenameOutcome(renamed: [], failures: ["存在无效的名称，未执行任何重命名。"], cancelled: false)
        }
        let pending = items.filter { $0.isChange }
        var renamed: [UndoMovePair] = []
        var failures: [String] = []
        var processed = 0
        progress(0, pending.count)
        for group in dependencyGroups(pending) {
            if Task.isCancelled {
                return BatchRenameOutcome(renamed: renamed, failures: failures, cancelled: true)
            }
            let outcome = await executeGroup(group)
            renamed += outcome.renamed
            failures += outcome.failures
            if outcome.cancelled {
                return BatchRenameOutcome(renamed: renamed, failures: failures, cancelled: true)
            }
            processed += group.count
            progress(processed, pending.count)
        }
        return BatchRenameOutcome(renamed: renamed, failures: failures, cancelled: false)
    }

    private struct Stage: Sendable {
        let item: BatchRenamePreviewItem
        let temporary: URL
    }

    private static func dependencyGroups(_ items: [BatchRenamePreviewItem]) -> [[BatchRenamePreviewItem]] {
        var parent = Array(items.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { index = parent[index] }
            return index
        }
        var owners: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            for path in [key(item.source), key(item.target)] {
                if let previous = owners[path] { parent[root(index)] = root(previous) }
                owners[path] = index
            }
        }
        var groups: [Int: [BatchRenamePreviewItem]] = [:]
        var order: [Int] = []
        for (index, item) in items.enumerated() {
            let group = root(index)
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(item)
        }
        return order.compactMap { groups[$0] }
    }

    private static func executeGroup(_ items: [BatchRenamePreviewItem]) async -> BatchRenameOutcome {
        let sources = Set(items.map { key($0.source) })
        // Recheck occupancy at execution time. An external target is never
        // moved aside, even if it appeared after the preview was computed.
        for item in items where SafeFileOperations.entryExists(at: item.target) && !sources.contains(key(item.target)) {
            return BatchRenameOutcome(renamed: [], failures: ["目标名称“\(item.proposedName)”已存在，未执行该组重命名。"], cancelled: false)
        }
        if items.count == 1, let item = items.first, key(item.source) != key(item.target) {
            do {
                try await move(item.source, to: item.target)
                return BatchRenameOutcome(renamed: [UndoMovePair(from: item.source, to: item.target)], failures: [], cancelled: false)
            } catch is CancellationError {
                return BatchRenameOutcome(renamed: [], failures: [], cancelled: true)
            } catch {
                return BatchRenameOutcome(renamed: [], failures: ["无法重命名为“\(item.proposedName)”：\(error.localizedDescription)"], cancelled: false)
            }
        }

        var staged: [Stage] = []
        do {
            for item in items {
                try Task.checkCancellation()
                let stage = Stage(item: item, temporary: temporaryURL(for: item.source))
                try await move(item.source, to: stage.temporary)
                staged.append(stage)
            }
            try Task.checkCancellation()
        } catch {
            let cancelled = error is CancellationError
            let stages = staged
            let recovery = await Task.detached { await rollback(stages, published: []) }.value
            let errors = cancelled ? [] : ["该组重命名未能开始：\(error.localizedDescription)"]
            return BatchRenameOutcome(renamed: recovery.renamed, failures: errors + recovery.failures, cancelled: cancelled)
        }

        // Publication and rollback must not inherit cancellation. A half-swapped
        // group cannot be restored one item at a time while names are occupied.
        let stages = staged
        return await Task.detached {
            var published: Set<Int> = []
            for stage in stages {
                do {
                    try await move(stage.temporary, to: stage.item.target)
                    published.insert(stage.item.id)
                } catch {
                    let recovery = await rollback(stages, published: published)
                    return BatchRenameOutcome(
                        renamed: recovery.renamed,
                        failures: ["无法重命名为“\(stage.item.proposedName)”：\(error.localizedDescription)"] + recovery.failures,
                        cancelled: false
                    )
                }
            }
            return BatchRenameOutcome(
                renamed: stages.map { UndoMovePair(from: $0.item.source, to: $0.item.target) },
                failures: [], cancelled: false
            )
        }.value
    }

    /// Vacate published names first, then restore all originals. If an external
    /// change prevents recovery, preserve the file and report its full path.
    private static func rollback(_ stages: [Stage], published: Set<Int>) async -> BatchRenameOutcome {
        var stillPublished = published
        var failures: [String] = []
        for stage in stages.reversed() where published.contains(stage.item.id) {
            do {
                try await move(stage.item.target, to: stage.temporary)
                stillPublished.remove(stage.item.id)
            } catch {
                failures.append("无法回滚“\(stage.item.target.path)”：\(error.localizedDescription)")
            }
        }
        for stage in stages where !stillPublished.contains(stage.item.id) {
            do {
                try await move(stage.temporary, to: stage.item.source)
            } catch {
                failures.append("无法恢复“\(stage.item.source.path)”，文件保留在“\(stage.temporary.path)”。")
            }
        }
        return BatchRenameOutcome(
            renamed: stages.filter { stillPublished.contains($0.item.id) }.map { UndoMovePair(from: $0.item.source, to: $0.item.target) },
            failures: failures, cancelled: false
        )
    }

    private static func validate(name: String) -> String? {
        if name.isEmpty {
            return "名称不能为空"
        }
        if name == "." || name == ".." {
            return "名称不能是 . 或 .."
        }
        if name.contains("/") || name.contains(":") || name.contains("\0") {
            return "名称不能包含 / 或 :"
        }
        if name.utf8.count > 255 {
            return "名称超过 255 字节"
        }
        return nil
    }

    private static func move(_ source: URL, to destination: URL) async throws {
        try await SafeFileOperations.perform(
            .move,
            sourceURL: source,
            destinationURL: destination,
            overwrite: false,
            progress: { _ in }
        )
    }

    private static func temporaryURL(for source: URL) -> URL {
        source.deletingLastPathComponent()
            .appendingPathComponent(".maxplorer-rename-\(UUID().uuidString.lowercased())")
    }

    /// Case-insensitive identity of an item on disk, used for conflict checks.
    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }

    private static func duplicateKey(parent: URL, name: String) -> String {
        parent.standardizedFileURL.path.lowercased() + "/" + name.lowercased()
    }
}
