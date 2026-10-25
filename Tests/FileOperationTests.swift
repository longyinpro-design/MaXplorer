import Foundation
import Darwin

enum TestFailure: Error { case assertion(String) }
nonisolated func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.assertion(message) }
}

@main struct FileOperationTests {
    static let fm = FileManager.default
    static var passed = 0
    static var failed = 0
    static var root: URL!

    static func test(_ name: String, _ body: (URL) async throws -> Void) async {
        if let filter = ProcessInfo.processInfo.environment["MAXPLORER_TEST_FILTER"], !name.contains(filter) { return }
        let dir = root.appendingPathComponent(UUID().uuidString)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try await body(dir)
            print("PASS \(name)")
            passed += 1
        } catch {
            print("FAIL \(name): \(error)")
            failed += 1
        }
        try? fm.removeItem(at: dir)
    }

    static func file(_ dir: URL, _ name: String, _ contents: String = "source") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }
    static func contents(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    static func copy(_ source: URL, _ destination: URL, overwrite: Bool = true) async throws {
        try await CopyWorker.perform(.copy, sourceURL: source, destinationURL: destination, overwrite: overwrite) { _ in }
    }
    static func mustFail(_ body: () async throws -> Void) async throws {
        do { try await body() } catch { return }
        throw TestFailure.assertion("operation unexpectedly succeeded")
    }

    static func main() async throws {
        root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        await test("overwrite missing source preserves destination") { dir in
            let target = try file(dir, "target", "old")
            try await mustFail { try await copy(dir.appendingPathComponent("missing"), target) }
            try expect(contents(target) == "old", "old destination was lost")
        }
        await test("overwrite unreadable source preserves destination") { dir in
            let source = try file(dir, "source")
            let target = try file(dir, "target", "old")
            chmod(source.path, 0)
            defer { chmod(source.path, 0o600) }
            try await mustFail { try await copy(source, target) }
            try expect(contents(target) == "old", "old destination was lost")
        }
        await test("parent alias self copy is rejected without loss") { dir in
            let source = try file(dir, "source")
            let alias = dir.appendingPathComponent("alias")
            try fm.createSymbolicLink(at: alias, withDestinationURL: dir)
            try await mustFail { try await copy(source, alias.appendingPathComponent("source")) }
            try expect(contents(source) == "source", "source was lost")
        }
        await test("executable mode is preserved") { dir in
            let source = try file(dir, "source")
            let target = dir.appendingPathComponent("target")
            chmod(source.path, 0o755)
            try await copy(source, target)
            let attrs = try fm.attributesOfItem(atPath: target.path)
            try expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o755, "mode changed")
        }
        await test("extended attributes are preserved") { dir in
            let source = try file(dir, "source")
            let target = dir.appendingPathComponent("target")
            let value: [UInt8] = [1, 2, 3, 4]
            try expect(setxattr(source.path, "com.maxplorer.test", value, value.count, 0, 0) == 0, "fixture xattr failed")
            try await copy(source, target)
            var result = [UInt8](repeating: 0, count: 4)
            let count = getxattr(target.path, "com.maxplorer.test", &result, result.count, 0, 0)
            try expect(count == 4 && result == value, "xattr lost")
        }
        await test("file symlink remains a symlink") { dir in
            _ = try file(dir, "referent")
            let source = dir.appendingPathComponent("source")
            let target = dir.appendingPathComponent("target")
            try fm.createSymbolicLink(atPath: source.path, withDestinationPath: "referent")
            try await copy(source, target)
            try expect((try? fm.destinationOfSymbolicLink(atPath: target.path)) == "referent", "symlink was dereferenced")
        }
        await test("dangling symlink is copied") { dir in
            let source = dir.appendingPathComponent("source")
            let target = dir.appendingPathComponent("target")
            try fm.createSymbolicLink(atPath: source.path, withDestinationPath: "missing")
            try await copy(source, target)
            try expect((try? fm.destinationOfSymbolicLink(atPath: target.path)) == "missing", "dangling link lost")
        }
        await extendedTests()
        await quickViewTests()
        await previewWindowPlacementTests()
        await basicFileActionTests()
        await searchTests()
        await searchFilterTests()
        await spotlightSearchTests()
        await indexedSearchIntegrationTests()
        await queueControlTests()
        await transferPlanTests()
        await archiveTests()
        await safetyHardeningTests()
        await recoveryScannerTests()
        await recoveryDestinationTests()
        await exclusiveCapabilityTests()
        await undoJournalTests()
        await batchRenameTests()
        await fileBrowserPresentationTests()
        await directoryTreeTests()
        await recentFilesTests()
        await fileInspectorTests()
        print("RESULT passed=\(passed) failed=\(failed)")
        if failed != 0 || passed == 0 { exit(1) }
    }
}
