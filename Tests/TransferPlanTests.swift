import Foundation

extension FileOperationTests {
    static func transferPlanTests() async {
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
