import Foundation

private actor DirectoryTreeTestGate {
    private var calls: [(URL, Bool)] = []
    private var pending: [Int: CheckedContinuation<[DirectoryTreeNode], Error>] = [:]

    func load(_ url: URL, _ hidden: Bool) async throws -> [DirectoryTreeNode] {
        let index = calls.count
        calls.append((url, hidden))
        // Deliberately ignore cancellation, modeling an uninterruptible filesystem call.
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func count() -> Int { calls.count }
    func hidden(at index: Int) -> Bool { calls[index].1 }
    func succeed(_ index: Int, _ nodes: [DirectoryTreeNode]) { pending.removeValue(forKey: index)?.resume(returning: nodes) }
    func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission)) }
}

extension FileOperationTests {
    static func directoryTreeTests() async {
        func treeExpect(_ condition: Bool, _ message: String) throws {
            try expect(condition, message)
        }
        func wait(_ condition: @MainActor () async -> Bool) async throws {
            for _ in 0..<2_000 {
                if await condition() { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw TestFailure.assertion("directory tree timed out")
        }
        func directory(_ parent: URL, _ name: String) throws -> URL {
            let child = parent.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: child, withIntermediateDirectories: true)
            return child
        }
        await test("directory tree service lists one level and obeys hidden setting") { dir in
            let a = try directory(dir, "folder 10")
            _ = try directory(dir, "folder 2")
            _ = try directory(dir, ".hidden")
            _ = try directory(a, "deep")
            _ = try file(dir, "file.txt")
            let normal = try await DirectoryTreeService.children(of: dir, showHiddenFiles: false)
            try treeExpect(normal.map(\.name) == ["folder 2", "folder 10"], "not a shallow natural-order directory listing")
            let hidden = try await DirectoryTreeService.children(of: dir, showHiddenFiles: true)
            try treeExpect(hidden.count == 3 && hidden.contains { $0.name == ".hidden" }, "hidden directory absent")
        }
        await test("directory tree packages are leaves and links aliases never recurse") { dir in
            let actual = try directory(dir, "actual")
            let package = try directory(dir, "Fixture.app")
            _ = try directory(package, "Contents")
            let link = dir.appendingPathComponent("loop")
            try fm.createSymbolicLink(at: link, withDestinationURL: dir)
            let alias = dir.appendingPathComponent("alias")
            let bookmark = try actual.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(bookmark, to: alias)
            try treeExpect(try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true, "fixture is not an alias")
            let children = try await DirectoryTreeService.children(of: dir, showHiddenFiles: false)
            try treeExpect(children.count == 2 && children.first { $0.name == "Fixture.app" }?.isExpandable == false, "package expanded or links displayed")
            for forbidden in [link, link.appendingPathComponent("actual"), alias, package] {
                try await mustFail { _ = try await DirectoryTreeService.children(of: forbidden, showHiddenFiles: false) }
            }
        }
        await test("directory tree lexical root containment has component boundaries") { dir in
            let root = dir.appendingPathComponent("folder")
            try treeExpect(DirectoryTreeService.contains(root.appendingPathComponent("child"), in: root), "child rejected")
            try treeExpect(!DirectoryTreeService.contains(dir.appendingPathComponent("folder-other"), in: root), "prefix escaped root")
            try treeExpect(!DirectoryTreeService.contains(root.appendingPathComponent("../outside"), in: root), "dotdot escaped root")
            try treeExpect(!DirectoryTreeService.contains(URL(string: "https://example.com/folder")!, in: root), "nonfile accepted")
        }
        await test("directory tree lazy model caches expansion without loading descendants") { dir in
            let gate = DirectoryTreeTestGate()
            let child = DirectoryTreeNode(url: dir.appendingPathComponent("child"))
            let model = DirectoryTreeModel(roots: [dir], loader: { try await gate.load($0, $1) })
            try treeExpect(await gate.count() == 0, "init performed IO")
            model.setExpanded(dir, true, showHiddenFiles: false)
            try await wait { await gate.count() == 1 }
            await gate.succeed(0, [child])
            try await wait { !model.isLoading(dir) }
            model.setExpanded(dir, false, showHiddenFiles: false)
            model.setExpanded(dir, true, showHiddenFiles: false)
            try treeExpect(await gate.count() == 1 && model.children(for: dir) == [child], "cached expansion reloaded or recursively loaded")
        }
        await test("directory tree collapse and reexpand discards late canceled result") { dir in
            let gate = DirectoryTreeTestGate()
            let model = DirectoryTreeModel(roots: [dir], loader: { try await gate.load($0, $1) })
            model.setExpanded(dir, true, showHiddenFiles: false)
            try await wait { await gate.count() == 1 }
            model.setExpanded(dir, false, showHiddenFiles: false)
            try treeExpect(!model.isLoading(dir), "collapse left spinner")
            model.setExpanded(dir, true, showHiddenFiles: false)
            try await wait { await gate.count() == 2 }
            let fresh = DirectoryTreeNode(url: dir.appendingPathComponent("fresh"))
            await gate.succeed(1, [fresh])
            try await wait { !model.isLoading(dir) }
            await gate.succeed(0, [DirectoryTreeNode(url: dir.appendingPathComponent("stale"))])
            for _ in 0..<20 { await Task.yield() }
            try treeExpect(model.children(for: dir) == [fresh], "late result overwrote current generation")
        }
        await test("directory tree loader errors remain visible and retry succeeds") { dir in
            let gate = DirectoryTreeTestGate()
            let model = DirectoryTreeModel(roots: [dir], loader: { try await gate.load($0, $1) })
            model.setExpanded(dir, true, showHiddenFiles: false)
            try await wait { await gate.count() == 1 }
            await gate.fail(0)
            try await wait { !model.isLoading(dir) }
            try treeExpect(model.error(for: dir) != nil, "failure swallowed")
            model.retry(dir)
            try await wait { await gate.count() == 2 }
            await gate.succeed(1, [])
            try await wait { !model.isLoading(dir) }
            try treeExpect(model.error(for: dir) == nil && model.states[DirectoryTreeService.normalized(dir)]?.hasLoaded == true, "retry did not clear failure")
        }
        await test("directory tree hidden toggle discards old result and reloads expanded roots") { dir in
            let gate = DirectoryTreeTestGate()
            let model = DirectoryTreeModel(roots: [dir], loader: { try await gate.load($0, $1) })
            model.setExpanded(dir, true, showHiddenFiles: false)
            try await wait { await gate.count() == 1 }
            model.setShowHiddenFiles(true)
            try await wait { await gate.count() == 2 }
            try treeExpect(await gate.hidden(at: 1), "hidden setting not forwarded")
            await gate.succeed(1, [DirectoryTreeNode(url: dir.appendingPathComponent(".hidden"))])
            try await wait { !model.isLoading(dir) }
            await gate.succeed(0, [])
            for _ in 0..<20 { await Task.yield() }
            try treeExpect(model.children(for: dir).map(\.name) == [".hidden"], "old visibility request replaced current result")
        }
        await test("directory tree reveal follows ancestors only and respects root boundary leaves") { dir in
            let child = try directory(dir, "child")
            let nested = try directory(child, "nested")
            _ = try directory(dir, "sibling")
            let package = try directory(dir, "Fixture.app")
            let model = DirectoryTreeModel(roots: [dir])
            try treeExpect(await model.reveal(nested, showHiddenFiles: false), "reveal failed")
            try treeExpect(model.isExpanded(dir) && model.isExpanded(child) && !model.isExpanded(nested), "reveal expanded target or missed ancestor")
            try treeExpect(model.states.count == 2, "reveal scanned siblings")
            try treeExpect(!(await model.reveal(dir.appendingPathComponent("../outside"), showHiddenFiles: false)), "reveal escaped root")
            try treeExpect(!(await model.reveal(package.appendingPathComponent("Contents"), showHiddenFiles: false)), "reveal crossed leaf")
            try treeExpect(!(await model.reveal(dir.appendingPathComponent("missing"), showHiddenFiles: false)), "missing target revealed")
        }
        await test("directory tree cached parent refreshes once for newly created child") { dir in
            let old = try directory(dir, "old")
            _ = try directory(old, "stale")
            let model = DirectoryTreeModel(roots: [dir])
            try treeExpect(await model.reveal(old.appendingPathComponent("stale"), showHiddenFiles: false), "fixture reveal failed")
            try treeExpect(model.isExpanded(old), "old subtree not cached")
            try fm.removeItem(at: old)
            _ = try directory(dir, "old")
            let created = try directory(dir, "created")
            let nested = try directory(created, "nested")
            try treeExpect(await model.reveal(nested, showHiddenFiles: false), "new child not revealed from cached parent")
            try treeExpect(model.isExpanded(dir) && model.isExpanded(created), "new chain not expanded")
            try treeExpect(model.states[DirectoryTreeService.normalized(old)] == nil, "refreshed parent retained stale descendant cache")
            try treeExpect(model.children(for: dir).contains { $0.id == DirectoryTreeService.normalized(created) }, "refresh did not publish new child")
        }
        await test("directory tree missing cached child refresh is bounded and cancelable") { dir in
            let gate = DirectoryTreeTestGate()
            let model = DirectoryTreeModel(roots: [dir], loader: { try await gate.load($0, $1) })
            model.setExpanded(dir, true, showHiddenFiles: false)
            try await wait { await gate.count() == 1 }
            await gate.succeed(0, [])
            try await wait { !model.isLoading(dir) }
            let missing = Task { await model.reveal(dir.appendingPathComponent("missing"), showHiddenFiles: false) }
            try await wait { await gate.count() == 2 }
            await gate.succeed(1, [])
            try treeExpect(!(await missing.value), "missing target unexpectedly revealed")
            try treeExpect(await gate.count() == 2, "missing item refreshed more than once")
            let canceled = Task { await model.reveal(dir.appendingPathComponent("later"), showHiddenFiles: false) }
            try await wait { await gate.count() == 3 }
            model.setExpanded(dir, false, showHiddenFiles: false)
            await gate.succeed(2, [DirectoryTreeNode(url: dir.appendingPathComponent("later"))])
            try treeExpect(!(await canceled.value), "collapsed refresh completed reveal")
            try treeExpect(model.children(for: dir).isEmpty && !model.isExpanded(dir), "collapsed refresh published late result")
        }
        await test("directory tree concurrent reveal abandons old ancestor chain") { dir in
            let gate = DirectoryTreeTestGate()
            let child = DirectoryTreeNode(url: dir.appendingPathComponent("child"))
            let model = DirectoryTreeModel(roots: [dir], loader: { try await gate.load($0, $1) })
            let first = Task { await model.reveal(child.id.appendingPathComponent("nested"), showHiddenFiles: false) }
            try await wait { await gate.count() == 1 }
            let second = Task { await model.reveal(dir, showHiddenFiles: false) }
            let secondResult = await second.value
            await gate.succeed(0, [child])
            let firstResult = await first.value
            try treeExpect(secondResult && !firstResult && !model.isExpanded(child.id), "old reveal kept navigating")
        }
        await test("directory tree cancelAll drops late results and service honors cancellation") { dir in
            let gate = DirectoryTreeTestGate()
            let model = DirectoryTreeModel(roots: [dir], loader: { try await gate.load($0, $1) })
            model.setExpanded(dir, true, showHiddenFiles: false)
            try await wait { await gate.count() == 1 }
            model.cancelAll()
            await gate.succeed(0, [DirectoryTreeNode(url: dir.appendingPathComponent("late"))])
            for _ in 0..<20 { await Task.yield() }
            try treeExpect(model.children(for: dir).isEmpty && !model.isLoading(dir), "cancelAll published late result")
            let request = Task { try await DirectoryTreeService.children(of: dir, showHiddenFiles: false) }
            request.cancel()
            do {
                _ = try await request.value
                throw TestFailure.assertion("canceled service succeeded")
            } catch is CancellationError { }
        }
        await test("directory tree collapsing ancestor cancels descendant publication") { dir in
            let gate = DirectoryTreeTestGate()
            let child = DirectoryTreeNode(url: dir.appendingPathComponent("child"))
            let model = DirectoryTreeModel(roots: [dir], loader: { try await gate.load($0, $1) })
            model.setExpanded(dir, true, showHiddenFiles: false)
            try await wait { await gate.count() == 1 }
            await gate.succeed(0, [child])
            try await wait { !model.isLoading(dir) }
            model.setExpanded(child.id, true, showHiddenFiles: false)
            try await wait { await gate.count() == 2 }
            model.setExpanded(dir, false, showHiddenFiles: false)
            await gate.succeed(1, [DirectoryTreeNode(url: child.id.appendingPathComponent("late"))])
            for _ in 0..<20 { await Task.yield() }
            try treeExpect(model.children(for: child.id).isEmpty && !model.isLoading(child.id) && !model.isExpanded(child.id), "collapsed descendant published result")
            model.cancelAll()
        }
    }
}
