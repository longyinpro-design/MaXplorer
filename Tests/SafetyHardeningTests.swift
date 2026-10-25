import Foundation
import Darwin

extension FileOperationTests {
    static func safetyHardeningTests() async {
        for operation in [CopyQueueOperation.copy, .move] {
            await test("fault injected publish failure rolls back old target: \(operation)") { dir in
                let source = try file(dir, "source", "new")
                let target = try file(dir, "target", "old")
                let message = try await injectedTransferFailure(
                    [.publishPayload: EIO], operation: operation, source: source, target: target
                )
                try expect(!message.isEmpty, "failure lacked a diagnostic")
                try expect(contents(source) == "new", "failed publish removed source")
                try expect(contents(target) == "old", "rollback did not restore old target")
                try expectNoTransferResidue(in: dir)
            }

            await test("fault injected rollback failure preserves reported backup: \(operation)") { dir in
                let source = try file(dir, "source", "new")
                let target = try file(dir, "target", "old")
                let message = try await injectedTransferFailure(
                    [.publishPayload: EIO, .rollbackBackup: EACCES],
                    operation: operation, source: source, target: target
                )
                let backups = try residues(in: dir, prefix: ".maxplorer-backup-")
                try expect(backups.count == 1, "old target recovery backup missing")
                try expect(contents(backups[0]) == "old", "backup lost old target data")
                try expect(message.contains(backups[0].path), "recovery path absent from error")
                try expect(contents(source) == "new", "failed rollback removed source")
                try expect(!SafeFileOperations.entryExists(at: target), "failed publication claimed target")
                let staging = try residues(in: dir, prefix: ".maxplorer-transfer-")
                try expect(staging.isEmpty, "unpublished replica was not cleaned")
            }
        }

        for fallback in [false, true] {
            await test("fault injected directory permissions failure retains recovery: fallback=\(fallback)") { dir in
                let source = try directory(dir, "source")
                _ = try file(source, "new.txt", "new")
                let target = try directory(dir, "target")
                _ = try file(target, "old.txt", "old")
                let message = try await injectedTransferFailure(
                    [.restorePermissions: EPERM], operation: .move,
                    source: source, target: target, fallback: fallback
                )
                try expect(contents(source.appendingPathComponent("new.txt")) == "new", "source removed before permission restoration")
                try expect(contents(target.appendingPathComponent("new.txt")) == "new", "complete publication lost")
                let staging = try residues(in: dir, prefix: ".maxplorer-transfer-")
                try expect(staging.count == 1 && message.contains(staging[0].path), "staging recovery path missing")
                let oldLocation: URL
                if fallback {
                    let backups = try residues(in: dir, prefix: ".maxplorer-backup-")
                    try expect(backups.count == 1 && message.contains(backups[0].path), "backup recovery path missing")
                    oldLocation = backups[0]
                } else {
                    oldLocation = staging[0].appendingPathComponent("payload")
                }
                try expect(contents(oldLocation.appendingPathComponent("old.txt")) == "old", "old target recovery data lost")
            }
        }

        for point in [SafeFileOperations.FailurePoint.cleanupStaging, .cleanupBackup] {
            await test("fault injected committed cleanup failure retains backup: \(point)") { dir in
                let source = try file(dir, "source", "new")
                let target = try file(dir, "target", "old")
                let message = try await injectedTransferFailure(
                    [point: EACCES], operation: .copy, source: source, target: target
                )
                let backups = try residues(in: dir, prefix: ".maxplorer-backup-")
                try expect(backups.count == 1 && contents(backups[0]) == "old", "cleanup failure lost old backup")
                try expect(message.contains(backups[0].path), "retained backup path absent")
                try expect(contents(source) == "new" && contents(target) == "new", "cleanup damaged complete files")
                let staging = try residues(in: dir, prefix: ".maxplorer-transfer-")
                if point == .cleanupStaging {
                    try expect(staging.count == 1 && message.contains(staging[0].path), "staging cleanup failure not reported")
                } else {
                    try expect(staging.isEmpty, "staging not cleaned before backup")
                }
            }
        }

        for code in [ENOSPC, ENOTCONN, ETIMEDOUT, EHOSTDOWN] {
            await test("fault injected mid-copy error preserves both originals: errno=\(code)") { dir in
                let source = dir.appendingPathComponent("source")
                let data = Data(repeating: 0x5a, count: 2 * 1024 * 1024)
                try data.write(to: source)
                let target = try file(dir, "target", "old")
                let message = try await injectedTransferFailure(
                    [.copyData: code], operation: .move, source: source, target: target
                )
                let sourceData = try Data(contentsOf: source)
                try expect(sourceData == data, "mid-copy failure changed source")
                try expect(contents(target) == "old", "mid-copy failure published incomplete target")
                if code == ENOSPC {
                    try expect(message.contains("需要") && message.contains("可用"), "space diagnostic lacks capacity: \(message)")
                } else {
                    try expect(message.contains("连接中断"), "network error not classified: \(message)")
                }
                try expectNoTransferResidue(in: dir)
                // A retry after a transient failure must use a fresh attempt.
                try await SafeFileOperations.perform(.copy, sourceURL: source, destinationURL: target,
                                                     overwrite: true, progress: { _ in })
                let targetData = try Data(contentsOf: target)
                try expect(targetData == data, "retry did not publish complete data")
            }
        }

        await test("forced swap fallback overwrites a file and cleans the backup") { dir in
            SafeFileOperations.setForcedSwapFallbackForTesting(true)
            defer { SafeFileOperations.setForcedSwapFallbackForTesting(false) }

            let source = try file(dir, "source", "new")
            let target = try file(dir, "target", "old")

            try await SafeFileOperations.perform(
                .copy,
                sourceURL: source,
                destinationURL: target,
                overwrite: true,
                progress: { _ in }
            )

            try expect(contents(target) == "new", "fallback did not publish new content")
            try expect(contents(source) == "new", "fallback removed the source")
            try expectNoTransferResidue(in: dir)
        }

        await test("forced swap fallback overwrites a directory and cleans the backup") { dir in
            SafeFileOperations.setForcedSwapFallbackForTesting(true)
            defer { SafeFileOperations.setForcedSwapFallbackForTesting(false) }

            let source = try directory(dir, "source")
            _ = try file(source, "new.txt", "new")
            let target = try directory(dir, "target")
            _ = try file(target, "old.txt", "old")

            try await SafeFileOperations.perform(
                .copy,
                sourceURL: source,
                destinationURL: target,
                overwrite: true,
                progress: { _ in }
            )

            try expect(contents(target.appendingPathComponent("new.txt")) == "new", "fallback directory content mismatch")
            try expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("old.txt").path), "fallback kept old content")
            try expectNoTransferResidue(in: dir)
        }

        await test("forced swap fallback keeps the old target when the source is missing") { dir in
            SafeFileOperations.setForcedSwapFallbackForTesting(true)
            defer { SafeFileOperations.setForcedSwapFallbackForTesting(false) }

            let target = try file(dir, "target", "old")
            try await mustFail {
                try await SafeFileOperations.perform(
                    .copy,
                    sourceURL: dir.appendingPathComponent("missing"),
                    destinationURL: target,
                    overwrite: true,
                    progress: { _ in }
                )
            }

            try expect(contents(target) == "old", "fallback failure damaged the old target")
            try expectNoTransferResidue(in: dir)
        }
    }

    private static func residues(in directory: URL, prefix: String) throws -> [URL] {
        try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private static func injectedTransferFailure(
        _ failures: [SafeFileOperations.FailurePoint: Int32],
        operation: CopyQueueOperation, source: URL, target: URL, fallback: Bool = true
    ) async throws -> String {
        SafeFileOperations.setForcedSwapFallbackForTesting(fallback)
        SafeFileOperations.setFailuresForTesting(failures)
        defer {
            SafeFileOperations.setForcedSwapFallbackForTesting(false)
            SafeFileOperations.setFailuresForTesting([:])
        }
        var failure: Error?
        do {
            try await SafeFileOperations.perform(operation, sourceURL: source,
                                                 destinationURL: target, overwrite: true,
                                                 progress: { _ in })
        } catch { failure = error }
        guard let failure else { throw TestFailure.assertion("fault-injected operation succeeded") }
        for point in failures.keys {
            try expect(SafeFileOperations.observedFailureForTesting(point), "failure point was not exercised: \(point)")
        }
        return failure.localizedDescription
    }

    static func expectNoTransferResidue(in dir: URL) throws {
        let entries = try fm.contentsOfDirectory(atPath: dir.path)
        let residue = entries.filter {
            $0.hasPrefix(".maxplorer-transfer-")
                || $0.hasPrefix(".maxplorer-backup-")
                || $0.hasPrefix(".maxplorer-probe-")
        }
        try expect(residue.isEmpty, "transfer residue left behind: \(residue)")
    }
}
