import Foundation

nonisolated enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case zip
    case tarGz

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zip: return "ZIP"
        case .tarGz: return "TAR.GZ"
        }
    }

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .tarGz: return "tar.gz"
        }
    }
}

nonisolated enum ArchiveError: LocalizedError {
    case unsupportedArchive
    case itemsMustShareParent
    case invalidItemName(String)
    case commandFailed(String)
    case unsafeEntry(String)
    case stagingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchive:
            return "不支持此压缩格式。"
        case .itemsMustShareParent:
            return "请选择同一文件夹中的项目进行压缩。"
        case .invalidItemName(let name):
            return "无法处理名称以“-”开头的项目：\(name)"
        case .commandFailed(let message):
            return message.isEmpty ? "压缩工具执行失败。" : message
        case .unsafeEntry(let path):
            return "压缩包包含不安全的路径，已停止解压：\(path)"
        case .stagingFailed(let message):
            return "无法创建临时目录：\(message)"
        }
    }
}

nonisolated struct ArchiveService {
    static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2"
    ]

    static func isArchive(_ url: URL) -> Bool {
        extractionKind(for: url) != nil
    }

    static func compress(
        items: [URL],
        to destination: URL,
        format: ArchiveFormat
    ) async throws {
        guard let parent = items.first?.deletingLastPathComponent() else {
            throw ArchiveError.unsupportedArchive
        }
        let standardizedParent = parent.standardizedFileURL
        guard items.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == standardizedParent }) else {
            throw ArchiveError.itemsMustShareParent
        }
        for item in items where item.lastPathComponent.hasPrefix("-") {
            throw ArchiveError.invalidItemName(item.lastPathComponent)
        }

        let staging = try makeStagingDirectory(in: destination.deletingLastPathComponent())
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporaryArchive = staging.appendingPathComponent("archive.\(format.fileExtension)")

        let names = items.map(\.lastPathComponent)
        switch format {
        case .zip:
            try await run(
                "/usr/bin/zip",
                arguments: ["-q", "-r", "-y", temporaryArchive.path] + names,
                currentDirectory: standardizedParent
            )
        case .tarGz:
            try await run(
                "/usr/bin/tar",
                arguments: ["-czf", temporaryArchive.path, "-C", standardizedParent.path, "--"] + names
            )
        }

        guard FileManager.default.fileExists(atPath: temporaryArchive.path) else {
            throw ArchiveError.commandFailed("压缩工具没有生成输出文件。")
        }

        try await SafeFileOperations.perform(
            .move,
            sourceURL: temporaryArchive,
            destinationURL: destination,
            overwrite: true,
            progress: { _ in }
        )
    }

    static func extract(
        archive: URL,
        toStagingIn destinationDirectory: URL
    ) async throws -> URL {
        guard let kind = extractionKind(for: archive) else {
            throw ArchiveError.unsupportedArchive
        }

        let staging = try makeStagingDirectory(in: destinationDirectory.deletingLastPathComponent())
        do {
            switch kind {
            case .zip:
                try await validateEntries(
                    executable: "/usr/bin/zipinfo",
                    arguments: ["-1", archive.path]
                )
                try await run(
                    "/usr/bin/ditto",
                    arguments: ["-x", "-k", archive.path, staging.path]
                )
            case .tar:
                try await validateEntries(
                    executable: "/usr/bin/tar",
                    arguments: ["-tf", archive.path]
                )
                try await run(
                    "/usr/bin/tar",
                    arguments: ["-xf", archive.path, "-C", staging.path]
                )
            case .gzip, .bzip2:
                let outputName = decompressedName(for: archive)
                let outputURL = staging.appendingPathComponent(outputName)
                guard FileManager.default.createFile(atPath: outputURL.path, contents: Data()) else {
                    throw ArchiveError.stagingFailed("无法创建解压输出文件。")
                }
                let tool = kind == .gzip ? "/usr/bin/gzip" : "/usr/bin/bzip2"
                try await run(
                    tool,
                    arguments: ["-dc", archive.path],
                    standardOutputURL: outputURL
                )
            }

            try validateSymlinks(in: staging)
            return staging
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    static func topLevelItems(in staging: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil,
            options: []
        )
    }

    static func conflicts(items: [URL], in destinationDirectory: URL) -> [URL] {
        items.filter { item in
            let destination = destinationDirectory.appendingPathComponent(item.lastPathComponent)
            return SafeFileOperations.entryExists(at: destination)
        }
    }

    static func moveExtractedItems(
        from staging: URL,
        to destinationDirectory: URL,
        overwrite: Bool
    ) async throws {
        let items = try topLevelItems(in: staging)
        for item in items {
            try Task.checkCancellation()
            let destination = destinationDirectory.appendingPathComponent(item.lastPathComponent)
            let destinationExists = SafeFileOperations.entryExists(at: destination)
            if destinationExists && !overwrite {
                continue
            }
            try await SafeFileOperations.perform(
                .move,
                sourceURL: item,
                destinationURL: destination,
                overwrite: destinationExists,
                progress: { _ in }
            )
        }
    }

    static func removeStaging(_ staging: URL) {
        try? FileManager.default.removeItem(at: staging)
    }

    // MARK: - Extraction kind

    private enum ExtractionKind {
        case zip
        case tar
        case gzip
        case bzip2
    }

    private static func extractionKind(for url: URL) -> ExtractionKind? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") {
            return .zip
        }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz")
            || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") || name.hasSuffix(".tbz")
            || name.hasSuffix(".tar") {
            return .tar
        }
        if name.hasSuffix(".gz") {
            return .gzip
        }
        if name.hasSuffix(".bz2") {
            return .bzip2
        }
        return nil
    }

    private static func decompressedName(for archive: URL) -> String {
        let name = archive.lastPathComponent
        let lowercased = name.lowercased()
        let suffixes = [".tar.gz", ".tar.bz2", ".tgz", ".tbz2", ".tbz", ".gz", ".bz2"]
        for suffix in suffixes where lowercased.hasSuffix(suffix) {
            let result = String(name.dropLast(suffix.count))
            if !result.isEmpty {
                return URL(fileURLWithPath: result).lastPathComponent
            }
        }
        return "extracted"
    }

    // MARK: - Validation

    private static func validateEntries(executable: String, arguments: [String]) async throws {
        let output = try await capture(executable, arguments: arguments)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            try validateEntryPath(String(line))
        }
    }

    private static func validateEntryPath(_ rawPath: String) throws {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let normalized = trimmed.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else {
            throw ArchiveError.unsafeEntry(trimmed)
        }
        guard normalized.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil else {
            throw ArchiveError.unsafeEntry(trimmed)
        }

        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains("..") else {
            throw ArchiveError.unsafeEntry(trimmed)
        }
    }

    private static func validateSymlinks(in staging: URL) throws {
        let stagingRoot = staging.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = stagingRoot.path.hasSuffix("/") ? stagingRoot.path : stagingRoot.path + "/"

        guard let enumerator = FileManager.default.enumerator(
            at: staging,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            return
        }

        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values?.isSymbolicLink == true else { continue }
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
                continue
            }
            guard !target.hasPrefix("/") else {
                throw ArchiveError.unsafeEntry(url.lastPathComponent)
            }

            let resolved = url
                .deletingLastPathComponent()
                .appendingPathComponent(target)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard resolved.path == stagingRoot.path || resolved.path.hasPrefix(rootPrefix) else {
                throw ArchiveError.unsafeEntry(url.lastPathComponent)
            }
        }
    }

    // MARK: - Process runner

    private static func run(
        _ executable: String,
        arguments: [String],
        currentDirectory: URL? = nil,
        standardOutputURL: URL? = nil
    ) async throws {
        let cancellation = ProcessCancellation()

        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectory
                process.environment = [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "LANG": "en_US.UTF-8",
                    "LC_ALL": "en_US.UTF-8"
                ]

                let stderrURL = try makeTemporaryFile()
                defer { try? FileManager.default.removeItem(at: stderrURL) }
                let stderrHandle = try FileHandle(forWritingTo: stderrURL)
                process.standardError = stderrHandle

                var outputHandle: FileHandle?
                if let standardOutputURL {
                    outputHandle = try FileHandle(forWritingTo: standardOutputURL)
                    process.standardOutput = outputHandle
                } else {
                    process.standardOutput = FileHandle.nullDevice
                }

                try process.run()
                cancellation.set(process)
                process.waitUntilExit()

                try? stderrHandle.close()
                try? outputHandle?.close()

                let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()
                let stderr = String(decoding: stderrData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if cancellation.isCancelled {
                    throw CancellationError()
                }
                guard process.terminationStatus == 0 else {
                    throw ArchiveError.commandFailed(
                        stderr.isEmpty ? "\(executable) 退出状态 \(process.terminationStatus)" : stderr
                    )
                }
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func capture(_ executable: String, arguments: [String]) async throws -> String {
        let cancellation = ProcessCancellation()

        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "LANG": "en_US.UTF-8",
                    "LC_ALL": "en_US.UTF-8"
                ]

                let stdoutURL = try makeTemporaryFile()
                let stderrURL = try makeTemporaryFile()
                defer {
                    try? FileManager.default.removeItem(at: stdoutURL)
                    try? FileManager.default.removeItem(at: stderrURL)
                }

                let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
                let stderrHandle = try FileHandle(forWritingTo: stderrURL)
                process.standardOutput = stdoutHandle
                process.standardError = stderrHandle

                try process.run()
                cancellation.set(process)
                process.waitUntilExit()

                try? stdoutHandle.close()
                try? stderrHandle.close()

                let output = String(decoding: (try? Data(contentsOf: stdoutURL)) ?? Data(), as: UTF8.self)
                let stderr = String(decoding: (try? Data(contentsOf: stderrURL)) ?? Data(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if cancellation.isCancelled {
                    throw CancellationError()
                }
                guard process.terminationStatus == 0 else {
                    throw ArchiveError.commandFailed(
                        stderr.isEmpty ? "\(executable) 退出状态 \(process.terminationStatus)" : stderr
                    )
                }
                return output
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func makeStagingDirectory(in parent: URL) throws -> URL {
        let staging = parent.appendingPathComponent(".maxplorer-archive-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        } catch {
            throw ArchiveError.stagingFailed(error.localizedDescription)
        }
    }

    private static func makeTemporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxplorer-archive-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
            throw ArchiveError.stagingFailed("无法创建临时文件。")
        }
        return url
    }
}

private nonisolated final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate {
            process.terminate()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        process?.terminate()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
