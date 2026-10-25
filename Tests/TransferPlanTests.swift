import Foundation

extension FileOperationTests {
    static func transferPlanTests() async {
        if let lowSpacePath = ProcessInfo.processInfo.environment["MAXPLORER_LOW_SPACE_ROOT"] {
            await test("transfer plan low-space real volume blocks copy and move without writes") { dir in
                let lowSpaceRoot = URL(fileURLWithPath: lowSpacePath, isDirectory: true)
                let destination = try directory(lowSpaceRoot, UUID().uuidString)
                defer { try? fm.removeItem(at: destination) }
                let source = dir.appendingPathComponent("source.bin")
                try Data().write(to: source)
                let handle = try FileHandle(forWritingTo: source)
                defer { try? handle.close() }
                let sourceBytes = 32 * 1024 * 1024
                try handle.truncate(atOffset: UInt64(sourceBytes))
                try handle.close()
                let target = try file(destination, "source.bin", "old destination")
                let originalEntries = try fm.contentsOfDirectory(atPath: destination.path).sorted()
                for operation in [CopyQueueOperation.copy, .move] {
                    let plan = try await TransferPlanService.makePlan(
                        sources: [source], destinationDirectory: destination, operation: operation
                    )
                    guard let free = plan.freeBytes else {
                        throw TestFailure.assertion("real low-space volume capacity is unknown")
                    }
                    try expect(plan.requiredBytes == Int64(sourceBytes) && free < plan.requiredBytes,
                               "low-space fixture does not exercise real capacity exhaustion")
                    try expect(!plan.canProceed && !plan.hasEnoughSpace && plan.destinationWritable,
                               "real low-space preflight did not block on capacity")
                    try expect(plan.conflictCount == 1, "existing destination conflict was missed")
                    print("CAPACITY operation=\(operation) freeBytes=\(free) requiredBytes=\(plan.requiredBytes) canProceed=\(plan.canProceed)")
                }
                let remainingEntries = try fm.contentsOfDirectory(atPath: destination.path).sorted()
                let sourceSize = try fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber
                try expect(sourceSize?.intValue == sourceBytes && contents(target) == "old destination",
                           "preflight changed source or existing destination")
                try expect(remainingEntries == originalEntries, "preflight created or removed destination entries")
                try noStaging(destination)
            }
        }

        await test("transfer plan is shown for directories and large batches") { dir in
            let singleFile = try file(dir, "single.txt")
            try expect(!TransferPlanService.shouldShowPlan(for: [singleFile]), "small single file should skip the plan")

            let folder = try directory(dir, "folder")
            try expect(TransferPlanService.shouldShowPlan(for: [folder]), "folder should show the plan")

            var manyFiles: [URL] = []
            for index in 0..<20 {
                manyFiles.append(try file(dir, "file-\(index).txt"))
            }
            try expect(TransferPlanService.shouldShowPlan(for: manyFiles), "20 files should show the plan")
        }

        await test("transfer plan threshold sums all selected file sizes") { dir in
            let sources = [dir.appendingPathComponent("a"), dir.appendingPathComponent("b")]
            for source in sources {
                try Data().write(to: source)
                let handle = try FileHandle(forWritingTo: source)
                try handle.truncate(atOffset: 600_000_000)
                try handle.close()
            }
            try expect(TransferPlanService.shouldShowPlan(for: sources), "aggregate gigabyte threshold was missed")
        }

        await test("transfer plan low capacity blocks staging and unknown capacity permits") { dir in
            let source = try file(dir, "source", "1234567890")
            let destination = try directory(dir, "destination")
            let target = try file(destination, "source", "old")
            for operation in [CopyQueueOperation.copy, .move] {
                let blocked = try await TransferPlanService.makePlan(sources: [source], destinationDirectory: destination, operation: operation, capacity: { _ in 9 })
                try expect(blocked.requiredBytes == 10 && blocked.freeBytes == 9 && !blocked.hasEnoughSpace && !blocked.canProceed, "ENOSPC staging preflight allowed")
                let unknown = try await TransferPlanService.makePlan(sources: [source], destinationDirectory: destination, operation: operation, capacity: { _ in nil })
                try expect(unknown.freeBytes == nil && unknown.canProceed, "unknown capacity blocked transfer")
            }
            try expect(contents(source) == "1234567890" && contents(target) == "old", "preflight mutated filesystem")
            try noStaging(destination)
        }

        await test("transfer plan permission warnings include nested unreadable files") { dir in
            let source = try directory(dir, "source")
            let unreadable = try file(source, "unreadable")
            let destination = try directory(dir, "destination")
            chmod(unreadable.path, 0)
            defer { chmod(unreadable.path, 0o600) }
            let plan = try await TransferPlanService.makePlan(sources: [source], destinationDirectory: destination, operation: .copy)
            try expect(plan.unreadableCount == 1 && !plan.canProceed, "nested unreadable source was not reported")
            chmod(destination.path, 0o500)
            defer { chmod(destination.path, 0o700) }
            let readonly = try await TransferPlanService.makePlan(sources: [], destinationDirectory: destination, operation: .copy)
            try expect(!readonly.destinationWritable && !readonly.canProceed, "read-only destination was allowed")
        }

        await test("transfer plan scans giant directory with progress and cancellation without writes") { dir in
            let source = try directory(dir, "source")
            let destination = try directory(dir, "destination")
            for index in 0..<2048 { _ = try file(source, "item-\(index)", "abc") }
            let progress = ProgressLog()
            let completed = try await TransferPlanService.makePlan(sources: [source], destinationDirectory: destination, operation: .copy, progress: { count, _ in progress.append(Int64(count)) })
            try expect(completed.totalBytes == 6144 && completed.itemCount == 1, "giant directory size mismatch")
            try expect(progress.snapshot.count > 2 && progress.snapshot.last == 2049, "scan progress was not incremental")
            let gate = TransferGate()
            defer { gate.release() }
            let worker = Task.detached {
                try await TransferPlanService.makePlan(sources: [source], destinationDirectory: destination, operation: .copy, progress: { count, _ in
                    if count >= 128 { gate.pause(Int64(count)) }
                })
            }
            try await waitFor { gate.hasEntered }
            worker.cancel()
            gate.release()
            do {
                _ = try await worker.value
                throw TestFailure.assertion("cancelled scan succeeded")
            } catch is CancellationError {}
            let entries = try fm.contentsOfDirectory(atPath: destination.path)
            try expect(entries.isEmpty, "cancelled plan changed destination")
            let sourceEntries = try fm.contentsOfDirectory(atPath: source.path)
            try expect(sourceEntries.count == 2048, "cancelled plan changed source")
        }

        await test("transfer plan does not follow symlink directories") { dir in
            let source = try directory(dir, "source")
            _ = try file(source, "payload", "abc")
            try fm.createSymbolicLink(at: source.appendingPathComponent("loop"), withDestinationURL: source)
            let destination = try directory(dir, "destination")
            let plan = try await TransferPlanService.makePlan(sources: [source], destinationDirectory: destination, operation: .copy)
            try expect(plan.totalBytes == 3 && plan.canProceed, "symlink loop inflated or blocked plan")
        }

        await test("transfer plan computes directory size and copy space") { dir in
            let source = try directory(dir, "source")
            _ = try file(source, "a", "12345")
            _ = try file(source, "b", "67890")
            let destination = try directory(dir, "destination")

            let plan = try await TransferPlanService.makePlan(
                sources: [source],
                destinationDirectory: destination,
                operation: .copy
            )
            try expect(plan.itemCount == 1, "item count mismatch")
            try expect(plan.totalBytes == 10, "directory size mismatch")
            try expect(plan.requiredBytes == 10, "copy should require full size")
            try expect(plan.conflictCount == 0, "unexpected conflicts")
            try expect(plan.destinationWritable, "destination should be writable")
            try expect(plan.canProceed, "plan should be startable")
        }

        await test("transfer plan reserves staging space for same-volume overwrite move") { dir in
            let source = try file(dir, "source", "new contents")
            let destination = try directory(dir, "destination")
            _ = try file(destination, "source", "old")
            let plan = try await TransferPlanService.makePlan(sources: [source], destinationDirectory: destination, operation: .move)
            try expect(plan.requiredBytes == 12, "overwrite move staging was omitted")
        }

        await test("transfer plan rejects a disappeared source") { dir in
            let destination = try directory(dir, "destination")
            try await mustFail {
                _ = try await TransferPlanService.makePlan(sources: [dir.appendingPathComponent("missing")], destinationDirectory: destination, operation: .copy)
            }
            let entries = try fm.contentsOfDirectory(atPath: destination.path)
            try expect(entries.isEmpty, "preflight wrote files")
        }

        await test("same-volume move requires no additional space") { dir in
            let source = try file(dir, "source", "abc")
            let destination = try directory(dir, "destination")

            let plan = try await TransferPlanService.makePlan(
                sources: [source],
                destinationDirectory: destination,
                operation: .move
            )
            try expect(plan.requiredBytes == 0, "same-volume move should not require extra space")
            try expect(plan.totalBytes == 3, "source size mismatch")
        }

        await test("transfer plan reports destination conflicts") { dir in
            let source = try file(dir, "source", "new")
            let destination = try directory(dir, "destination")
            _ = try file(destination, "source", "old")

            let plan = try await TransferPlanService.makePlan(
                sources: [source],
                destinationDirectory: destination,
                operation: .copy
            )
            try expect(plan.conflictCount == 1, "conflict was not detected")
        }
    }
}
