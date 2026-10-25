import Foundation

@MainActor
private final class InspectorGate {
    var calls: [URL] = []
    var active = 0
    var maximumActive = 0
    var waiting: [CheckedContinuation<QuickViewContent, Error>] = []
    func load(_ url: URL) async throws -> QuickViewContent {
        calls.append(url)
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
    func succeed(text: Bool = false) {
        let url = calls.last!
        waiting.removeFirst().resume(returning: QuickViewContent(url: url, title: url.lastPathComponent, detail: "snapshot", allowsTextEncoding: text))
    }
    func fail() { waiting.removeFirst().resume(throwing: NSError(domain: "InspectorFixture", code: 17)) }
}

@MainActor
private final class InspectorCancellationProbe {
    var didStart = false
    var didObserveCancellation = false
    func started() { didStart = true }
    func observed(_ cancelled: Bool) { didObserveCancellation = cancelled }
}

@MainActor
private final class InspectorDecodeGate {
    var calls = 0
    var waiting: CheckedContinuation<String, Error>?
    func decode() async throws -> String {
        calls += 1
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }
    func succeed() { waiting?.resume(returning: "old encoding"); waiting = nil }
}

extension FileOperationTests {
    private static func inspectorItem(_ url: URL, directory: Bool = false, package: Bool = false,
                                      alias: Bool = false, network: Bool = false, size: Int64 = 1,
                                      modified: Date = Date(timeIntervalSince1970: 1)) -> FileItem {
        FileItem(url: url, name: url.lastPathComponent, typeDescription: "Fixture", isDirectory: directory,
                 isPackage: package, isAlias: alias, aliasTargetURL: nil, isAliasTargetDirectory: false,
                 isAliasTargetPackage: false, isHidden: false, size: size, modifiedAt: modified,
                 isNetworkLocation: network)
    }
    private static func inspectorEventually(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate() {
            guard Date() < deadline else { throw TestFailure.assertion("inspector async transition timed out") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    static func fileInspectorTests() async {
        await test("inspector snapshot states do not load file metadata") { dir in
            let gate = InspectorGate()
            let model = FileInspectorModel(loader: { try await gate.load($0) })
            let url = dir.appendingPathComponent("unread.txt")
            let item = inspectorItem(url)
            let cases: [([FileItem], Bool, Bool, FileInspectorModel.Status)] = [
                ([item], false, true, .hidden), ([], true, true, .empty),
                ([item, item], true, true, .multiple),
                ([inspectorItem(url, directory: true)], true, true, .directory),
                ([inspectorItem(url, directory: true, package: true)], true, true, .package),
                ([inspectorItem(url, network: true)], true, true, .network),
                ([inspectorItem(url, alias: true)], true, true, .details),
                ([item], true, false, .details)
            ]
            for (items, visible, preview, status) in cases {
                model.update(selection: items, isVisible: visible, showsPreview: preview)
                try expect(model.status == status && model.items == items, "snapshot state mismatch")
            }
            await Task.yield()
            try expect(gate.calls.isEmpty && model.content == nil, "snapshot states performed I/O")
        }
        await test("inspector success and metadata snapshot deduplication") { dir in
            let gate = InspectorGate()
            let model = FileInspectorModel(loader: { try await gate.load($0) })
            let item = inspectorItem(dir.appendingPathComponent("a.txt"))
            model.update(selection: [item], isVisible: true)
            try await inspectorEventually { gate.calls.count == 1 }
            gate.succeed()
            try await inspectorEventually { model.status == .ready }
            model.update(selection: [item], isVisible: true)
            await Task.yield()
            try expect(gate.calls.count == 1 && model.content?.url == item.url && model.error == nil, "same snapshot reloaded")
        }
        await test("inspector exposes loader failure") { dir in
            let gate = InspectorGate()
            let model = FileInspectorModel(loader: { try await gate.load($0) })
            model.update(selection: [inspectorItem(dir.appendingPathComponent("bad"))], isVisible: true)
            try await inspectorEventually { gate.calls.count == 1 }
            gate.fail()
            try await inspectorEventually { model.status == .failed }
            try expect(model.error != nil && model.content == nil, "failure was hidden")
        }
        await test("inspector queues only latest selection with one active request") { dir in
            let gate = InspectorGate()
            let model = FileInspectorModel(loader: { try await gate.load($0) })
            let a = inspectorItem(dir.appendingPathComponent("a"))
            let b = inspectorItem(dir.appendingPathComponent("b"))
            let c = inspectorItem(dir.appendingPathComponent("c"))
            model.update(selection: [a], isVisible: true)
            try await inspectorEventually { gate.calls.count == 1 }
            model.update(selection: [b], isVisible: true)
            model.update(selection: [c], isVisible: true)
            await Task.yield()
            try expect(gate.calls == [a.url] && model.content == nil, "queued I/O started early")
            gate.fail()
            try await inspectorEventually { gate.calls.count == 2 }
            try expect(gate.calls == [a.url, c.url] && model.status == .loading && model.error == nil, "late error or intermediate request escaped")
            gate.succeed()
            try await inspectorEventually { model.status == .ready }
            try expect(model.content?.url == c.url && gate.maximumActive == 1, "latest selection or bound lost")
        }
        await test("inspector hiding drops late success and pending work") { dir in
            let gate = InspectorGate()
            let model = FileInspectorModel(loader: { try await gate.load($0) })
            model.update(selection: [inspectorItem(dir.appendingPathComponent("a"))], isVisible: true)
            try await inspectorEventually { gate.calls.count == 1 }
            model.update(selection: [inspectorItem(dir.appendingPathComponent("b"))], isVisible: true)
            model.cancel()
            gate.succeed()
            try await inspectorEventually { gate.active == 0 }
            await Task.yield()
            try expect(model.status == .hidden && model.content == nil && gate.calls.count == 1, "hidden inspector accepted late content")
        }
        await test("inspector reloads same URL when metadata changes") { dir in
            let gate = InspectorGate()
            let model = FileInspectorModel(loader: { try await gate.load($0) })
            let url = dir.appendingPathComponent("a")
            model.update(selection: [inspectorItem(url)], isVisible: true)
            try await inspectorEventually { gate.calls.count == 1 }
            gate.succeed()
            try await inspectorEventually { model.status == .ready }
            model.update(selection: [inspectorItem(url, size: 2)], isVisible: true)
            try await inspectorEventually { gate.calls.count == 2 }
            gate.succeed()
            try await inspectorEventually { model.status == .ready }
            model.update(selection: [inspectorItem(url, size: 2, modified: Date(timeIntervalSince1970: 2))], isVisible: true)
            try await inspectorEventually { gate.calls.count == 3 }
            gate.succeed()
            try await inspectorEventually { model.status == .ready }
        }
        await test("inspector explicit encoding waits for metadata and decodes off snapshot") { dir in
            let gate = InspectorGate()
            let model = FileInspectorModel(loader: { try await gate.load($0) }, decoder: { _, encoding in
                encoding == .utf8 ? "UTF8 fixture" : "UTF16 fixture"
            })
            let item = inspectorItem(dir.appendingPathComponent("a.txt"))
            model.update(selection: [item], isVisible: true, encoding: .utf8)
            try await inspectorEventually { gate.calls.count == 1 }
            model.update(selection: [item], isVisible: true, encoding: .utf16)
            gate.succeed(text: true)
            try await inspectorEventually { gate.calls.count == 2 }
            try expect(model.decodedText == nil, "old encoding content appeared")
            gate.succeed(text: true)
            try await inspectorEventually { model.status == .ready }
            try expect(model.decodedText == "UTF16 fixture", "encoding change was ignored")
        }
        await test("inspector decoder remains within single active request and discards late text") { dir in
            let gate = InspectorGate()
            let decode = InspectorDecodeGate()
            let model = FileInspectorModel(loader: { try await gate.load($0) }, decoder: { _, _ in try await decode.decode() })
            let a = inspectorItem(dir.appendingPathComponent("a.txt"))
            let b = inspectorItem(dir.appendingPathComponent("b.pdf"))
            model.update(selection: [a], isVisible: true, encoding: .utf8)
            try await inspectorEventually { gate.calls.count == 1 }
            gate.succeed(text: true)
            try await inspectorEventually { decode.calls == 1 }
            model.update(selection: [b], isVisible: true)
            await Task.yield()
            try expect(gate.calls.count == 1, "next metadata started while decode was active")
            decode.succeed()
            try await inspectorEventually { gate.calls.count == 2 }
            try expect(model.decodedText == nil && model.status == .loading, "late decoded text appeared")
            gate.succeed()
            try await inspectorEventually { model.status == .ready }
            try expect(model.content?.url == b.url && model.decodedText == nil, "latest nontext preview failed")
        }
        await test("inspector automatic and nontext previews skip explicit decoder") { dir in
            let gate = InspectorGate()
            let decode = InspectorDecodeGate()
            let model = FileInspectorModel(loader: { try await gate.load($0) }, decoder: { _, _ in try await decode.decode() })
            let item = inspectorItem(dir.appendingPathComponent("file"))
            model.update(selection: [item], isVisible: true)
            try await inspectorEventually { gate.calls.count == 1 }
            gate.succeed(text: true)
            try await inspectorEventually { model.status == .ready }
            model.update(selection: [item], isVisible: true, encoding: .utf8)
            try await inspectorEventually { gate.calls.count == 2 }
            gate.succeed(text: false)
            try await inspectorEventually { model.status == .ready }
            try expect(decode.calls == 0 && model.decodedText == nil, "automatic/nontext preview decoded bytes")
        }
        await test("inspector cancel propagates to cooperative loader without late state") { dir in
            let cancellation = InspectorCancellationProbe()
            let model = FileInspectorModel(loader: { _ in
                await cancellation.started()
                do { try await Task.sleep(for: .seconds(60)) }
                catch {
                    await cancellation.observed(Task.isCancelled)
                    throw error
                }
                throw TestFailure.assertion("cancelled loader completed normally")
            })
            model.update(selection: [inspectorItem(dir.appendingPathComponent("cancel"))], isVisible: true)
            try await inspectorEventually { cancellation.didStart }
            model.cancel()
            try await inspectorEventually { cancellation.didObserveCancellation }
            await Task.yield()
            try expect(model.status == .hidden && model.content == nil && model.error == nil,
                       "cancelled loader overwrote hidden state")
        }
        await test("inspector shared coordinator bounds I/O across model lifetimes") { dir in
            let coordinator = FileInspectorWorkCoordinator()
            let gate = InspectorGate()
            var first: FileInspectorModel? = FileInspectorModel(coordinator: coordinator, loader: { try await gate.load($0) })
            weak let released = first
            first?.update(selection: [inspectorItem(dir.appendingPathComponent("first"))], isVisible: true)
            try await inspectorEventually { gate.calls.count == 1 }
            first = nil
            try expect(released == nil, "coordinator retained destroyed model")
            let second = FileInspectorModel(coordinator: coordinator, loader: { try await gate.load($0) })
            second.update(selection: [inspectorItem(dir.appendingPathComponent("second"))], isVisible: true)
            for _ in 0..<10 { await Task.yield() }
            try expect(gate.calls.count == 1, "recreated model bypassed occupied capacity")
            gate.succeed()
            try await inspectorEventually { gate.calls.count == 2 }
            try expect(gate.maximumActive == 1, "actual operations overlapped across models")
            gate.succeed()
            try await inspectorEventually { second.status == .ready }
        }
        await test("inspector cancelled shared queue request never starts I/O") { dir in
            let coordinator = FileInspectorWorkCoordinator()
            let gate = InspectorGate()
            let first = FileInspectorModel(coordinator: coordinator, loader: { try await gate.load($0) })
            let cancelled = FileInspectorModel(coordinator: coordinator, loader: { try await gate.load($0) })
            let latest = FileInspectorModel(coordinator: coordinator, loader: { try await gate.load($0) })
            let a = inspectorItem(dir.appendingPathComponent("first"))
            let b = inspectorItem(dir.appendingPathComponent("cancelled"))
            let c = inspectorItem(dir.appendingPathComponent("latest"))
            first.update(selection: [a], isVisible: true)
            try await inspectorEventually { gate.calls.count == 1 }
            cancelled.update(selection: [b], isVisible: true)
            for _ in 0..<10 { await Task.yield() }
            cancelled.cancel()
            latest.update(selection: [c], isVisible: true)
            gate.succeed()
            try await inspectorEventually { gate.calls.count == 2 }
            try expect(gate.calls == [a.url, c.url] && gate.maximumActive == 1, "cancelled queued operation started")
            gate.succeed()
            try await inspectorEventually { latest.status == .ready }
            try expect(cancelled.status == .hidden && cancelled.content == nil, "cancelled waiter accepted result")
        }
        await test("inspector blocked loader does not retain model") { dir in
            let gate = InspectorGate()
            var model: FileInspectorModel? = FileInspectorModel(loader: { try await gate.load($0) })
            weak let weakModel = model
            model?.update(selection: [inspectorItem(dir.appendingPathComponent("a"))], isVisible: true)
            try await inspectorEventually { gate.calls.count == 1 }
            model = nil
            try expect(weakModel == nil, "blocked request retained inspector")
            gate.succeed()
            try await inspectorEventually { gate.active == 0 }
        }
        await test("inspector preferences persist and clamp invalid dimensions") { _ in
            let suite = "MaXplorer.InspectorTests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            try expect(FileInspectorPreferences(defaults: defaults) == FileInspectorPreferences(), "default inspector changed")
            FileInspectorPreferences(isVisible: true, mode: .details, width: 400).save(to: defaults)
            let saved = FileInspectorPreferences(defaults: defaults)
            try expect(saved.isVisible && saved.mode == .details && saved.width == 400, "preferences did not roundtrip")
            for (input, expected) in [(0.0, 240.0), (900, 520), (.nan, 320), (.infinity, 320), (-.infinity, 320)] {
                try expect(FileInspectorPreferences.clampedWidth(input) == expected, "dimension clamp failed")
            }
            defaults.set("invalid", forKey: "fileInspector.mode")
            defaults.set(9999, forKey: "fileInspector.width")
            let invalid = FileInspectorPreferences(defaults: defaults)
            try expect(invalid.mode == .preview && invalid.width == 520, "invalid stored preferences escaped")
        }
    }
}
