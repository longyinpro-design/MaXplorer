import Foundation

extension FileOperationTests {
    static func recoveryScannerTests() async {
        await test("recovery scanner finds residue and leaves normal items alone") { dir in
            let transfer = try directory(dir, ".maxplorer-transfer-AAAA")
            _ = try file(transfer, "payload", "unpublished")
            let backup = try directory(dir, ".maxplorer-backup-BBBB")
            _ = try file(backup, "old", "old")
            let probe = try directory(dir, ".maxplorer-probe-CCCC")
            let normal = try directory(dir, "normal")
            _ = try file(normal, "keep.txt", "keep")

            let residues = RecoveryScanner.scan(in: [dir])
            try expect(residues.count == 3, "unexpected residue count: \(residues.count)")
            try expect(!residues.contains { $0.name == "normal" }, "normal folder was reported as residue")

            for residue in residues {
                try RecoveryScanner.remove(residue)
            }
            try expect(!FileManager.default.fileExists(atPath: transfer.path), "transfer residue survived")
            try expect(!FileManager.default.fileExists(atPath: backup.path), "backup residue survived")
            try expect(!FileManager.default.fileExists(atPath: probe.path), "probe residue survived")
            try expect(contents(normal.appendingPathComponent("keep.txt")) == "keep", "normal folder was modified")
        }

        await test("recovery scanner removes a symlink residue without following it") { dir in
            let victim = try file(dir, "victim", "safe")
            let link = dir.appendingPathComponent(".maxplorer-transfer-link")
            try fm.createSymbolicLink(at: link, withDestinationURL: victim)

            let residues = RecoveryScanner.scan(in: [dir])
            try expect(residues.count == 1, "symlink residue was not detected")
            try RecoveryScanner.remove(residues[0])

            try expect(contents(victim) == "safe", "recovery cleanup followed the symlink")
            try expect(!FileManager.default.fileExists(atPath: link.path), "symlink residue survived")
        }
    }
}
