import Foundation
import Combine
import Darwin

enum CopyConflictResolution {
    case overwrite
    case overwriteAll
    case keepBoth
    case keepBothAll
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

    var canRetry: Bool {
        switch self {
        case .failed, .cancelled:
            return true
        case .pending, .running, .completed:
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
    /// Groups every item enqueued by one paste/duplicate/move so undo can
    /// restore the whole batch with a single ⌘Z.
    let batchID: UUID
    let sourceURL: URL
    var destinationURL: URL
    var name: String
    var shouldOverwrite: Bool
    var approval: SafeFileOperations.ConflictApproval? = nil
    let operation: CopyQueueOperation
    var state: CopyQueueItemState
    var totalBytes: Int64
    var copiedBytes: Int64
    var bytesPerSecond: Double
    var startedAt: Date?
    var transferPhase: TransferControl.Phase = .transferring
    var transferRevision: UInt64 = 0

    var progress: Double {
        guard totalBytes > 0 else {
            return state == .completed ? 1 : 0
        }

        return min(1, Double(copiedBytes) / Double(totalBytes))
    }

    var estimatedSecondsRemaining: TimeInterval? {
        guard state == .running, transferPhase == .transferring, bytesPerSecond > 0, totalBytes > copiedBytes else {
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
    @Published private(set) var isPaused = false

    private var itemCompletionObservers: [(URL, URL, CopyQueueOperation, Bool, UUID) -> Void] = []
    private var moveCompletionObservers: [(URL) -> Void] = []
    private var batchCompletionObservers: [(UUID) -> Void] = []

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

    private let recordDestinations: @MainActor ([URL]) -> Void

    init(recordDestinations: @escaping @MainActor ([URL]) -> Void = { RecentTransferDestinations.shared.record($0) }) {
        self.recordDestinations = recordDestinations
    }

    private var tasks: [CopyQueueItem.ID: Task<Void, Never>] = [:]
    private var controls: [CopyQueueItem.ID: TransferControl] = [:]
    private var attempts: [CopyQueueItem.ID: UUID] = [:]
    private var isShuttingDown = false
    private var aggregateTotalItemCount = 0
    private var aggregateFinishedItemCount = 0

    var reservedDestinationURLs: Set<URL> {
        Set(items.filter { $0.state.isActive }.map(\.destinationURL))
    }

    var hasItems: Bool {
        !items.isEmpty
    }

    var activeCopyCount: Int {
        items.filter { $0.state.isActive }.count
    }

    var hasActiveOperations: Bool {
        activeCopyCount > 0
    }

    var failedCount: Int {
        items.filter { $0.state.canRetry }.count
    }

    var canPause: Bool {
        !isPaused && hasActiveOperations
    }

    var canResume: Bool {
        isPaused && hasActiveOperations
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

    func observeItemCompletions(_ observer: @escaping (URL, URL, CopyQueueOperation, Bool, UUID) -> Void) {
        itemCompletionObservers.append(observer)
    }

    func observeMoveCompletions(_ observer: @escaping (URL) -> Void) {
        moveCompletionObservers.append(observer)
    }

    /// Called once when no item of a batch is pending or running anymore, so
    /// undo can record the finished batch as one history entry.
    func observeBatchCompletions(_ observer: @escaping (UUID) -> Void) {
        batchCompletionObservers.append(observer)
    }

    func hasActiveItems(inBatch batchID: UUID) -> Bool {
        items.contains { $0.batchID == batchID && $0.state.isActive }
    }

    func enqueue(_ sources: [URL], to destinationDirectory: URL, conflictResolution: CopyConflictResolution) {
        guard conflictResolution != .cancel else {
            return
        }

        let batchID = UUID()
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
                batchID: batchID,
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
        let batchID = UUID()
        let destinationDirectory = destinationDirectory.standardizedFileURL
        let newItems = resolvedItems.compactMap { (sourceURL, shouldOverwrite) -> CopyQueueItem? in
            let source = sourceURL.standardizedFileURL
            guard source.deletingLastPathComponent() != destinationDirectory else {
                return nil
            }
            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            return CopyQueueItem(
                id: UUID(),
                batchID: batchID,
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
        let batchID = UUID()
        let destinationDirectory = destinationDirectory.standardizedFileURL
        let newItems = resolvedItems.compactMap { sourceURL, shouldOverwrite -> CopyQueueItem? in
            let source = sourceURL.standardizedFileURL
            guard source.deletingLastPathComponent() != destinationDirectory else {
                return nil
            }

            return CopyQueueItem(
                id: UUID(),
                batchID: batchID,
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

    func enqueueResolved(_ resolvedItems: [ResolvedTransferItem], operation: CopyQueueOperation) {
        let batchID = UUID()
        let newItems = resolvedItems.map { item in
            CopyQueueItem(
                id: UUID(), batchID: batchID,
                sourceURL: item.source.standardizedFileURL, destinationURL: item.destination.standardizedFileURL,
                name: item.destination.lastPathComponent, shouldOverwrite: item.shouldOverwrite,
                approval: item.approval, operation: operation, state: .pending,
                totalBytes: 0, copiedBytes: 0, bytesPerSecond: 0, startedAt: nil
            )
        }
        guard !newItems.isEmpty else { return }
        appendToQueue(newItems)
        startAvailableCopies()
    }

    func enqueueDuplicates(_ items: [(source: URL, destination: URL)]) {
        let batchID = UUID()
        let newItems = items.map { sourceURL, destinationURL -> CopyQueueItem in
            CopyQueueItem(
                id: UUID(),
                batchID: batchID,
                sourceURL: sourceURL.standardizedFileURL,
                destinationURL: destinationURL.standardizedFileURL,
                name: destinationURL.lastPathComponent,
                shouldOverwrite: false,
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

    func cancel(_ itemID: CopyQueueItem.ID) {
        guard let item = items.first(where: { $0.id == itemID }), item.state.isActive else {
            return
        }
        if item.state == .running {
            // Keep ownership and the running slot until the worker acknowledges
            // cancellation, or finishes a publication that already committed.
            controls[itemID]?.cancel()
            tasks[itemID]?.cancel()
        } else {
            markCancelled(itemID)
        }
    }

    func pauseItem(_ itemID: CopyQueueItem.ID) {
        guard items.contains(where: { $0.id == itemID && $0.state == .running }) else { return }
        controls[itemID]?.requestPause()
    }

    func resumeItem(_ itemID: CopyQueueItem.ID) {
        controls[itemID]?.resume()
    }

    /// Normal quit cancels and wakes paused workers, then waits asynchronously
    /// for actual cleanup/commit acknowledgements before the process exits.
    func cancelAllAndWait() async {
        isShuttingDown = true
        isPaused = true
        let running = Array(tasks.values)
        for item in items where item.state.isActive { cancel(item.id) }
        for task in running { await task.value }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        startAvailableCopies()
    }

    func retry(_ itemID: CopyQueueItem.ID, shouldOverwrite: Bool? = nil, approval: SafeFileOperations.ConflictApproval? = nil) {
        guard !isShuttingDown else { return }
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].state.canRetry else {
            return
        }

        // Approval belongs to this attempt. A failed attempt may be retried
        // after another writer has replaced the target, so never reuse it.
        items[index].shouldOverwrite = shouldOverwrite ?? false
        items[index].approval = approval
        guard resetForRetry(itemID) else { return }
        startAvailableCopies()
    }

    func retry(_ itemID: CopyQueueItem.ID, resolved: ResolvedTransferItem) {
        guard !isShuttingDown else { return }
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].state.canRetry, items[index].sourceURL == resolved.source.standardizedFileURL else { return }
        items[index].destinationURL = resolved.destination.standardizedFileURL
        items[index].name = resolved.destination.lastPathComponent
        retry(itemID, shouldOverwrite: resolved.shouldOverwrite, approval: resolved.approval)
    }

    func retryNeedsOverwrite(_ itemID: CopyQueueItem.ID) -> Bool {
        guard let item = items.first(where: { $0.id == itemID }),
              item.state.canRetry else {
            return false
        }

        return SafeFileOperations.entryExists(at: item.destinationURL)
    }

    func retryAllFailed() {
        guard !isShuttingDown else { return }
        let failedIDs = items
            .filter { $0.state.canRetry && !retryNeedsOverwrite($0.id) }
            .map(\.id)
        guard !failedIDs.isEmpty else { return }

        for itemID in failedIDs {
            if let index = items.firstIndex(where: { $0.id == itemID }) {
                items[index].shouldOverwrite = false
                items[index].approval = nil
            }
            _ = resetForRetry(itemID)
        }
        startAvailableCopies()
    }

    func dismiss(_ itemID: CopyQueueItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              !items[index].state.isActive else {
            return
        }

        tasks[itemID] = nil
        items.remove(at: index)
        aggregateTotalItemCount = max(0, aggregateTotalItemCount - 1)
        aggregateFinishedItemCount = max(0, aggregateFinishedItemCount - 1)
        if items.isEmpty {
            aggregateTotalItemCount = 0
            aggregateFinishedItemCount = 0
        }
    }

    private func resetForRetry(_ itemID: CopyQueueItem.ID) -> Bool {
        guard !isShuttingDown else { return false }
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].state.canRetry else {
            return false
        }

        recordDestinations([items[index].destinationURL.deletingLastPathComponent()])
        tasks[itemID] = nil
        aggregateFinishedItemCount = max(0, aggregateFinishedItemCount - 1)
        items[index].state = .pending
        items[index].totalBytes = 0
        items[index].copiedBytes = 0
        items[index].bytesPerSecond = 0
        items[index].startedAt = nil
        items[index].transferPhase = .transferring
        items[index].transferRevision = 0
        return true
    }

    private func startAvailableCopies() {
        guard !isPaused, !isShuttingDown else { return }

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
        let approval = items[index].approval
        let attempt = UUID()
        attempts[itemID] = attempt
        let control = TransferControl { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.updateTransferState(snapshot, for: itemID, attempt: attempt)
            }
        }
        controls[itemID] = control
        let progressThrottle = CopyProgressUpdateThrottle()

        tasks[itemID] = Task {
            do {
                try await CopyWorker.perform(
                    operation,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    overwrite: shouldOverwrite,
                    approval: approval,
                    control: control,
                    totalBytes: { total in
                        Task { @MainActor in
                            self.updateTotalBytes(total, for: itemID, attempt: attempt)
                        }
                    }
                ) { copiedBytes in
                    guard progressThrottle.shouldPublish() else {
                        return
                    }
                    Task { @MainActor in
                        self.updateCopiedBytes(copiedBytes, for: itemID, attempt: attempt)
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

    private func updateTransferState(_ snapshot: TransferControl.Snapshot, for itemID: CopyQueueItem.ID, attempt: UUID) {
        guard attempts[itemID] == attempt,
              let index = items.firstIndex(where: { $0.id == itemID }), items[index].state == .running,
              snapshot.revision >= items[index].transferRevision else { return }
        items[index].transferRevision = snapshot.revision
        items[index].transferPhase = snapshot.phase
        if snapshot.phase != .transferring { items[index].bytesPerSecond = 0 }
    }

    private func updateTotalBytes(_ totalBytes: Int64, for itemID: CopyQueueItem.ID, attempt: UUID) {
        guard attempts[itemID] == attempt else { return }
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            return
        }

        items[index].totalBytes = totalBytes
    }

    private func updateCopiedBytes(_ copiedBytes: Int64, for itemID: CopyQueueItem.ID, attempt: UUID) {
        guard attempts[itemID] == attempt else { return }
        guard let index = items.firstIndex(where: { $0.id == itemID }),
              items[index].state == .running else {
            return
        }

        items[index].copiedBytes = copiedBytes
        if let snapshot = controls[itemID]?.snapshot {
            items[index].bytesPerSecond = snapshot.phase == .transferring
                ? Double(copiedBytes) / max(snapshot.activeElapsed, 0.1) : 0
        }
    }

    private func complete(_ itemID: CopyQueueItem.ID) {
        controls[itemID] = nil
        attempts[itemID] = nil
        tasks[itemID] = nil
        guard let index = items.firstIndex(where: { $0.id == itemID }) else {
            startAvailableCopies()
            return
        }

        let sourceURL = items[index].sourceURL
        let destinationURL = items[index].destinationURL
        let operation = items[index].operation
        let shouldOverwrite = items[index].shouldOverwrite
        let batchID = items[index].batchID
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
        itemCompletionObservers.forEach { $0(sourceURL, destinationURL, operation, shouldOverwrite, batchID) }
        if operation == .move {
            moveCompletionObservers.forEach { $0(sourceURL) }
        }
        notifyBatchSettled(batchID)
        startAvailableCopies()
    }

    private func markCancelled(_ itemID: CopyQueueItem.ID) {
        controls[itemID] = nil
        attempts[itemID] = nil
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
        notifyBatchSettled(items[index].batchID)
        startAvailableCopies()
    }

    private func fail(_ itemID: CopyQueueItem.ID, message: String) {
        controls[itemID] = nil
        attempts[itemID] = nil
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
        notifyBatchSettled(items[index].batchID)
        startAvailableCopies()
    }

    private func notifyBatchSettled(_ batchID: UUID) {
        guard !hasActiveItems(inBatch: batchID) else { return }
        batchCompletionObservers.forEach { $0(batchID) }
    }

    private func appendToQueue(_ newItems: [CopyQueueItem]) {
        guard !isShuttingDown else { return }
        // Failed/cancelled entries still belong to this progress cohort: a
        // later retry must share the denominator with newly enqueued work.
        if items.isEmpty {
            aggregateTotalItemCount = 0
            aggregateFinishedItemCount = 0
        }

        recordDestinations(newItems.map { $0.destinationURL.deletingLastPathComponent() })
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
