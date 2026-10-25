import Foundation
import Darwin

nonisolated private final class TransferPauseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Int64 = 0
    private var requested = false
    var bytes: Int64 { lock.lock(); defer { lock.unlock() }; return latest }
    func progress(_ bytes: Int64, total: Int64, control: TransferControl) {
        lock.lock()
        latest = bytes
        let shouldPause = !requested && bytes > 0 && bytes < total
        if shouldPause { requested = true }
        lock.unlock()
        if shouldPause { control.requestPause() }
    }
}

extension FileOperationTests {
    static func transferPauseTests() async {
        for overwrite in [false, true] {
            await test("transfer pause real file preserves bytes then resumes overwrite \(overwrite)") { dir in
                let data = Data(repeating: 0x6D, count: 32 * 1024 * 1024)
                let source = dir.appendingPathComponent("source")
                try data.write(to: source)
                let destination = try directory(dir, "destination")
                let target = destination.appendingPathComponent("target")
                if overwrite { try Data("old".utf8).write(to: target) }
                let control = TransferControl()
                let probe = TransferPauseProbe()
                let task = Task {
                    try await SafeFileOperations.perform(.copy, sourceURL: source, destinationURL: target,
                        overwrite: overwrite, control: control) { bytes in
                            probe.progress(bytes, total: Int64(data.count), control: control)
                        }
                }
                do {
                    try await waitFor { control.snapshot.phase == .paused }
                    let bytes = probe.bytes
                    try expect(bytes > 0 && bytes < data.count, "pause was not inside actual data copying")
                    let elapsed = control.snapshot.activeElapsed
                    try await Task.sleep(for: .milliseconds(80))
                    try expect(probe.bytes == bytes, "data progress advanced while acknowledged paused")
                    try expect(abs(control.snapshot.activeElapsed - elapsed) < 0.01, "pause counted as active transfer time")
                    try expect(overwrite ? contents(target) == "old" : !fm.fileExists(atPath: target.path), "paused operation published target")
                    // A paused copy cannot hold the global publication lock.
                    let other = try file(dir, "other", "independent")
                    try await SafeFileOperations.perform(.copy, sourceURL: other,
                        destinationURL: destination.appendingPathComponent("other"), overwrite: false) { _ in }
                    control.resume()
                    try await task.value
                    let targetData = try Data(contentsOf: target)
                    let sourceData = try Data(contentsOf: source)
                    try expect(targetData == data, "resumed payload changed")
                    try expect(sourceData == data, "copy modified source")
                    try expect(control.snapshot.phase == .finished && !control.requestPause(), "finished transfer accepted pause")
                    print("TRANSFER_PAUSE bytes_at_pause=\(bytes) total=\(data.count) overwrite=\(overwrite)")
                    try noStaging(destination)
                } catch {
                    control.cancel(); task.cancel(); _ = try? await task.value
                    throw error
                }
            }
        }

        for mutateSource in [false, true] {
            await test("transfer pause cancellation or changed source preserves old target mutate \(mutateSource)") { dir in
                let data = Data(repeating: 0x4B, count: 32 * 1024 * 1024)
                let source = dir.appendingPathComponent("source")
                try data.write(to: source)
                let destination = try directory(dir, "destination")
                let target = try file(destination, "target", "old")
                let control = TransferControl()
                let probe = TransferPauseProbe()
                let task = Task {
                    try await SafeFileOperations.perform(.copy, sourceURL: source, destinationURL: target,
                        overwrite: true, control: control) { bytes in
                            probe.progress(bytes, total: Int64(data.count), control: control)
                        }
                }
                do {
                    try await waitFor { control.snapshot.phase == .paused }
                    if mutateSource {
                        let handle = try FileHandle(forWritingTo: source)
                        try handle.seekToEnd(); try handle.write(contentsOf: Data([0x22])); try handle.close()
                        control.resume()
                    } else {
                        // Cancel only the async task: the engine's cancellation
                        // handler must wake the condition without an explicit resume.
                        task.cancel()
                    }
                    try await mustFail { try await task.value }
                    try expect(contents(target) == "old", "cancel/change replaced old target")
                    let actual = try Data(contentsOf: source)
                    try expect(actual.count == data.count + (mutateSource ? 1 : 0) && actual.prefix(data.count) == data,
                               "cancel/change removed source bytes")
                    try noStaging(destination)
                } catch {
                    control.cancel(); task.cancel(); _ = try? await task.value
                    throw error
                }
            }
        }

        await test("transfer pause same volume move finishes without holding pause gate") { dir in
            let source = try file(dir, "source", "move")
            let target = dir.appendingPathComponent("target")
            let control = TransferControl()
            try await SafeFileOperations.perform(.move, sourceURL: source, destinationURL: target,
                overwrite: false, control: control) { _ in }
            try expect(control.snapshot.phase == .finished && !control.requestPause(), "fast move left pause gate open")
            try expect(contents(target) == "move" && !fm.fileExists(atPath: source.path), "fast move changed semantics")
        }

        await test("transfer pause queue keeps slot and queue resume does not resume individual item") { dir in
            let a = try file(dir, "a")
            let b = try file(dir, "b")
            let destination = try directory(dir, "destination")
            let queue = CopyQueueViewModel(recordDestinations: { _ in })
            do {
                queue.maximumConcurrentCopies = 1
                queue.enqueue([(a, false), (b, false)], to: destination)
                let id = queue.items[0].id
                queue.pauseItem(id)
                try await waitFor { queue.items.first { $0.id == id }?.transferPhase == .paused }
                queue.pause(); queue.resume()
                try await Task.sleep(for: .milliseconds(50))
                try expect(queue.items.first { $0.id == id }?.state == .running, "paused worker lost ownership")
                try expect(queue.items.filter { $0.state == .running }.count == 1 && queue.items[1].state == .pending,
                           "paused worker slot was reused")
                try expect(queue.items[0].bytesPerSecond == 0 && queue.items[0].estimatedSecondsRemaining == nil, "paused speed or ETA shown")
                queue.pause()
                queue.resumeItem(id)
                try await waitFor { queue.history.count == 1 }
                try expect(queue.items.count == 1 && queue.items[0].state == .pending, "item resume bypassed queue scheduling pause")
                queue.resume()
                try await waitFor { !queue.hasActiveOperations }
                try expect(queue.history.count == 2, "queue/item resume combination failed")
            } catch {
                await queue.cancelAllAndWait()
                throw error
            }
        }

        await test("transfer pause queue width three keeps one paused slot while other workers drain") { dir in
            let sources = try (0..<5).map { try file(dir, "concurrent-\($0)", "payload-\($0)") }
            let destination = try directory(dir, "destination")
            let queue = CopyQueueViewModel(recordDestinations: { _ in })
            do {
                queue.maximumConcurrentCopies = 3
                queue.enqueue(sources.map { ($0, false) }, to: destination)
                let pausedID = queue.items[0].id
                queue.pauseItem(pausedID)
                try await waitFor { queue.items.first { $0.id == pausedID }?.transferPhase == .paused }
                try await waitFor { queue.history.count == 4 }
                try expect(queue.items.count == 1 && queue.items[0].id == pausedID && queue.items[0].state == .running,
                           "paused owner was released or other workers could not finish")
                try expect(queue.reservedDestinationURLs == [destination.appendingPathComponent(sources[0].lastPathComponent)],
                           "paused destination reservation lost")
                queue.resumeItem(pausedID)
                try await waitFor { !queue.hasActiveOperations }
                try expect(queue.history.count == 5 && Set(queue.history.map(\.sourceURL)).count == 5,
                           "concurrent resume produced lost or duplicate completion")
                try noStaging(destination)
            } catch {
                await queue.cancelAllAndWait()
                throw error
            }
        }

        await test("transfer pause queue cancel wakes worker and retry uses fresh control") { dir in
            let source = try file(dir, "source", "payload")
            let destination = try directory(dir, "destination")
            let queue = CopyQueueViewModel(recordDestinations: { _ in })
            do {
                queue.enqueue([(source, false)], to: destination)
                let id = queue.items[0].id
                queue.pauseItem(id)
                try await waitFor { queue.items.first?.transferPhase == .paused }
                queue.cancel(id)
                try await waitFor { !queue.hasActiveOperations }
                try expect(queue.items.first?.state == .cancelled && queue.history.isEmpty, "paused cancellation made false success")
                try noStaging(destination)
                queue.retry(id)
                try await waitFor { !queue.hasActiveOperations }
                try expect(queue.history.count == 1 && contents(destination.appendingPathComponent("source")) == "payload",
                           "retry reused paused/cancelled control")
            } catch {
                await queue.cancelAllAndWait()
                throw error
            }
        }

        await test("transfer pause queue shutdown cancels paused and pending tasks and drains cleanup") { dir in
            let sources = try (0..<3).map { try file(dir, "item-\($0)") }
            let destination = try directory(dir, "destination")
            let queue = CopyQueueViewModel(recordDestinations: { _ in })
            do {
                queue.maximumConcurrentCopies = 1
                queue.enqueue(sources.map { ($0, false) }, to: destination)
                queue.pauseItem(queue.items[0].id)
                try await waitFor { queue.items.first?.transferPhase == .paused }
                await queue.cancelAllAndWait()
                try expect(!queue.hasActiveOperations && queue.items.allSatisfy { $0.state == .cancelled }, "shutdown did not drain all ownership")
                try expect(queue.history.isEmpty && sources.allSatisfy { fm.fileExists(atPath: $0.path) }, "shutdown lost source/recorded success")
                let cancelledItems = queue.items
                let retryID = queue.items[0].id
                queue.retry(retryID, shouldOverwrite: true)
                queue.retry(retryID, resolved: ResolvedTransferItem(
                    source: sources[0], destination: destination.appendingPathComponent("late renamed target")
                ))
                queue.retryAllFailed()
                try expect(queue.items == cancelledItems && queue.reservedDestinationURLs.isEmpty && queue.history.isEmpty,
                           "shutdown retry revived state, renamed destination or changed ownership/history")
                queue.enqueue([(sources[0], false)], to: destination)
                try expect(!queue.hasActiveOperations, "late preparation enqueued work during shutdown")
                try noStaging(destination)
            } catch {
                await queue.cancelAllAndWait()
                throw error
            }
        }

        if let path = ProcessInfo.processInfo.environment["MAXPLORER_CROSS_VOLUME_ROOT"] {
            for cancel in [false, true] {
                await test("transfer pause actual cross volume move cancel \(cancel)") { dir in
                    let data = Data(repeating: 0x5C, count: 32 * 1024 * 1024)
                    let source = dir.appendingPathComponent("source")
                    try data.write(to: source)
                    let destination = URL(fileURLWithPath: path).appendingPathComponent(UUID().uuidString)
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                    defer { try? fm.removeItem(at: destination) }
                    let target = destination.appendingPathComponent("target")
                    let control = TransferControl()
                    let probe = TransferPauseProbe()
                    let task = Task {
                        try await SafeFileOperations.perform(.move, sourceURL: source, destinationURL: target,
                            overwrite: false, control: control) { bytes in
                                probe.progress(bytes, total: Int64(data.count), control: control)
                            }
                    }
                    do {
                        try await waitFor { control.snapshot.phase == .paused }
                        try expect(probe.bytes > 0 && probe.bytes < data.count && fm.fileExists(atPath: source.path)
                                   && !fm.fileExists(atPath: target.path), "cross-volume pause published early")
                        if cancel { task.cancel(); try await mustFail { try await task.value } }
                        else { control.resume(); try await task.value }
                        try expect(fm.fileExists(atPath: source.path) == cancel, "cross-volume source disposition incorrect")
                        if cancel { try expect(!fm.fileExists(atPath: target.path), "cancel published target") }
                        else { let targetData = try Data(contentsOf: target); try expect(targetData == data, "cross-volume bytes changed") }
                        try noStaging(destination)
                    } catch {
                        control.cancel(); task.cancel(); _ = try? await task.value
                        throw error
                    }
                }
            }
        } else {
            print("NOT_PROVEN transfer pause cross-volume: private second filesystem required")
        }
    }
}
