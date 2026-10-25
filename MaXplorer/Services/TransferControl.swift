import Foundation

/// Cooperative, process-local control for one transfer worker. Checkpoints and
/// beginFinalization() must be called outside any filesystem mutation lock.
nonisolated final class TransferControl: @unchecked Sendable {
    enum Phase: Equatable, Sendable {
        case transferring, pauseRequested, paused, finalizing, cancelling, finished
    }

    enum TransitionError: Error, Equatable, Sendable {
        case invalidPhase(Phase)
    }

    struct Snapshot: Equatable, Sendable {
        let phase: Phase
        let revision: UInt64
        let activeElapsed: TimeInterval
    }

    private let condition = NSCondition()
    private let onChange: @Sendable (Snapshot) -> Void
    private let clock: @Sendable () -> TimeInterval
    private let startedAt: TimeInterval
    private var phase: Phase = .transferring
    private var revision: UInt64 = 0
    private var pausedAt: TimeInterval?
    private var pausedDuration: TimeInterval = 0
    private var finishedAt: TimeInterval?

    convenience init(onChange: @escaping @Sendable (Snapshot) -> Void = { _ in }) {
        self.init(clock: { ProcessInfo.processInfo.systemUptime }, onChange: onChange)
    }

    // Injecting a monotonic clock keeps pause accounting tests deterministic.
    init(clock: @escaping @Sendable () -> TimeInterval,
         onChange: @escaping @Sendable (Snapshot) -> Void = { _ in }) {
        self.clock = clock
        self.onChange = onChange
        startedAt = clock()
    }

    var snapshot: Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return snapshotLocked(at: clock())
    }

    @discardableResult
    func requestPause() -> Bool {
        condition.lock()
        guard phase == .transferring else { condition.unlock(); return false }
        let change = transitionLocked(to: .pauseRequested)
        condition.unlock()
        onChange(change)
        return true
    }

    func resume() {
        condition.lock()
        guard phase == .pauseRequested || phase == .paused else { condition.unlock(); return }
        let change = transitionLocked(to: .transferring)
        condition.broadcast()
        condition.unlock()
        onChange(change)
    }

    func cancel() {
        condition.lock()
        guard phase != .cancelling && phase != .finished else { condition.unlock(); return }
        let change = transitionLocked(to: .cancelling)
        condition.broadcast()
        condition.unlock()
        onChange(change)
    }

    /// A pause request is acknowledged here, on the worker. Waiting releases
    /// the condition lock and never holds a filesystem publication lock.
    func checkpoint() throws { try passCheckpoint(finalizing: false) }

    /// Atomically closes the pause gate. If a request won the race, first
    /// acknowledge and wait for it; then enter finalizing under the same lock.
    func beginFinalization() throws { try passCheckpoint(finalizing: true) }

    /// Only the engine may call this after an exclusive rename failed with
    /// EXDEV before publishing anything. Copying data must regain checkpoints.
    func resumeDataPhaseAfterCrossVolumeFallback() throws {
        condition.lock()
        switch phase {
        case .finalizing:
            let change = transitionLocked(to: .transferring)
            condition.unlock()
            onChange(change)
        case .cancelling, .finished:
            condition.unlock()
            throw CancellationError()
        default:
            let rejectedPhase = phase
            condition.unlock()
            throw TransitionError.invalidPhase(rejectedPhase)
        }
    }

    func finish() {
        condition.lock()
        guard phase != .finished else { condition.unlock(); return }
        let change = transitionLocked(to: .finished)
        condition.broadcast()
        condition.unlock()
        onChange(change)
    }

    private func passCheckpoint(finalizing: Bool) throws {
        condition.lock()
        while true {
            switch phase {
            case .cancelling, .finished:
                condition.unlock()
                throw CancellationError()
            case .pauseRequested:
                let change = transitionLocked(to: .paused)
                // The callback can re-enter resume/cancel/snapshot. Reacquire
                // and recheck before waiting so that no wakeup can be lost.
                condition.unlock()
                onChange(change)
                condition.lock()
            case .paused:
                condition.wait()
            case .transferring:
                if finalizing {
                    let change = transitionLocked(to: .finalizing)
                    condition.unlock()
                    onChange(change)
                } else {
                    condition.unlock()
                }
                return
            case .finalizing:
                condition.unlock()
                return
            }
        }
    }

    private func transitionLocked(to next: Phase) -> Snapshot {
        let now = clock()
        if let pausedAt {
            pausedDuration += now - pausedAt
            self.pausedAt = nil
        }
        if next == .paused { pausedAt = now }
        if next == .finished { finishedAt = now }
        phase = next
        revision += 1
        return snapshotLocked(at: now)
    }

    private func snapshotLocked(at now: TimeInterval) -> Snapshot {
        let end = finishedAt ?? now
        let currentPause = pausedAt.map { end - $0 } ?? 0
        return Snapshot(phase: phase, revision: revision,
                        activeElapsed: max(0, end - startedAt - pausedDuration - currentPause))
    }
}
