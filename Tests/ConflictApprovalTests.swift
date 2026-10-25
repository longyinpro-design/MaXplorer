import Darwin
import Foundation

extension FileOperationTests {
    static func conflictApprovalTests() async {
        for operation in [CopyQueueOperation.copy, .move] {
            await test("conflict approval unchanged \(operation == .copy ? "copy" : "move") passes with comparison details") { dir in
                let source = try directory(dir, "source")
                _ = try file(source, "new.txt", "new data")
                let target = try directory(dir, "target")
                _ = try file(target, "old.txt", "old")
                let comparison = try await SafeFileOperations.captureConflictComparison(sourceURL: source, destinationURL: target)
                try expect(comparison.source.name == "source" && comparison.source.kind == "文件夹", "source details incorrect")
                try expect(comparison.source.byteCount == 8 && comparison.destination.byteCount == 3, "tree byte counts incorrect")
                try expect(comparison.source.modifiedAt.timeIntervalSince1970 > 0, "modification date missing")
                try await SafeFileOperations.perform(operation, sourceURL: source, destinationURL: target, overwrite: true, approval: comparison.approval) { _ in }
                try expect(contents(target.appendingPathComponent("new.txt")) == "new data", "approved payload missing")
                try expect(!fm.fileExists(atPath: target.appendingPathComponent("old.txt").path), "old target survived")
                try expect(fm.fileExists(atPath: source.path) == (operation == .copy), "source disposition incorrect")
            }
        }
        for changeSource in [true, false] {
            await test("conflict approval rejects \(changeSource ? "source" : "destination") nested mutation") { dir in
                let source = try directory(dir, "source")
                let sourceChild = try file(source, "value", "source")
                let target = try directory(dir, "target")
                let targetChild = try file(target, "value", "target")
                let comparison = try await SafeFileOperations.captureConflictComparison(sourceURL: source, destinationURL: target)
                try Data("changed payload".utf8).write(to: changeSource ? sourceChild : targetChild)
                try await mustFail {
                    try await SafeFileOperations.perform(.move, sourceURL: source, destinationURL: target, overwrite: true, approval: comparison.approval) { _ in }
                }
                try expect(contents(sourceChild) == (changeSource ? "changed payload" : "source"), "source mutated by rejected operation")
                try expect(contents(targetChild) == (changeSource ? "target" : "changed payload"), "target mutated by rejected operation")
            }
            await test("conflict approval rejects \(changeSource ? "source" : "destination") inode replacement") { dir in
                let source = try file(dir, "source", "source")
                let target = try file(dir, "target", "target")
                let comparison = try await SafeFileOperations.captureConflictComparison(sourceURL: source, destinationURL: target)
                let changed = changeSource ? source : target
                try fm.moveItem(at: changed, to: dir.appendingPathComponent("original"))
                _ = try file(dir, changed.lastPathComponent, "replacement")
                try await mustFail {
                    try await SafeFileOperations.perform(.copy, sourceURL: source, destinationURL: target, overwrite: true, approval: comparison.approval) { _ in }
                }
                try expect(contents(changed) == "replacement", "replacement object was overwritten")
                try expect(contents(dir.appendingPathComponent("original")) == (changeSource ? "source" : "target"), "original object modified")
            }
            await test("conflict approval rejects \(changeSource ? "source" : "destination") parent replacement") { dir in
                let sourceParent = try directory(dir, "source-parent")
                let targetParent = try directory(dir, "target-parent")
                let source = try file(sourceParent, "source", "source")
                let target = try file(targetParent, "target", "target")
                let comparison = try await SafeFileOperations.captureConflictComparison(sourceURL: source, destinationURL: target)
                let changedParent = changeSource ? sourceParent : targetParent
                let movedParent = dir.appendingPathComponent("original-parent")
                try fm.moveItem(at: changedParent, to: movedParent)
                try fm.createDirectory(at: changedParent, withIntermediateDirectories: false)
                let name = changeSource ? "source" : "target"
                try fm.moveItem(at: movedParent.appendingPathComponent(name), to: changedParent.appendingPathComponent(name))
                try await mustFail {
                    try await SafeFileOperations.perform(.move, sourceURL: source, destinationURL: target, overwrite: true, approval: comparison.approval) { _ in }
                }
                try expect(contents(source) == "source" && contents(target) == "target", "rejected parent replacement modified payload")
            }
        }
        await test("conflict approval binds exact pair and refuses nonoverwrite") { dir in
            let source = try file(dir, "source", "source")
            let target = try file(dir, "target", "target")
            let other = try file(dir, "other", "other")
            let comparison = try await SafeFileOperations.captureConflictComparison(sourceURL: source, destinationURL: target)
            for pair in [(source, other), (other, target)] {
                try await mustFail {
                    try await SafeFileOperations.perform(.copy, sourceURL: pair.0, destinationURL: pair.1, overwrite: true, approval: comparison.approval) { _ in }
                }
            }
            try await mustFail {
                try await SafeFileOperations.perform(.copy, sourceURL: source, destinationURL: target, overwrite: false, approval: comparison.approval) { _ in }
            }
            try expect(contents(source) == "source" && contents(target) == "target" && contents(other) == "other", "wrong-pair operation changed files")
        }
        await test("conflict approval capture cancellation unreadable tree and missing target fail") { dir in
            let source = try directory(dir, "source")
            _ = try file(source, "value", "source")
            let target = try file(dir, "target", "target")
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await SafeFileOperations.captureConflictComparison(sourceURL: source, destinationURL: target)
            }
            do { _ = try await task.value; throw TestFailure.assertion("cancelled capture succeeded") }
            catch is CancellationError { }
            chmod(source.path, 0o000)
            defer { chmod(source.path, 0o755) }
            try await mustFail { _ = try await SafeFileOperations.captureConflictComparison(sourceURL: source, destinationURL: target) }
            chmod(source.path, 0o755)
            try await mustFail { _ = try await SafeFileOperations.captureConflictComparison(sourceURL: source, destinationURL: dir.appendingPathComponent("missing")) }
            try expect(contents(target) == "target", "failed capture changed target")
        }
    }
}
