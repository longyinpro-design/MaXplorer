import Foundation

extension FileOperationTests {
    static func transferControlTests() async {
        await test("transfer control pause is acknowledged only at checkpoint") { _ in
            let events = TransferControlEvents()
            let control = TransferControl(onChange: { events.record($0) })
            defer { control.cancel() }
            try expect(control.snapshot.phase == .transferring && control.snapshot.revision == 0, "wrong initial state")
            try expect(control.requestPause(), "pause rejected while transferring")
            try expect(control.snapshot.phase == .pauseRequested, "request falsely acknowledged paused")
            try expect(!control.requestPause(), "duplicate request reported a new transition")
            let worker = Task.detached { () -> Bool in
                do { try control.checkpoint(); return true } catch { return false }
            }
            try transferExpect(await transferWait(events, .paused), "worker did not acknowledge pause")
            try expect(control.snapshot.phase == .paused, "pause wait ended prematurely")
            let pausedRevision = control.snapshot.revision
            do {
                try control.resumeDataPhaseAfterCrossVolumeFallback()
                throw TestFailure.assertion("paused EXDEV transition accepted")
            } catch TransferControl.TransitionError.invalidPhase(let phase) {
                try expect(phase == .paused, "wrong paused rejection")
            }
            try expect(control.snapshot.revision == pausedRevision, "paused EXDEV rejection mutated state")
            control.resume()
            control.resume()
            try transferExpect(await worker.value, "resume failed to release worker")
            try expect(events.snapshots.map(\.phase) == [.pauseRequested, .paused, .transferring], "duplicate or missing transitions")
        }
        await test("transfer control resume withdraws an unacknowledged request") { _ in
            let events = TransferControlEvents()
            let control = TransferControl(onChange: { events.record($0) })
            try expect(control.requestPause(), "request rejected")
            control.resume()
            try await Task.detached { try control.checkpoint() }.value
            try expect(control.snapshot.phase == .transferring, "withdrawn pause blocked worker")
            try expect(events.snapshots.map(\.phase) == [.pauseRequested, .transferring], "withdrawal acknowledged a pause")
        }
        await test("transfer control cancellation before work wins over resume") { _ in
            let events = TransferControlEvents()
            let control = TransferControl(onChange: { events.record($0) })
            control.cancel()
            control.cancel()
            control.resume()
            try expect(!control.requestPause(), "cancelled control accepted pause")
            do { try control.checkpoint(); throw TestFailure.assertion("cancelled checkpoint returned") }
            catch is CancellationError {}
            do { try control.beginFinalization(); throw TestFailure.assertion("cancelled finalization returned") }
            catch is CancellationError {}
            try expect(events.snapshots.map(\.phase) == [.cancelling], "cancellation was reversed or duplicated")
        }
        await test("transfer control cancellation wakes a paused worker") { _ in
            let events = TransferControlEvents()
            let control = TransferControl(onChange: { events.record($0) })
            defer { control.cancel() }
            control.requestPause()
            let worker = Task.detached { () -> Bool in
                do { try control.checkpoint(); return false } catch is CancellationError { return true } catch { return false }
            }
            try transferExpect(await transferWait(events, .paused), "worker did not wait")
            control.cancel()
            control.resume()
            try transferExpect(await worker.value, "paused worker did not receive cancellation")
            try expect(control.snapshot.phase == .cancelling, "resume overrode cancellation")
        }
        await test("transfer control finish is idempotent and wakes paused workers") { _ in
            let events = TransferControlEvents()
            let control = TransferControl(onChange: { events.record($0) })
            defer { control.cancel() }
            control.requestPause()
            let worker = Task.detached { () -> Bool in
                do { try control.checkpoint(); return false } catch is CancellationError { return true } catch { return false }
            }
            try transferExpect(await transferWait(events, .paused), "worker did not wait")
            control.finish()
            let frozen = control.snapshot
            control.finish()
            control.resume()
            control.cancel()
            try transferExpect(await worker.value, "finished worker remained blocked")
            try expect(control.snapshot == frozen && !control.requestPause(), "finished control changed")
        }
        await test("transfer control finalization closes pause gate atomically") { _ in
            let events = TransferControlEvents()
            let control = TransferControl(onChange: { events.record($0) })
            try control.beginFinalization()
            try expect(control.snapshot.phase == .finalizing, "finalization missing")
            try expect(!control.requestPause(), "pause accepted during publication")
            control.resume()
            try control.checkpoint()
            try control.beginFinalization()
            try expect(events.snapshots.map(\.phase) == [.finalizing], "finalization repeated state transition")
            control.cancel()
            do { try control.checkpoint(); throw TestFailure.assertion("finalization ignored cancellation") }
            catch is CancellationError {}
        }
        await test("transfer control finalization waits for a prior pause") { _ in
            let events = TransferControlEvents()
            let control = TransferControl(onChange: { events.record($0) })
            defer { control.cancel() }
            control.requestPause()
            let worker = Task.detached { () -> Bool in
                do { try control.beginFinalization(); return true } catch { return false }
            }
            try transferExpect(await transferWait(events, .paused), "finalization did not acknowledge existing pause")
            try expect(control.snapshot.phase == .paused, "finalization bypassed prior pause")
            control.resume()
            try transferExpect(await worker.value, "resumed finalization failed")
            try expect(control.snapshot.phase == .finalizing && !control.requestPause(), "finalization gate not closed")
        }
        await test("transfer control callbacks can reenter snapshot and resume") { _ in
            let box = TransferControlBox()
            let events = TransferControlEvents()
            let control = TransferControl(onChange: { snapshot in
                events.record(snapshot)
                guard let value = box.value else { return }
                _ = value.snapshot
                if snapshot.phase == .pauseRequested { value.resume() }
            })
            box.value = control
            defer { box.value = nil; control.cancel() }
            let changed = await Task.detached { control.requestPause() }.value
            try expect(changed && control.snapshot.phase == .transferring, "reentrant callback deadlocked or lost resume")
            try expect(events.snapshots.map(\.revision) == [1, 2], "reentrant callback revisions wrong")
        }
        await test("transfer control paused callback cancellation cannot lose wakeup") { _ in
            let box = TransferControlBox()
            let events = TransferControlEvents()
            let control = TransferControl(onChange: { snapshot in
                events.record(snapshot)
                if snapshot.phase == .paused { box.value?.cancel() }
            })
            box.value = control
            defer { box.value = nil; control.cancel() }
            control.requestPause()
            let cancelled = await Task.detached { () -> Bool in
                do { try control.checkpoint(); return false } catch is CancellationError { return true } catch { return false }
            }.value
            try expect(cancelled && control.snapshot.phase == .cancelling, "callback cancellation lost wakeup")
        }
        await test("transfer control active time excludes acknowledged pauses and freezes at finish") { _ in
            let clock = TransferControlClock(100)
            let events = TransferControlEvents()
            let control = TransferControl(clock: { clock.now }, onChange: { events.record($0) })
            defer { control.cancel() }
            clock.now = 105
            control.requestPause()
            clock.now = 109
            let worker = Task.detached { try control.checkpoint() }
            try transferExpect(await transferWait(events, .paused), "worker did not acknowledge timed pause")
            clock.now = 1000
            try expect(control.snapshot.activeElapsed == 9, "paused wall time was counted")
            clock.now = 1005
            control.resume()
            try await worker.value
            clock.now = 1010
            try expect(control.snapshot.activeElapsed == 14, "resume did not subtract acknowledged pause")
            clock.now = 1012
            control.finish()
            clock.now = 2000
            try expect(control.snapshot.activeElapsed == 16, "finished elapsed continued advancing")
            try expect(events.snapshots.map(\.revision) == [1, 2, 3, 4], "timed transitions revisions wrong")
        }
        await test("transfer control EXDEV fallback restores data pause checkpoints") { _ in
            let events = TransferControlEvents()
            let control = TransferControl(onChange: { events.record($0) })
            defer { control.cancel() }
            try control.beginFinalization()
            try control.resumeDataPhaseAfterCrossVolumeFallback()
            try expect(control.snapshot.phase == .transferring && control.snapshot.revision == 2, "EXDEV did not restore data phase")
            try expect(control.requestPause(), "EXDEV fallback no longer accepts pause")
            let worker = Task.detached { try control.checkpoint() }
            try transferExpect(await transferWait(events, .paused), "EXDEV fallback skipped pause checkpoint")
            control.resume()
            try await worker.value
            try control.beginFinalization()
            try expect(events.snapshots.map(\.phase) == [.finalizing, .transferring, .pauseRequested, .paused, .transferring, .finalizing], "EXDEV transitions wrong")
        }
        await test("transfer control EXDEV fallback rejects other phases without mutation") { _ in
            let control = TransferControl()
            for phase in [TransferControl.Phase.transferring, .pauseRequested] {
                if phase == .pauseRequested { control.requestPause() }
                let revision = control.snapshot.revision
                do {
                    try control.resumeDataPhaseAfterCrossVolumeFallback()
                    throw TestFailure.assertion("invalid EXDEV transition accepted")
                } catch TransferControl.TransitionError.invalidPhase(let actual) {
                    try expect(actual == phase, "wrong rejected phase")
                }
                try expect(control.snapshot.phase == phase && control.snapshot.revision == revision, "rejected EXDEV mutated state")
            }
            control.cancel()
            do { try control.resumeDataPhaseAfterCrossVolumeFallback(); throw TestFailure.assertion("cancelled EXDEV transition accepted") }
            catch is CancellationError {}
            try expect(control.snapshot.phase == .cancelling, "EXDEV undid cancellation")
            control.finish()
            do { try control.resumeDataPhaseAfterCrossVolumeFallback(); throw TestFailure.assertion("finished EXDEV transition accepted") }
            catch is CancellationError {}
        }
        await test("transfer control pause versus finalization race has a single winner") { _ in
            for _ in 0..<100 {
                let box = TransferControlBox()
                let events = TransferControlEvents()
                let gate = TransferControlGate()
                let control = TransferControl(onChange: { snapshot in
                    events.record(snapshot)
                    if snapshot.phase == .paused { box.value?.resume() }
                })
                box.value = control
                let pause = Task.detached { gate.wait(); return control.requestPause() }
                let finalize = Task.detached { () -> Bool in
                    gate.wait()
                    do { try control.beginFinalization(); return true } catch { return false }
                }
                gate.open()
                let requested = await pause.value
                let finalized = await finalize.value
                let ordered = events.snapshots.sorted { $0.revision < $1.revision }
                try expect(finalized && control.snapshot.phase == .finalizing, "race did not finish finalizing")
                try expect(ordered.map(\.phase) == (requested ? [.pauseRequested, .paused, .transferring, .finalizing] : [.finalizing]), "race bypassed acknowledged pause")
                try expect(!control.requestPause(), "race left pause gate open")
                box.value = nil
                control.finish()
            }
        }
    }
}

@MainActor private func transferWait(_ events: TransferControlEvents, _ phase: TransferControl.Phase) async -> Bool {
    await Task.detached { events.wait(for: phase) }.value
}

nonisolated private final class TransferControlEvents: @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [TransferControl.Snapshot] = []
    var snapshots: [TransferControl.Snapshot] {
        condition.lock(); defer { condition.unlock() }; return values
    }
    func record(_ value: TransferControl.Snapshot) {
        condition.lock(); values.append(value); condition.broadcast(); condition.unlock()
    }
    func wait(for phase: TransferControl.Phase) -> Bool {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(3)
        while !values.contains(where: { $0.phase == phase }) {
            if !condition.wait(until: deadline) { return values.contains(where: { $0.phase == phase }) }
        }
        return true
    }
}

nonisolated private final class TransferControlBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TransferControl?
    var value: TransferControl? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

nonisolated private final class TransferControlClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TimeInterval
    init(_ value: TimeInterval) { stored = value }
    var now: TimeInterval {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

nonisolated private final class TransferControlGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var ready = false
    func wait() { condition.lock(); while !ready { condition.wait() }; condition.unlock() }
    func open() { condition.lock(); ready = true; condition.broadcast(); condition.unlock() }
}

nonisolated private func transferExpect(_ condition: Bool, _ message: String) throws {
    try expect(condition, message)
}
