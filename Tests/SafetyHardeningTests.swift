import Foundation

extension FileOperationTests {
    static func safetyHardeningTests() async {
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
