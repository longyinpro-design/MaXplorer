import Foundation
import Darwin

nonisolated private func propertyWait(_ semaphore: DispatchSemaphore) { semaphore.wait() }

extension FileOperationTests {
    static func filePropertyServiceTests() async {
        let tagKey = "com.apple.metadata:_kMDItemUserTags"
        func propertyExpect(_ value: Bool, _ message: String) throws { try expect(value, message) }
        func snapshot(_ url: URL) async throws -> FilePropertySnapshot {
            let result = await FilePropertyService.inspect([url])
            guard let value = result.first?.snapshot else {
                throw TestFailure.assertion("inspect failed: \(String(describing: result.first?.error))")
            }
            return value
        }
        func writeAttribute(_ url: URL, _ key: String, _ data: Data) throws {
            let result = data.withUnsafeBytes { setxattr(url.path, key, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) }
            try propertyExpect(result == 0, "fixture setxattr errno \(errno)")
        }
        func readAttribute(_ url: URL, _ key: String) throws -> Data? {
            let size = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
            if size < 0 && errno == ENOATTR { return nil }
            try propertyExpect(size >= 0, "fixture getxattr errno \(errno)")
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            try propertyExpect(read == size, "fixture xattr size changed")
            return data
        }
        func setTags(_ url: URL, _ tags: [String]) throws {
            try writeAttribute(url, tagKey, PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0))
        }
        func rawTags(_ url: URL) throws -> [String]? {
            guard let data = try readAttribute(url, tagKey) else { return nil }
            return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        }
        func attributes(_ url: URL) throws -> stat {
            var value = stat()
            try propertyExpect(lstat(url.path, &value) == 0, "fixture lstat failed")
            return value
        }
        await test("property permissions edit ordinary file preserves special bits and unrelated metadata") { dir in
            let url = try file(dir, "ordinary", "payload")
            try propertyExpect(chmod(url.path, 0o4755) == 0, "fixture chmod failed")
            try writeAttribute(url, "com.maxplorer.property.other", Data([1, 2, 3]))
            try setTags(url, ["Keep\n6"])
            let before = try attributes(url)
            let result = await FilePropertyService.apply([FilePropertyChange(snapshot: try await snapshot(url), permissions: 0o640)])
            let after = try attributes(url)
            try propertyExpect(result[0].error == nil && result[0].appliedFields == [.permissions], "permission result incorrect")
            try propertyExpect(after.st_mode & 0o7777 == 0o4640, "special bits lost")
            try propertyExpect(before.st_uid == after.st_uid && before.st_gid == after.st_gid, "ownership changed")
            try propertyExpect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, "mtime changed")
            try propertyExpect(before.st_birthtimespec.tv_sec == after.st_birthtimespec.tv_sec, "birthtime changed")
            try propertyExpect(try readAttribute(url, "com.maxplorer.property.other") == Data([1,2,3]), "unrelated xattr changed")
            try propertyExpect(try rawTags(url) == ["Keep\n6"], "permission edit changed tags")
        }
        await test("property directory permissions affect selected directory only") { dir in
            let folder = dir.appendingPathComponent("folder", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let child = try file(folder, "child")
            try propertyExpect(chmod(child.path, 0o640) == 0, "fixture chmod failed")
            let result = await FilePropertyService.apply([FilePropertyChange(snapshot: try await snapshot(folder), permissions: 0o700)])
            try propertyExpect(result[0].error == nil && (try attributes(child)).st_mode & 0o777 == 0o640, "directory edit recursed")
        }
        await test("property tags preserve existing colors and unicode spelling while adding no color comma labels") { dir in
            let url = try file(dir, "tags")
            try setTags(url, ["Red\n6", "Cafe\u{301}\n4", "No suffix"])
            let before = try attributes(url)
            let preview = try await snapshot(url)
            try propertyExpect(preview.tagNames == ["Red", "Café", "No suffix"], "names not NFC")
            let result = await FilePropertyService.apply([FilePropertyChange(snapshot: preview, tagNames: ["Red", "Café", "No suffix", "a,b", "新增", "Cafe\u{301}"])])
            try propertyExpect(result[0].error == nil && result[0].appliedFields == [.tags], "tags result incorrect")
            try propertyExpect(try rawTags(url) == ["Red\n6", "Cafe\u{301}\n4", "No suffix", "a,b\n0", "新增\n0"], "colors spelling or comma altered")
            try propertyExpect((try attributes(url)).st_mode == before.st_mode, "tags edit changed mode")
        }
        await test("property tags clear removes only tag attribute and nil fields remain unchanged") { dir in
            let url = try file(dir, "clear")
            try setTags(url, ["Keep\n2"])
            var finderInfo = Data(repeating: 0, count: 32)
            finderInfo[0] = 65
            try writeAttribute(url, "com.apple.FinderInfo", finderInfo)
            try writeAttribute(url, "com.maxplorer.property.other", Data([9]))
            let preview = try await snapshot(url)
            let noop = await FilePropertyService.apply([FilePropertyChange(snapshot: preview)])
            try propertyExpect(noop[0].error == nil && noop[0].appliedFields.isEmpty, "nil fields written")
            let result = await FilePropertyService.apply([FilePropertyChange(snapshot: preview, tagNames: [])])
            try propertyExpect(result[0].error == nil && result[0].appliedFields == [.tags], "clear failed")
            try propertyExpect(try readAttribute(url, tagKey) == nil, "tags xattr not removed")
            try propertyExpect(try readAttribute(url, "com.maxplorer.property.other") == Data([9]), "other xattr removed")
            try propertyExpect(try readAttribute(url, "com.apple.FinderInfo") == finderInfo, "FinderInfo changed")
        }
        await test("property tags no-op preserves original binary bytes") { dir in
            let url = try file(dir, "unchanged")
            try setTags(url, ["Cafe\u{301}\n7"])
            let before = try readAttribute(url, tagKey)
            let preview = try await snapshot(url)
            let result = await FilePropertyService.apply([FilePropertyChange(snapshot: preview, tagNames: ["Café", "Cafe\u{301}"])])
            try propertyExpect(result[0].error == nil && result[0].appliedFields.isEmpty, "canonical duplicate created a write")
            try propertyExpect(try readAttribute(url, tagKey) == before, "no-op rewrote original bytes")
        }
        await test("property malformed tag metadata is rejected without replacement") { dir in
            let url = try file(dir, "malformed")
            let variants = [Data([1,2,3]), try PropertyListSerialization.data(fromPropertyList:["bad\n8"],format:.binary,options:0), try PropertyListSerialization.data(fromPropertyList:["é\n1","e\u{301}\n2"],format:.binary,options:0)]
            for data in variants {
                try writeAttribute(url, tagKey, data)
                let result = await FilePropertyService.inspect([url])
                try propertyExpect(result[0].snapshot == nil && result[0].error == .malformedTags, "malformed metadata accepted")
                try propertyExpect(try readAttribute(url, tagKey) == data, "malformed bytes changed")
            }
        }
        await test("property oversized and nonbinary tag metadata fail without mutation") { dir in
            let url = try file(dir, "large-metadata")
            let oversized = Data(repeating: 65, count: FilePropertyService.maximumTagDataBytes + 1)
            try writeAttribute(url, tagKey, oversized)
            let large = await FilePropertyService.inspect([url])
            try propertyExpect(large[0].error == .tagDataTooLarge && large[0].snapshot == nil, "oversized metadata accepted")
            try propertyExpect(try readAttribute(url, tagKey) == oversized, "oversized bytes changed")
            let xml = try PropertyListSerialization.data(fromPropertyList: ["XML"], format: .xml, options: 0)
            try writeAttribute(url, tagKey, xml)
            let nonbinary = await FilePropertyService.inspect([url])
            try propertyExpect(nonbinary[0].error == .malformedTags && nonbinary[0].snapshot == nil, "nonbinary Finder metadata accepted")
            try propertyExpect(try readAttribute(url, tagKey) == xml, "nonbinary bytes changed")
        }
        await test("property validates permissions and tag name limits before writes") { dir in
            let url = try file(dir, "limits")
            let preview = try await snapshot(url)
            var changes = [FilePropertyChange(snapshot: preview, permissions: 0o1000)]
            for name in ["", "  ", "a\0b", "a\nb", "a\rb", "bad\n9", String(repeating:"é",count:128)] {
                changes.append(FilePropertyChange(snapshot: preview, permissions: 0o000, tagNames: [name]))
            }
            changes.append(FilePropertyChange(snapshot:preview,tagNames:(0...100).map { "tag\($0)" }))
            let result = await FilePropertyService.apply(changes)
            try propertyExpect(result.allSatisfy { $0.error != nil && $0.appliedFields.isEmpty }, "invalid input partially wrote")
            try propertyExpect((try attributes(url)).st_mode & 0o777 == preview.permissions, "validation changed permissions")
        }
        await test("property snapshot replaced path is rejected and new object untouched") { dir in
            let url = try file(dir, "source", "old")
            let preview = try await snapshot(url)
            try fm.moveItem(at:url,to:dir.appendingPathComponent("old"))
            _ = try file(dir, "source", "new")
            let before = try attributes(url)
            let result = await FilePropertyService.apply([FilePropertyChange(snapshot:preview,permissions:0o000,tagNames:["wrong"])])
            try propertyExpect(result[0].error != nil && result[0].appliedFields.isEmpty, "replaced snapshot applied")
            try propertyExpect(contents(url) == "new" && (try attributes(url)).st_mode == before.st_mode, "replacement modified")
            try propertyExpect(try readAttribute(url,tagKey) == nil, "replacement tagged")
        }
        await test("property stale permissions ctime and tag bytes refuse old preview") { dir in
            let url = try file(dir,"stale")
            var preview = try await snapshot(url)
            try propertyExpect(chmod(url.path,0o640)==0,"fixture chmod failed")
            var result = await FilePropertyService.apply([FilePropertyChange(snapshot:preview,permissions:0o700)])
            try propertyExpect(result[0].error != nil && result[0].appliedFields.isEmpty,"stale mode accepted")
            preview = try await snapshot(url)
            try setTags(url,["external\n3"])
            result = await FilePropertyService.apply([FilePropertyChange(snapshot:preview,tagNames:["overwrite"])])
            try propertyExpect(result[0].error != nil && result[0].appliedFields.isEmpty,"stale tags accepted")
            try propertyExpect(try rawTags(url)==["external\n3"],"external tags overwritten")
        }
        await test("property symlink and FIFO reject without blocking or editing referent") { dir in
            let target = try file(dir,"target")
            let link = dir.appendingPathComponent("link")
            try fm.createSymbolicLink(at:link,withDestinationURL:target)
            let fifo = dir.appendingPathComponent("fifo")
            try propertyExpect(mkfifo(fifo.path,0o600)==0,"fixture FIFO failed")
            let start=Date()
            let result = await FilePropertyService.inspect([link,fifo])
            try propertyExpect(result.allSatisfy { $0.error == .unsupportedFileType && $0.snapshot == nil },"special input accepted")
            try propertyExpect(Date().timeIntervalSince(start)<2,"FIFO blocked")
            try propertyExpect(contents(target)=="source","referent changed")
        }
        await test("property mode000 returns permission refusal and selected readable file can become000") { dir in
            let url = try file(dir,"zero")
            try propertyExpect(chmod(url.path,0)==0,"fixture mode000 failed")
            defer { chmod(url.path,0o600) }
            let refusal = await FilePropertyService.inspect([url])
            try propertyExpect(refusal[0].snapshot == nil,"mode000 unexpectedly inspectable on this host")
            if case .system(_,let code) = refusal[0].error {
                try propertyExpect(code==EACCES || code==EPERM,"mode000 wrong failure")
            } else { throw TestFailure.assertion("mode000 missing permission error") }
            try propertyExpect((try attributes(url)).st_mode & 0o777 == 0,"mode000 refusal changed mode")
            try propertyExpect(chmod(url.path,0o600)==0,"fixture restore failed")
            let result = await FilePropertyService.apply([FilePropertyChange(snapshot:try await snapshot(url),permissions:0)])
            try propertyExpect(result[0].error==nil && result[0].appliedFields==[.permissions],"fd chmod000 failed")
            try propertyExpect((try attributes(url)).st_mode & 0o777 == 0,"mode000 not applied")
        }
        await test("property partial field failure and batch continuation report exact successful writes") { dir in
            let first = try file(dir,"first")
            let second = try file(dir,"second")
            let changes = [FilePropertyChange(snapshot:try await snapshot(first),permissions:0,tagNames:["denied"]), FilePropertyChange(snapshot:try await snapshot(second),tagNames:["success"])]
            defer { chmod(first.path,0o600) }
            let result = await FilePropertyService.apply(changes)
            try propertyExpect(result[0].appliedFields==[.permissions] && result[0].error != nil,"partial write hidden")
            try propertyExpect(result[1].appliedFields==[.tags] && result[1].error==nil,"batch stopped after failure")
            try propertyExpect((try attributes(first)).st_mode & 0o777 == 0,"completed permission missing")
            try propertyExpect(try rawTags(second)==["success\n0"],"second result not applied")
        }
        #if MAXPLORER_FAULT_TESTS
        await test("property cancellation retains completed item and stops unstarted batch items") { dir in
            let urls = try (0..<3).map { try file(dir,"item\($0)") }
            var changes: [FilePropertyChange] = []
            for url in urls { changes.append(FilePropertyChange(snapshot:try await snapshot(url),tagNames:["written"])) }
            let entered=DispatchSemaphore(value:0)
            let release=DispatchSemaphore(value:0)
            let request=Task {
                await FilePropertyService.applyForTesting(changes) { index in
                    if index==1 { entered.signal(); release.wait() }
                }
            }
            await Task.detached { propertyWait(entered) }.value
            request.cancel()
            release.signal()
            let result=await request.value
            try propertyExpect(result[0].error==nil && result[0].appliedFields==[.tags],"completed result lost on cancel")
            try propertyExpect(result.dropFirst().allSatisfy { $0.error == .cancelled && $0.appliedFields.isEmpty },"unstarted items written after cancel")
            try propertyExpect(try readAttribute(urls[1],tagKey)==nil && readAttribute(urls[2],tagKey)==nil,"canceled file modified")
        }
        #endif
        if let mount=ProcessInfo.processInfo.environment["MAXPLORER_PROPERTY_READONLY_ROOT"] {
            await test("property read-only private volume refuses writes without mutation") { _ in
                let url=URL(fileURLWithPath:mount).appendingPathComponent("readonly-fixture")
                let preview=try await snapshot(url)
                let result=await FilePropertyService.apply([
                    FilePropertyChange(snapshot:preview,permissions:0o000,tagNames:["no"]),
                    FilePropertyChange(snapshot:preview,tagNames:["no"])
                ])
                for item in result {
                    try propertyExpect(item.appliedFields.isEmpty,"read-only volume reported applied field")
                    if case .system(_,let code)=item.error {
                        try propertyExpect(code==EROFS,"expected EROFS, got \(code)")
                    } else { throw TestFailure.assertion("read-only failure not reported") }
                }
                try propertyExpect((try attributes(url)).st_mode & 0o777 == preview.permissions,"read-only mode changed")
                try propertyExpect(try readAttribute(url,tagKey)==nil,"read-only tags changed")
            }
        }
    }
}
