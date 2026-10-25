import Darwin
import Foundation

extension FileOperationTests {
    static func transferDestinationNamingTests() async {
        await test("keep both preserves final extensions Unicode dotfiles and package names") { dir in
            let sourceDirectory = try directory(dir, "sources")
            let destination = try directory(dir, "destination")
            let cases: [(String, Bool, String)] = [
                ("archive.tar.gz", false, "archive.tar copy.gz"),
                ("folder.ext", true, "folder.ext copy"),
                ("Example.app", true, "Example.app copy"),
                ("中文 📁.txt", false, "中文 📁 copy.txt"),
                ("README", false, "README copy"),
                (".gitignore", false, ".gitignore copy"),
                (".config.json", false, ".config copy.json")
            ]
            for (name, isDirectory, expected) in cases {
                let source = isDirectory ? try directory(sourceDirectory, name) : try file(sourceDirectory, name)
                let target = try BasicFileActions.keepBothDestination(for: source, isDirectory: isDirectory, in: destination, reserved: [])
                try expect(target.lastPathComponent == expected, "unexpected destination for \(name): \(target.lastPathComponent)")
                try expect(target.deletingLastPathComponent() == destination, "destination parent changed")
                try expect(!fm.fileExists(atPath: target.path), "planning created a file")
            }
        }
        await test("keep both excludes disk case NFC and dangling symlink collisions") { dir in
            let source = try file(dir, "café.txt")
            _ = try file(dir, "CAFÉ COPY.TXT")
            _ = try file(dir, "cafe\u{301} copy 2.txt")
            try fm.createSymbolicLink(at: dir.appendingPathComponent("café copy 3.txt"), withDestinationURL: dir.appendingPathComponent("missing"))
            let result = try BasicFileActions.keepBothDestination(for: source, isDirectory: false, in: dir, reserved: [])
            try expect(result.lastPathComponent == "café copy 4.txt", "disk normalized collision ignored")
        }
        await test("keep both excludes canonical parent and normalized reservations across batch") { dir in
            let target = try directory(dir, "target")
            let alias = dir.appendingPathComponent("alias")
            try fm.createSymbolicLink(at: alias, withDestinationURL: target)
            let source = try file(dir, "café.txt")
            var reserved: Set<URL> = [alias.appendingPathComponent("CAFE\u{301} COPY.TXT")]
            var allocated: [String] = []
            for _ in 0..<3 {
                let value = try BasicFileActions.keepBothDestination(for: source, isDirectory: false, in: target, reserved: reserved)
                reserved.insert(value)
                allocated.append(value.lastPathComponent)
            }
            try expect(allocated == ["café copy 2.txt", "café copy 3.txt", "café copy 4.txt"], "batch reservations collided")
        }
        await test("keep both reports unreadable readonly missing and overlong destinations") { dir in
            let source = try file(dir, "source.txt")
            for mode: mode_t in [0o555, 0o300] {
                let target = try directory(dir, "mode-\(mode)")
                chmod(target.path, mode)
                defer { chmod(target.path, 0o755) }
                do {
                    _ = try BasicFileActions.keepBothDestination(for: source, isDirectory: false, in: target, reserved: [])
                    throw TestFailure.assertion("inaccessible destination accepted")
                } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
                    try expect(error.code == Int(EACCES), "access errno lost: \(error)")
                    try expect(error.userInfo[NSFilePathErrorKey] as? String == target.path, "access path lost")
                }
            }
            do {
                _ = try BasicFileActions.keepBothDestination(for: source, isDirectory: false, in: dir.appendingPathComponent("missing"), reserved: [])
                throw TestFailure.assertion("missing destination accepted")
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
                try expect(error.code == Int(ENOENT), "missing errno lost")
            }
            let long = try file(dir, String(repeating: "x", count: 255))
            do {
                _ = try BasicFileActions.keepBothDestination(for: long, isDirectory: false, in: dir, reserved: [])
                throw TestFailure.assertion("overlong destination accepted")
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
                try expect(error.code == Int(ENAMETOOLONG), "overlong errno lost")
            }
        }
        await test("keep both batch plans 1000 files with disk normalized and reserved collisions") { dir in
            var items: [FileItem] = []
            var reserved = Set<URL>()
            for index in 0..<1000 {
                let source = try file(dir, "Café-\(index).tar.gz", "payload")
                items.append(try await LocalFileSystemService().fileItem(at: source, options: DirectoryListingOptions()))
                if index.isMultiple(of: 10) {
                    _ = try file(dir, "CAFE\u{301}-\(index).TAR COPY.GZ")
                    reserved.insert(dir.appendingPathComponent("CAFE\u{301}-\(index).TAR COPY 2.GZ"))
                }
            }
            let started = Date()
            let values = try BasicFileActions.duplicateDestinations(for: items, reserved: reserved)
            print("MEASURE duplicate naming 1000 items: \(Date().timeIntervalSince(started)) seconds")
            try expect(values.count == 1000, "batch lost items")
            var allocated = Set<String>()
            for (index, pair) in values.enumerated() {
                let expected = index.isMultiple(of: 10) ? "Café-\(index).tar copy 3.gz" : "Café-\(index).tar copy.gz"
                try expect(pair.destination.lastPathComponent == expected, "batch name or compound extension incorrect at \(index)")
                try expect(pair.source == items[index].url, "batch source order changed")
                try expect(allocated.insert(BasicFileActions.destinationReservationKey(for: pair.destination)).inserted, "batch allocated duplicate destination")
                try expect(!fm.fileExists(atPath: pair.destination.path), "planning created destination")
            }
        }
        await test("keep both cancellation plans no destination") { dir in
            let source = try file(dir, "source.txt")
            let task = Task.detached {
                withUnsafeCurrentTask { $0?.cancel() }
                return try BasicFileActions.keepBothDestination(for: source, isDirectory: false, in: dir, reserved: [])
            }
            do { _ = try await task.value; throw TestFailure.assertion("cancelled naming succeeded") }
            catch is CancellationError { }
            try expect(!fm.fileExists(atPath: dir.appendingPathComponent("source copy.txt").path), "cancelled planning created destination")
        }
    }
}
