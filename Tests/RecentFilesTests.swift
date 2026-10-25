import Foundation
import Darwin

private final class RecentProbeGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    nonisolated func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 5) == .success
    }

    nonisolated func probe(_ url: URL) -> RecentFile.Availability {
        entered.signal()
        guard release.wait(timeout: .now() + 10) == .success else { return .unavailable }
        return .available
    }
}

extension FileOperationTests {
    static func recentFilesTests() async {
        await test("recent files persist MRU and timestamp without probing") { dir in
            let suite = "MaXplorer.RecentFilesTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = RecentFilesStore(defaults: defaults, probe: { _ in
                preconditionFailure("record must never probe the filesystem")
            })
            let a = dir.appendingPathComponent("a")
            let b = dir.appendingPathComponent("b")
            store.record(a, date: Date(timeIntervalSince1970: 1))
            store.record(b, date: Date(timeIntervalSince1970: 2))
            store.record(a, date: Date(timeIntervalSince1970: 3))
            try expect(store.entries.map(\.url) == [a, b], "MRU order or deduplication wrong")
            let restored = RecentFilesStore(defaults: defaults)
            try expect(restored.entries == store.entries, "persisted entries differ")
            try expect(restored.entries.first?.lastOpened == Date(timeIntervalSince1970: 3), "timestamp lost")
            try expect(restored.entries.first?.name == "a", "display name wrong")
            restored.remove(a)
            try expect(RecentFilesStore(defaults: defaults).entries.map(\.url) == [b], "remove did not persist")
            restored.clear()
            try expect(RecentFilesStore(defaults: defaults).entries.isEmpty, "clear did not persist")
        }
        await test("recent files bound fifty records and reject remote URLs") { dir in
            let suite = "MaXplorer.RecentFilesTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = RecentFilesStore(defaults: defaults)
            for index in 0..<55 { store.record(dir.appendingPathComponent("file-\(index)")) }
            store.record(URL(string: "https://example.com/file")!)
            store.record(URL(string: "file://server/share/file")!)
            try expect(store.entries.count == 50, "MRU limit or URL validation wrong")
            try expect(store.entries.first?.name == "file-54" && store.entries.last?.name == "file-5", "wrong records retained")
            let alternate = URL(fileURLWithPath: dir.path + "/other/../file-54")
            store.record(alternate)
            try expect(store.entries.count == 50 && store.entries.first?.name == "file-54", "lexical normalization did not deduplicate")
        }
        await test("recent files refresh known paths without resolving links") { dir in
            let suite = "MaXplorer.RecentFilesTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = RecentFilesStore(defaults: defaults)
            let regular = try file(dir, "regular")
            let missing = dir.appendingPathComponent("missing")
            let link = dir.appendingPathComponent("link")
            try fm.createSymbolicLink(at: link, withDestinationURL: regular)
            let loop = dir.appendingPathComponent("loop")
            try fm.createSymbolicLink(at: loop, withDestinationURL: loop)
            let privateFile = try file(dir, "private")
            chmod(privateFile.path, 0)
            defer { chmod(privateFile.path, 0o600) }
            for url in [regular, missing, link, loop, dir, privateFile] { store.record(url) }
            await store.refreshAvailability()
            let statuses = Dictionary(uniqueKeysWithValues: store.entries.map { ($0.url, $0.status) })
            try expect(statuses[regular] == .available, "regular file unavailable")
            try expect(statuses[missing] == .missing, "missing path status wrong")
            try expect(statuses[link] == .unavailable && statuses[loop] == .unavailable, "symlink resolved")
            try expect(store.entries.first { $0.url.path == dir.path }?.status == .unavailable, "directory accepted as regular file")
            if geteuid() != 0 { try expect(statuses[privateFile] == .unavailable, "unreadable file available") }
            try expect(store.entries.count == 6, "refresh deleted unavailable history")
            let restored = RecentFilesStore(defaults: defaults)
            try expect(restored.entries.allSatisfy { $0.status == .unavailable }, "persisted availability reused without refresh")
        }
        await test("recent files injected probe keeps unavailable entries") { dir in
            let suite = "MaXplorer.RecentFilesTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = RecentFilesStore(defaults: defaults, probe: { _ in .unavailable })
            store.record(dir.appendingPathComponent("permission-denied"))
            await store.refreshAvailability()
            try expect(store.entries.count == 1 && store.entries[0].status == .unavailable, "probe failure lost history")
        }
        await test("recent files clear rejects late refresh results") { dir in
            let suite = "MaXplorer.RecentFilesTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let gate = RecentProbeGate()
            let store = RecentFilesStore(defaults: defaults, probe: { gate.probe($0) })
            store.record(dir.appendingPathComponent("file"))
            let refresh = Task { await store.refreshAvailability() }
            let entered = await Task.detached { gate.waitUntilEntered() }.value
            try expect(entered, "background probe did not start")
            store.clear()
            gate.release.signal()
            await refresh.value
            try expect(store.entries.isEmpty, "late refresh resurrected cleared history")
            try expect(RecentFilesStore(defaults: defaults).entries.isEmpty, "late refresh rewrote persisted history")
        }
        await test("recent files cancelled refresh rejects late results") { dir in
            let suite = "MaXplorer.RecentFilesTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let gate = RecentProbeGate()
            let store = RecentFilesStore(defaults: defaults, probe: { gate.probe($0) })
            store.record(dir.appendingPathComponent("file"))
            let refresh = Task { await store.refreshAvailability() }
            let entered = await Task.detached { gate.waitUntilEntered() }.value
            try expect(entered, "background probe did not start")
            refresh.cancel()
            gate.release.signal()
            await refresh.value
            try expect(store.entries.first?.status == .unavailable, "cancelled refresh applied result")
        }
        await test("recent files record rejects older refresh snapshot") { dir in
            let suite = "MaXplorer.RecentFilesTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let gate = RecentProbeGate()
            let store = RecentFilesStore(defaults: defaults, probe: { gate.probe($0) })
            let a = dir.appendingPathComponent("a")
            let b = dir.appendingPathComponent("b")
            store.record(a)
            let refresh = Task { await store.refreshAvailability() }
            let entered = await Task.detached { gate.waitUntilEntered() }.value
            try expect(entered, "background probe did not start")
            store.record(b)
            gate.release.signal()
            await refresh.value
            try expect(store.entries.map(\.url) == [b, a], "late refresh replaced new MRU")
        }
    }
}
