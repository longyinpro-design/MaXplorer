import Foundation
import Combine
import Darwin

enum CopyConflictResolution {
    case overwrite
    case overwriteAll
    case skip
    case skipAll
    case cancel
}

enum CopyQueueItemState: Equatable {
    case pending
    case running
    case completed
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .pending, .running:
            return true
        case .completed, .failed, .cancelled:
            return false
        }
    }
}

nonisolated enum CopyQueueOperation: Equatable, Sendable {
    case copy
    case move
}

struct CopyQueueItem: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    let destinationURL: URL
    let name: String
    let shouldOverwrite: Bool
    let operation: CopyQueueOperation
    var state: CopyQueueItemState
    var totalBytes: Int64
    var copiedBytes: Int64
    var bytesPerSecond: Double
    var startedAt: Date?

    var progress: Double {
        guard totalBytes > 0 else {
            return state == .completed ? 1 : 0
        }

        return min(1, Double(copiedBytes) / Double(totalBytes))
    }

    var estimatedSecondsRemaining: TimeInterval? {
        guard state == .running, bytesPerSecond > 0, totalBytes > copiedBytes else {
            return nil
        }

        return Double(totalBytes - copiedBytes) / bytesPerSecond
    }
}

struct CopyQueueHistoryItem: Identifiable, Equatable {
    let id: UUID
    let sourceURL: URL
    let destinationURL: URL
    let name: String
    let operation: CopyQueueOperation
    let totalBytes: Int64
    let completedAt: Date
}

@MainActor
final class CopyQueueViewModel: ObservableObject {
    @Published private(set) var items: [CopyQueueItem] = []
    @Published private(set) var history: [CopyQueueHistoryItem] = []

    private var itemCompletionObservers: [(URL) -> Void] = []
    private var moveCompletionObservers: [(URL) -> Void] = []

    var maximumConcurrentCopies = 3 {
        didSet {
            maximumConcurrentCopies = min(max(maximumConcurrentCopies, 1), 5)
            startAvailableCopies()
        }
    }

    var historyLimit = 100 {
        didSet {
            historyLimit = min(max(historyLimit, 0), 500)
            trimHistory()
        }
    }

    private var tasks: [CopyQueueItem.ID: Task<Void, Never>] = [:]
    private var aggregateTotalItemCount = 0
    private var aggregateFinishedItemCount = 0

    var hasItems: Bool {
        !items.isEmpty
    }

    var activeCopyCount: Int {
        items.filter { $0.state.isActive }.count
    }

    var hasActiveOperations: Bool {
        activeCopyCount > 0
    }

    var overallProgress: Double {
        guard aggregateTotalItemCount > 0 else {
            return 0
        }

        let activeProgress = items
            .filter { $0.state.isActive }
            .reduce(0) { $0 + $1.progress }
        return min(
            1,
            (Double(aggregateFinishedItemCount) + activeProgress) / Double(aggregateTotalItemCount)
        )
    }

    func observeItemCompletions(_ observer: @escaping (URL) -> Void) {
        itemCompletionObservers.append(observer)
    }

    func observeMoveCompletions(_ observer: @escaping (URL) -> Void) {
        moveCompletionObservers.append(observer)
    }

    func enqueue(_ sources: [URL], to destinationDirectory: URL, conflictResolution: CopyConflictResolution) {
        guard conflictResolution != .cancel else {
            return
        }

        let destinationDirectory = destinationDirectory.standardizedFileURL
        let shouldSkip = conflictResolution == .skip || conflictResolution == .skipAll
        let shouldOverwrite = conflictResolution == .overwrite || conflictResolution == .overwriteAll
        let newItems = sources.compactMap { sourceURL -> CopyQueueItem? in
            let source = sourceURL.standardizedFileURL
            guard source.deletingLastPathComponent() != destinationDirectory else {
                return nil
            }

            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            let destinationExists = SafeFileOperations.entryExists(at: destination)
            if destinationExists, shouldSkip {
                return nil
            }

            return CopyQueueItem(
                id: UUID(),
                sourceURL: source,
                destinationURL: destination,
                name: source.lastPathComponent,
                shouldOverwrite: destinationExists && shouldOverwrite,
                operation: .copy,
                state: .pending,
                totalBytes: 0,
                copiedBytes: 0,
                bytesPerSecond: 0,
                startedAt: nil
            )
        }

        guard !newItems.isEmpty else {
            return
        }

        appendToQueue(newItems)
        startAvailableCopies()
    }

    func enqueue(_ resolvedItems: [(source: URL, shouldOverwrite: Bool)], to destinationDirectory: URL) {
        let destinationDirectory = destinationDirectory.standardizedFileURL
        let newItems = resolvedItems.compactMap { (sourceURL, shouldOverwrite) -> CopyQueueItem? in
            let source = sourceURL.standardizedFileURL
            guard source.deletingLastPathComponent() != destinationDirectory else {
                return nil
            }
            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            return CopyQueueItem(
                id: UUID(),
                sourceURL: source,
                destinationURL: destination,
                name: source.lastPathComponent,
                shouldOverwrite: shouldOverwrite,
                operation: .copy,
                state: .pending,
                totalBytes: 0,
                copiedBytes: 0,
                bytesPerSecond: 0,
                startedAt: nil
            )
        }

        guard !newItems.isEmpty else {
            return
        }

        appendToQueue(newItems)
        startAvailableCopies()
    }

    func enqueueMoves(_ resolvedItems: [(source: URL, shouldOverwrite: Bool)], to destinationDirectory: URL) {
        let destinationDirectory = destinationDirectory.standardizedFileURL
        let newItems = resolvedItems.compactMap { sourceURL, shouldOverwrite -> CopyQueueItem? in
            let source = sourceURL.standardizedFileURL
            guard source.deletingLastPathComponent() != destinationDirectory else {
                return nil
            }

            return CopyQueueItem(
                id: UUID(),
                sourceURL: source,
                destinationURL: destinationDirectory.appendingPathComponent(source.lastPathComponent),
                name: source.lastPathComponent,
                shouldOverwrite: shouldOverwrite,
                operation: .move,
                state: .pending,
                totalBytes: 0,
                copiedBytes: 0,
                bytesPerSecond: 0,
                startedAt: nil
            )
        }

        guard !newItems.isEmpty else {
            return
        }

        appendToQueue(newItems)
        startAvailableCopies()
    }

    func cancel(_ itemID: CopyQueueItem.ID) {
        guard let item = items.first(where: { $0.id == itemID }), item.state.isActive else {
            return
        }
        if item.state == .running {
            // Keep ownership and the running slot until the worker acknowledges
            // cancellation, or finishes a publication that already committed.
            tasks[itemID]?.cancel()
        } else {
            markCancelled(itemID)
        }
    }

    private func startAvailableCopies() {
        let runningCount = items.filter { $0.state == .running }.count
        let availableSlots = max(0, maximumConcurrentCopies - runningCount)
        guard availableSlots > 0 else {
            return
        }

        let pendingIDs = items
            .filter { $0.state == .pending }
            .prefix(availableSlots)
            .map(\.id)

        for itemID in pendingIDs {
            startCopy(itemID)
        }
    }

    private func startCopy(_ itemID: CopyQueueItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        items[index].state = .running
        items[index].startedAt = Date()
        let sourceURL = items[index].sourceURL
        let destinationURL = items[index].destinationURL
        let operation = items[index].operation
        let shouldOverwrite = items[index].shouldOverwrite
        let progressThrottle = CopyProgressUpdateThrottle()

        tasks[itemID] = Task {
            do {
                let totalBytes = try await CopyWorker.totalByteCount(for: sourceURL)
                updateTotalBytes(totalBytes, for: itemID)

                try await CopyWorker.perform(
                    operation,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    overwrite: shouldOverwrite
                ) { copiedBytes in
                    guard progressThrottle.shouldPublish() else {
                        return
                    }
                    Task { @MainActor in
                        self.updateCopiedBytes(copiedBytes, for: itemID)
                    }
                }

                complete(itemID)
            } catch is CancellationError {
                markCancelled(itemID)
            } catch {
                fail(itemID, message: error.localizedDescription)
            }
        }
    }

    private func updateTotalBytes(_ totalBytes: Int64, for itemID: CopyQueueItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        items[index].totalBytes = totalBytes
    }

    private func updateCopiedBytes(_ copiedBytes: Int64, for itemID: CopyQueueItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].state == .running else {
            return
        }

        items[index].copiedBytes = copiedBytes
        if let startedAt = items[index].startedAt {
            let elapsed = max(Date().timeIntervalSince(startedAt), 0.1)
            items[index].bytesPerSecond = Double(copiedBytes) / elapsed
        }
    }

    private func complete(_ itemID: CopyQueueItem.ID) {
        tasks[itemID] = nil
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            startAvailableCopies()
            return
        }

        let sourceURL = items[index].sourceURL
        let destinationURL = items[index].destinationURL
        let operation = items[index].operation
        let historyItem = CopyQueueHistoryItem(
            id: UUID(),
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            name: items[index].name,
            operation: operation,
            totalBytes: items[index].totalBytes,
            completedAt: Date()
        )
        items.remove(at: index)
        if historyLimit > 0 {
            history.insert(historyItem, at: 0)
            trimHistory()
        }
        aggregateFinishedItemCount += 1
        itemCompletionObservers.forEach { $0(destinationURL) }
        if operation == .move {
            moveCompletionObservers.forEach { $0(sourceURL) }
        }
        startAvailableCopies()
    }

    private func markCancelled(_ itemID: CopyQueueItem.ID) {
        tasks[itemID] = nil
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            startAvailableCopies()
            return
        }

        guard items[index].state.isActive else {
            startAvailableCopies()
            return
        }

        items[index].state = .cancelled
        aggregateFinishedItemCount += 1
        startAvailableCopies()
    }

    private func fail(_ itemID: CopyQueueItem.ID, message: String) {
        tasks[itemID] = nil
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            startAvailableCopies()
            return
        }

        guard items[index].state.isActive else {
            startAvailableCopies()
            return
        }

        items[index].state = .failed(message)
        aggregateFinishedItemCount += 1
        startAvailableCopies()
    }

    private func appendToQueue(_ newItems: [CopyQueueItem]) {
        if !hasActiveOperations {
            aggregateTotalItemCount = 0
            aggregateFinishedItemCount = 0
        }

        aggregateTotalItemCount += newItems.count
        items.append(contentsOf: newItems)
    }

    private func trimHistory() {
        if history.count > historyLimit {
            history = Array(history.prefix(historyLimit))
        }
    }
}

nonisolated private final class CopyProgressUpdateThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPublishTime = Date.distantPast

    func shouldPublish() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        guard now.timeIntervalSince(lastPublishTime) >= 0.25 else {
            return false
        }

        lastPublishTime = now
        return true
    }
}

typealias CopyWorker = SafeFileOperations
