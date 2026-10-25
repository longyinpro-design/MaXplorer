import Foundation
import Darwin

nonisolated final class TransferGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    func pause(_ count: Int64) {
        condition.lock()
        defer { condition.unlock() }
        guard count > 0, !entered else { return }
        entered = true
        while !released { condition.wait() }
    }
    var hasEntered: Bool {
        condition.lock(); defer { condition.unlock() }
        return entered
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

nonisolated final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []
    func append(_ value: Int64) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [Int64] { lock.lock(); defer { lock.unlock() }; return values }
}

extension FileOperationTests {
    static func directory(_ parent: URL, _ name: String) throws -> URL {
        let result = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    static func largeFile(_ parent: URL, _ name: String) throws -> URL {
        let result = parent.appendingPathComponent(name)
        try Data(repeating: 0x5a, count: 8 * 1024 * 1024).write(to: result)
        return result
    }
    static func waitFor(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        try expect(condition(), "timed out")
    }
    static func noStaging(_ dir: URL) throws {
        let entries = try fm.contentsOfDirectory(atPath: dir.path)
        try expect(!entries.contains { $0.hasPrefix(".maxplorer-transfer-") }, "unexpected staging residue")
    }
    static func move(_ source: URL, _ target: URL, overwrite: Bool = true) async throws {
        try await CopyWorker.perform(.move, sourceURL: source, destinationURL: target, overwrite: overwrite) { _ in }
    }
    static func aclText(_ url: URL) throws -> String {
        guard let acl = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { throw TestFailure.assertion("cannot read ACL") }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length = 0
        guard let text = acl_to_text(acl, &length) else { throw TestFailure.assertion("cannot serialize ACL") }
        defer { acl_free(text) }
        return String(cString: text)
    }

    static func extendedTests() async {
        await test("normal copy and overwrite replace complete contents") { dir in
            let source = try file(dir, "source", "new")
            let target = try file(dir, "target", "old")
            try await copy(source, target)
            try expect(contents(source) == "new" && contents(target) == "new", "content mismatch")
            try noStaging(dir)
        }
        await test("nonempty directory and file-directory replacements are complete") { dir in
            let source = try directory(dir, "source")
            _ = try file(source, "new", "new")
            let target = try directory(dir, "target")
            _ = try file(target, "old", "old")
            try await copy(source, target)
            try expect(contents(target.appendingPathComponent("new")) == "new", "new directory incomplete")
            try expect(!SafeFileOperations.entryExists(at: target.appendingPathComponent("old")), "old tree merged")
            let replacement = try file(dir, "replacement")
            try await copy(replacement, target)
            try expect(contents(target) == "source", "file-directory swap failed")
            try noStaging(dir)
        }
        await test("directory metadata hidden children and symlink loop are preserved") { dir in
            let source = try directory(dir, "source")
            let child = try directory(source, "child")
            _ = try file(child, ".hidden", "hidden")
            try fm.createSymbolicLink(atPath: child.appendingPathComponent("dangling").path, withDestinationPath: "missing")
            try fm.createSymbolicLink(atPath: source.appendingPathComponent("loop").path, withDestinationPath: ".")
            let date = Date(timeIntervalSince1970: 1_600_000_000)
            try fm.setAttributes([.modificationDate: date, .posixPermissions: 0o555], ofItemAtPath: child.path)
            try fm.setAttributes([.modificationDate: date, .posixPermissions: 0o555], ofItemAtPath: source.path)
            defer { chmod(source.path, 0o755); chmod(child.path, 0o755) }
            let target = dir.appendingPathComponent("target", isDirectory: true)
            try await copy(source, target)
            defer { chmod(target.path, 0o755); chmod(target.appendingPathComponent("child").path, 0o755) }
            let attrs = try fm.attributesOfItem(atPath: target.path)
            try expect(attrs[.modificationDate] as? Date == date, "directory timestamp changed")
            try expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o555, "directory mode changed")
            try expect(contents(target.appendingPathComponent("child/.hidden")) == "hidden", "hidden file missing or nested incorrectly")
            try expect((try? fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("loop").path)) == ".", "directory link followed")
            try expect((try? fm.destinationOfSymbolicLink(atPath: target.appendingPathComponent("child/dangling").path)) == "missing", "child link missing")
            let bytes = try await CopyWorker.totalByteCount(for: source)
            try expect(bytes == 6, "hidden files not counted or symlink followed")
        }
        await test("read-only existing directory is preserved if replacement is denied") { dir in
            let source = try directory(dir, "source")
            _ = try file(source, "new")
            let target = try directory(dir, "target")
            _ = try file(target, "old", "old")
            chmod(target.path, 0o555)
            defer { chmod(target.path, 0o755) }
            try await mustFail { try await copy(source, target) }
            let attrs = try fm.attributesOfItem(atPath: target.path)
            try expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o555, "old directory permissions changed")
            try expect(contents(target.appendingPathComponent("old")) == "old", "old contents lost")
            try noStaging(dir)
        }
        await test("recursive progress is monotonic and includes hidden data") { dir in
            let source = try directory(dir, "source")
            _ = try file(source, "a", "abc")
            _ = try file(source, ".b", "1234567")
            let log = ProgressLog()
            try await CopyWorker.perform(.copy, sourceURL: source, destinationURL: dir.appendingPathComponent("target"), overwrite: false) { log.append($0) }
            let values = log.snapshot
            try expect(values.last == 10, "wrong final progress")
            try expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "progress regressed")
        }
        await test("ACL resource fork and file timestamp are preserved") { dir in
            let source = try file(dir, "source")
            let target = dir.appendingPathComponent("target")
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/bin/chmod")
            command.arguments = ["+a", "user:\(NSUserName()) allow read,readattr,readextattr,readsecurity", source.path]
            try command.run(); command.waitUntilExit()
            try expect(command.terminationStatus == 0, "ACL fixture failed")
            let fork: [UInt8] = [7, 8, 9]
            try expect(setxattr(source.path, "com.apple.ResourceFork", fork, fork.count, 0, 0) == 0, "resource fork fixture failed")
            let date = Date(timeIntervalSince1970: 1_600_000_001)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: source.path)
            try await copy(source, target)
            let sourceACL = try aclText(source)
            let targetACL = try aclText(target)
            try expect(sourceACL == targetACL, "ACL changed")
            var result = [UInt8](repeating: 0, count: 3)
            try expect(getxattr(target.path, "com.apple.ResourceFork", &result, result.count, 0, 0) == 3 && result == fork, "resource fork changed")
            let attrs = try fm.attributesOfItem(atPath: target.path)
            try expect(attrs[.modificationDate] as? Date == date, "file timestamp changed")
        }
        await test("overwriting a symlink leaves its referent unchanged") { dir in
            let source = try file(dir, "source", "new")
            let referent = try file(dir, "referent", "untouched")
            let target = dir.appendingPathComponent("target")
            try fm.createSymbolicLink(at: target, withDestinationURL: referent)
            try await copy(source, target)
            try expect(contents(target) == "new" && contents(referent) == "untouched", "referent was modified")
        }
        await test("dangling destination conflicts without overwrite") { dir in
            let source = try file(dir, "source")
            let target = dir.appendingPathComponent("target")
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: "missing")
            try expect(SafeFileOperations.entryExists(at: target), "dangling destination not detected")
            try await mustFail { try await copy(source, target, overwrite: false) }
            try expect((try? fm.destinationOfSymbolicLink(atPath: target.path)) == "missing", "old link lost")
        }
        await test("same path and hardlink aliases are rejected") { dir in
            let source = try file(dir, "source")
            let target = dir.appendingPathComponent("hardlink")
            try expect(link(source.path, target.path) == 0, "hardlink fixture failed")
            try await mustFail { try await copy(source, source) }
            try await mustFail { try await copy(source, target) }
            try expect(contents(source) == "source" && contents(target) == "source", "aliased data lost")
        }
        await test("directory descendant and ancestor overwrites are rejected") { dir in
            let source = try directory(dir, "source")
            let child = try directory(source, "child")
            let file = try file(child, "file")
            try await mustFail { try await copy(source, child.appendingPathComponent("target")) }
            try await mustFail { try await copy(file, source) }
            try expect(contents(file) == "source", "tree lost")
            try noStaging(child)
        }
        await test("unsupported FIFO fails before touching destination") { dir in
            let source = dir.appendingPathComponent("fifo")
            let target = try file(dir, "target", "old")
            try expect(mkfifo(source.path, 0o600) == 0, "FIFO fixture failed")
            try await mustFail { try await copy(source, target) }
            try expect(contents(target) == "old", "old target lost")
        }
        await test("recursive read failure preserves old tree") { dir in
            let source = try directory(dir, "source")
            let bad = try file(source, "unreadable")
            let target = try directory(dir, "target")
            let old = try file(target, "old", "old")
            chmod(bad.path, 0)
            defer { chmod(bad.path, 0o600) }
            try await mustFail { try await copy(source, target) }
            try expect(contents(old) == "old", "old tree lost")
            try noStaging(dir)
        }
        await test("cancelled overwrite preserves old target and removes staging") { dir in
            let source = try largeFile(dir, "source")
            let target = try file(dir, "target", "old")
            let gate = TransferGate()
            defer { gate.release() }
            let task = Task { try await CopyWorker.perform(.copy, sourceURL: source, destinationURL: target, overwrite: true, progress: { gate.pause($0) }) }
            try await waitFor { gate.hasEntered }
            task.cancel(); gate.release()
            do { try await task.value; throw TestFailure.assertion("cancel succeeded") }
            catch is CancellationError {}
            try expect(contents(target) == "old", "cancel destroyed old target")
            try noStaging(dir)
        }
        await test("source mutation during copy prevents publication") { dir in
            let source = try largeFile(dir, "source")
            let target = try file(dir, "target", "old")
            let gate = TransferGate()
            defer { gate.release() }
            let task = Task { try await CopyWorker.perform(.copy, sourceURL: source, destinationURL: target, overwrite: true, progress: { gate.pause($0) }) }
            try await waitFor { gate.hasEntered }
            try Data("changed".utf8).write(to: source, options: .atomic)
            gate.release()
            try await mustFail { try await task.value }
            try expect(contents(target) == "old" && contents(source) == "changed", "mutation was lost")
            try noStaging(dir)
        }
        await test("cancellation after publication reports committed success") { dir in
            let source = try file(dir, "source")
            let target = dir.appendingPathComponent("target")
            let gate = TransferGate()
            defer { gate.release() }
            let task = Task {
                try await CopyWorker.perform(.copy, sourceURL: source, destinationURL: target, overwrite: false) { count in
                    if SafeFileOperations.entryExists(at: target) { gate.pause(count) }
                }
            }
            try await waitFor { gate.hasEntered }
            task.cancel(); gate.release()
            try await task.value
            try expect(contents(target) == "source", "committed target was removed")
            try noStaging(dir)
        }
        await test("concurrent exclusive copies publish only one complete target") { dir in
            let a = try file(dir, "a", "first")
            let b = try file(dir, "b", "second")
            let target = dir.appendingPathComponent("target")
            let first = Task { () -> Bool in
                do { try await copy(a, target, overwrite: false); return true } catch { return false }
            }
            let second = Task { () -> Bool in
                do { try await copy(b, target, overwrite: false); return true } catch { return false }
            }
            let aWon = await first.value; let bWon = await second.value
            try expect(aWon != bWon, "exclusive copies did not elect one winner")
            try expect(contents(target) == (aWon ? "first" : "second"), "winner contents corrupted")
            try noStaging(dir)
        }
        await test("destination mutation during copy prevents replacement") { dir in
            let source = try largeFile(dir, "source")
            let target = try file(dir, "target", "old")
            let gate = TransferGate()
            defer { gate.release() }
            let task = Task { try await CopyWorker.perform(.copy, sourceURL: source, destinationURL: target, overwrite: true, progress: { gate.pause($0) }) }
            try await waitFor { gate.hasEntered }
            try Data("external edit".utf8).write(to: target, options: .atomic)
            gate.release()
            try await mustFail { try await task.value }
            try expect(contents(target) == "external edit", "external edit was lost")
            try noStaging(dir)
        }
        await test("nested destination edit during copy prevents replacement") { dir in
            let source = try directory(dir, "source")
            _ = try largeFile(source, "data")
            let target = try directory(dir, "target")
            let nested = try directory(target, "nested")
            let edited = try file(nested, "file", "old")
            let gate = TransferGate()
            defer { gate.release() }
            let task = Task { try await CopyWorker.perform(.copy, sourceURL: source, destinationURL: target, overwrite: true, progress: { gate.pause($0) }) }
            try await waitFor { gate.hasEntered }
            let handle = try FileHandle(forWritingTo: edited)
            try handle.write(contentsOf: Data("external edit".utf8))
            try handle.close()
            gate.release()
            try await mustFail { try await task.value }
            try expect(contents(edited) == "external edit", "nested external edit was lost")
            try noStaging(dir)
        }
        await test("move supports exclusive rename and transactional overwrite") { dir in
            let source = try file(dir, "source")
            let target = dir.appendingPathComponent("target")
            try await move(source, target, overwrite: false)
            try expect(!SafeFileOperations.entryExists(at: source) && contents(target) == "source", "rename failed")
            let replacement = try file(dir, "replacement", "new")
            try await move(replacement, target)
            try expect(!SafeFileOperations.entryExists(at: replacement) && contents(target) == "new", "overwrite move failed")
            try noStaging(dir)
        }
        await test("service move failure preserves destination") { dir in
            let sourceDir = try directory(dir, "source")
            let targetDir = try directory(dir, "target")
            let old = try file(targetDir, "missing", "old")
            try await mustFail {
                _ = try await LocalFileSystemService().moveItems([(sourceDir.appendingPathComponent("missing"), true)], to: targetDir)
            }
            try expect(contents(old) == "old", "service removed old target")
        }
        await test("queue cancellation retains slot until worker termination") { dir in
            let source = try largeFile(dir, "blocker")
            let gate = TransferGate()
            defer { gate.release() }
            let blocker = Task { try await CopyWorker.perform(.copy, sourceURL: source, destinationURL: dir.appendingPathComponent("blocker-copy"), overwrite: false, progress: { gate.pause($0) }) }
            try await waitFor { gate.hasEntered }
            let a = try file(dir, "a")
            let b = try file(dir, "b")
            let destination = try directory(dir, "destination")
            let queue = CopyQueueViewModel()
            queue.maximumConcurrentCopies = 1
            queue.enqueue([(a, false), (b, false)], to: destination)
            let cancelledID = queue.items[0].id
            queue.cancel(cancelledID)
            try expect(queue.items.count == 2 && queue.items[0].state == .running && queue.items[1].state == .pending,
                       "cancel released a running slot before worker returned")
            gate.release()
            try await blocker.value
            try await waitFor { !queue.hasActiveOperations }
            try expect(queue.history.count == 1 && queue.history[0].name == "b", "cancel produced false completion")
            try expect(!SafeFileOperations.entryExists(at: destination.appendingPathComponent("a")), "cancelled item published")
        }
        if let crossRoot = ProcessInfo.processInfo.environment["MAXPLORER_CROSS_VOLUME_ROOT"] {
            await crossVolumeTests(URL(fileURLWithPath: crossRoot, isDirectory: true))
        } else {
            print("NOT_PROVEN cross-volume tests: set MAXPLORER_CROSS_VOLUME_ROOT to an isolated second filesystem")
        }
    }

    static func crossVolumeTests(_ volume: URL) async {
        await test("cross-volume capability cache separates mounted filesystems") { dir in
            let targetDir = try directory(volume, UUID().uuidString)
            defer { try? fm.removeItem(at: targetDir) }
            var sourceStat = stat(); var targetStat = stat()
            try expect(lstat(dir.path, &sourceStat) == 0 && lstat(targetDir.path, &targetStat) == 0,
                       "filesystem identity fixture unavailable")
            try expect(sourceStat.st_dev != targetStat.st_dev, "test requires two mounted filesystems")
            SafeFileOperations.resetSwapCapabilitiesForTesting()
            defer { SafeFileOperations.resetSwapCapabilitiesForTesting() }
            let source = try file(dir, "source", "new")
            let local = try file(dir, "local", "old")
            let remote = try file(targetDir, "target", "old")
            try await copy(source, local)
            try expect(SafeFileOperations.swapProbeCountForTesting == 1, "first filesystem not probed")
            try await copy(source, remote)
            try expect(SafeFileOperations.swapProbeCountForTesting == 2, "second filesystem reused another capability")
            try await copy(source, remote)
            try expect(SafeFileOperations.swapProbeCountForTesting == 2, "second filesystem capability not cached")
            try expect(contents(local) == "new" && contents(remote) == "new", "cache changed overwrite content")
            try expectNoTransferResidue(in: targetDir)
        }
        await test("real cross-volume move preserves content and removes source") { dir in
            let targetDir = try directory(volume, UUID().uuidString)
            defer { try? fm.removeItem(at: targetDir) }
            let source = try file(dir, "source")
            let target = targetDir.appendingPathComponent("target")
            var a = stat(); var b = stat()
            lstat(source.path, &a); lstat(targetDir.path, &b)
            try expect(a.st_dev != b.st_dev, "test is not cross-volume")
            try await move(source, target, overwrite: false)
            try expect(contents(target) == "source" && !SafeFileOperations.entryExists(at: source), "cross-volume move incomplete")
        }
        await test("real cross-volume overwrite publishes complete content") { dir in
            let targetDir = try directory(volume, UUID().uuidString)
            defer { try? fm.removeItem(at: targetDir) }
            let source = try file(dir, "source", "new")
            let target = try file(targetDir, "target", "old")

            try await CopyWorker.perform(
                .copy,
                sourceURL: source,
                destinationURL: target,
                overwrite: true,
                progress: { _ in }
            )
            try expect(contents(target) == "new", "cross-volume overwrite did not publish")
            try expect(contents(source) == "new", "cross-volume overwrite removed source")
            try noStaging(targetDir)
        }
        await test("source removal failure preserves complete cross-volume target") { dir in
            let targetDir = try directory(volume, UUID().uuidString)
            defer { try? fm.removeItem(at: targetDir) }
            let parent = try directory(dir, "read-only-parent")
            let source = try file(parent, "source")
            let target = targetDir.appendingPathComponent("target")
            chmod(parent.path, 0o555)
            defer { chmod(parent.path, 0o755) }
            try await mustFail { try await move(source, target, overwrite: false) }
            try expect(contents(target) == "source" && contents(source) == "source", "valid target was rolled back")
            try noStaging(targetDir)
        }
        if let lowSpaceRoot = ProcessInfo.processInfo.environment["MAXPLORER_LOW_SPACE_ROOT"] {
            await lowSpaceTests(URL(fileURLWithPath: lowSpaceRoot, isDirectory: true))
        } else {
            print("NOT_PROVEN low-space tests: set MAXPLORER_LOW_SPACE_ROOT to a small filesystem")
        }
    }

    static func lowSpaceTests(_ volume: URL) async {
        await test("real mid-copy low-space failure preserves originals and permits retry") { dir in
            let targetDir = try directory(volume, UUID().uuidString)
            defer { try? fm.removeItem(at: targetDir) }
            let target = try file(targetDir, "target", "old")
            let source = try directory(dir, "source")
            let data = Data(repeating: 0x6b, count: 6 * 1024 * 1024)
            for name in ["a.bin", "b.bin", "c.bin"] {
                try data.write(to: source.appendingPathComponent(name))
            }
            let gate = TransferGate()
            let progress = ProgressLog()
            let task = Task {
                try await SafeFileOperations.perform(.move, sourceURL: source, destinationURL: target,
                                                     overwrite: true, progress: {
                    progress.append($0)
                    gate.pause($0)
                })
            }
            do {
                try await waitFor { gate.hasEntered }
            } catch {
                task.cancel()
                gate.release()
                _ = await task.result
                throw error
            }
            // The preflight succeeded and native copyfile has written data. Fill
            // only this private 24 MiB test filesystem before allowing it to continue.
            let firstBytes = progress.snapshot.first(where: { $0 > 0 }) ?? 0
            let filler = targetDir.appendingPathComponent("filler")
            let fd = open(filler.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            var fillError: Int32 = fd < 0 ? errno : 0
            if fd >= 0 {
                let block = [UInt8](repeating: 0x41, count: 64 * 1024)
                for _ in 0..<1024 {
                    let count = block.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                    if count < 0 { fillError = errno; break }
                }
                close(fd)
            }
            gate.release()
            let result = await task.result
            try expect(firstBytes > 0 && firstBytes < data.count * 3, "fixture did not pause during directory copy")
            try expect(fillError == ENOSPC, "private volume was not filled to ENOSPC: \(fillError)")
            switch result {
            case .success: throw TestFailure.assertion("copy into exhausted volume unexpectedly succeeded")
            case .failure(let error):
                try expect(error.localizedDescription.contains("空间不足"), "actual ENOSPC misreported: \(error)")
            }
            try expect(contents(target) == "old", "incomplete copy replaced old target")
            for name in ["a.bin", "b.bin", "c.bin"] {
                let remainingSource = try Data(contentsOf: source.appendingPathComponent(name))
                try expect(remainingSource == data, "mid-copy failure changed source")
            }
            try expectNoTransferResidue(in: targetDir)
            try fm.removeItem(at: filler)
            try await SafeFileOperations.perform(.copy, sourceURL: source, destinationURL: target,
                                                 overwrite: true, progress: { _ in })
            for name in ["a.bin", "b.bin", "c.bin"] {
                let copied = try Data(contentsOf: target.appendingPathComponent(name))
                try expect(copied == data, "retry after freeing space failed")
            }
        }
        await test("low-space overwrite preserves source and old destination") { dir in
            let targetDir = try directory(volume, UUID().uuidString)
            defer { try? fm.removeItem(at: targetDir) }
            let target = try file(targetDir, "target", "old")
            let source = dir.appendingPathComponent("large.bin")
            try Data(repeating: 0x5a, count: 32 * 1024 * 1024).write(to: source)

            do {
                try await CopyWorker.perform(
                    .copy,
                    sourceURL: source,
                    destinationURL: target,
                    overwrite: true,
                    progress: { _ in }
                )
                throw TestFailure.assertion("low-space copy unexpectedly succeeded")
            } catch is TestFailure {
                throw TestFailure.assertion("low-space copy unexpectedly succeeded")
            } catch {
                // Expected ENOSPC or a preflight space failure.
            }

            try expect(contents(target) == "old", "low-space copy damaged the old destination")
            let sourceSize = try Data(contentsOf: source).count
            try expect(sourceSize == 32 * 1024 * 1024, "low-space copy damaged the source")
            try noStaging(targetDir)
        }
    }
}
