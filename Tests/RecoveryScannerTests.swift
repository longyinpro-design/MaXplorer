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
        for replacementIsDirectory in [true, false] {
            await test("recovery scanner rejects replaced \(replacementIsDirectory ? "directory" : "file") residue") { dir in
                let residueURL = try directory(dir, ".maxplorer-transfer-replaced")
                _ = try file(residueURL, "old", "old")
                let scanned = RecoveryScanner.scan(in: [dir])
                try expect(scanned.count == 1, "original residue missing")
                // Keep the original inode alive so replacement cannot reuse it.
                try fm.moveItem(at: residueURL, to: dir.appendingPathComponent("original"))
                if replacementIsDirectory {
                    _ = try directory(dir, residueURL.lastPathComponent)
                    _ = try file(residueURL, "keep", "replacement")
                } else {
                    _ = try file(dir, residueURL.lastPathComponent, "replacement")
                }
                var rejected = false
                do { try RecoveryScanner.remove(scanned[0]) } catch { rejected = true }
                try expect(rejected, "cleanup accepted a different object at scanned path")
                try expect(fm.fileExists(atPath: residueURL.path), "replacement was deleted")
                try expect(contents(dir.appendingPathComponent("original/old")) == "old", "original residue data changed")
                let replacement = replacementIsDirectory ? residueURL.appendingPathComponent("keep") : residueURL
                try expect(contents(replacement) == "replacement", "replacement content changed")
            }
        }

        await test("recovery scanner removes nested and dangling links without touching targets") { dir in
            let victim = try directory(dir, "victim")
            _ = try file(victim, "keep", "safe")
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: victim.path)
            let residue = try directory(dir, ".maxplorer-transfer-nested")
            let nested = try directory(residue, "nested")
            try fm.createSymbolicLink(at: nested.appendingPathComponent("outside"), withDestinationURL: victim)
            try fm.createSymbolicLink(at: nested.appendingPathComponent("dangling"), withDestinationURL: dir.appendingPathComponent("absent"))
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: nested.path)
            try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: residue.path)
            let dangling = dir.appendingPathComponent(".maxplorer-probe-dangling")
            try fm.createSymbolicLink(at: dangling, withDestinationURL: dir.appendingPathComponent("missing"))
            let scanned = RecoveryScanner.scan(in: [dir])
            try expect(scanned.count == 2, "dangling residue missing")
            for item in scanned { try RecoveryScanner.remove(item) }
            try expect(!fm.fileExists(atPath: residue.path), "nested residue survived")
            try expect((try? fm.destinationOfSymbolicLink(atPath: dangling.path)) == nil, "dangling residue survived")
            try expect(contents(victim.appendingPathComponent("keep")) == "safe", "outside target changed")
            let mode = try fm.attributesOfItem(atPath: victim.path)[.posixPermissions] as? NSNumber
            try expect(mode?.uint16Value == 0o500, "outside directory permissions changed")
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: victim.path)
        }
        await test("recovery scanner restores inaccessible directory permissions for cleanup") { dir in
            let residue = try directory(dir, ".maxplorer-backup-inaccessible")
            let child = try directory(residue, "child")
            _ = try file(child, "payload", "old")
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: child.path)
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: residue.path)
            let scanned = RecoveryScanner.scan(in: [dir])
            try expect(scanned.count == 1, "inaccessible residue missing")
            try RecoveryScanner.remove(scanned[0])
            try expect(!fm.fileExists(atPath: residue.path), "inaccessible residue survived")
        }
    }
}
