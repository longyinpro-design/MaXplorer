import Darwin
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

extension FileOperationTests {
    static func basicFileActionTests() async {
        await test("basic new file preserves occupied regular directory and dangling link") { dir in
            let existing = try file(dir, "existing", "original")
            let folder = try directory(dir, "folder")
            let missing = dir.appendingPathComponent("missing")
            let link = dir.appendingPathComponent("link")
            try fm.createSymbolicLink(at: link, withDestinationURL: missing)
            for target in [existing, folder, link] {
                do {
                    _ = try BasicFileActions.createEmptyFile(named: target.lastPathComponent, in: dir)
                    throw TestFailure.assertion("occupied name accepted")
                } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
                    try expect(error.code == Int(EEXIST), "existing item did not report EEXIST")
                    try expect(error.userInfo[NSFilePathErrorKey] as? String == target.path, "error lost target path")
                }
            }
            try expect(contents(existing) == "original", "existing file truncated")
            try expect(!fm.fileExists(atPath: missing.path), "dangling link referent created")
            let linkTarget = try fm.destinationOfSymbolicLink(atPath: link.path)
            try expect(linkTarget == missing.path, "link changed")
        }
        await test("basic new file validates names and creates Unicode empty file") { dir in
            for name in ["", "   ", ".", "..", "a/b", "bad\0name"] {
                do {
                    _ = try BasicFileActions.createEmptyFile(named: name, in: dir)
                    throw TestFailure.assertion("invalid name accepted")
                } catch is FileSystemError { }
            }
            let created = try BasicFileActions.createEmptyFile(named: " 中文 空格.txt ", in: dir)
            let data = try Data(contentsOf: created)
            try expect(created.lastPathComponent == "中文 空格.txt" && data.isEmpty, "Unicode empty file wrong")
        }
        await test("basic concurrent same-name creation has exactly one winner") { dir in
            let wins = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0..<24 {
                    group.addTask {
                        do { _ = try BasicFileActions.createEmptyFile(named: "raced.txt", in: dir); return true }
                        catch { return false }
                    }
                }
                var count = 0
                for await won in group where won { count += 1 }
                return count
            }
            try expect(wins == 1, "concurrent creation winner count: \(wins)")
            let data = try Data(contentsOf: dir.appendingPathComponent("raced.txt"))
            try expect(data.isEmpty, "created file not empty")
        }
        await test("basic new file permission failure preserves errno and path") { dir in
            let target = try directory(dir, "readonly")
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
            do {
                _ = try BasicFileActions.createEmptyFile(named: "denied.txt", in: target)
                throw TestFailure.assertion("readonly creation succeeded")
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
                try expect(error.code == Int(EACCES), "permission errno changed")
                try expect(error.userInfo[NSFilePathErrorKey] as? String == target.appendingPathComponent("denied.txt").path, "permission path missing")
            }
        }
        await test("basic duplicates reserve disk queue and same-batch destinations") { dir in
            let source = try file(dir, "中文.txt", "data")
            let item = try await LocalFileSystemService().fileItem(at: source, options: DirectoryListingOptions())
            let link = dir.appendingPathComponent("中文 copy.txt")
            try fm.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("missing"))
            let reserved: Set<URL> = [dir.appendingPathComponent("中文 copy 2.txt")]
            let values = try BasicFileActions.duplicateDestinations(for: [item, item], reserved: reserved)
            try expect(values.map { $0.destination.lastPathComponent } == ["中文 copy 3.txt", "中文 copy 4.txt"], "duplicate collision allocation wrong")
            let folder = try directory(dir, "folder.ext")
            let folderItem = try await LocalFileSystemService().fileItem(at: folder, options: DirectoryListingOptions())
            let directories = try BasicFileActions.duplicateDestinations(for: [folderItem])
            try expect(directories[0].destination.lastPathComponent == "folder.ext copy", "directory extension moved")
            let entries = try fm.contentsOfDirectory(atPath: dir.path)
            try expect(!entries.contains("中文 copy 3.txt"), "planning duplicate wrote files")
        }
        await test("basic duplicate planning fails on readonly parents and overlong names") { dir in
            let parent = try directory(dir, "readonly")
            let source = try file(parent, "source.txt")
            let item = try await LocalFileSystemService().fileItem(at: source, options: DirectoryListingOptions())
            chmod(parent.path, 0o555)
            defer { chmod(parent.path, 0o755) }
            do {
                _ = try BasicFileActions.duplicateDestinations(for: [item])
                throw TestFailure.assertion("readonly duplicate planning succeeded")
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
                try expect(error.code == Int(EACCES), "readonly errno lost")
            }
            let long = try file(dir, String(repeating: "a", count: 255))
            let longItem = try await LocalFileSystemService().fileItem(at: long, options: DirectoryListingOptions())
            do {
                _ = try BasicFileActions.duplicateDestinations(for: [longItem])
                throw TestFailure.assertion("overlong duplicate name accepted")
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
                try expect(error.code == Int(ENAMETOOLONG), "name-too-long errno lost")
            }
        }
        await test("basic cancelled create and duplicate planning cause no changes") { dir in
            let source = try file(dir, "source.txt", "source")
            let item = try await LocalFileSystemService().fileItem(at: source, options: DirectoryListingOptions())
            let createTask = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try BasicFileActions.createEmptyFile(named: "cancelled.txt", in: dir)
            }
            do { try await createTask.value; throw TestFailure.assertion("cancelled creation succeeded") }
            catch is CancellationError { }
            let duplicateTask = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try BasicFileActions.duplicateDestinations(for: [item])
            }
            do { try await duplicateTask.value; throw TestFailure.assertion("cancelled planning succeeded") }
            catch is CancellationError { }
            try expect(!fm.fileExists(atPath: dir.appendingPathComponent("cancelled.txt").path), "cancelled file created")
        }
        await test("basic file info refreshes stale metadata and fails for missing items") { dir in
            let source = try file(dir, "source.txt", "old")
            let item = try await LocalFileSystemService().fileItem(at: source, options: DirectoryListingOptions())
            try Data("new contents".utf8).write(to: source)
            let info = try await BasicFileActions.fileInfo(for: item)
            try expect(info.name == "source.txt" && info.size == 12, "file info returned stale data")
            try expect(info.owner != nil && info.group != nil && info.permissions != nil && info.modifiedAt != nil, "file info metadata missing")
            try fm.removeItem(at: source)
            do { _ = try await BasicFileActions.fileInfo(for: item); throw TestFailure.assertion("missing info succeeded") }
            catch is TestFailure { throw TestFailure.assertion("missing info succeeded") }
            catch { }
        }
        await test("basic file info loads EXIF date and Finder tags independently of listing") { dir in
            let url = dir.appendingPathComponent("photo.jpg")
            let pixel = Data([255, 0, 0, 255])
            guard let provider = CGDataProvider(data: pixel as CFData),
                  let image = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw TestFailure.assertion("cannot create EXIF fixture")
            }
            let metadata: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:03:17 12:34:56"]]
            CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
            try expect(CGImageDestinationFinalize(destination), "cannot write EXIF fixture")
            let tags = try PropertyListSerialization.data(fromPropertyList: ["验收标签\n6"], format: .binary, options: 0)
            let result = tags.withUnsafeBytes { bytes in
                setxattr(url.path, "com.apple.metadata:_kMDItemUserTags", bytes.baseAddress, tags.count, 0, 0)
            }
            try expect(result == 0, "cannot set Finder tag fixture")
            let item = try await LocalFileSystemService().fileItem(at: url, options: DirectoryListingOptions())
            try expect(item.dateTaken == nil && item.tagColors.isEmpty, "listing unexpectedly fetched optional metadata")
            let info = try await BasicFileActions.fileInfo(for: item)
            guard let date = info.dateTaken else { throw TestFailure.assertion("EXIF date missing") }
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            try expect(components.year == 2024 && components.month == 3 && components.day == 17 && components.hour == 12 && components.minute == 34 && components.second == 56, "EXIF date incorrect")
            try expect(info.tagNames == ["验收标签"], "Finder tags missing")
        }
        await test("basic file info reports inaccessible parent and cancellation") { dir in
            let parent = try directory(dir, "private")
            let source = try file(parent, "source.txt", "data")
            let item = try await LocalFileSystemService().fileItem(at: source, options: DirectoryListingOptions())
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
            do {
                _ = try await BasicFileActions.fileInfo(for: item)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
                throw TestFailure.assertion("inaccessible info succeeded")
            } catch is TestFailure { throw TestFailure.assertion("inaccessible info succeeded") }
              catch { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                _ = try await BasicFileActions.fileInfo(for: item)
            }
            do { try await task.value; throw TestFailure.assertion("cancelled info succeeded") }
            catch is CancellationError { }
        }
    }
}
