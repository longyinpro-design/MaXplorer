import Darwin
import Foundation

extension FileOperationTests {
    static func archiveCatalogTests() async {
        for format in ["zip", "tar", "7z"] {
            await test("archive catalog \(format) exact special-name file selection") { dir in
                let source = try directory(dir, "input")
                for (name, payload) in [("[a].txt", "brackets"), ("a.txt", "plain"), ("line\nbreak.txt", "line"), ("中文🌈.txt", "unicode")] {
                    _ = try file(source, name, payload)
                }
                let archive = dir.appendingPathComponent("sample.\(format)")
                if format == "zip" {
                    try runTool("/usr/bin/zip", ["-q", "-0", archive.path, "[a].txt", "a.txt", "line\nbreak.txt", "中文🌈.txt"], currentDirectory: source)
                } else {
                    var arguments = ["-cf", archive.path]
                    if format == "7z" { arguments += ["--format=7zip"] }
                    arguments += ["-C", source.path, "--", "[a].txt", "a.txt", "line\nbreak.txt", "中文🌈.txt"]
                    try runTool("/usr/bin/tar", arguments)
                }
                let catalog = try await ArchiveCatalogService.catalog(archive: archive)
                try expect(catalog.entries.count == 4, "special names lost")
                try expect(catalog.entries.contains { $0.id == "line\nbreak.txt" }, "newline was line-parsed")
                let destination = try directory(dir, "output")
                let progress = ArchiveCatalogProgressLog()
                let staging = try await ArchiveCatalogService.extract(
                    catalog: catalog, selectedIDs: ["[a].txt", "中文🌈.txt"], toStagingIn: destination,
                    progress: { progress.append($0) }
                )
                let updates = progress.values()
                try expect(updates.first == 8 && updates.last == 15, "progress omitted first write or completion, or counted unselected data")
                defer { try? fm.removeItem(at: staging) }
                try expect(contents(staging.appendingPathComponent("[a].txt")) == "brackets", "bracket selection was treated as a glob")
                try expect(contents(staging.appendingPathComponent("中文🌈.txt")) == "unicode", "Unicode payload lost")
                try expect(!fm.fileExists(atPath: staging.appendingPathComponent("a.txt").path), "unselected file extracted")
                try expect(!fm.fileExists(atPath: staging.appendingPathComponent("line\nbreak.txt").path), "unselected newline file extracted")
                let permissions = try fm.attributesOfItem(atPath: staging.path)[.posixPermissions] as? NSNumber
                try expect(permissions?.intValue == 0o700, "staging root not private")
            }
        }
        await test("archive catalog inferred explicit empty and root directories merge safely") { dir in
            let archive = dir.appendingPathComponent("tree.tar")
            try catalogTar([
                ("./", 53, Data(), ""),
                ("folder/sub/first.txt", 48, Data("first".utf8), ""),
                ("folder/second.txt", 48, Data("second".utf8), ""),
                ("folder/", 53, Data(), ""),
                ("empty/", 53, Data(), ""),
                ("outside.txt", 48, Data("outside".utf8), "")
            ], at: archive)
            let catalog = try await ArchiveCatalogService.catalog(archive: archive)
            try expect(catalog.entries.filter { $0.id == "folder" }.count == 1, "explicit inferred directory duplicated")
            try expect(catalog.entries.first { $0.id == "folder/sub" }?.ordinal == nil, "implicit directory has an ordinal")
            let destination = try directory(dir, "output")
            let staging = try await ArchiveCatalogService.extract(catalog: catalog, selectedIDs: ["folder", "empty"], toStagingIn: destination)
            defer { try? fm.removeItem(at: staging) }
            try expect(contents(staging.appendingPathComponent("folder/sub/first.txt")) == "first", "directory descendants omitted")
            try expect(contents(staging.appendingPathComponent("folder/second.txt")) == "second", "second descendant omitted")
            var isDirectory: ObjCBool = false
            try expect(fm.fileExists(atPath: staging.appendingPathComponent("empty").path, isDirectory: &isDirectory) && isDirectory.boolValue, "empty directory omitted")
            try expect(!fm.fileExists(atPath: staging.appendingPathComponent("outside.txt").path), "unselected sibling extracted")
        }
        for fixture in ["test_read_format_rar.rar", "test_read_format_rar5_stored.rar", "test_read_format_rar5_compressed.rar"] {
            await test("archive catalog official \(fixture) reads and extracts selected file") { dir in
                let archive = catalogFixture(fixture)
                let catalog = try await ArchiveCatalogService.catalog(archive: archive)
                guard let entry = catalog.entries.first(where: { $0.kind == .file }) else { throw TestFailure.assertion("RAR contains no file") }
                let destination = try directory(dir, "output")
                let staging = try await ArchiveCatalogService.extract(catalog: catalog, selectedIDs: [entry.id], toStagingIn: destination)
                defer { try? fm.removeItem(at: staging) }
                let data = try Data(contentsOf: staging.appendingPathComponent(entry.path))
                try expect(Int64(data.count) == entry.size && !data.isEmpty, "RAR payload missing or truncated")
                if fixture.contains("compressed") { try expect(data.count == 1200, "RAR5 compressed fixture wrong size") }
                if fixture == "test_read_format_rar.rar" {
                    try expect(catalog.entries.contains { $0.kind == .unsupported }, "RAR symlink incorrectly extractable")
                }
            }
        }
        await test("archive catalog rejects traversal absolute Windows drive backslash and control paths") { dir in
            for (index, path) in ["../outside", "/absolute", "a/../../outside", "C:/outside", "C:outside", "a\\outside", "bad\u{01}name", "a/../b"].enumerated() {
                let archive = dir.appendingPathComponent("unsafe-\(index).tar")
                try catalogTar([(path, 48, Data("payload".utf8), "")], at: archive)
                try await mustFail { _ = try await ArchiveCatalogService.catalog(archive: archive) }
            }
        }
        await test("archive catalog rejects duplicate case NFC and file-ancestor collisions") { dir in
            let cases: [[String]] = [
                ["same.txt", "same.txt"], ["Readme", "README"], ["café", "cafe\u{301}"],
                ["file/child", "file"], ["file", "file/child"], ["Folder/a", "folder/b"],
                ["café/a", "cafe\u{301}/b"]
            ]
            for (index, paths) in cases.enumerated() {
                let archive = dir.appendingPathComponent("collision-\(index).tar")
                try catalogTar(paths.map { ($0, 48, Data("data".utf8), "") }, at: archive)
                try await mustFail { _ = try await ArchiveCatalogService.catalog(archive: archive) }
            }
        }
        await test("archive catalog lists links device FIFO as unsupported and rejects containing selection") { dir in
            let archive = dir.appendingPathComponent("special.tar")
            try catalogTar([
                ("folder/safe", 48, Data("safe".utf8), ""),
                ("folder/symlink", 50, Data(), "../../victim"),
                ("folder/hardlink", 49, Data(), "../../victim"),
                ("folder/device", 51, Data(), ""),
                ("folder/fifo", 54, Data(), "")
            ], at: archive)
            let catalog = try await ArchiveCatalogService.catalog(archive: archive)
            try expect(catalog.entries.filter { $0.kind == .unsupported }.count == 4, "special files misclassified")
            let destination = try directory(dir, "output")
            for id in ["folder", "folder/symlink", "folder/hardlink", "folder/device", "folder/fifo"] {
                try await mustFail { _ = try await ArchiveCatalogService.extract(catalog: catalog, selectedIDs: [id], toStagingIn: destination) }
                try expectNoArchiveStaging(in: destination)
            }
            let staging = try await ArchiveCatalogService.extract(catalog: catalog, selectedIDs: ["folder/safe"], toStagingIn: destination)
            defer { try? fm.removeItem(at: staging) }
            try expect(contents(staging.appendingPathComponent("folder/safe")) == "safe", "safe peer could not be selected")
        }
        await test("archive catalog binds source identity and rejects final symlink directory and FIFO") { dir in
            let archive = dir.appendingPathComponent("original.tar")
            try catalogTar([("safe", 48, Data("safe".utf8), "")], at: archive)
            let catalog = try await ArchiveCatalogService.catalog(archive: archive)
            let saved = dir.appendingPathComponent("saved.tar")
            try fm.moveItem(at: archive, to: saved)
            try catalogTar([("safe", 48, Data("evil".utf8), "")], at: archive)
            let destination = try directory(dir, "output")
            try await mustFail { _ = try await ArchiveCatalogService.extract(catalog: catalog, selectedIDs: ["safe"], toStagingIn: destination) }
            try expectNoArchiveStaging(in: destination)
            let link = dir.appendingPathComponent("link.tar")
            try fm.createSymbolicLink(at: link, withDestinationURL: saved)
            let fifo = dir.appendingPathComponent("fifo.tar")
            try expect(mkfifo(fifo.path, 0o600) == 0, "cannot create FIFO fixture")
            for url in [link, destination, fifo] { try await mustFail { _ = try await ArchiveCatalogService.catalog(archive: url) } }
        }
        await test("archive catalog rejects changed bytes after listing and invalid selections") { dir in
            let archive = dir.appendingPathComponent("same-inode.tar")
            try catalogTar([("safe", 48, Data("safe".utf8), "")], at: archive)
            let catalog = try await ArchiveCatalogService.catalog(archive: archive)
            let destination = try directory(dir, "output")
            for selection: Set<String> in [[], ["missing"]] {
                try await mustFail { _ = try await ArchiveCatalogService.extract(catalog: catalog, selectedIDs: selection, toStagingIn: destination) }
            }
            let handle = try FileHandle(forWritingTo: archive)
            try handle.seek(toOffset: 512); try handle.write(contentsOf: Data("evil".utf8)); try handle.close()
            try await mustFail { _ = try await ArchiveCatalogService.extract(catalog: catalog, selectedIDs: ["safe"], toStagingIn: destination) }
            try expectNoArchiveStaging(in: destination)
        }
        await test("archive catalog enforces count byte path and depth limits") { dir in
            let archive = dir.appendingPathComponent("limits.tar")
            try catalogTar([("a/b/c.txt", 48, Data("12345".utf8), ""), ("other", 48, Data("67890".utf8), "")], at: archive)
            var limits: [ArchiveReadLimits] = []
            var value = ArchiveReadLimits.default; value.maxEntries = 2; limits.append(value)
            value = .default; value.maxEntryBytes = 4; limits.append(value)
            value = .default; value.maxTotalBytes = 9; limits.append(value)
            value = .default; value.maxPathBytes = 8; limits.append(value)
            value = .default; value.maxDepth = 2; limits.append(value)
            value = .default; value.maxEntries = 0; limits.append(value)
            for limit in limits { try await mustFail { _ = try await ArchiveCatalogService.catalog(archive: archive, limits: limit) } }
            let catalog = try await ArchiveCatalogService.catalog(archive: archive)
            let destination = try directory(dir, "output")
            for limit in limits { try await mustFail { _ = try await ArchiveCatalogService.extract(catalog: catalog, selectedIDs: ["a"], toStagingIn: destination, limits: limit) } }
            try expectNoArchiveStaging(in: destination)
        }
        await test("archive catalog cancellation and unwritable staging preserve source and target") { dir in
            let archive = dir.appendingPathComponent("cancel.tar")
            try catalogTar([("safe", 48, Data("safe".utf8), "")], at: archive)
            let listing = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await ArchiveCatalogService.catalog(archive: archive)
            }
            do { _ = try await listing.value; throw TestFailure.assertion("cancelled catalog succeeded") }
            catch is CancellationError { }
            let catalog = try await ArchiveCatalogService.catalog(archive: archive)
            let destination = try directory(dir, "output")
            let extraction = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await ArchiveCatalogService.extract(catalog: catalog, selectedIDs: ["safe"], toStagingIn: destination)
            }
            do { _ = try await extraction.value; throw TestFailure.assertion("cancelled extraction succeeded") }
            catch is CancellationError { }
            chmod(destination.path, 0o555)
            defer { chmod(destination.path, 0o755) }
            try await mustFail { _ = try await ArchiveCatalogService.extract(catalog: catalog, selectedIDs: ["safe"], toStagingIn: destination) }
            chmod(destination.path, 0o755)
            try expectNoArchiveStaging(in: destination)
            try expect(fm.fileExists(atPath: archive.path), "source removed")
        }
        await test("archive catalog cancels after real partial extraction and cleans staging") { dir in
            let archive = dir.appendingPathComponent("partial.tar")
            let byteCount = 32 * 1024 * 1024
            try catalogTar([
                ("large.bin", 48, Data(repeating: 0x61, count: byteCount), ""),
                ("unselected.bin", 48, Data("never extract".utf8), "")
            ], at: archive)
            let archiveBefore = try Data(contentsOf: archive)
            let catalog = try await ArchiveCatalogService.catalog(archive: archive)
            let destination = try directory(dir, "output")
            let gate = ArchiveCatalogCancellationGate(total: Int64(byteCount))
            let extraction = Task {
                try await ArchiveCatalogService.extract(
                    catalog: catalog, selectedIDs: ["large.bin"], toStagingIn: destination,
                    progress: { gate.observed($0) }
                )
            }
            gate.install(extraction)
            do { _ = try await extraction.value; throw TestFailure.assertion("partial extraction ignored cancellation") }
            catch is CancellationError { }
            let observed = gate.values()
            try expect(observed.contains { $0 > 0 && $0 < Int64(byteCount) }, "no actual partial data write observed")
            print("MEASURE archive cancelled after writing \(observed.first ?? 0) / \(byteCount) bytes")
            try expectNoArchiveStaging(in: destination)
            let remaining = try fm.contentsOfDirectory(atPath: destination.path)
            try expect(remaining.isEmpty, "cancelled extraction left selected or unselected payload")
            let archiveAfter = try Data(contentsOf: archive)
            try expect(archiveAfter == archiveBefore, "cancellation changed source archive")
        }
        await test("archive catalog corrupt compressed payload is rejected and staging cleaned") { dir in
            let source = try file(dir, "payload.txt", "UNIQUE-PAYLOAD-FOR-CRC-TEST")
            let archive = dir.appendingPathComponent("crc.zip")
            try runTool("/usr/bin/zip", ["-q", "-0", archive.path, source.lastPathComponent], currentDirectory: dir)
            var bytes = try Data(contentsOf: archive)
            guard let range = bytes.range(of: Data("UNIQUE-PAYLOAD-FOR-CRC-TEST".utf8)) else { throw TestFailure.assertion("stored fixture payload missing") }
            bytes[range.lowerBound] ^= 0xff
            try bytes.write(to: archive)
            let catalog = try await ArchiveCatalogService.catalog(archive: archive)
            let destination = try directory(dir, "output")
            try await mustFail { _ = try await ArchiveCatalogService.extract(catalog: catalog, selectedIDs: ["payload.txt"], toStagingIn: destination) }
            try expectNoArchiveStaging(in: destination)
            let junk = try file(dir, "junk.tar", "not an archive")
            try await mustFail { _ = try await ArchiveCatalogService.catalog(archive: junk) }
            let mtree = try file(dir, "unsafe.mtree", "#mtree\nfile type=file contents=/etc/passwd\n")
            try await mustFail { _ = try await ArchiveCatalogService.catalog(archive: mtree) }
        }
        for fixture in ["test_read_format_7zip_encryption.7z", "test_read_format_7zip_encryption_header.7z", "test_read_format_rar_encryption_data.rar", "test_read_format_rar_encryption_header.rar"] {
            await test("archive catalog explicitly rejects encrypted \(fixture)") { dir in
                let destination = try directory(dir, "output")
                do {
                    let catalog = try await ArchiveCatalogService.catalog(archive: catalogFixture(fixture))
                    _ = try await ArchiveCatalogService.extract(catalog: catalog, selectedIDs: Set(catalog.entries.map(\.id)), toStagingIn: destination)
                    throw TestFailure.assertion("encrypted archive was accepted")
                } catch ArchiveCatalogError.encrypted { }
                try expectNoArchiveStaging(in: destination)
            }
        }
    }

    private static func catalogFixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ArchiveCatalog").appendingPathComponent(name)
    }

    /// Minimal deterministic ustar fixtures, including names the filesystem itself cannot create.
    private static func catalogTar(_ members: [(String, UInt8, Data, String)], at url: URL) throws {
        var output = Data()
        for (name, type, payload, link) in members {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, _ offset: Int, _ count: Int) throws {
                let bytes = Array(text.utf8)
                try expect(bytes.count <= count, "fixture header value too long")
                for (index, byte) in bytes.enumerated() { header[offset + index] = byte }
            }
            try put(name, 0, 100); try put("0004755", 100, 8)
            try put("0000000", 108, 8); try put("0000000", 116, 8)
            try put(String(format: "%011o", payload.count), 124, 12)
            try put("00000000001", 136, 12)
            for index in 148..<156 { header[index] = 32 }
            header[156] = type
            try put(link, 157, 100); try put("ustar", 257, 6); try put("00", 263, 2)
            let sum = header.reduce(0) { $0 + Int($1) }
            try put(String(format: "%06o", sum), 148, 6); header[154] = 0; header[155] = 32
            output.append(contentsOf: header); output.append(payload)
            if !payload.isEmpty, payload.count % 512 != 0 { output.append(Data(repeating: 0, count: 512 - payload.count % 512)) }
        }
        output.append(Data(repeating: 0, count: 1024))
        try output.write(to: url)
    }
}

/// The callback can run before install; remember cancellation until its task exists.
nonisolated private final class ArchiveCatalogCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int64
    private var task: Task<URL, Error>?
    private var cancelRequested = false
    private var observedBytes: [Int64] = []
    init(total: Int64) { self.total = total }
    func install(_ task: Task<URL, Error>) {
        lock.lock()
        self.task = task
        let cancel = cancelRequested
        lock.unlock()
        if cancel { task.cancel() }
    }
    func observed(_ bytes: Int64) {
        lock.lock()
        observedBytes.append(bytes)
        if bytes > 0 && bytes < total { cancelRequested = true }
        let cancel = cancelRequested
        let task = task
        lock.unlock()
        if cancel { task?.cancel() }
    }
    func values() -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        return observedBytes
    }
}

nonisolated private final class ArchiveCatalogProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [Int64] = []
    func append(_ value: Int64) { lock.lock(); bytes.append(value); lock.unlock() }
    func values() -> [Int64] { lock.lock(); defer { lock.unlock() }; return bytes }
}
