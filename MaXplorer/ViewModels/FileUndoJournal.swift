import Foundation
import Combine

/// In-memory undo history for the current app run. Entries are dropped when
/// MaXplorer quits, which is shown in the undo history sheet.
@MainActor
final class FileUndoJournal: ObservableObject {
    @Published private(set) var entries: [FileUndoEntry] = []

    let limit: Int

    init(limit: Int = 20) {
        self.limit = max(1, limit)
    }

    /// The entry the next ⌘Z will revert. Non-restorable markers (overwrites)
    /// are skipped because they can only be shown, never replayed.
    var nextUndoableEntry: FileUndoEntry? {
        entries.first { $0.isRestorable }
    }

    var canUndo: Bool { nextUndoableEntry != nil }

    var undoActionTitle: String? { nextUndoableEntry?.menuTitle }

    func record(_ entry: FileUndoEntry) {
        entries.insert(entry, at: 0)
        if entries.count > limit {
            entries = Array(entries.prefix(limit))
        }
    }

    func remove(id: FileUndoEntry.ID) {
        entries.removeAll { $0.id == id }
    }

    /// Replaces a partially undone entry in place so the remaining items keep
    /// their position in the history.
    func replace(_ entry: FileUndoEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            record(entry)
            return
        }
        entries[index] = entry
    }

    func clear() {
        entries.removeAll()
    }
}
