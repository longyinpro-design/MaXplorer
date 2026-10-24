import Foundation

extension FileOperationTests {
    static func archiveTests() async {
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
