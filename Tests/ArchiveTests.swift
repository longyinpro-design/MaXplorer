import Foundation

extension FileOperationTests {
    static func archiveTests() async {
        await archiveAcceptanceTests()
        await test("zip compression and extraction round-trip") { dir in
            let source = try directory(dir, "source")
            _ = try file(source, "one.txt", "one")
            let target = try directory(dir, "target")
            let archive = dir.appendingPathComponent("source.zip")

            try await ArchiveService.compress(items: [source], to: archive, format: .zip)
            try expect(FileManager.default.fileExists(atPath: archive.path), "zip was not created")

            let staging = try await ArchiveService.extract(archive: archive, toStagingIn: target)
            let items = try ArchiveService.topLevelItems(in: staging)
            try expect(ArchiveService.conflicts(items: items, in: target).isEmpty, "unexpected extraction conflict")
            try await ArchiveService.moveExtractedItems(from: staging, to: target, overwrite: false)
            ArchiveService.removeStaging(staging)

            try expect(contents(target.appendingPathComponent("source/one.txt")) == "one", "zip round-trip lost content")
        }

        await test("tar.gz compression and extraction round-trip") { dir in
            let source = try directory(dir, "source")
            _ = try file(source, "one.txt", "one")
            _ = try file(source, "two.txt", "two")
            let target = try directory(dir, "target")
            let archive = dir.appendingPathComponent("source.tar.gz")

            try await ArchiveService.compress(items: [source], to: archive, format: .tarGz)
            try expect(FileManager.default.fileExists(atPath: archive.path), "tar.gz was not created")

            let staging = try await ArchiveService.extract(archive: archive, toStagingIn: target)
            try await ArchiveService.moveExtractedItems(from: staging, to: target, overwrite: false)
            ArchiveService.removeStaging(staging)

            try expect(contents(target.appendingPathComponent("source/one.txt")) == "one", "tar.gz lost one.txt")
            try expect(contents(target.appendingPathComponent("source/two.txt")) == "two", "tar.gz lost two.txt")
        }

        await test("plain gzip extraction produces the decompressed file") { dir in
            let source = try file(dir, "note.txt", "hello gzip")
            let archive = dir.appendingPathComponent("note.txt.gz")
            try runTool("/usr/bin/gzip", ["-c", source.path], standardOutput: archive)

            let target = try directory(dir, "target")
            let staging = try await ArchiveService.extract(archive: archive, toStagingIn: target)
            let items = try ArchiveService.topLevelItems(in: staging)
            try expect(items.map(\.lastPathComponent) == ["note.txt"], "unexpected gzip output")
            try await ArchiveService.moveExtractedItems(from: staging, to: target, overwrite: false)
            ArchiveService.removeStaging(staging)
            try expect(contents(target.appendingPathComponent("note.txt")) == "hello gzip", "gzip content mismatch")
        }

        await test("move hidden source directory over existing directory") { dir in
            let holder = try directory(dir, ".holder")
            let source = try directory(holder, "source")
            _ = try file(source, "new.txt", "new")
            let target = try directory(dir, "target")
            _ = try file(target, "old.txt", "old")

            try await SafeFileOperations.perform(
                .move,
                sourceURL: source,
                destinationURL: target,
                overwrite: true,
                progress: { _ in }
            )
            try expect(contents(target.appendingPathComponent("new.txt")) == "new", "hidden source move failed")
            try expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("old.txt").path), "old content survived")
        }

        await test("directory with provenance metadata moves over existing") { dir in
            let source = try directory(dir, "source")
            _ = try file(source, "new.txt", "new")
            let value: [UInt8] = [1, 2, 3]
            try expect(
                setxattr(source.path, "com.apple.provenance", value, value.count, 0, 0) == 0,
                "cannot set provenance fixture"
            )
            let target = try directory(dir, "target")
            _ = try file(target, "old.txt", "old")

            try await SafeFileOperations.perform(
                .move,
                sourceURL: source,
                destinationURL: target,
                overwrite: true,
                progress: { _ in }
            )
            try expect(contents(target.appendingPathComponent("new.txt")) == "new", "provenance move failed")
        }

        await test("move source over nested existing directory") { dir in
            let holder = try directory(dir, ".holder")
            let source = try directory(holder, "source")
            _ = try file(source, "new.txt", "new")
            let targetParent = try directory(dir, "target")
            let target = try directory(targetParent, "source")
            _ = try file(target, "old.txt", "old")

            try await SafeFileOperations.perform(
                .move,
                sourceURL: source,
                destinationURL: target,
                overwrite: true,
                progress: { _ in }
            )
            try expect(contents(target.appendingPathComponent("new.txt")) == "new", "nested destination move failed")
        }

        await test("directory containing provenance file moves over existing") { dir in
            let source = try directory(dir, "source")
            let child = try file(source, "new.txt", "new")
            let value: [UInt8] = [1, 2, 3]
            try expect(
                setxattr(child.path, "com.apple.provenance", value, value.count, 0, 0) == 0,
                "cannot set file provenance fixture"
            )
            let target = try directory(dir, "target")
            _ = try file(target, "old.txt", "old")

            try await SafeFileOperations.perform(
                .move,
                sourceURL: source,
                destinationURL: target,
                overwrite: true,
                progress: { _ in }
            )
            try expect(contents(target.appendingPathComponent("new.txt")) == "new", "file provenance move failed")
        }

        await test("extraction conflicts can be skipped or overwritten") { dir in
            let source = try directory(dir, "source")
            _ = try file(source, "new.txt", "new")
            let archive = dir.appendingPathComponent("source.zip")
            try await ArchiveService.compress(items: [source], to: archive, format: .zip)

            let target = try directory(dir, "target")
            let existing = try directory(target, "source")
            _ = try file(existing, "old.txt", "old")

            let skipStaging = try await ArchiveService.extract(archive: archive, toStagingIn: target)
            let skipItems = try ArchiveService.topLevelItems(in: skipStaging)
            try expect(ArchiveService.conflicts(items: skipItems, in: target).count == 1, "conflict was not detected")
            try await ArchiveService.moveExtractedItems(from: skipStaging, to: target, overwrite: false)
            try expect(contents(existing.appendingPathComponent("old.txt")) == "old", "skip removed the existing item")
            try expect(!FileManager.default.fileExists(atPath: existing.appendingPathComponent("new.txt").path), "skip merged new content")
            ArchiveService.removeStaging(skipStaging)

            let overwriteStaging = try await ArchiveService.extract(archive: archive, toStagingIn: target)
            try await ArchiveService.moveExtractedItems(from: overwriteStaging, to: target, overwrite: true)
            ArchiveService.removeStaging(overwriteStaging)
            try expect(contents(existing.appendingPathComponent("new.txt")) == "new", "overwrite did not publish new content")
            try expect(!FileManager.default.fileExists(atPath: existing.appendingPathComponent("old.txt").path), "overwrite merged old content")
        }

        await test("zip slip entries are rejected without leaving staging") { dir in
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
                print("SKIP zip slip fixture: python3 is unavailable")
                return
            }

            let archive = dir.appendingPathComponent("malicious.zip")
            let script = """
            import sys, zipfile
            with zipfile.ZipFile(sys.argv[1], "w") as archive:
                archive.writestr("../escaped.txt", "bad")
            """
            try runTool("/usr/bin/python3", ["-c", script, archive.path])

            let target = try directory(dir, "target")
            do {
                _ = try await ArchiveService.extract(archive: archive, toStagingIn: target)
                throw TestFailure.assertion("zip slip was extracted")
            } catch is TestFailure {
                throw TestFailure.assertion("zip slip was extracted")
            } catch {
                // Expected unsafeEntry failure.
            }

            try expectNoArchiveStaging(in: dir)
        }

        await test("corrupt archive fails without leaving staging") { dir in
            let archive = dir.appendingPathComponent("broken.zip")
            try Data("not a zip".utf8).write(to: archive)
            let target = try directory(dir, "target")

            do {
                _ = try await ArchiveService.extract(archive: archive, toStagingIn: target)
                throw TestFailure.assertion("corrupt archive was extracted")
            } catch is TestFailure {
                throw TestFailure.assertion("corrupt archive was extracted")
            } catch {
                // Expected command failure.
            }

            try expectNoArchiveStaging(in: dir)
        }
    }

    static func archiveAcceptanceTests() async {
        await test("archive formats preserve Unicode nested and empty directories") { dir in
            let source = try directory(dir, "源 文件夹")
            _ = try file(source, "中文 空格.txt", "archive contents")
            _ = try directory(source, "空目录")
            for format in [ArchiveFormat.zip, .tar, .tarGz] {
                let archive = dir.appendingPathComponent("roundtrip.\(format.fileExtension)")
                try await ArchiveService.compress(items: [source], to: archive, format: format)
                try runTool("/usr/bin/tar", ["-tf", archive.path])
                let target = try directory(dir, "target-\(format.rawValue)")
                let staging = try await ArchiveService.extract(archive: archive, toStagingIn: target)
                defer { ArchiveService.removeStaging(staging) }
                try expect(contents(staging.appendingPathComponent("源 文件夹/中文 空格.txt")) == "archive contents", "Unicode contents mismatch")
                var isDirectory: ObjCBool = false
                try expect(fm.fileExists(atPath: staging.appendingPathComponent("源 文件夹/空目录").path, isDirectory: &isDirectory) && isDirectory.boolValue, "empty directory missing")
            }
        }
        await test("gzip compression round-trip and unsupported multiple items") { dir in
            let source = try file(dir, "中文 空格.txt", "gzip data")
            let archive = dir.appendingPathComponent("中文 空格.txt.gz")
            try await ArchiveService.compress(items: [source], to: archive, format: .gzip)
            try runTool("/usr/bin/gzip", ["-t", archive.path])
            let target = try directory(dir, "target")
            let staging = try await ArchiveService.extract(archive: archive, toStagingIn: target)
            defer { ArchiveService.removeStaging(staging) }
            try expect(contents(staging.appendingPathComponent(source.lastPathComponent)) == "gzip data", "gzip content mismatch")
            ArchiveService.removeStaging(staging)
            do {
                try await ArchiveService.compress(items: [source, source], to: archive, format: .gzip)
                throw TestFailure.assertion("multiple files accepted for gzip")
            } catch is ArchiveError { }
            try expectNoArchiveStaging(in: dir)
        }
        await test("empty zip and tar extract successfully") { dir in
            try runTool("/usr/bin/python3", ["-c", "import sys,zipfile,tarfile; zipfile.ZipFile(sys.argv[1], 'w').close(); tarfile.open(sys.argv[2], 'w').close()", dir.appendingPathComponent("empty.zip").path, dir.appendingPathComponent("empty.tar").path])
            let target = try directory(dir, "target")
            for name in ["empty.zip", "empty.tar"] {
                let staging = try await ArchiveService.extract(archive: dir.appendingPathComponent(name), toStagingIn: target)
                let entries = try ArchiveService.topLevelItems(in: staging)
                try expect(entries.isEmpty, "empty archive has entries")
                ArchiveService.removeStaging(staging)
            }
            try expectNoArchiveStaging(in: dir)
        }
        await test("bzip2 and tar bzip aliases extract system-generated archives") { dir in
            let source = try file(dir, "中文.txt", "bzip data")
            let archive = dir.appendingPathComponent("中文.txt.bz2")
            try runTool("/usr/bin/bzip2", ["-c", source.path], standardOutput: archive)
            let target = try directory(dir, "target")
            let staging = try await ArchiveService.extract(archive: archive, toStagingIn: target)
            try expect(contents(staging.appendingPathComponent("中文.txt")) == "bzip data", "bzip2 mismatch")
            ArchiveService.removeStaging(staging)
            for suffix in ["tar.bz2", "tbz", "tbz2", "tgz"] {
                let archive = dir.appendingPathComponent("source.\(suffix)")
                try runTool("/usr/bin/tar", [suffix == "tgz" ? "-czf" : "-cjf", archive.path, "-C", dir.path, "中文.txt"])
                let staging = try await ArchiveService.extract(archive: archive, toStagingIn: target)
                try expect(contents(staging.appendingPathComponent("中文.txt")) == "bzip data", "tar alias mismatch")
                ArchiveService.removeStaging(staging)
            }
        }
        await test("zip and tar absolute paths traversal and escaping links are rejected") { dir in
            let outside = try directory(dir, "outside")
            let sentinel = try file(outside, "sentinel", "original")
            let target = try directory(dir, "target")
            let script = """
            import io,sys,tarfile,zipfile,stat
            kind,path,mode,outside=sys.argv[1:]
            entries = [("../outside/sentinel", b"bad", None)] if mode=="dotdot" else [(outside+"/sentinel", b"bad", None)] if mode=="absolute" else [("link", b"", outside), ("link/sentinel", b"bad", None)]
            if kind=="zip":
                with zipfile.ZipFile(path,"w") as a:
                    for name,data,link in entries:
                        if link:
                            i=zipfile.ZipInfo(name); i.create_system=3; i.external_attr=(stat.S_IFLNK|0o777)<<16; a.writestr(i,link)
                        else: a.writestr(name,data)
            else:
                with tarfile.open(path,"w") as a:
                    for name,data,link in entries:
                        i=tarfile.TarInfo(name)
                        if link: i.type=tarfile.SYMTYPE; i.linkname=link; a.addfile(i)
                        else: i.size=len(data); a.addfile(i,io.BytesIO(data))
            """
            for kind in ["zip", "tar"] {
                for mode in ["dotdot", "absolute", "symlink"] {
                    let archive = dir.appendingPathComponent("\(mode).\(kind)")
                    try runTool("/usr/bin/python3", ["-c", script, kind, archive.path, mode, outside.path])
                    do {
                        let staging = try await ArchiveService.extract(archive: archive, toStagingIn: target)
                        ArchiveService.removeStaging(staging)
                        throw TestFailure.assertion("unsafe archive accepted: \(kind)/\(mode)")
                    } catch is ArchiveError { }
                    try expect(contents(sentinel) == "original", "archive wrote outside staging")
                    try expectNoArchiveStaging(in: dir)
                }
            }
        }
        await test("safe internal symlinks survive extraction") { dir in
            let source = try directory(dir, "source")
            _ = try file(source, "real.txt", "linked content")
            try fm.createSymbolicLink(atPath: source.appendingPathComponent("link").path, withDestinationPath: "real.txt")
            let target = try directory(dir, "target")
            for format in [ArchiveFormat.zip, .tar] {
                let archive = dir.appendingPathComponent("source.\(format.fileExtension)")
                try await ArchiveService.compress(items: [source], to: archive, format: format)
                let staging = try await ArchiveService.extract(archive: archive, toStagingIn: target)
                try expect(contents(staging.appendingPathComponent("source/link")) == "linked content", "safe link lost")
                ArchiveService.removeStaging(staging)
            }
        }
        await test("running large compression cancellation removes staging and preserves output") { dir in
            let source = dir.appendingPathComponent("large.dat")
            fm.createFile(atPath: source.path, contents: Data())
            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: 512 * 1024 * 1024)
            try handle.close()
            let destination = try file(dir, "existing.gz", "original")
            let task = Task { try await ArchiveService.compress(items: [source], to: destination, format: .gzip) }
            for _ in 0..<500 {
                let entries = try fm.contentsOfDirectory(atPath: dir.path)
                if entries.contains(where: { $0.hasPrefix(".maxplorer-archive-") }) { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try await Task.sleep(nanoseconds: 30_000_000)
            let cancelledAt = Date()
            task.cancel()
            do { try await task.value; throw TestFailure.assertion("cancelled compression succeeded") }
            catch is CancellationError { }
            try expect(Date().timeIntervalSince(cancelledAt) < 3, "cancellation did not terminate child promptly")
            try expect(contents(destination) == "original", "cancel replaced existing destination")
            try expectNoArchiveStaging(in: dir)
        }
        await test("running large extraction cancellation terminates child and cleans staging") { dir in
            let source = dir.appendingPathComponent("large.dat")
            fm.createFile(atPath: source.path, contents: Data())
            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: 512 * 1024 * 1024)
            try handle.close()
            let archive = dir.appendingPathComponent("large.dat.gz")
            try runTool("/usr/bin/gzip", ["-c", source.path], standardOutput: archive)
            let target = try directory(dir, "target")
            let task = Task { try await ArchiveService.extract(archive: archive, toStagingIn: target) }
            for _ in 0..<500 {
                let entries = try fm.contentsOfDirectory(atPath: dir.path)
                if entries.contains(where: { $0.hasPrefix(".maxplorer-archive-") }) { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try await Task.sleep(nanoseconds: 30_000_000)
            let cancelledAt = Date()
            task.cancel()
            do {
                let staging = try await task.value
                ArchiveService.removeStaging(staging)
                throw TestFailure.assertion("cancelled extraction succeeded")
            } catch is CancellationError { }
            try expect(Date().timeIntervalSince(cancelledAt) < 3, "extraction child did not terminate promptly")
            try expectNoArchiveStaging(in: dir)
            let targetEntries = try fm.contentsOfDirectory(atPath: target.path)
            try expect(targetEntries.isEmpty, "cancelled extraction published output")
        }
        await test("compression publication refuses unapproved conflict") { dir in
            let source = try file(dir, "source.txt", "source")
            let destination = try file(dir, "existing.zip", "original")
            do {
                try await ArchiveService.compress(items: [source], to: destination, format: .zip)
                throw TestFailure.assertion("compression overwrote unapproved target")
            } catch is TestFailure { throw TestFailure.assertion("compression overwrote unapproved target") }
              catch { }
            try expect(contents(destination) == "original", "unapproved target changed")
            try expectNoArchiveStaging(in: dir)
            try await ArchiveService.compress(items: [source], to: destination, format: .zip, overwrite: true)
            try runTool("/usr/bin/tar", ["-tf", destination.path])
            try expectNoArchiveStaging(in: dir)
        }
        await test("pre-cancelled extraction creates no staging") { dir in
            let target = try directory(dir, "target")
            let archive = try file(dir, "broken.zip", "broken")
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await ArchiveService.extract(archive: archive, toStagingIn: target)
            }
            do { try await task.value; throw TestFailure.assertion("cancel ignored") }
            catch is CancellationError { }
            try expectNoArchiveStaging(in: dir)
        }
        await test("unwritable compression target preserves source and cleans staging") { dir in
            let source = try file(dir, "source.txt", "source")
            let target = try directory(dir, "readonly")
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
            do {
                try await ArchiveService.compress(items: [source], to: target.appendingPathComponent("output.zip"), format: .zip)
                throw TestFailure.assertion("readonly target accepted")
            } catch is ArchiveError { }
            try expect(contents(source) == "source", "source changed")
            try expectNoArchiveStaging(in: target)
        }
    }

    static func runTool(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        standardOutput: URL? = nil
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8"
        ]

        if let standardOutput {
            guard FileManager.default.createFile(atPath: standardOutput.path, contents: Data()) else {
                throw TestFailure.assertion("cannot create tool output")
            }
            process.standardOutput = try FileHandle(forWritingTo: standardOutput)
        }

        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "\(executable) failed with status \(process.terminationStatus)")
    }

    static func expectNoArchiveStaging(in dir: URL) throws {
        let entries = try fm.contentsOfDirectory(atPath: dir.path)
        try expect(!entries.contains { $0.hasPrefix(".maxplorer-archive-") }, "archive staging residue")
    }
}
