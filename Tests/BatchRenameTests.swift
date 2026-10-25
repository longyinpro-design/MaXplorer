import Foundation
import Darwin

extension FileOperationTests {
    static func batchRenameTests() async {

        await test("batch rename treats inserted template tokens as literal text") { dir in
            let source = try file(dir, "report-{index}-{date}.txt", "content")
            let preview = BatchRenameService.preview(urls: [source], options: BatchRenameOptions())
            try expect(preview[0].proposedName == source.lastPathComponent, "default template reinterpreted the file name")
            try expect(!preview[0].isChange, "default options unexpectedly rename a file")
            var options = BatchRenameOptions()
            options.template = "{name}-{index}"
            let numbered = BatchRenameService.preview(urls: [source], options: options)
            try expect(numbered[0].proposedName == "report-{index}-{date}-01.txt", "inserted tokens were expanded")
        }

        await test("batch rename rechecks targets changed after preview") { dir in
            let source = try file(dir, "a.txt", "A")
            var options = BatchRenameOptions()
            options.template = "target"
            let preview = BatchRenameService.preview(urls: [source], options: options)
            let target = try file(dir, "target.txt", "external")
            let result = await BatchRenameService.execute(preview)
            try expect(result.renamed.isEmpty && !result.failures.isEmpty, "external target was accepted")
            try expect(contents(source) == "A" && contents(target) == "external", "external conflict changed data")
        }

        await test("batch rename rolls back a group when staging fails") { dir in
            let first = try file(dir, "a.txt", "A")
            let second = dir.appendingPathComponent("b.txt")
            let items = [
                BatchRenamePreviewItem(id: 0, source: first, originalName: "a.txt", proposedName: "b.txt", issue: nil),
                BatchRenamePreviewItem(id: 1, source: second, originalName: "b.txt", proposedName: "a.txt", issue: nil),
            ]
            let result = await BatchRenameService.execute(items)
            try expect(result.renamed.isEmpty && !result.failures.isEmpty, "missing dependency did not fail the group")
            let names = try fm.contentsOfDirectory(atPath: dir.path)
            try expect(names == ["a.txt"] && contents(first) == "A", "staged file did not return to its original name")
        }

        await test("batch rename rolls back published names before restoring a failed group") { dir in
            let first = try file(dir, "a.txt", "A")
            let second = try file(dir, "b.txt", "B")
            // Force a publication error after the first publish. Normal preview
            // rejects this duplicate; the execution boundary must still retain data.
            let items = [
                BatchRenamePreviewItem(id: 0, source: first, originalName: "a.txt", proposedName: "c.txt", issue: nil),
                BatchRenamePreviewItem(id: 1, source: second, originalName: "b.txt", proposedName: "c.txt", issue: nil),
            ]
            let result = await BatchRenameService.execute(items)
            try expect(result.renamed.isEmpty && !result.failures.isEmpty, "publication failure was not rolled back")
            try expect(contents(first) == "A" && contents(second) == "B", "rollback lost original contents")
            let names = try fm.contentsOfDirectory(atPath: dir.path).sorted()
            try expect(names == ["a.txt", "b.txt"], "rollback left names behind: \(names)")
        }

        await test("batch rename undo preserves a modified member of a swap") { dir in
            let first = try file(dir, "a.txt", "A")
            let second = try file(dir, "b.txt", "B")
            let items = [
                BatchRenamePreviewItem(id: 0, source: first, originalName: "a.txt", proposedName: "b.txt", issue: nil),
                BatchRenamePreviewItem(id: 1, source: second, originalName: "b.txt", proposedName: "a.txt", issue: nil),
            ]
            let result = await BatchRenameService.execute(items)
            let states = await FileUndoService.states(of: result.renamed.map(\.to))
            try Data("external edit".utf8).write(to: second)
            let entry = FileUndoEntry(kind: .renameBatch(items: result.renamed, expected: states))
            let undone = try await FileUndoService.undo(entry)
            guard case .partial(let remaining, _) = undone else { throw TestFailure.assertion("changed swap was undone") }
            try expect(remaining.affectedCount == 2, "blocked swap dependency disappeared from journal")
            try expect(contents(first) == "B" && contents(second) == "external edit", "undo touched an externally changed swap")
        }

        for proposals in [["b.txt", "a.txt"], ["A.txt", "B.txt"], ["b.txt", "c.txt"]] {
            await test("batch rename regression undo \(proposals.joined(separator: ","))") { dir in
                let first = try file(dir, "a.txt", "A")
                let second = try file(dir, "b.txt", "B")
                let items = zip([first, second], proposals).enumerated().map { index, pair in
                    BatchRenamePreviewItem(id: index, source: pair.0, originalName: pair.0.lastPathComponent, proposedName: pair.1, issue: nil)
                }
                let outcome = await BatchRenameService.execute(items)
                try expect(outcome.failures.isEmpty && outcome.renamed.count == 2, "rename did not complete")
                let states = await FileUndoService.states(of: outcome.renamed.map(\.to))
                let entry = FileUndoEntry(kind: .renameBatch(items: outcome.renamed, expected: states))
                let undone = try await FileUndoService.undo(entry)
                guard case .completed = undone else { throw TestFailure.assertion("dependent rename undo was partial") }
                try expect(contents(first) == "A" && contents(second) == "B", "undo did not restore original contents")
                let names = try fm.contentsOfDirectory(atPath: dir.path).sorted()
                try expect(names == ["a.txt", "b.txt"], "undo did not restore exact names: \(names)")
            }
        }

        await test("batch rename regression cancellation restores staged names") { dir in
            let first = try file(dir, "x.txt", "X")
            let second = try file(dir, "a.txt", "A")
            let items = [
                BatchRenamePreviewItem(id: 0, source: first, originalName: "x.txt", proposedName: "y.txt", issue: nil),
                BatchRenamePreviewItem(id: 1, source: second, originalName: "a.txt", proposedName: "A.txt", issue: nil),
            ]
            let task = Task {
                await BatchRenameService.execute(items) { done, _ in
                    if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            let outcome = await task.value
            try expect(outcome.cancelled, "cancellation was not reported")
            try expect(outcome.failures.isEmpty, "cancelled cleanup failed: \(outcome.failures)")
            try expect(contents(second) == "A", "staged source was not restored")
            let names = try fm.contentsOfDirectory(atPath: dir.path)
            try expect(!names.contains { $0.hasPrefix(".maxplorer-rename-") }, "temporary rename residue remained")
        }
        await test("batch rename expands template variables") { dir in
            let folder = try directory(dir, "Trip")
            let photo = try file(folder, "photo.jpg", "a")
            let clip = try file(folder, "clip.mov", "b")
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            var options = BatchRenameOptions()
            options.template = "{parent}-{name}-{index}-{date}"
            options.padding = 2

            let preview = BatchRenameService.preview(urls: [photo, clip], options: options, date: date)
            let dateText = BatchRenameName.dateText(date)

            try expect(preview.count == 2, "unexpected preview size")
            try expect(preview[0].proposedName == "Trip-photo-01-\(dateText).jpg", "unexpected name \(preview[0].proposedName)")
            try expect(preview[1].proposedName == "Trip-clip-02-\(dateText).mov", "unexpected name \(preview[1].proposedName)")
            try expect(preview.allSatisfy { $0.issue == nil }, "unexpected validation issue")
        }

        await test("batch rename keeps the extension when the template omits it") { dir in
            let source = try file(dir, "a.txt", "content")
            var options = BatchRenameOptions()
            options.template = "{name}-{index}"
            options.padding = 2

            let preview = BatchRenameService.preview(urls: [source], options: options)
            try expect(preview[0].proposedName == "a-01.txt", "extension was not kept: \(preview[0].proposedName)")

            let outcome = await BatchRenameService.execute(preview)
            try expect(outcome.failures.isEmpty, "unexpected failure \(outcome.failures)")
            try expect(contents(dir.appendingPathComponent("a-01.txt")) == "content", "content lost")
            try expect(!SafeFileOperations.entryExists(at: source), "old name still exists")
        }

        await test("batch rename applies find, replace and case conversion") { dir in
            let source = try file(dir, "IMG_001.JPG", "content")
            var options = BatchRenameOptions()
            options.template = "{name}"
            options.findText = "IMG_"
            options.replaceText = "Photo_"
            options.caseMode = .lowercase

            let preview = BatchRenameService.preview(urls: [source], options: options)
            try expect(preview[0].proposedName == "photo_001.JPG", "unexpected name \(preview[0].proposedName)")
        }

        await test("batch rename respects start number, step and padding") { dir in
            let names = ["a.txt", "b.txt", "c.txt"]
            let urls = try names.map { try file(dir, $0, $0) }
            var options = BatchRenameOptions()
            options.template = "{index}"
            options.startNumber = 5
            options.step = 2
            options.padding = 0

            let preview = BatchRenameService.preview(urls: urls, options: options)
            try expect(preview.map(\.proposedName) == ["5.txt", "7.txt", "9.txt"], "unexpected numbers \(preview.map(\.proposedName))")
        }

        await test("batch rename supports unicode names") { dir in
            let source = try file(dir, "文档.txt", "内容")
            var options = BatchRenameOptions()
            options.template = "{name}-副本"
            options.caseMode = .uppercase

            let preview = BatchRenameService.preview(urls: [source], options: options)
            try expect(preview[0].proposedName == "文档-副本.txt", "unexpected name \(preview[0].proposedName)")

            let outcome = await BatchRenameService.execute(preview)
            try expect(outcome.failures.isEmpty, "unexpected failure \(outcome.failures)")
            try expect(outcome.renamed.count == 1, "unicode rename was not reported")
        }

        await test("batch rename preview rejects duplicate names") { dir in
            let first = try file(dir, "a.txt", "a")
            let second = try file(dir, "b.txt", "b")
            var options = BatchRenameOptions()
            options.template = "same"

            let preview = BatchRenameService.preview(urls: [first, second], options: options)
            try expect(preview.allSatisfy { $0.issue == "与同批次的其他项目重名" }, "duplicate was not rejected")
        }

        await test("batch rename preview rejects illegal characters and empty names") { dir in
            let source = try file(dir, "a.txt", "content")

            var slashed = BatchRenameOptions()
            slashed.template = "{name}/x"
            let slashPreview = BatchRenameService.preview(urls: [source], options: slashed)
            try expect(slashPreview[0].issue == "名称不能包含 / 或 :", "slash was not rejected")

            var empty = BatchRenameOptions()
            empty.template = "   "
            empty.keepsExtension = false
            let emptyPreview = BatchRenameService.preview(urls: [source], options: empty)
            try expect(emptyPreview[0].issue == "名称不能为空", "empty name was not rejected")
        }

        await test("batch rename preview rejects an existing target") { dir in
            let source = try file(dir, "a.txt", "content")
            _ = try file(dir, "target.txt", "other")
            var options = BatchRenameOptions()
            options.template = "target"

            let preview = BatchRenameService.preview(urls: [source], options: options)
            try expect(preview[0].issue == "目标名称已存在", "existing target was not rejected")

            let outcome = await BatchRenameService.execute(preview)
            try expect(outcome.renamed.isEmpty, "invalid batch was executed")
            try expect(contents(source) == "content", "source was changed")
        }

        await test("batch rename swaps names through temporary names") { dir in
            let first = try file(dir, "a.txt", "A")
            let second = try file(dir, "b.txt", "B")
            let items = [
                BatchRenamePreviewItem(id: 0, source: first, originalName: "a.txt", proposedName: "b.txt", issue: nil),
                BatchRenamePreviewItem(id: 1, source: second, originalName: "b.txt", proposedName: "a.txt", issue: nil),
            ]

            let outcome = await BatchRenameService.execute(items)
            try expect(outcome.failures.isEmpty, "swap failed: \(outcome.failures)")
            try expect(outcome.renamed.count == 2, "swap was not reported")
            try expect(contents(first) == "B", "content did not follow the swap")
            try expect(contents(second) == "A", "content did not follow the swap")
        }

        await test("batch rename resolves chains without collisions") { dir in
            let first = try file(dir, "a.txt", "A")
            let second = try file(dir, "b.txt", "B")
            let items = [
                BatchRenamePreviewItem(id: 0, source: first, originalName: "a.txt", proposedName: "b.txt", issue: nil),
                BatchRenamePreviewItem(id: 1, source: second, originalName: "b.txt", proposedName: "c.txt", issue: nil),
            ]

            let outcome = await BatchRenameService.execute(items)
            try expect(outcome.failures.isEmpty, "chain failed: \(outcome.failures)")
            try expect(contents(dir.appendingPathComponent("b.txt")) == "A", "first item did not reach b.txt")
            try expect(contents(dir.appendingPathComponent("c.txt")) == "B", "second item did not reach c.txt")
        }

        await test("batch rename handles case-only renames") { dir in
            let source = try file(dir, "a.txt", "content")
            let items = [
                BatchRenamePreviewItem(id: 0, source: source, originalName: "a.txt", proposedName: "A.txt", issue: nil),
            ]

            let outcome = await BatchRenameService.execute(items)
            try expect(outcome.failures.isEmpty, "case-only rename failed: \(outcome.failures)")
            try expect(contents(dir.appendingPathComponent("A.txt")) == "content", "content lost")
        }

        await test("batch rename reports partial failures") { dir in
            let writable = try directory(dir, "writable")
            let locked = try directory(dir, "locked")
            let first = try file(writable, "one.txt", "one")
            let second = try file(locked, "two.txt", "two")
            chmod(locked.path, 0o555)
            defer { chmod(locked.path, 0o755) }

            let items = [
                BatchRenamePreviewItem(id: 0, source: first, originalName: "one.txt", proposedName: "one-renamed.txt", issue: nil),
                BatchRenamePreviewItem(id: 1, source: second, originalName: "two.txt", proposedName: "two-renamed.txt", issue: nil),
            ]

            let outcome = await BatchRenameService.execute(items)
            try expect(outcome.renamed.count == 1, "expected one successful rename, got \(outcome.renamed.count)")
            try expect(outcome.failures.count == 1, "expected one failure, got \(outcome.failures)")
            try expect(contents(writable.appendingPathComponent("one-renamed.txt")) == "one", "first rename lost content")
            try expect(contents(second) == "two", "failed item was moved anyway")
        }

        await test("batch rename can be cancelled before it starts") { dir in
            let first = try file(dir, "a.txt", "A")
            let items = [
                BatchRenamePreviewItem(id: 0, source: first, originalName: "a.txt", proposedName: "b.txt", issue: nil),
            ]

            let task = Task { await BatchRenameService.execute(items) }
            task.cancel()
            let outcome = await task.value
            try expect(outcome.cancelled, "expected the batch to report cancellation")
            try expect(outcome.renamed.isEmpty, "cancelled batch renamed items")
            try expect(contents(first) == "A", "cancelled batch changed the source")
        }

        await test("batch rename records an undoable entry that restores names") { dir in
            let first = try file(dir, "a.txt", "A")
            let second = try file(dir, "b.txt", "B")
            var options = BatchRenameOptions()
            options.template = "renamed-{index}"
            options.padding = 2

            let preview = BatchRenameService.preview(urls: [first, second], options: options)
            let outcome = await BatchRenameService.execute(preview)
            try expect(outcome.renamed.count == 2, "batch rename did not complete")

            let states = await FileUndoService.states(of: outcome.renamed.map(\.to))
            let entry = FileUndoEntry(kind: .renameBatch(items: outcome.renamed, expected: states))
            try expect(entry.title == "重命名", "unexpected title \(entry.title)")
            try expect(entry.affectedCount == 2, "unexpected affected count")
            try expect(entry.menuTitle == "重命名（2 项）", "unexpected menu title \(entry.menuTitle)")

            let undoOutcome = try await FileUndoService.undo(entry)
            guard case .completed = undoOutcome else {
                throw TestFailure.assertion("rename batch undo was partial")
            }
            try expect(contents(first) == "A", "first name was not restored")
            try expect(contents(second) == "B", "second name was not restored")
        }

        await test("batch rename undo refuses items changed after the batch") { dir in
            let first = try file(dir, "a.txt", "A")
            let second = try file(dir, "b.txt", "B")
            var options = BatchRenameOptions()
            options.template = "renamed-{index}"

            let preview = BatchRenameService.preview(urls: [first, second], options: options)
            let outcome = await BatchRenameService.execute(preview)
            let states = await FileUndoService.states(of: outcome.renamed.map(\.to))

            // Modify one of the renamed items after the batch finished.
            try Data("changed".utf8).write(to: outcome.renamed[0].to)

            let entry = FileUndoEntry(kind: .renameBatch(items: outcome.renamed, expected: states))
            let undoOutcome = try await FileUndoService.undo(entry)
            guard case .partial(let remaining, let failures) = undoOutcome else {
                throw TestFailure.assertion("expected a partial undo")
            }
            try expect(remaining.affectedCount == 1, "unexpected remaining count \(remaining.affectedCount)")
            try expect(failures.count == 1, "unexpected failure count \(failures.count)")
            try expect(contents(dir.appendingPathComponent("b.txt")) == "B", "untouched item was not restored")
            try expect(!SafeFileOperations.entryExists(at: first), "modified item was restored anyway")
            try expect(contents(outcome.renamed[0].to) == "changed", "modified item was overwritten")
        }
    }
}
