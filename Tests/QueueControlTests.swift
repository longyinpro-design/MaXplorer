import Foundation

extension FileOperationTests {
    static func queueControlTests() async {
        for operation in [CopyQueueOperation.copy, .move] {
          for concurrency in [1, 3, 5] {
            await test("queue running pause resume \(operation) concurrency \(concurrency)") { dir in
                let destination = try directory(dir, "destination")
                let sources = try (0..<(concurrency * 2 + 2)).map { try file(dir, "item-\($0)", "payload-\($0)") }
                let queue = CopyQueueViewModel()
                queue.maximumConcurrentCopies = concurrency
                if operation == .copy {
                    queue.enqueue(sources.map { ($0, false) }, to: destination)
                } else {
                    queue.enqueueMoves(sources.map { ($0, false) }, to: destination)
                }
                try expect(queue.items.filter { $0.state == .running }.count == concurrency, "initial running width mismatch")
                queue.pause()
                queue.maximumConcurrentCopies = 1
                try await waitFor { !queue.items.contains { $0.state == .running } }
                try expect(queue.history.count == concurrency, "pause killed running work or started pending work")
                try expect(queue.items.allSatisfy { $0.state == .pending }, "paused pending items changed state")
                queue.resume()
                try expect(queue.items.filter { $0.state == .running }.count == 1, "lower concurrency was not applied")
                queue.maximumConcurrentCopies = 5
                try expect(queue.items.filter { $0.state == .running }.count == min(5, concurrency + 2), "higher concurrency did not fill slots")
                try await waitFor { !queue.hasActiveOperations }
                try expect(queue.history.count == sources.count && queue.items.isEmpty, "queue did not drain exactly once")
                try expect(Set(queue.history.map(\.sourceURL)).count == sources.count, "duplicate completion history")
                try expect(queue.overallProgress == 1, "completed progress mismatch")
                for (index, source) in sources.enumerated() {
                    try expect(contents(destination.appendingPathComponent(source.lastPathComponent)) == "payload-\(index)", "copied payload mismatch")
                    try expect(fm.fileExists(atPath: source.path) == (operation == .copy), "source disposition mismatch")
                }
                try noStaging(destination)
            }

            await test("queue paused cancellation and retry \(operation) concurrency \(concurrency)") { dir in
                let destination = try directory(dir, "destination")
                let sources = try (0..<(concurrency * 2 + 2)).map { try file(dir, "item-\($0)") }
                let queue = CopyQueueViewModel()
                queue.maximumConcurrentCopies = concurrency
                if operation == .copy {
                    queue.enqueue(sources.map { ($0, false) }, to: destination)
                } else {
                    queue.enqueueMoves(sources.map { ($0, false) }, to: destination)
                }
                queue.pause()
                let running = queue.items.first { $0.state == .running }!
                let pending = queue.items.first { $0.state == .pending }!
                queue.cancel(running.id)
                queue.cancel(pending.id)
                try await waitFor { !queue.items.contains { $0.state == .running } }
                try expect(queue.items.first { $0.id == running.id }?.state == .cancelled, "running cancellation not acknowledged")
                try expect(queue.items.first { $0.id == pending.id }?.state == .cancelled, "pending cancellation failed")
                try expect(!fm.fileExists(atPath: running.destinationURL.path) && !fm.fileExists(atPath: pending.destinationURL.path), "cancelled item published")
                try expect(queue.history.count == concurrency - 1, "cancellation created completion history")
                queue.retryAllFailed()
                try expect(queue.items.allSatisfy { $0.state == .pending }, "retry started while paused")
                queue.resume()
                try await waitFor { !queue.hasActiveOperations }
                try expect(queue.history.count == sources.count && queue.items.isEmpty, "cancel retry failed to drain")
                try expect(Set(queue.history.map(\.sourceURL)).count == sources.count, "retry duplicated history")
                try expect(queue.overallProgress == 1, "retry progress mismatch")
                try noStaging(destination)
            }
          }
        }

        await test("queue retry alongside a new batch does not finish progress early") { dir in
            let source = try file(dir, "source")
            let destination = try directory(dir, "destination")
            let target = try file(destination, "source", "old")
            let queue = CopyQueueViewModel()
            queue.maximumConcurrentCopies = 1
            queue.enqueue([(source, false)], to: destination)
            try await waitFor { queue.failedCount == 1 }
            let failedID = queue.items[0].id
            try fm.removeItem(at: target)
            queue.pause()
            let second = try file(dir, "second")
            queue.enqueue([(second, false)], to: destination)
            queue.retry(failedID)
            var prematureCompletion = false
            queue.observeItemCompletions { _, _, _, _, _ in
                if queue.hasActiveOperations && queue.overallProgress >= 1 { prematureCompletion = true }
            }
            queue.resume()
            try await waitFor { !queue.hasActiveOperations }
            try expect(!prematureCompletion, "progress reached 100 percent with retry pending")
            try expect(queue.history.count == 2 && queue.overallProgress == 1, "retry/new batch completion mismatch")
        }

        await test("queue repeated retry failure keeps one item and no false history") { dir in
            let source = try file(dir, "source", "new")
            let destination = try directory(dir, "destination")
            let target = try file(destination, "source", "old")
            let queue = CopyQueueViewModel()
            queue.enqueue([(source, false)], to: destination)
            try await waitFor { queue.failedCount == 1 }
            let id = queue.items[0].id
            for _ in 0..<3 {
                queue.retry(id)
                try await waitFor { queue.failedCount == 1 }
                try expect(queue.items.count == 1 && queue.items[0].id == id, "retry duplicated or lost queue item")
                try expect(queue.history.isEmpty && contents(target) == "old", "failed retry changed target/history")
            }
            queue.retry(id, shouldOverwrite: true)
            try await waitFor { !queue.hasActiveOperations }
            try expect(contents(target) == "new" && queue.history.count == 1, "confirmed retry did not complete once")
            queue.retry(id)
            try expect(queue.history.count == 1, "completed item retried twice")
        }

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

        await test("queue retry requires fresh overwrite confirmation after failure") { dir in
            let source = dir.appendingPathComponent("source")
            let destination = try directory(dir, "destination")
            let target = try file(destination, "source", "old")
            let queue = CopyQueueViewModel()
            queue.enqueue([(source, true)], to: destination)
            try await waitFor { queue.failedCount == 1 }
            let item = queue.items[0]
            _ = try file(dir, "source", "new")
            _ = try file(destination, "source", "changed since approval")
            try expect(queue.retryNeedsOverwrite(item.id), "stale overwrite permission was reused")
            queue.retryAllFailed()
            try await Task.sleep(for: .milliseconds(50))
            try expect(contents(target) == "changed since approval", "retry all overwrote a changed destination")
            try expect(queue.history.isEmpty, "unconfirmed retry published history")
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
