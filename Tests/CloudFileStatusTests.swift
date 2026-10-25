import Foundation

extension FileOperationTests {
    static func cloudFileStatusTests() async {
        await test("cloud status model confirmation tokens reject old cancelled and duplicate requests") { dir in
            let file = try file(dir, "selected", "unchanged")
            let fake = CloudStatusFakeAdapter()
            let model = CloudFileStatusModel(service: CloudFileService(adapter: fake.adapter))
            model.load([file]); while model.isLoading { await Task.yield() }
            let snapshot = model.snapshots[0]
            model.prepare(.evict, for: snapshot)
            let oldID = model.confirmation!.id
            model.cancelConfirmation(); await model.submit(confirmationID: oldID)
            try expect(fake.count() == 0, "cancelled confirmation executed")
            model.prepare(.evict, for: snapshot)
            let newID = model.confirmation!.id
            await model.submit(confirmationID: oldID)
            try expect(model.confirmation?.id == newID && fake.count() == 0, "stale token executed or cleared new confirmation")
            await model.submit(confirmationID: newID); await model.submit(confirmationID: newID)
            try expect(fake.count() == 1 && model.messages[file]?.contains("请求已提交") == true, "duplicate request or receipt lost")
            try expect(contents(file) == "unchanged", "fake tests deleted local content")
        }
        await test("cloud status model download receipt remains a request after metadata refresh") { dir in
            let file = try file(dir, "placeholder", "private bytes")
            let fake = CloudStatusFakeAdapter(); fake.setDownloadStatus(.notDownloaded)
            let model = CloudFileStatusModel(service: CloudFileService(adapter: fake.adapter))
            model.load([file]); while model.isLoading { await Task.yield() }
            model.prepare(.download, for: model.snapshots[0])
            await model.submit(confirmationID: model.confirmation!.id)
            try expect(fake.count() == 1 && model.snapshots[0].status == .notDownloaded, "download request fabricated current state")
            try expect(model.messages[file]?.contains("是否完成") == true && model.error == nil, "request/completion distinction missing")
        }
        await test("cloud status model revalidates reviewed state and reports provider errors") { dir in
            let file = try file(dir, "selected")
            let fake = CloudStatusFakeAdapter()
            let model = CloudFileStatusModel(service: CloudFileService(adapter: fake.adapter))
            model.load([file]); while model.isLoading { await Task.yield() }
            model.prepare(.evict, for: model.snapshots[0])
            fake.setDownloadStatus(.downloaded)
            await model.submit(confirmationID: model.confirmation!.id)
            try expect(fake.count() == 0 && model.error != nil && model.messages.isEmpty, "stale state submitted or reported success")
            fake.setDownloadStatus(.current)
            model.load([file]); while model.isLoading { await Task.yield() }
            model.prepare(.evict, for: model.snapshots[0])
            fake.setError(NSError(domain: "Fake.Status.Provider", code: 73, userInfo: [NSLocalizedDescriptionKey: "refused"]))
            await model.submit(confirmationID: model.confirmation!.id)
            // Preserve provider domain/code as well as the localized message.
            try expect(fake.count() == 1 && model.error?.contains("refused") == true && model.error?.contains("Fake.Status.Provider") == true && model.error?.contains("73") == true && model.messages.isEmpty, "provider failure hidden as success")
        }
        await test("cloud status model unsupported selection has no actionable confirmation") { dir in
            let file = try file(dir, "ordinary")
            let fake = CloudStatusFakeAdapter(); fake.setUbiquitous(false)
            let model = CloudFileStatusModel(service: CloudFileService(adapter: fake.adapter))
            model.load([file]); while model.isLoading { await Task.yield() }
            for action in [CloudFileAction.download, .evict] {
                model.prepare(action, for: model.snapshots[0])
                try expect(model.confirmation == nil && model.error != nil, "unsupported provider got a confirmation")
            }
            try expect(model.snapshots[0].status == .unsupported && fake.count() == 0, "ordinary file inferred synchronized")
        }
    }
}

nonisolated private final class CloudStatusFakeAdapter: @unchecked Sendable {
    private let lock = NSLock()
    private var metadata = CloudFileMetadata(isUbiquitousItem: true, downloadStatus: .current,
        isDownloading: false, isUploading: false, isUploaded: true, downloadRequested: false, hasUnresolvedConflicts: false)
    private var calls = 0
    private var error: NSError?
    var adapter: CloudFileAdapter {
        CloudFileAdapter(readMetadata: { _ in self.read() }, startDownloading: { _ in try self.request() }, evict: { _ in try self.request() })
    }
    func setDownloadStatus(_ state: CloudFileDownloadStatus) { lock.lock(); metadata.downloadStatus = state; lock.unlock() }
    func setUbiquitous(_ state: Bool) { lock.lock(); metadata.isUbiquitousItem = state; lock.unlock() }
    func setError(_ value: NSError) { lock.lock(); error = value; lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
    private func read() -> CloudFileMetadata { lock.lock(); defer { lock.unlock() }; return metadata }
    private func request() throws {
        lock.lock(); calls += 1; let error = error; lock.unlock()
        if let error { throw error }
    }
}
