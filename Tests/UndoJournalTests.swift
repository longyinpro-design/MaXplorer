import Foundation

extension FileOperationTests {
    static func undoJournalTests() async {
        await test("undo rename restores the original name") { dir in
            let original = try file(dir, "original.txt", "content")
            let renamed = dir.appendingPathComponent("renamed.txt")
            try fm.moveItem(at: original, to: renamed)
            let expected = await FileUndoService.state(of: renamed)
            let entry = FileUndoEntry(kind: .rename(from: original, to: renamed, expected: expected))

            let outcome = try await FileUndoService.undo(entry)
            guard case .completed = outcome else {
                throw TestFailure.assertion("rename undo was partial")
            }
            try expect(contents(original) == "content", "rename undo lost content")
            try expect(!SafeFileOperations.entryExists(at: renamed), "rename undo left the new name")
        }

        await test("undo rename refuses after the renamed item changes") { dir in
            let original = try file(dir, "original.txt", "content")
            let renamed = dir.appendingPathComponent("renamed.txt")
            try fm.moveItem(at: original, to: renamed)
            let expected = await FileUndoService.state(of: renamed)
            try Data("changed".utf8).write(to: renamed)

            let entry = FileUndoEntry(kind: .rename(from: original, to: renamed, expected: expected))
            try await mustFail { _ = try await FileUndoService.undo(entry) }
            try expect(contents(renamed) == "changed", "changed item was restored anyway")
        }

        await test("undo move returns the item to its original location") { dir in
            let source = try file(dir, "source.txt", "content")
            let targetDirectory = try directory(dir, "target")
            let moved = targetDirectory.appendingPathComponent("source.txt")
            try await SafeFileOperations.perform(
                .move,
                sourceURL: source,
                destinationURL: moved,
                overwrite: false,
                progress: { _ in }
            )
            let expected = await FileUndoService.states(of: [moved])
            let entry = FileUndoEntry(
                kind: .move(items: [UndoMovePair(from: source, to: moved)], expected: expected)
            )

            let outcome = try await FileUndoService.undo(entry)
            guard case .completed = outcome else {
                throw TestFailure.assertion("move undo was partial")
            }
            try expect(contents(source) == "content", "move undo lost content")
            try expect(!SafeFileOperations.entryExists(at: moved), "move undo left the moved item")
        }

        await test("undo move batch returns every item") { dir in
            let first = try file(dir, "first.txt", "first")
            let second = try file(dir, "second.txt", "second")
            let targetDirectory = try directory(dir, "target")
            let firstTarget = targetDirectory.appendingPathComponent("first.txt")
            let secondTarget = targetDirectory.appendingPathComponent("second.txt")
            for (source, destination) in [(first, firstTarget), (second, secondTarget)] {
                try await SafeFileOperations.perform(
                    .move,
                    sourceURL: source,
                    destinationURL: destination,
                    overwrite: false,
                    progress: { _ in }
                )
            }
            let expected = await FileUndoService.states(of: [firstTarget, secondTarget])
            let entry = FileUndoEntry(
                kind: .move(
                    items: [
                        UndoMovePair(from: first, to: firstTarget),
                        UndoMovePair(from: second, to: secondTarget)
                    ],
                    expected: expected
                )
            )

            let outcome = try await FileUndoService.undo(entry)
            guard case .completed = outcome else {
                throw TestFailure.assertion("batch move undo was partial")
            }
            try expect(contents(first) == "first", "first item was not restored")
            try expect(contents(second) == "second", "second item was not restored")
            try expect(!SafeFileOperations.entryExists(at: firstTarget), "first item stayed in the target folder")
            try expect(!SafeFileOperations.entryExists(at: secondTarget), "second item stayed in the target folder")
        }

        await test("undo move batch reports partial failure and keeps the rest") { dir in
            let first = try file(dir, "first.txt", "first")
            let second = try file(dir, "second.txt", "second")
            let targetDirectory = try directory(dir, "target")
            let firstTarget = targetDirectory.appendingPathComponent("first.txt")
            let secondTarget = targetDirectory.appendingPathComponent("second.txt")
            for (source, destination) in [(first, firstTarget), (second, secondTarget)] {
                try await SafeFileOperations.perform(
                    .move,
                    sourceURL: source,
                    destinationURL: destination,
                    overwrite: false,
                    progress: { _ in }
                )
            }
            let expected = await FileUndoService.states(of: [firstTarget, secondTarget])
            try Data("edited".utf8).write(to: secondTarget)

            let entry = FileUndoEntry(
                kind: .move(
                    items: [
                        UndoMovePair(from: first, to: firstTarget),
                        UndoMovePair(from: second, to: secondTarget)
                    ],
                    expected: expected
                )
            )

            let outcome = try await FileUndoService.undo(entry)
            guard case .partial(let remaining, let failures) = outcome else {
                throw TestFailure.assertion("batch move undo did not report the failing item")
            }
            try expect(remaining.affectedCount == 1, "partial batch move did not retain the failing item")
            try expect(failures.count == 1, "partial batch move failure count mismatch")
            try expect(contents(first) == "first", "unchanged item was not restored")
            try expect(contents(secondTarget) == "edited", "modified item was restored anyway")
        }

        await test("undo move refuses when the original location is occupied") { dir in
            let source = try file(dir, "source.txt", "content")
            let targetDirectory = try directory(dir, "target")
            let moved = targetDirectory.appendingPathComponent("source.txt")
            try await SafeFileOperations.perform(
                .move,
                sourceURL: source,
                destinationURL: moved,
                overwrite: false,
                progress: { _ in }
            )
            let expected = await FileUndoService.states(of: [moved])
            try Data("new file".utf8).write(to: source)

            let entry = FileUndoEntry(
                kind: .move(items: [UndoMovePair(from: source, to: moved)], expected: expected)
            )
            let outcome = try await FileUndoService.undo(entry)
            guard case .partial(_, let failures) = outcome else {
                throw TestFailure.assertion("occupied original location did not block the undo")
            }
            try expect(failures.count == 1, "occupied original location produced no failure message")
            try expect(contents(moved) == "content", "moved file was lost or overwritten")
            try expect(contents(source) == "new file", "the file occupying the original location was replaced")
        }

        await test("undo copy removes the created copy") { dir in
            let source = try file(dir, "source.txt", "content")
            let copy = dir.appendingPathComponent("copy.txt")
            try fm.copyItem(at: source, to: copy)
            let expected = await FileUndoService.state(of: copy)
            let entry = FileUndoEntry(kind: .copy(created: [copy], expected: [copy: expected]))

            let outcome = try await FileUndoService.undo(entry)
            guard case .completed = outcome else {
                throw TestFailure.assertion("copy undo was partial")
            }
            try expect(!SafeFileOperations.entryExists(at: copy), "copy undo left the copy")
            try expect(contents(source) == "content", "copy undo changed the source")
        }

        await test("undo copy refuses to delete a modified copy") { dir in
            let source = try file(dir, "source.txt", "content")
            let copy = dir.appendingPathComponent("copy.txt")
            try fm.copyItem(at: source, to: copy)
            let expected = await FileUndoService.state(of: copy)
            try Data("user edit".utf8).write(to: copy)

            let entry = FileUndoEntry(kind: .copy(created: [copy], expected: [copy: expected]))
            let outcome = try await FileUndoService.undo(entry)
            guard case .partial(let remaining, let failures) = outcome else {
                throw TestFailure.assertion("modified copy was removed")
            }
            try expect(remaining.affectedCount == 1, "modified copy was dropped from the undo entry")
            try expect(!failures.isEmpty, "modified copy produced no failure message")
            try expect(contents(copy) == "user edit", "modified copy was removed")
        }

        await test("undo copy reports partial batch results") { dir in
            let first = try file(dir, "first.txt", "first")
            let second = try file(dir, "second.txt", "second")
            let firstCopy = dir.appendingPathComponent("first copy.txt")
            let secondCopy = dir.appendingPathComponent("second copy.txt")
            try fm.copyItem(at: first, to: firstCopy)
            try fm.copyItem(at: second, to: secondCopy)
            let expected = await FileUndoService.states(of: [firstCopy, secondCopy])
            try Data("edited".utf8).write(to: secondCopy)

            let entry = FileUndoEntry(kind: .copy(created: [firstCopy, secondCopy], expected: expected))
            let outcome = try await FileUndoService.undo(entry)
            guard case .partial(let remaining, let failures) = outcome else {
                throw TestFailure.assertion("partial copy undo was reported as complete")
            }
            try expect(remaining.affectedCount == 1, "partial undo did not retain the failed item")
            try expect(failures.count == 1, "partial undo failure count mismatch")
            try expect(!SafeFileOperations.entryExists(at: firstCopy), "unchanged copy was not removed")
            try expect(contents(secondCopy) == "edited", "modified copy was removed")
        }

        await test("undo refuses to replay an overwrite marker") { dir in
            let entry = FileUndoEntry(
                kind: .notRestorable(action: "覆盖", detail: "“report.txt”被覆盖，此操作无法撤销。")
            )
            try await mustFail { _ = try await FileUndoService.undo(entry) }
        }

        await test("undo journal keeps at most 20 entries with the newest first") { dir in
            let journal = FileUndoJournal(limit: 20)
            let state = UndoItemState(
                exists: true,
                isDirectory: false,
                size: 1,
                modifiedAt: nil,
                fingerprint: "state"
            )

            for index in 0..<25 {
                journal.record(
                    FileUndoEntry(
                        kind: .rename(
                            from: dir.appendingPathComponent("old\(index)"),
                            to: dir.appendingPathComponent("new\(index)"),
                            expected: state
                        )
                    )
                )
            }

            try expect(journal.entries.count == 20, "journal did not enforce its limit")
            try expect(
                journal.entries.first?.historyDetail.contains("new24") == true,
                "journal did not keep the newest entry first"
            )
            try expect(
                journal.entries.last?.historyDetail.contains("new5") == true,
                "journal trimmed the wrong entries"
            )
        }

        await test("undo journal skips non-restorable markers for the next undo") { dir in
            let journal = FileUndoJournal(limit: 20)
            let copy = dir.appendingPathComponent("copy.txt")
            let state = UndoItemState(
                exists: true,
                isDirectory: false,
                size: 1,
                modifiedAt: nil,
                fingerprint: "state"
            )
            let copyEntry = FileUndoEntry(kind: .copy(created: [copy], expected: [copy: state]))
            let marker = FileUndoEntry(
                kind: .notRestorable(action: "覆盖", detail: "“x.txt”被覆盖，此操作无法撤销。")
            )

            journal.record(copyEntry)
            journal.record(marker)

            try expect(journal.canUndo, "journal did not find the older restorable entry")
            try expect(journal.nextUndoableEntry?.id == copyEntry.id, "journal offered the overwrite marker as undo target")
            try expect(journal.undoActionTitle == "复制", "undo menu title ignored the marker")
            try expect(journal.entries.first?.id == marker.id, "history no longer shows the newest entry first")

            journal.remove(id: copyEntry.id)
            try expect(!journal.canUndo, "journal still offered an undo target")
            try expect(journal.entries.count == 1, "removing the undone entry dropped the history marker")
            try expect(journal.entries.first?.isRestorable == false, "history marker lost its non-restorable state")
        }

        await test("undo journal replaces a partially undone entry in place") { dir in
            let journal = FileUndoJournal(limit: 20)
            let olderURL = dir.appendingPathComponent("older.txt")
            let newestURL = dir.appendingPathComponent("newest.txt")
            let older = FileUndoEntry(kind: .copy(created: [olderURL], expected: [:]))
            let newest = FileUndoEntry(kind: .copy(created: [newestURL], expected: [:]))
            journal.record(older)
            journal.record(newest)

            let remaining = FileUndoEntry(
                id: newest.id,
                kind: .copy(created: [newestURL], expected: [:]),
                createdAt: newest.createdAt
            )
            journal.replace(remaining)

            try expect(journal.entries.count == 2, "partial undo changed the history size")
            try expect(journal.entries.first?.id == newest.id, "partial undo did not stay on top")
            try expect(journal.entries.last?.id == older.id, "partial undo moved the older entry")
        }

        await test("undo journal records an unknown replacement entry") { dir in
            let journal = FileUndoJournal(limit: 20)
            let unknown = FileUndoEntry(
                id: UUID(),
                kind: .copy(created: [dir.appendingPathComponent("unknown.txt")], expected: [:])
            )

            journal.replace(unknown)

            try expect(journal.entries.count == 1, "unknown replacement was dropped")
            try expect(journal.entries.first?.id == unknown.id, "unknown replacement id changed")
        }

        await test("undo batch accumulator groups a whole batch") { dir in
            var accumulator = UndoBatchAccumulator()
            let first = dir.appendingPathComponent("first.txt")
            let second = dir.appendingPathComponent("second.txt")

            accumulator.recordCopy(created: first)
            accumulator.recordCopy(created: second)
            accumulator.recordCopy(created: first)
            try expect(accumulator.copiedDestinations == [first, second], "copy batch did not deduplicate destinations")

            let target = dir.appendingPathComponent("target")
            accumulator.recordMove(from: first, to: target.appendingPathComponent("first.txt"))
            accumulator.recordMove(from: first, to: target.appendingPathComponent("first.txt"))
            try expect(accumulator.movedItems.count == 1, "move batch did not deduplicate moves")

            accumulator.recordOverwrite(second)
            accumulator.recordOverwrite(second)
            try expect(
                accumulator.overwrittenDestinations == [second],
                "overwrite markers were not deduplicated"
            )
            try expect(!accumulator.isEmpty, "accumulator with an overwrite marker reported empty")

            let entry = FileUndoEntry(
                kind: .copy(created: accumulator.copiedDestinations, expected: [:])
            )
            try expect(entry.menuTitle == "复制（2 项）", "batch menu title did not include the item count")
            try expect(entry.isRestorable, "copy entry was marked as non-restorable")
        }
    }
}
