import Foundation
import Darwin

extension FileOperationTests {
    static func exclusiveCapabilityTests() async {
        await test("exclusive capability records a real successful move") { dir in
            SafeFileOperations.resetExclusiveCapabilitiesForTesting()
            defer { SafeFileOperations.resetExclusiveCapabilitiesForTesting() }
            let source = try file(dir, "source", "new")
            let target = dir.appendingPathComponent("target")
            try await CopyWorker.perform(.move, sourceURL: source, destinationURL: target, overwrite: false) { _ in }
            try expect(SafeFileOperations.exclusiveCapabilityForTesting(at: dir) == true, "success was not observed")
            try expect(contents(target) == "new" && !SafeFileOperations.entryExists(at: source), "real move did not complete")
            try expectNoTransferResidue(in: dir)
        }

        await test("exclusive capability real EEXIST preserves both files and stays unknown") { dir in
            SafeFileOperations.resetExclusiveCapabilitiesForTesting()
            defer { SafeFileOperations.resetExclusiveCapabilitiesForTesting() }
            let source = try file(dir, "source", "new")
            let target = try file(dir, "target", "old")
            let code = try SafeFileOperations.renameExclusiveForTesting(from: source, to: target)
            try expect(code == EEXIST, "real exclusive rename did not reject existing target")
            try expect(SafeFileOperations.exclusiveCapabilityForTesting(at: dir) == nil, "EEXIST polluted capability")
            try expect(contents(source) == "new" && contents(target) == "old", "EEXIST changed files")
        }

        await test("exclusive capability unsupported move retains POSIX error and source") { dir in
            SafeFileOperations.resetExclusiveCapabilitiesForTesting()
            SafeFileOperations.setFailuresForTesting([.renameExclusive: ENOTSUP])
            defer {
                SafeFileOperations.setFailuresForTesting([:])
                SafeFileOperations.resetExclusiveCapabilitiesForTesting()
            }
            let source = try file(dir, "source", "new")
            let target = dir.appendingPathComponent("target")
            var failure: NSError?
            do {
                try await CopyWorker.perform(.move, sourceURL: source, destinationURL: target, overwrite: false) { _ in }
            } catch { failure = error as NSError }
            try expect(failure?.domain == NSPOSIXErrorDomain && failure?.code == Int(ENOTSUP), "unsupported diagnostic changed POSIX identity")
            try expect(failure?.localizedDescription.contains("不支持排他重命名") == true, "unsupported capability diagnostic missing")
            try expect(contents(source) == "new" && !SafeFileOperations.entryExists(at: target), "failed move changed files")
        }

        for code in [ENOTSUP, ENOSYS, EXDEV, EEXIST, EACCES, EINVAL] {
            await test("exclusive capability classifies errno \(code) without moving data") { dir in
                SafeFileOperations.resetExclusiveCapabilitiesForTesting()
                SafeFileOperations.setFailuresForTesting([.renameExclusive: code])
                defer {
                    SafeFileOperations.setFailuresForTesting([:])
                    SafeFileOperations.resetExclusiveCapabilitiesForTesting()
                }
                let source = try file(dir, "source", "new")
                let target = dir.appendingPathComponent("target")
                let actual = try SafeFileOperations.renameExclusiveForTesting(from: source, to: target)
                try expect(actual == code, "rename errno changed")
                try expect(SafeFileOperations.observedFailureForTesting(.renameExclusive), "helper injection was not reached")
                let expected: Bool? = code == ENOTSUP || code == ENOSYS ? false : nil
                try expect(SafeFileOperations.exclusiveCapabilityForTesting(at: dir) == expected, "unrelated error polluted capability")
                try expect(contents(source) == "new" && !SafeFileOperations.entryExists(at: target), "failed attempt changed files")
            }
        }

        await test("exclusive capability negative observation still retries real rename") { dir in
            SafeFileOperations.resetExclusiveCapabilitiesForTesting()
            SafeFileOperations.setFailuresForTesting([.renameExclusive: ENOTSUP])
            defer {
                SafeFileOperations.setFailuresForTesting([:])
                SafeFileOperations.resetExclusiveCapabilitiesForTesting()
            }
            let source = try file(dir, "source", "new")
            let target = dir.appendingPathComponent("target")
            let unsupported = try SafeFileOperations.renameExclusiveForTesting(from: source, to: target)
            try expect(unsupported == ENOTSUP, "unsupported fixture failed")
            try expect(SafeFileOperations.exclusiveCapabilityForTesting(at: dir) == false, "negative observation missing")
            try await CopyWorker.perform(.move, sourceURL: source, destinationURL: target, overwrite: false) { _ in }
            try expect(contents(target) == "new" && !SafeFileOperations.entryExists(at: source), "negative cache blocked retry")
            try expect(SafeFileOperations.exclusiveCapabilityForTesting(at: dir) == true, "real success did not refresh negative observation")
            try expectNoTransferResidue(in: dir)
        }

        await test("exclusive capability negative observation permits real backup rollback") { dir in
            SafeFileOperations.resetExclusiveCapabilitiesForTesting()
            SafeFileOperations.setFailuresForTesting([.renameExclusive: ENOSYS])
            SafeFileOperations.setForcedSwapFallbackForTesting(true)
            defer {
                SafeFileOperations.setForcedSwapFallbackForTesting(false)
                SafeFileOperations.setFailuresForTesting([:])
                SafeFileOperations.resetExclusiveCapabilitiesForTesting()
            }
            let source = try file(dir, "source", "new")
            let target = try file(dir, "target", "old")
            let unused = dir.appendingPathComponent("unused")
            let unsupported = try SafeFileOperations.renameExclusiveForTesting(from: source, to: unused)
            try expect(unsupported == ENOSYS, "unsupported fixture failed")
            SafeFileOperations.setFailuresForTesting([.publishPayload: EIO])
            try await mustFail { try await copy(source, target) }
            try expect(SafeFileOperations.observedFailureForTesting(.publishPayload), "publication failure not reached")
            try expect(contents(source) == "new" && contents(target) == "old", "backup rollback failed after negative observation")
            try expect(SafeFileOperations.exclusiveCapabilityForTesting(at: dir) == true, "actual backup and rollback not observed")
            try expectNoTransferResidue(in: dir)
        }
    }
}
