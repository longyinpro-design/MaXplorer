import Darwin
import Foundation

extension FileOperationTests {
    static func cloudFileServiceTests() async {
        await test("cloud fake unknown nil and non-iCloud never imply local or synchronized") { dir in
            let url = try file(dir, "selected", "private fixture")
            for ubiquitous: Bool? in [nil, false] {
                var metadata = cloudCurrentMetadata(); metadata.isUbiquitousItem = ubiquitous
                let fake = CloudFileFakeAdapter(metadata: metadata)
                let snapshot = try await CloudFileService(adapter: fake.adapter).inspect([url])[0]
                try expect(snapshot.status == (ubiquitous == nil ? .unknown : .unsupported), "unconfirmed provider shown synchronized")
                try expect(!snapshot.canDownload && !snapshot.canEvict, "unconfirmed provider action enabled")
            }
            let fake = CloudFileFakeAdapter(metadata: CloudFileMetadata())
            let snapshot = try await CloudFileService(adapter: fake.adapter).inspect([url])[0]
            try expect(snapshot.status == .unknown && !snapshot.canEvict && !snapshot.canDownload, "missing metadata treated as current")
        }
        await test("cloud fake distinguishes stale downloaded current requested and busy states") { dir in
            let url = try file(dir, "selected")
            let cases: [(CloudFileDownloadStatus, CloudFileStatus)] = [(.unknown, .unknown), (.notDownloaded, .notDownloaded), (.downloaded, .downloaded), (.current, .current)]
            for (download, expected) in cases {
                var metadata = cloudCurrentMetadata(); metadata.downloadStatus = download
                let fake = CloudFileFakeAdapter(metadata: metadata)
                let snapshot = try await CloudFileService(adapter: fake.adapter).inspect([url])[0]
                try expect(snapshot.status == expected, "download states conflated")
            }
            for expected in [CloudFileStatus.downloadRequested, .downloading, .uploading, .conflicted] {
                var metadata = cloudCurrentMetadata()
                switch expected {
                case .downloadRequested: metadata.downloadRequested = true
                case .downloading: metadata.isDownloading = true
                case .uploading: metadata.isUploading = true
                case .conflicted: metadata.hasUnresolvedConflicts = true
                default: break
                }
                let fake = CloudFileFakeAdapter(metadata: metadata)
                let snapshot = try await CloudFileService(adapter: fake.adapter).inspect([url])[0]
                try expect(snapshot.status == expected && !snapshot.canEvict, "busy state hidden or evict enabled")
            }
        }
        await test("cloud fake eviction requires every affirmative safety condition including optional flags") { dir in
            let url = try file(dir, "selected", "keep")
            var cases: [CloudFileMetadata] = []
            var value = cloudCurrentMetadata(); value.isUbiquitousItem = nil; cases.append(value)
            value = cloudCurrentMetadata(); value.isUbiquitousItem = false; cases.append(value)
            for state in [CloudFileDownloadStatus.unknown, .notDownloaded, .downloaded] {
                value = cloudCurrentMetadata(); value.downloadStatus = state; cases.append(value)
            }
            for flag: Bool? in [nil, false] { value = cloudCurrentMetadata(); value.isUploaded = flag; cases.append(value) }
            for flag: Bool? in [nil, true] {
                value = cloudCurrentMetadata(); value.isUploading = flag; cases.append(value)
                value = cloudCurrentMetadata(); value.isDownloading = flag; cases.append(value)
                value = cloudCurrentMetadata(); value.downloadRequested = flag; cases.append(value)
                value = cloudCurrentMetadata(); value.hasUnresolvedConflicts = flag; cases.append(value)
            }
            let known = CloudFileFailure(NSError(domain: "FakeProvider", code: 71))
            value = cloudCurrentMetadata(); value.downloadingError = known; cases.append(value)
            value = cloudCurrentMetadata(); value.uploadingError = known; cases.append(value)
            for metadata in cases {
                let fake = CloudFileFakeAdapter(metadata: metadata)
                let service = CloudFileService(adapter: fake.adapter)
                let snapshot = try await service.inspect([url])[0]
                try expect(!snapshot.canEvict && snapshot.evictUnavailableReason != nil, "unsafe eviction gate enabled")
                try await mustFail { _ = try await service.request(.evict, for: snapshot) }
                try expect(fake.operationCounts() == (0, 0), "disabled gate called provider")
            }
            try expect(contents(url) == "keep", "gate test deleted or edited file")
        }
        await test("cloud fake safe eviction submits exactly once without deleting local data") { dir in
            let url = try file(dir, "selected", "must remain")
            let fake = CloudFileFakeAdapter(metadata: cloudCurrentMetadata())
            let service = CloudFileService(adapter: fake.adapter)
            let snapshot = try await service.inspect([url])[0]
            try expect(snapshot.canEvict, "valid safe eviction disabled")
            let receipt = try await service.request(.evict, for: snapshot)
            try expect(receipt.action == .evict && receipt.url == url && receipt.message.contains("请求已提交"), "eviction asserted completion")
            try expect(fake.operationCounts() == (0, 1), "wrong provider call count")
            try expect(contents(url) == "must remain", "service used delete fallback")
        }
        await test("cloud fake download request does not imply completion and missing identity is unavailable") { dir in
            for state in [CloudFileDownloadStatus.notDownloaded, .downloaded] {
                let url = try file(dir, state == .notDownloaded ? "placeholder" : "stale", "old")
                var metadata = cloudCurrentMetadata(); metadata.downloadStatus = state
                let fake = CloudFileFakeAdapter(metadata: metadata)
                let service = CloudFileService(adapter: fake.adapter)
                let snapshot = try await service.inspect([url])[0]
                try expect(snapshot.canDownload && !snapshot.canEvict, "downloadable state gate incorrect")
                let receipt = try await service.request(.download, for: snapshot)
                try expect(receipt.action == .download && receipt.message.contains("刷新状态确认"), "request incorrectly treated as downloaded")
                let after = try await service.inspect([url])[0]
                try expect(after.metadata?.downloadStatus == state, "request synthesized completion")
                try expect(fake.operationCounts() == (1, 0), "download did not call injected adapter once")
            }
            var metadata = cloudCurrentMetadata(); metadata.downloadStatus = .notDownloaded
            let fake = CloudFileFakeAdapter(metadata: metadata)
            let service = CloudFileService(adapter: fake.adapter)
            let missing = try await service.inspect([dir.appendingPathComponent("missing-placeholder")])[0]
            try expect(missing.identity == nil && !missing.canDownload && !missing.canEvict, "missing identity authorized cloud operation")
            try await mustFail { _ = try await service.request(.download, for: missing) }
            try expect(fake.operationCounts() == (0, 0), "missing identity reached provider")
        }
        await test("cloud fake metadata failures preserve NSError domain code and do not hide other selections") { dir in
            let bad = try file(dir, "bad")
            let good = try file(dir, "good")
            let original = NSError(domain: "Fake.Cloud.Provider", code: 401, userInfo: [NSLocalizedDescriptionKey: "metadata denied"])
            let current = cloudCurrentMetadata()
            let adapter = CloudFileAdapter(readMetadata: { url in
                if url.lastPathComponent == "bad" { throw original }
                return current
            }, startDownloading: { _ in throw TestFailure.assertion("unexpected real operation") }, evict: { _ in throw TestFailure.assertion("unexpected real operation") })
            let snapshots = try await CloudFileService(adapter: adapter).inspect([bad, good])
            try expect(snapshots.count == 2 && snapshots.map(\.url) == [bad, good], "selection order or failure row lost")
            try expect(snapshots[0].failure?.domain == original.domain && snapshots[0].failure?.code == original.code, "metadata error identity lost")
            try expect(snapshots[0].status == .failed && !snapshots[0].canEvict, "metadata failure allowed operation")
            try expect(snapshots[1].status == .current, "other selected file hidden by failure")
        }
        await test("cloud fake operation errors preserve original NSError without fallback") { dir in
            let url = try file(dir, "selected", "safe")
            for action in [CloudFileAction.download, .evict] {
                var metadata = cloudCurrentMetadata()
                if action == .download { metadata.downloadStatus = .notDownloaded }
                let fake = CloudFileFakeAdapter(metadata: metadata)
                let original = NSError(domain: "Fake.Operation", code: action == .download ? 91 : 92)
                fake.setOperationError(original)
                let service = CloudFileService(adapter: fake.adapter)
                let snapshot = try await service.inspect([url])[0]
                do { _ = try await service.request(action, for: snapshot); throw TestFailure.assertion("provider error swallowed") }
                catch let error as NSError where error.domain == original.domain { try expect(error.code == original.code, "provider errno changed") }
                try expect(fake.operationCounts() == (action == .download ? 1 : 0, action == .evict ? 1 : 0), "failure retried or used fallback")
            }
            try expect(contents(url) == "safe", "failed operation modified data")
        }
        await test("cloud fake stale inode content and metadata reject before provider request") { dir in
            let url = try file(dir, "selected", "original")
            let fake = CloudFileFakeAdapter(metadata: cloudCurrentMetadata())
            let service = CloudFileService(adapter: fake.adapter)
            let first = try await service.inspect([url])[0]
            try fm.moveItem(at: url, to: dir.appendingPathComponent("kept-original"))
            _ = try file(dir, "selected", "replacement")
            do { _ = try await service.request(.evict, for: first); throw TestFailure.assertion("replaced inode accepted") }
            catch CloudFileServiceError.staleSnapshot { }
            let second = try await service.inspect([url])[0]
            try Data("changed replacement".utf8).write(to: url)
            do { _ = try await service.request(.evict, for: second); throw TestFailure.assertion("changed file accepted") }
            catch CloudFileServiceError.staleSnapshot { }
            let third = try await service.inspect([url])[0]
            var changed = cloudCurrentMetadata(); changed.isUploading = true; fake.setMetadata(changed)
            do { _ = try await service.request(.evict, for: third); throw TestFailure.assertion("changed cloud state accepted") }
            catch CloudFileServiceError.staleSnapshot { }
            try expect(fake.operationCounts() == (0, 0), "stale request reached provider")
        }
        await test("cloud fake nofollow rejects symlink FIFO directories and multiply linked files for eviction") { dir in
            let ordinary = try file(dir, "ordinary")
            let link = dir.appendingPathComponent("symlink")
            try fm.createSymbolicLink(at: link, withDestinationURL: ordinary)
            let fifo = dir.appendingPathComponent("fifo")
            try expect(mkfifo(fifo.path, 0o600) == 0, "cannot make FIFO fixture")
            let directory = try directory(dir, "folder")
            let hardlink = dir.appendingPathComponent("hardlink")
            try fm.linkItem(at: ordinary, to: hardlink)
            let fake = CloudFileFakeAdapter(metadata: cloudCurrentMetadata())
            let service = CloudFileService(adapter: fake.adapter)
            for url in [link, fifo, directory, hardlink] {
                let snapshot = try await service.inspect([url])[0]
                try expect(!snapshot.canEvict, "nonordinary selected entry allows eviction")
                try await mustFail { _ = try await service.request(.evict, for: snapshot) }
            }
            try expect(fake.operationCounts() == (0, 0), "nofollow safety gate called provider")
        }
        await test("cloud fake detects identity changed inside metadata adapter") { dir in
            let url = try file(dir, "selected", "original")
            let current = cloudCurrentMetadata()
            let adapter = CloudFileAdapter(readMetadata: { url in
                try Data("mutation during inspection".utf8).write(to: url)
                return current
            }, startDownloading: { _ in throw TestFailure.assertion("unexpected operation") }, evict: { _ in throw TestFailure.assertion("unexpected operation") })
            let snapshot = try await CloudFileService(adapter: adapter).inspect([url])[0]
            try expect(snapshot.failure != nil && snapshot.status == .failed && !snapshot.canEvict, "identity changed while reading metadata accepted")
        }
        await test("cloud fake pre-cancellation submits nothing and read cancellation remains cancellation") { dir in
            let url = try file(dir, "selected")
            let fake = CloudFileFakeAdapter(metadata: cloudCurrentMetadata())
            let service = CloudFileService(adapter: fake.adapter)
            let snapshot = try await service.inspect([url])[0]
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await service.request(.evict, for: snapshot)
            }
            do { _ = try await cancelled.value; throw TestFailure.assertion("cancelled request submitted") }
            catch is CancellationError { }
            let cancelledInspection = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await service.inspect([url])
            }
            do { _ = try await cancelledInspection.value; throw TestFailure.assertion("cancelled inspection succeeded") }
            catch is CancellationError { }
            fake.setReadHook { withUnsafeCurrentTask { $0?.cancel() } }
            do { _ = try await service.inspect([url]); throw TestFailure.assertion("cancelled reader returned state") }
            catch is CancellationError { }
            try expect(fake.operationCounts() == (0, 0), "cancellation reached provider operation")
        }
        await test("cloud fake cancellation during submitted API does not claim request revoked") { dir in
            let url = try file(dir, "selected")
            for action in [CloudFileAction.download, .evict] {
                var metadata = cloudCurrentMetadata()
                if action == .download { metadata.downloadStatus = .notDownloaded }
                let fake = CloudFileFakeAdapter(metadata: metadata)
                fake.setOperationHook { withUnsafeCurrentTask { $0?.cancel() } }
                let service = CloudFileService(adapter: fake.adapter)
                let snapshot = try await service.inspect([url])[0]
                let receipt = try await service.request(action, for: snapshot)
                try expect(receipt.action == action && receipt.message.contains("请求已提交"), "submitted request reported as revoked")
                try expect(fake.operationCounts() == (action == .download ? 1 : 0, action == .evict ? 1 : 0), "submission count incorrect")
            }
        }
        await test("cloud fake reads only passed selection and rejects non-file URLs") { dir in
            let first = try file(dir, "first")
            let second = try file(dir, "second")
            _ = try file(dir, "unselected")
            let fake = CloudFileFakeAdapter(metadata: cloudCurrentMetadata())
            let service = CloudFileService(adapter: fake.adapter)
            let snapshots = try await service.inspect([second, first])
            try expect(snapshots.map(\.url) == [second, first] && fake.readURLs() == [second, first], "service scanned outside passed URLs")
            let invalid = try await service.inspect([
                URL(string: "https://example.invalid/file")!,
                URL(string: first.absoluteString + "%00suffix")!
            ])
            try expect(invalid.count == 2 && invalid.allSatisfy { $0.failure != nil && !$0.canDownload && !$0.canEvict }, "non-file or NUL URL accepted")
            try expect(fake.readURLs().count == 2, "invalid URL reached provider")
        }
    }

    private static func cloudCurrentMetadata() -> CloudFileMetadata {
        CloudFileMetadata(isUbiquitousItem: true, downloadStatus: .current, isDownloading: false,
                          isUploading: false, isUploaded: true, downloadRequested: false,
                          hasUnresolvedConflicts: false)
    }
}

nonisolated private final class CloudFileFakeAdapter: @unchecked Sendable {
    private let lock = NSLock()
    private var metadata: CloudFileMetadata
    private var operationError: NSError?
    private var readHook: (@Sendable () -> Void)?
    private var operationHook: (@Sendable () -> Void)?
    private var urls: [URL] = []
    private var downloads = 0
    private var evictions = 0
    init(metadata: CloudFileMetadata) { self.metadata = metadata }
    var adapter: CloudFileAdapter {
        CloudFileAdapter(readMetadata: { try self.read($0) }, startDownloading: { _ in try self.perform(download: true) }, evict: { _ in try self.perform(download: false) })
    }
    func setMetadata(_ value: CloudFileMetadata) { lock.lock(); metadata = value; lock.unlock() }
    func setOperationError(_ error: NSError) { lock.lock(); operationError = error; lock.unlock() }
    func setReadHook(_ hook: @escaping @Sendable () -> Void) { lock.lock(); readHook = hook; lock.unlock() }
    func setOperationHook(_ hook: @escaping @Sendable () -> Void) { lock.lock(); operationHook = hook; lock.unlock() }
    func operationCounts() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (downloads, evictions) }
    func readURLs() -> [URL] { lock.lock(); defer { lock.unlock() }; return urls }
    private func read(_ url: URL) throws -> CloudFileMetadata {
        lock.lock(); urls.append(url); let value = metadata; let hook = readHook; lock.unlock()
        hook?(); return value
    }
    private func perform(download: Bool) throws {
        lock.lock()
        if download { downloads += 1 } else { evictions += 1 }
        let error = operationError; let hook = operationHook
        lock.unlock()
        hook?()
        if let error { throw error }
    }
}
