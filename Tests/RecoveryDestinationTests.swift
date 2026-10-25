import Foundation

extension FileOperationTests {
    static func recoveryDestinationTests() async {
        await test("recovery destinations persist bounded deduplicated file roots and legacy") { dir in
            let suite = "MaXplorerRecoveryDestinations-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = RecentTransferDestinations(defaults: defaults, limit: 3)
            let first = dir.appendingPathComponent("first")
            let second = dir.appendingPathComponent("second")
            let third = dir.appendingPathComponent("third")
            let fourth = dir.appendingPathComponent("fourth")
            store.record([first, second, first, URL(string: "https://example.com/not-a-file")!])
            store.record([third, fourth])
            let restored = RecentTransferDestinations(defaults: defaults, limit: 3)
            try expect(restored.directories.map(\.lastPathComponent) == ["third", "fourth", "first"], "MRU bound or persistence incorrect")
            defaults.set(second.path, forKey: "LastTransferDestination")
            let roots = restored.recoveryRoots(including: [third, URL(string: "smb://example.com/share")!])
            try expect(roots.count == 4 && roots.allSatisfy(\.isFileURL), "legacy merge or non-file filtering incorrect")
            try expect(roots.contains { $0.path == second.path }, "legacy destination missing")
        }

        await test("recovery destinations record paste moves duplicates at actual enqueue") { dir in
            let suite = "MaXplorerRecoveryDestinations-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = RecentTransferDestinations(defaults: defaults)
            let queue = CopyQueueViewModel(recordDestinations: { store.record($0) })
            queue.pause()
            let source = dir.appendingPathComponent("source/item")
            let paste = dir.appendingPathComponent("paste")
            let move = dir.appendingPathComponent("move")
            let duplicate = dir.appendingPathComponent("duplicate")
            queue.enqueue([(source: source, shouldOverwrite: false)], to: paste)
            queue.enqueueMoves([(source: source, shouldOverwrite: false)], to: move)
            queue.enqueueDuplicates([(source: source, destination: duplicate.appendingPathComponent("item copy"))])
            try expect(store.directories.map(\.lastPathComponent) == ["duplicate", "move", "paste"], "queue entry point omitted destinations")
            queue.enqueue([], to: dir.appendingPathComponent("empty"), conflictResolution: .skip)
            queue.enqueue([source], to: dir.appendingPathComponent("cancelled"), conflictResolution: .cancel)
            try expect(store.directories.count == 3, "non-enqueued actions recorded roots")
            let copy = dir.appendingPathComponent("copy")
            queue.enqueue([source], to: copy, conflictResolution: .skip)
            try expect(store.directories.first?.path == copy.path, "simple copy entry point omitted destination")
            // A retry refreshes the existing item's root even after more recent
            // transfers have pushed it down the bounded history.
            let pending = queue.items[0]
            queue.cancel(pending.id)
            queue.retry(pending.id)
            try expect(store.directories.first?.path == paste.path, "retry did not refresh original destination")
            for item in queue.items { queue.cancel(item.id) }
        }

        await test("recovery destinations discover older roots without deleting residue") { dir in
            let suite = "MaXplorerRecoveryDestinations-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let old = try directory(dir, "old-transfer-root")
            let recent = try directory(dir, "recent-transfer-root")
            let residue = try directory(old, ".maxplorer-transfer-old")
            _ = try file(residue, "payload", "keep until explicit cleanup")
            RecentTransferDestinations(defaults: defaults).record([old])
            let restored = RecentTransferDestinations(defaults: defaults)
            restored.record([recent])
            let roots = restored.recoveryRoots(including: [])
            let scanned = await Task.detached { RecoveryScanner.scan(in: roots) }.value
            try expect(scanned.contains { $0.url.path == residue.path }, "older destination residue omitted")
            try expect(contents(residue.appendingPathComponent("payload")) == "keep until explicit cleanup", "scan unexpectedly cleaned residue")
        }
    }
}
