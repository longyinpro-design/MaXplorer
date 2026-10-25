import Foundation
import Darwin

extension FileOperationTests {
    static func transferConflictPlannerTests() async {
        await test("conflict planner reserves names across batch and canonical queue aliases") { dir in
            let first = try directory(dir, "first")
            let second = try directory(dir, "second")
            let destination = try directory(dir, "destination")
            let a = try file(first, "Résumé.txt")
            let b = try file(second, "Résumé.txt")
            let plan = try await Task.detached {
                try TransferConflictPlanner.preflight(sources: [a, b], destinationDirectory: destination, reserved: [])
            }.value
            try expect(plan.approvedItems.count == 1 && plan.conflicts.count == 1, "batch name collision missed")
            try expect(plan.conflicts[0].isReserved, "batch collision offered overwrite")
            let alias = dir.appendingPathComponent("alias")
            try fm.createSymbolicLink(at: alias, withDestinationURL: destination)
            let reserved = alias.appendingPathComponent("RE\u{301}SUMÉ.TXT")
            let queued = try await Task.detached {
                try TransferConflictPlanner.preflight(sources: [a], destinationDirectory: destination, reserved: [reserved])
            }.value
            try expect(queued.approvedItems.isEmpty && queued.conflicts.first?.isReserved == true,
                       "canonical/case/NFC queue reservation missed")
        }

        await test("conflict planner disk conflict remains distinct from queue reservation") { dir in
            let source = try file(dir, "source.txt")
            let destination = try directory(dir, "destination")
            let target = try file(destination, "source.txt", "old")
            let plan = try await Task.detached {
                try TransferConflictPlanner.preflight(sources: [source], destinationDirectory: destination, reserved: [])
            }.value
            try expect(plan.approvedItems.isEmpty && plan.conflicts.count == 1, "disk conflict approved silently")
            try expect(plan.conflicts[0].destination == target && !plan.conflicts[0].isReserved, "disk conflict misclassified")
        }

        await test("conflict keep both plans file and package names and never overwrites racer") { dir in
            let source = try file(dir, "report.tar.gz", "new")
            let destination = try directory(dir, "destination")
            let target = try file(destination, source.lastPathComponent, "old")
            let resolved = try await Task.detached {
                try TransferConflictPlanner.keepBoth(for: source, in: destination, reserved: [])
            }.value
            try expect(resolved.destination.lastPathComponent == "report.tar copy.gz", "compound extension rule changed")
            let queue = CopyQueueViewModel(recordDestinations: { _ in })
            queue.pause()
            queue.enqueueResolved([resolved], operation: .copy)
            _ = try file(destination, resolved.destination.lastPathComponent, "racer")
            queue.resume()
            try await waitFor { !queue.hasActiveOperations }
            try expect(queue.failedCount == 1 && queue.history.isEmpty, "exclusive name race reported success")
            try expect(contents(target) == "old" && contents(resolved.destination) == "racer" && contents(source) == "new",
                       "name race changed existing data")
            try noStaging(destination)
            let package = try directory(dir, "Example.app")
            let renamed = try await Task.detached {
                try TransferConflictPlanner.keepBoth(for: package, in: destination, reserved: [destination.appendingPathComponent("Example.app copy")])
            }.value
            try expect(renamed.destination.lastPathComponent == "Example.app copy 2", "package name/reservation lost")
        }

        for operation in [CopyQueueOperation.copy, .move] {
            await test("conflict keep both queue and undo use actual destination \(operation)") { dir in
                let source = try file(dir, "source.txt", "new")
                let destination = try directory(dir, "destination")
                let original = try file(destination, "source.txt", "old")
                let resolved = try await Task.detached {
                    try TransferConflictPlanner.keepBoth(for: source, in: destination, reserved: [])
                }.value
                let queue = CopyQueueViewModel(recordDestinations: { _ in })
                var observed: (URL, URL, Bool)?
                queue.observeItemCompletions { source, target, _, overwritten, _ in observed = (source, target, overwritten) }
                queue.enqueueResolved([resolved], operation: operation)
                try await waitFor { !queue.hasActiveOperations }
                try expect(queue.history.first?.destinationURL == resolved.destination && queue.history.first?.name == "source copy.txt",
                           "history rebuilt original basename")
                try expect(observed?.0 == source && observed?.1 == resolved.destination && observed?.2 == false,
                           "completion supplied wrong undo identity")
                let expected = await FileUndoService.states(of: [resolved.destination])
                let kind: FileUndoKind = operation == .copy
                    ? .copy(created: [resolved.destination], expected: expected)
                    : .move(items: [UndoMovePair(from: source, to: resolved.destination)], expected: expected)
                let outcome = try await FileUndoService.undo(FileUndoEntry(kind: kind))
                guard case .completed = outcome else { throw TestFailure.assertion("keep-both undo incomplete") }
                try expect(contents(original) == "old" && contents(source) == "new" && !fm.fileExists(atPath: resolved.destination.path),
                           "undo changed original conflict or failed to restore source")
            }
        }

        await test("conflict queue rejects changed approval and accepts a freshly compared retry") { dir in
            let source = try file(dir, "source", "new")
            let destination = try directory(dir, "destination")
            let target = try file(destination, "source", "old")
            let comparison = try await SafeFileOperations.captureConflictComparison(sourceURL: source, destinationURL: target)
            let queue = CopyQueueViewModel(recordDestinations: { _ in })
            queue.pause()
            queue.enqueueResolved([ResolvedTransferItem(source: source, destination: target, shouldOverwrite: true, approval: comparison.approval)], operation: .copy)
            try expect(queue.reservedDestinationURLs == [target], "queue did not expose pending reservation")
            _ = try file(destination, "source", "changed after comparison")
            queue.resume()
            try await waitFor { !queue.hasActiveOperations }
            try expect(queue.failedCount == 1 && queue.history.isEmpty && contents(target) == "changed after comparison",
                       "queue reused stale approval")
            let failedID = queue.items[0].id
            let fresh = try await SafeFileOperations.captureConflictComparison(sourceURL: source, destinationURL: target)
            queue.retry(failedID, resolved: ResolvedTransferItem(source: source, destination: target, shouldOverwrite: true, approval: fresh.approval))
            try await waitFor { !queue.hasActiveOperations }
            try expect(queue.history.count == 1 && contents(target) == "new", "fresh retry failed")
            try expect(queue.reservedDestinationURLs.isEmpty, "completed reservation leaked")
        }

        await test("conflict retry keep both resets overwrite approval and records renamed target") { dir in
            let source = try file(dir, "source", "new")
            let destination = try directory(dir, "destination")
            let original = try file(destination, "source", "old")
            let queue = CopyQueueViewModel(recordDestinations: { _ in })
            queue.enqueue([(source, false)], to: destination)
            try await waitFor { queue.failedCount == 1 }
            let resolved = try await Task.detached {
                try TransferConflictPlanner.keepBoth(for: source, in: destination, reserved: [])
            }.value
            queue.retry(queue.items[0].id, resolved: resolved)
            try await waitFor { !queue.hasActiveOperations }
            try expect(contents(original) == "old" && contents(resolved.destination) == "new", "retry overwrote original conflict")
            try expect(queue.history.count == 1 && queue.history[0].destinationURL == resolved.destination, "retry history has old name")
        }
    }
}
