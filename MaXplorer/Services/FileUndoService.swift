import Foundation
import Darwin

nonisolated struct FileUndoService {
    static func state(of url: URL) async -> UndoItemState {
        await Task.detached(priority: .utility) {
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                return UndoItemState(
                    exists: false,
                    isDirectory: false,
                    size: nil,
                    modifiedAt: nil,
                    fingerprint: ""
                )
            }

            let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
            return UndoItemState(
                exists: true,
                isDirectory: isDirectory,
                size: isDirectory ? nil : Int64(info.st_size),
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                fingerprint: fingerprint(for: url, rootInfo: info)
            )
        }.value
    }

    static func states(of urls: [URL]) async -> [URL: UndoItemState] {
        var result: [URL: UndoItemState] = [:]
        for url in urls {
            result[url] = await state(of: url)
        }
        return result
    }

    static func undo(_ entry: FileUndoEntry) async throws -> FileUndoOutcome {
        switch entry.kind {
        case .rename(let from, let to, let expected):
            try await undoRename(from: from, to: to, expected: expected)
            return .completed

        case .renameBatch(let items, let expected):
            return await undoRenameBatch(entry: entry, items: items, expected: expected)

        case .move(let items, let expected):
            return try await undoMoves(
                entryID: entry.id,
                items: items,
                expected: expected,
                createdAt: entry.createdAt
            )

        case .copy(let created, let expected):
            return try await undoCopy(entryID: entry.id, created: created, expected: expected, createdAt: entry.createdAt)

        case .notRestorable:
            // The journal keeps these markers for the undo history, but they
            // must never be handed to the service as something to replay.
            throw FileUndoError.notRestorable("覆盖操作无法撤销，仅保留在撤销历史中。")
        }
    }

    private static func undoRenameBatch(
        entry: FileUndoEntry,
        items: [UndoMovePair],
        expected: [URL: UndoItemState]
    ) async -> FileUndoOutcome {
        var eligible: [BatchRenamePreviewItem] = []
        var failures: [String] = []
        for (index, pair) in items.enumerated() {
            let current = await state(of: pair.to)
            if current.exists, current == expected[pair.to] {
                eligible.append(BatchRenamePreviewItem(
                    id: index, source: pair.to, originalName: pair.to.lastPathComponent,
                    proposedName: pair.from.lastPathComponent, issue: nil
                ))
            } else {
                failures.append("“\(pair.to.lastPathComponent)”已被修改或不存在，未恢复原名。")
            }
        }
        // The same dependency-aware engine handles swaps, chains and case-only
        // renames in both directions. Changed items are never passed to it.
        let outcome = await BatchRenameService.execute(eligible)
        failures += outcome.failures
        if outcome.cancelled { failures.append("批量撤销已取消。") }
        let restored = Set(outcome.renamed.map(\.from))
        let remaining = items.filter { !restored.contains($0.to) }
        guard !remaining.isEmpty else { return .completed }
        return .partial(
            remaining: FileUndoEntry(
                id: entry.id, kind: .renameBatch(items: remaining, expected: expected), createdAt: entry.createdAt
            ),
            failures: failures
        )
    }

    private static func undoRename(from: URL, to: URL, expected: UndoItemState) async throws {
        let current = await state(of: to)
        guard current.exists, current == expected else {
            throw FileUndoError.changed(to.lastPathComponent)
        }
        guard !SafeFileOperations.entryExists(at: from) else {
            throw FileUndoError.occupied(from.lastPathComponent)
        }

        try await SafeFileOperations.perform(
            .move,
            sourceURL: to,
            destinationURL: from,
            overwrite: false,
            progress: { _ in }
        )
    }

    /// Undoes one copy/move batch. Every item is verified against the state
    /// that was captured right after the operation; items that changed are
    /// reported back instead of being touched.
    private static func undoMoves(
        entryID: UUID,
        items: [UndoMovePair],
        expected: [URL: UndoItemState],
        createdAt: Date
    ) async throws -> FileUndoOutcome {
        var remainingItems: [UndoMovePair] = []
        var remainingStates: [URL: UndoItemState] = [:]
        var failures: [String] = []

        for pair in items {
            let current = await state(of: pair.to)
            guard current.exists, current == expected[pair.to] else {
                failures.append("“\(pair.to.lastPathComponent)”已被修改或不存在，未移回。")
                remainingItems.append(pair)
                if let expectedState = expected[pair.to] {
                    remainingStates[pair.to] = expectedState
                }
                continue
            }

            guard !SafeFileOperations.entryExists(at: pair.from) else {
                failures.append("原位置“\(pair.from.lastPathComponent)”已被占用，未移回。")
                remainingItems.append(pair)
                if let expectedState = expected[pair.to] {
                    remainingStates[pair.to] = expectedState
                }
                continue
            }

            do {
                try await SafeFileOperations.perform(
                    .move,
                    sourceURL: pair.to,
                    destinationURL: pair.from,
                    overwrite: false,
                    progress: { _ in }
                )
            } catch {
                failures.append("无法移回“\(pair.to.lastPathComponent)”：\(error.localizedDescription)")
                remainingItems.append(pair)
                if let expectedState = expected[pair.to] {
                    remainingStates[pair.to] = expectedState
                }
            }
        }

        guard !remainingItems.isEmpty else {
            return .completed
        }

        let remaining = FileUndoEntry(
            id: entryID,
            kind: .move(items: remainingItems, expected: remainingStates),
            createdAt: createdAt
        )
        return .partial(remaining: remaining, failures: failures)
    }

    private static func undoCopy(
        entryID: UUID,
        created: [URL],
        expected: [URL: UndoItemState],
        createdAt: Date
    ) async throws -> FileUndoOutcome {
        var remainingStates: [URL: UndoItemState] = [:]
        var failures: [String] = []

        for url in created {
            let expectedState = expected[url]
            let current = await state(of: url)

            guard current.exists, current == expectedState else {
                failures.append("“\(url.lastPathComponent)”已被修改或不存在，未删除。")
                if let expectedState {
                    remainingStates[url] = expectedState
                }
                continue
            }

            do {
                try await trash(url)
            } catch {
                failures.append("无法移除“\(url.lastPathComponent)”：\(error.localizedDescription)")
                if let expectedState {
                    remainingStates[url] = expectedState
                }
            }
        }

        guard !remainingStates.isEmpty else {
            return .completed
        }

        let remaining = FileUndoEntry(
            id: entryID,
            kind: .copy(created: created.filter { remainingStates[$0] != nil }, expected: remainingStates),
            createdAt: createdAt
        )
        return .partial(remaining: remaining, failures: failures)
    }

    private static func trash(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        }.value
    }

    private static func fingerprint(for url: URL, rootInfo: stat) -> String {
        let root = "\(rootInfo.st_mode)|\(rootInfo.st_size)|\(rootInfo.st_mtimespec.tv_sec)|\(rootInfo.st_mtimespec.tv_nsec)|\(rootInfo.st_ino)"
        guard (rootInfo.st_mode & S_IFMT) == S_IFDIR else {
            return root
        }

        var hasher = Hasher()
        hasher.combine(root)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) else {
            return root
        }

        var entries: [String] = []
        while let child = enumerator.nextObject() as? URL {
            var childInfo = stat()
            if lstat(child.path, &childInfo) == 0 {
                entries.append(
                    "\(child.path)|\(childInfo.st_mode)|\(childInfo.st_size)|\(childInfo.st_mtimespec.tv_sec)|\(childInfo.st_mtimespec.tv_nsec)"
                )
            }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true, values?.isDirectory == true {
                enumerator.skipDescendants()
            }
        }

        for entry in entries.sorted() {
            hasher.combine(entry)
        }
        return "\(root)|\(hasher.finalize())"
    }
}
