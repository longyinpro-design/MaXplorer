import Foundation

nonisolated struct UndoItemState: Equatable, Sendable {
    let exists: Bool
    let isDirectory: Bool
    let size: Int64?
    let modifiedAt: Date?
    let fingerprint: String
}

nonisolated struct UndoMovePair: Equatable, Sendable {
    let from: URL
    let to: URL
}

nonisolated enum FileUndoKind: Equatable, Sendable {
    case rename(from: URL, to: URL, expected: UndoItemState)
    case move(items: [UndoMovePair], expected: [URL: UndoItemState])
    case copy(created: [URL], expected: [URL: UndoItemState])
    /// A recorded action that cannot be restored (for example an overwrite).
    /// It is kept in the history so the user can see why ⌘Z cannot replay it.
    case notRestorable(action: String, detail: String)

    var title: String {
        switch self {
        case .rename: return "重命名"
        case .move: return "移动"
        case .copy: return "复制"
        case .notRestorable(let action, _): return action
        }
    }

    var affectedCount: Int {
        switch self {
        case .rename: return 1
        case .move(let items, _): return items.count
        case .copy(let created, _): return created.count
        case .notRestorable: return 1
        }
    }

    var isRestorable: Bool {
        if case .notRestorable = self {
            return false
        }
        return true
    }

    var historyDetail: String {
        switch self {
        case .rename(let from, let to, _):
            return "“\(to.lastPathComponent)”恢复为“\(from.lastPathComponent)”"
        case .move(let items, _):
            return Self.moveDetail(items)
        case .copy(let created, _):
            return "移除 \(created.count) 个本次运行中新建的项目"
        case .notRestorable(_, let detail):
            return detail
        }
    }

    private static func moveDetail(_ items: [UndoMovePair]) -> String {
        guard items.count == 1, let item = items.first else {
            return "\(items.count) 个项目返回原位置"
        }
        let originalFolder = item.from.deletingLastPathComponent().lastPathComponent
        return "“\(item.to.lastPathComponent)”返回“\(originalFolder)”"
    }
}

nonisolated struct FileUndoEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: FileUndoKind
    let createdAt: Date

    init(id: UUID = UUID(), kind: FileUndoKind, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
    }

    var title: String { kind.title }
    var affectedCount: Int { kind.affectedCount }
    var isRestorable: Bool { kind.isRestorable }
    var historyDetail: String { kind.historyDetail }

    /// Title used in the Edit > Undo menu item.
    var menuTitle: String {
        affectedCount > 1 ? "\(title)（\(affectedCount) 项）" : title
    }
}

/// Collects the items of one copy/move batch so a single ⌘Z can undo the
/// whole batch instead of one queue item at a time.
nonisolated struct UndoBatchAccumulator: Equatable {
    private(set) var copiedDestinations: [URL] = []
    private(set) var movedItems: [UndoMovePair] = []
    /// Destinations this batch overwrote. Overwrites cannot be restored, so
    /// they become history markers instead of undo entries.
    private(set) var overwrittenDestinations: [URL] = []

    var isEmpty: Bool {
        copiedDestinations.isEmpty && movedItems.isEmpty && overwrittenDestinations.isEmpty
    }

    mutating func recordCopy(created url: URL) {
        guard !copiedDestinations.contains(url) else { return }
        copiedDestinations.append(url)
    }

    mutating func recordMove(from: URL, to: URL) {
        let pair = UndoMovePair(from: from, to: to)
        guard !movedItems.contains(pair) else { return }
        movedItems.append(pair)
    }

    mutating func recordOverwrite(_ url: URL) {
        guard !overwrittenDestinations.contains(url) else { return }
        overwrittenDestinations.append(url)
    }
}

nonisolated enum FileUndoOutcome: Sendable {
    case completed
    case partial(remaining: FileUndoEntry, failures: [String])
}

nonisolated enum FileUndoError: LocalizedError {
    case changed(String)
    case occupied(String)
    case trashed(String)
    case notRestorable(String)

    var errorDescription: String? {
        switch self {
        case .changed(let name):
            return "“\(name)”在操作后已被修改，已拒绝撤销以保护数据。"
        case .occupied(let name):
            return "原位置“\(name)”已被占用，无法撤销。"
        case .trashed(let message):
            return message
        case .notRestorable(let message):
            return message
        }
    }
}
