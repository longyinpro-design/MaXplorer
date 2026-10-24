import Foundation

extension FileOperationTests {
    static func queueControlTests() async {
        await test("queue pause prevents new work and resume drains it") { dir in
            let a = try file(dir, "a")
            let b = try file(dir, "b")
            let destination = try directory(dir, "destination")
            let queue = CopyQueueViewModel()
            queue.maximumConcurrentCopies = 1
            queue.pause()
            queue.enqueue([(a, false), (b, false)], to: destination)

            try await Task.sleep(for: .milliseconds(300))
            try expect(queue.isPaused, "queue should stay paused")
            try expect(queue.items.count == 2, "enqueue while paused must retain items")
            try expect(queue.items.allSatisfy { $0.state == .pending }, "paused queue started work")
            try expect(queue.history.isEmpty, "paused queue completed work")

            queue.resume()
            try await waitFor { !queue.hasActiveOperations }
            try expect(queue.history.count == 2, "resume did not drain both items")
            try expect(queue.items.isEmpty, "completed items should leave the active queue")
        }

        await test("queue retry re-runs a failed item after the conflict is removed") { dir in
            let source = try file(dir, "source", "new")
            let destination = try directory(dir, "destination")
            let target = try file(destination, "source", "old")
            let queue = CopyQueueViewModel()
            queue.maximumConcurrentCopies = 1
            queue.enqueue([(source, false)], to: destination)

            try await waitFor { queue.failedCount == 1 }
            guard let failedItem = queue.items.first else {
                throw TestFailure.assertion("failed item disappeared")
            }
            try expect(contents(target) == "old", "failed retry changed the old target")
            try expect(failedItem.state.canRetry, "failed item must be retryable")

            try fm.removeItem(at: target)
            queue.retry(failedItem.id)
            try await waitFor { queue.history.count == 1 }
            try expect(contents(destination.appendingPathComponent("source")) == "new", "retry did not copy content")
            try expect(queue.items.isEmpty, "successful retry should leave the active queue")
        }

        await test("queue duplicate copies to an explicit destination name") { dir in
            let source = try file(dir, "source", "content")
            let destination = dir.appendingPathComponent("source copy")
            let queue = CopyQueueViewModel()
            queue.maximumConcurrentCopies = 1
            queue.enqueueDuplicates([(source: source, destination: destination)])

            try await waitFor { !queue.hasActiveOperations }
            try expect(contents(destination) == "content", "duplicate content mismatch")
            try expect(queue.history.count == 1 && queue.history[0].name == "source copy", "duplicate history mismatch")
            try expect(contents(source) == "content", "duplicate removed the source")
        }

        await test("queue retry reports a destination conflict before overwriting") { dir in
            let source = try file(dir, "source", "new")
            let destination = try directory(dir, "destination")
            let target = try file(destination, "source", "old")
            let queue = CopyQueueViewModel()
            queue.maximumConcurrentCopies = 1
            queue.enqueue([(source, false)], to: destination)

            try await waitFor { queue.failedCount == 1 }
            guard let failedItem = queue.items.first else {
                throw TestFailure.assertion("failed item disappeared")
            }
            try expect(queue.retryNeedsOverwrite(failedItem.id), "retry did not flag an existing destination")

            queue.retry(failedItem.id, shouldOverwrite: true)
            try await waitFor { queue.history.count == 1 }
            try expect(contents(target) == "new", "confirmed retry did not overwrite")
            try expect(queue.items.isEmpty, "confirmed retry left the item active")
        }

        await test("queue dismiss removes a failed item without a completion record") { dir in
            let source = try file(dir, "source")
            let destination = try directory(dir, "destination")
            _ = try file(destination, "source", "old")
            let queue = CopyQueueViewModel()
            queue.maximumConcurrentCopies = 1
            queue.enqueue([(source, false)], to: destination)

            try await waitFor { queue.failedCount == 1 }
            guard let failedItem = queue.items.first else {
                throw TestFailure.assertion("failed item disappeared")
            }
            queue.dismiss(failedItem.id)
            try expect(queue.items.isEmpty, "dismiss did not remove the failed item")
            try expect(queue.history.isEmpty, "dismiss created a false history entry")
            try expect(!queue.hasActiveOperations, "dismiss left the queue active")
        }

        await test("queue retry all works while paused and starts only after resume") { dir in
            let a = try file(dir, "a", "new-a")
            let b = try file(dir, "b", "new-b")
            let destination = try directory(dir, "destination")
            _ = try file(destination, "a", "old-a")
            _ = try file(destination, "b", "old-b")
            let queue = CopyQueueViewModel()
            queue.maximumConcurrentCopies = 2
            queue.enqueue([(a, false), (b, false)], to: destination)

            try await waitFor { queue.failedCount == 2 }
            try fm.removeItem(at: destination.appendingPathComponent("a"))
            try fm.removeItem(at: destination.appendingPathComponent("b"))

            queue.pause()
            queue.retryAllFailed()
            try await Task.sleep(for: .milliseconds(250))
            try expect(queue.items.count == 2 && queue.items.allSatisfy { $0.state == .pending },
                       "retry all started while paused")

            queue.resume()
            try await waitFor { !queue.hasActiveOperations }
            try expect(queue.history.count == 2, "retry all did not complete both items")
            try expect(contents(destination.appendingPathComponent("a")) == "new-a", "retry all missed a")
            try expect(contents(destination.appendingPathComponent("b")) == "new-b", "retry all missed b")
        }
    }
}
