import Foundation

private actor ArchiveBrowserLoadGate {
    private var request: CheckedContinuation<ArchiveCatalog, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func load() async -> ArchiveCatalog {
        await withCheckedContinuation { continuation in
            request = continuation
            observer?.resume(); observer = nil
        }
    }
    func waitStarted() async {
        if request != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func finish(_ catalog: ArchiveCatalog) { request?.resume(returning: catalog); request = nil }
}

extension FileOperationTests {
    static func archiveBrowserTests() async {
        await test("archive browser seven zip creation and full extraction preserve nested Unicode") { dir in
            let source = try directory(dir, "源 文件夹")
            _ = try file(source, "中文.txt", "seven zip")
            _ = try directory(source, "empty")
            let archive = dir.appendingPathComponent("source.7z")
            try await ArchiveService.compress(items: [source], to: archive, format: .sevenZip)
            try expect(ArchiveService.isArchive(archive) && ArchiveService.isBrowsable(archive), "7z dispatch not enabled")
            let target = try directory(dir, "target")
            let staging = try await ArchiveService.extract(archive: archive, toStagingIn: target)
            defer { ArchiveService.removeStaging(staging) }
            try expect(contents(staging.appendingPathComponent("源 文件夹/中文.txt")) == "seven zip", "7z full extraction changed bytes")
            try expect(fm.fileExists(atPath: staging.appendingPathComponent("源 文件夹/empty").path), "7z empty dir missing")
            try await ArchiveService.moveExtractedItems(from: staging, to: target, overwrite: false, approvals: [:])
            try expect(contents(target.appendingPathComponent("源 文件夹/中文.txt")) == "seven zip", "7z safe publication failed")
        }

        for format in [ArchiveFormat.zip, .sevenZip] {
            await test("archive review prepared compression binds confirmed target \(format)") { dir in
                let source = try file(dir, "source", "payload")
                let target = try file(dir, "archive.\(format.fileExtension)", "old")
                let prepared = try await ArchiveService.prepareCompression(items: [source], to: target, format: format)
                defer { ArchiveService.removeStaging(prepared.staging) }
                let comparison = try await SafeFileOperations.captureConflictComparison(sourceURL: prepared.archive, destinationURL: target)
                _ = try file(dir, target.lastPathComponent, "racer after confirmation")
                try await mustFail { try await ArchiveService.publishCompression(prepared, overwrite: true, approval: comparison.approval) }
                try expect(contents(target) == "racer after confirmation" && fm.fileExists(atPath: prepared.archive.path),
                           "compressed output overwrote changed target or was lost")
                let fresh = try await SafeFileOperations.captureConflictComparison(sourceURL: prepared.archive, destinationURL: target)
                try await ArchiveService.publishCompression(prepared, overwrite: true, approval: fresh.approval)
                let catalog = try await ArchiveCatalogService.catalog(archive: target)
                try expect(catalog.entries.contains { $0.path == "source" }, "fresh prepared output failed publication")
                try expect(contents(source) == "payload", "compression changed source input")
            }
        }

        await test("archive review prepared compression rejects changed payload and unapproved late target") { dir in
            let source = try file(dir, "source", "payload")
            let target = dir.appendingPathComponent("archive.zip")
            let prepared = try await ArchiveService.prepareCompression(items: [source], to: target, format: .zip)
            defer { ArchiveService.removeStaging(prepared.staging) }
            _ = try file(dir, target.lastPathComponent, "late target")
            try await mustFail { try await ArchiveService.publishCompression(prepared, overwrite: false) }
            let comparison = try await SafeFileOperations.captureConflictComparison(sourceURL: prepared.archive, destinationURL: target)
            let handle = try FileHandle(forWritingTo: prepared.archive)
            try handle.seekToEnd(); try handle.write(contentsOf: Data([0x7F])); try handle.close()
            try await mustFail { try await ArchiveService.publishCompression(prepared, overwrite: true, approval: comparison.approval) }
            try expect(contents(target) == "late target" && fm.fileExists(atPath: prepared.archive.path), "unapproved or changed output published")
        }

        await test("archive browser session rejects closed and superseded directory callbacks") { dir in
            let source = try file(dir, "source", "payload")
            let archive = dir.appendingPathComponent("source.tar")
            try await ArchiveService.compress(items: [source], to: archive, format: .tar)
            let catalog = try await ArchiveCatalogService.catalog(archive: archive)
            var session = ArchiveBrowserSession()
            session.present(archive)
            let closedID = session.request!.id
            session.close(requestID: closedID)
            try expect(!session.finish(requestID: closedID, catalog: catalog, ids: ["source"], destination: dir), "closed callback retained a selection")
            try expect(session.takePendingAfterDismissal() == nil, "closed selection survived dismissal")
            session.present(archive)
            let reopenedID = session.request!.id
            try expect(reopenedID != closedID, "reopen reused request identity")
            try expect(!session.finish(requestID: closedID, catalog: catalog, ids: ["source"], destination: dir), "old callback hijacked reopened browser")
            session.close(requestID: closedID)
            try expect(session.request?.id == reopenedID, "stale close dismissed new browser")
            try expect(session.finish(requestID: reopenedID, catalog: catalog, ids: ["source"], destination: dir), "active callback rejected")
            // SwiftUI's nil binding write after a successful finish must retain
            // only the deliberate selection until actual onDismiss.
            session.close()
            try expect(session.takePendingAfterDismissal()?.ids == ["source"], "valid selection lost before dismissal")
            try expect(session.takePendingAfterDismissal() == nil, "selection committed twice")
        }

        await test("archive browser session discards pending selection before a different browser opens") { dir in
            let source = try file(dir, "source", "payload")
            let archive = dir.appendingPathComponent("source.tar")
            try await ArchiveService.compress(items: [source], to: archive, format: .tar)
            let catalog = try await ArchiveCatalogService.catalog(archive: archive)
            var session = ArchiveBrowserSession()
            session.present(archive)
            let id = session.request!.id
            try expect(session.finish(requestID: id, catalog: catalog, ids: ["source"], destination: dir), "selection failed")
            session.present(dir.appendingPathComponent("different.tar"))
            let otherID = session.request!.id
            try expect(session.takePendingAfterDismissal() == nil, "old dismissal committed pending extraction")
            try expect(!session.finish(requestID: otherID, catalog: catalog, ids: ["source"], destination: dir), "wrong archive catalog accepted")
            session.close(requestID: otherID)
            try expect(session.takePendingAfterDismissal() == nil, "different browser inherited old selection")
        }

        await test("archive browser virtual navigation uses metadata and clears selection") { dir in
            let source = try directory(dir, "folder")
            _ = try file(source, "file.txt", "not materialized")
            _ = try file(dir, "root.txt", "root")
            let archive = dir.appendingPathComponent("source.tar")
            try runTool("/usr/bin/tar", ["-cf", archive.path, "-C", dir.path, "folder", "root.txt"])
            let model = ArchiveBrowserModel(archiveURL: archive)
            model.load()
            try await waitFor { !model.isLoading }
            try expect(model.errorMessage == nil && model.visibleEntries.map(\.path) == ["folder", "root.txt"], "virtual root order incorrect")
            let folder = model.visibleEntries[0]
            model.selectedIDs = [folder.id]
            try expect(model.canExtractSelection, "directory selection rejected")
            model.enter(folder)
            try expect(model.currentPath == "folder" && model.visibleEntries.map(\.path) == ["folder/file.txt"] && model.selectedIDs.isEmpty,
                       "virtual entry failed or selection leaked")
            model.goUp()
            try expect(model.currentPath.isEmpty && !model.canGoUp && model.visibleEntries.count == 2, "virtual parent failed")
            let names = try fm.contentsOfDirectory(atPath: dir.path)
            try expect(names.allSatisfy { !$0.hasPrefix(".maxplorer-archive") },
                       "metadata browse materialized payload")
            model.cancel()
        }

        await test("archive browser cancellation rejects late noncooperative metadata") { dir in
            let source = try file(dir, "source", "x")
            let archive = dir.appendingPathComponent("source.tar")
            try runTool("/usr/bin/tar", ["-cf", archive.path, "-C", dir.path, source.lastPathComponent])
            let catalog = try await ArchiveCatalogService.catalog(archive: archive)
            let gate = ArchiveBrowserLoadGate()
            let model = ArchiveBrowserModel(archiveURL: archive, loader: { _ in await gate.load() })
            model.load()
            await gate.waitStarted()
            model.cancel()
            await gate.finish(catalog)
            for _ in 0..<8 { await Task.yield() }
            try expect(model.catalog == nil && model.visibleEntries.isEmpty && !model.isLoading, "late metadata revived cancelled model")
        }

        await test("archive browser blocked metadata does not retain closed model") { dir in
            let source = try file(dir, "source", "x")
            let archive = dir.appendingPathComponent("source.tar")
            try runTool("/usr/bin/tar", ["-cf", archive.path, "-C", dir.path, source.lastPathComponent])
            let catalog = try await ArchiveCatalogService.catalog(archive: archive)
            let gate = ArchiveBrowserLoadGate()
            var model: ArchiveBrowserModel? = ArchiveBrowserModel(archiveURL: archive, loader: { _ in await gate.load() })
            weak var closed = model
            model?.load()
            await gate.waitStarted()
            model = nil
            let retained = closed != nil
            closed = nil
            await gate.finish(catalog)
            try expect(!retained, "closed browser retained by pending metadata")
        }

        await test("archive browser read error is explicit and cannot extract") { dir in
            let archive = try file(dir, "broken.zip", "bad archive")
            let model = ArchiveBrowserModel(archiveURL: archive)
            model.load()
            try await waitFor { !model.isLoading }
            try expect(model.errorMessage != nil && model.catalog == nil && !model.canExtractSelection, "backend failure shown as empty success")
        }

        await test("archive browser publication validates compared target after prompt") { dir in
            let staging = try directory(dir, "staging")
            let item = try file(staging, "item", "new")
            let target = try directory(dir, "target")
            let existing = try file(target, "item", "old")
            let approvals = try await ArchiveService.captureConflictApprovals(items: [item], in: target)
            _ = try file(target, "item", "racer")
            try await mustFail {
                try await ArchiveService.moveExtractedItems(from: staging, to: target, overwrite: true, approvals: approvals)
            }
            try expect(contents(existing) == "racer" && contents(item) == "new", "archive reused stale overwrite approval")
            try noStaging(target)
        }

        await test("archive browser publication rejects unapproved late target and preserves planned skip") { dir in
            let staging = try directory(dir, "staging")
            let item = try file(staging, "item", "new")
            let target = try directory(dir, "target")
            let existing = try file(target, "item", "racer")
            try await mustFail {
                try await ArchiveService.moveExtractedItems(from: staging, to: target, overwrite: false, approvals: [:])
            }
            try expect(contents(existing) == "racer" && contents(item) == "new", "late target was skipped as false success or overwritten")
            let approvals = try await ArchiveService.captureConflictApprovals(items: [item], in: target)
            try fm.removeItem(at: existing)
            try await ArchiveService.moveExtractedItems(from: staging, to: target, overwrite: false, approvals: approvals)
            try expect(contents(item) == "new" && !fm.fileExists(atPath: existing.path), "planned skip unexpectedly published after target vanished")
        }
    }
}
