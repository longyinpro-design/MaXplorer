import Foundation
import Darwin

nonisolated enum FilePropertyField: String, Hashable, Sendable {
    case permissions
    case tags
}

nonisolated enum FilePropertyError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL
    case unsupportedFileType
    case staleSnapshot
    case pathReplaced
    case metadataChanged
    case malformedTags
    case invalidPermissions
    case invalidTagName
    case tooManyTags
    case tagNameTooLong
    case tagDataTooLarge
    case cancelled
    case verificationFailed(FilePropertyField)
    case system(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "只支持有效的本机文件路径。"
        case .unsupportedFileType: return "仅支持普通文件和目录；不编辑符号链接或特殊文件。"
        case .staleSnapshot: return "文件身份或属性已变化，请重新读取后再应用。"
        case .pathReplaced: return "路径指向的文件已被替换，请重新读取；已写入的字段会单独列出。"
        case .metadataChanged: return "读取期间属性发生变化，请重新读取后再应用。"
        case .malformedTags: return "现有 Finder 标签数据无效，已停止编辑以保留原始数据。"
        case .invalidPermissions: return "权限只能是 000 到 777，不编辑特殊权限位。"
        case .invalidTagName: return "标签名称不能为空或只含空白，也不能含 NUL 或换行。"
        case .tooManyTags: return "每个文件最多支持 100 个标签。"
        case .tagNameTooLong: return "每个标签名称最多支持 255 个 UTF-8 字节。"
        case .tagDataTooLarge: return "标签属性最多支持 64 KiB。"
        case .cancelled: return "操作已取消；已写入的字段会单独列出。"
        case .verificationFailed(let field): return "\(field == .permissions ? "权限" : "标签")写入后的复核不一致，请重新读取属性。"
        case .system(let operation, let code):
            let detail = String(cString: strerror(code))
            return "\(operation)失败：\(detail)（\(code)）。"
        }
    }
}

nonisolated fileprivate struct FilePropertyIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let type: UInt16
    let birthSeconds: Int
    let birthNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        type = value.st_mode & UInt16(S_IFMT)
        birthSeconds = value.st_birthtimespec.tv_sec
        birthNanoseconds = value.st_birthtimespec.tv_nsec
    }
}

nonisolated fileprivate struct FilePropertyVersion: Equatable, Sendable {
    let identity: FilePropertyIdentity
    let mode: UInt16
    let owner: UInt32
    let group: UInt32
    let flags: UInt32
    let changeSeconds: Int
    let changeNanoseconds: Int

    init(_ value: stat) {
        identity = FilePropertyIdentity(value)
        mode = value.st_mode
        owner = value.st_uid
        group = value.st_gid
        flags = value.st_flags
        changeSeconds = value.st_ctimespec.tv_sec
        changeNanoseconds = value.st_ctimespec.tv_nsec
    }
}

/// Snapshots can only be minted by inspect; identity and original tag bytes are not caller-editable.
nonisolated struct FilePropertySnapshot: Sendable {
    let url: URL
    let permissions: UInt16
    let tagNames: [String]
    let isDirectory: Bool
    fileprivate let version: FilePropertyVersion
    fileprivate let rawTagData: Data?

    fileprivate init(url: URL, version: FilePropertyVersion, rawTagData: Data?, tagNames: [String]) {
        self.url = url
        self.permissions = version.mode & 0o777
        self.tagNames = tagNames
        self.isDirectory = version.identity.type == UInt16(S_IFDIR)
        self.version = version
        self.rawTagData = rawTagData
    }
}

nonisolated struct FilePropertyInspection: Sendable {
    let url: URL
    let snapshot: FilePropertySnapshot?
    let error: FilePropertyError?
}

nonisolated struct FilePropertyChange: Sendable {
    let snapshot: FilePropertySnapshot
    let permissions: UInt16?
    let tagNames: [String]?

    init(snapshot: FilePropertySnapshot, permissions: UInt16? = nil, tagNames: [String]? = nil) {
        self.snapshot = snapshot
        self.permissions = permissions
        self.tagNames = tagNames
    }
}

nonisolated struct FilePropertyApplyResult: Sendable {
    let url: URL
    /// Successful field write syscalls, even when a subsequent check or field fails.
    let appliedFields: [FilePropertyField]
    let error: FilePropertyError?
}

/// Nonrecursive, no elevation. Each write targets the same opened descriptor. POSIX provides no
/// atomic compare-and-swap across chmod/xattrs, so concurrent modification can still be reported
/// after an already completed write. We never attempt a path-based rollback.
nonisolated enum FilePropertyService {
    static let maximumTagCount = 100
    static let maximumTagNameUTF8Bytes = 255
    static let maximumTagDataBytes = 65_536
    private static let tagAttribute = "com.apple.metadata:_kMDItemUserTags"

    static func inspect(_ urls: [URL]) async -> [FilePropertyInspection] {
        let worker = Task.detached(priority: .userInitiated) {
            urls.map { url in
                do {
                    try checkCancellation()
                    return FilePropertyInspection(url: url, snapshot: try inspectOne(url), error: nil)
                } catch {
                    return FilePropertyInspection(url: url, snapshot: nil, error: typed(error))
                }
            }
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    static func apply(_ changes: [FilePropertyChange]) async -> [FilePropertyApplyResult] {
        await perform(changes, beforeItem: nil)
    }

    #if MAXPLORER_FAULT_TESTS
    /// Deterministic cancellation/replacement gates for private test fixtures only.
    static func applyForTesting(
        _ changes: [FilePropertyChange], beforeItem: @escaping @Sendable (Int) -> Void
    ) async -> [FilePropertyApplyResult] {
        await perform(changes, beforeItem: beforeItem)
    }
    #endif

    private static func perform(
        _ changes: [FilePropertyChange], beforeItem: (@Sendable (Int) -> Void)?
    ) async -> [FilePropertyApplyResult] {
        let worker = Task.detached(priority: .userInitiated) {
            changes.enumerated().map { index, change in
                beforeItem?(index)
                return applyOne(change)
            }
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    private static func inspectOne(_ url: URL) throws -> FilePropertySnapshot {
        let fd = try openFile(url)
        defer { close(fd) }
        let version = try versionOf(fd)
        let raw = try readTags(fd)
        let names = try parseTags(raw).map(\.name)
        try validate(fd, url: url, expected: version, rawTags: raw)
        try checkCancellation()
        return FilePropertySnapshot(url: url, version: version, rawTagData: raw, tagNames: names)
    }

    private static func applyOne(_ change: FilePropertyChange) -> FilePropertyApplyResult {
        let snapshot = change.snapshot
        var applied: [FilePropertyField] = []
        do {
            try checkCancellation()
            if let mode = change.permissions, mode > 0o777 { throw FilePropertyError.invalidPermissions }
            let desiredTags = try change.tagNames.map { try encodedTags($0, original: snapshot.rawTagData) }
            let fd = try openFile(snapshot.url)
            defer { close(fd) }
            var expected = snapshot.version
            var expectedTags = snapshot.rawTagData
            try validate(fd, url: snapshot.url, expected: expected, rawTags: expectedTags)
            if let mode = change.permissions, mode != snapshot.permissions {
                try checkCancellation()
                try validate(fd, url: snapshot.url, expected: expected, rawTags: expectedTags)
                let fullMode = (expected.mode & 0o7000) | mode
                guard fchmod(fd, fullMode) == 0 else { throw systemError("权限写入") }
                applied.append(.permissions)
                let updated = try versionOf(fd)
                try checkIdentity(updated, expected: expected)
                guard updated.mode & 0o7777 == fullMode else {
                    throw FilePropertyError.verificationFailed(.permissions)
                }
                expected = updated
                try validatePath(snapshot.url, expected: expected)
            }
            // Permissions are applied first. A restrictive new mode may deny a subsequent tag
            // operation; the result retains .permissions and reports the actual failing boundary.
            if let desiredTags, desiredTags != expectedTags {
                try checkCancellation()
                try validate(fd, url: snapshot.url, expected: expected, rawTags: expectedTags)
                if let data = desiredTags {
                    let status = data.withUnsafeBytes { bytes in
                        fsetxattr(fd, tagAttribute, bytes.baseAddress, data.count, 0, 0)
                    }
                    guard status == 0 else { throw systemError("标签写入") }
                } else {
                    guard fremovexattr(fd, tagAttribute, 0) == 0 else { throw systemError("标签清除") }
                }
                applied.append(.tags)
                let updated = try versionOf(fd)
                try checkIdentity(updated, expected: expected)
                guard updated.mode == expected.mode, try readTags(fd) == desiredTags else {
                    throw FilePropertyError.verificationFailed(.tags)
                }
                expected = updated
                expectedTags = desiredTags
                try validatePath(snapshot.url, expected: expected)
            }
            // Even a no-op change must reject a stale preview, as checked above.
            return FilePropertyApplyResult(url: snapshot.url, appliedFields: applied, error: nil)
        } catch {
            return FilePropertyApplyResult(url: snapshot.url, appliedFields: applied, error: typed(error))
        }
    }

    private static func openFile(_ url: URL) throws -> Int32 {
        guard url.isFileURL, !url.path.contains("\0") else { throw FilePropertyError.invalidURL }
        var before = stat()
        guard lstat(url.path, &before) == 0 else { throw systemError("文件读取") }
        let kind = before.st_mode & UInt16(S_IFMT)
        guard kind == UInt16(S_IFREG) || kind == UInt16(S_IFDIR) else {
            throw FilePropertyError.unsupportedFileType
        }
        // O_EVTONLY still requires authorization on this host; mode000 may return EACCES.
        // No path-based chmod fallback: all metadata writes must remain descriptor-anchored.
        let fd = open(url.path, O_EVTONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw systemError("文件打开") }
        do {
            let opened = try versionOf(fd)
            guard opened == FilePropertyVersion(before) else { throw FilePropertyError.staleSnapshot }
            try validatePath(url, expected: opened)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func versionOf(_ fd: Int32) throws -> FilePropertyVersion {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw systemError("属性读取") }
        let kind = value.st_mode & UInt16(S_IFMT)
        guard kind == UInt16(S_IFREG) || kind == UInt16(S_IFDIR) else {
            throw FilePropertyError.unsupportedFileType
        }
        return FilePropertyVersion(value)
    }

    private static func validatePath(_ url: URL, expected: FilePropertyVersion) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw systemError("路径复核") }
        let path = FilePropertyVersion(value)
        guard path.identity == expected.identity else { throw FilePropertyError.pathReplaced }
        guard path == expected else { throw FilePropertyError.metadataChanged }
    }

    private static func checkIdentity(_ actual: FilePropertyVersion, expected: FilePropertyVersion) throws {
        guard actual.identity == expected.identity else { throw FilePropertyError.pathReplaced }
        guard actual.owner == expected.owner, actual.group == expected.group, actual.flags == expected.flags else {
            throw FilePropertyError.metadataChanged
        }
    }

    private static func validate(
        _ fd: Int32, url: URL, expected: FilePropertyVersion, rawTags: Data?
    ) throws {
        let before = try versionOf(fd)
        guard before == expected else { throw FilePropertyError.staleSnapshot }
        guard try readTags(fd) == rawTags else { throw FilePropertyError.staleSnapshot }
        guard try versionOf(fd) == before else { throw FilePropertyError.metadataChanged }
        try validatePath(url, expected: before)
    }

    private static func readTags(_ fd: Int32) throws -> Data? {
        let length = fgetxattr(fd, tagAttribute, nil, 0, 0, 0)
        if length < 0 {
            if errno == ENOATTR { return nil }
            throw systemError("标签读取")
        }
        guard length <= maximumTagDataBytes else { throw FilePropertyError.tagDataTooLarge }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { bytes in
            fgetxattr(fd, tagAttribute, bytes.baseAddress, length, 0, 0)
        }
        guard read >= 0 else { throw systemError("标签读取") }
        guard read == length else { throw FilePropertyError.metadataChanged }
        return data
    }

    private struct Tag {
        let name: String
        let raw: String
    }

    private static func parseTags(_ data: Data?) throws -> [Tag] {
        guard let data else { return [] }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let values = try? PropertyListSerialization.propertyList(from: data, format: &format),
              format == .binary, let strings = values as? [String] else { throw FilePropertyError.malformedTags }
        guard strings.count <= maximumTagCount else { throw FilePropertyError.tooManyTags }
        var seen = Set<String>()
        return try strings.map { raw in
            let parts = raw.components(separatedBy: "\n")
            guard parts.count == 1 || (parts.count == 2 && parts[1].utf8.count == 1 && ("0"..."7").contains(parts[1])) else {
                throw FilePropertyError.malformedTags
            }
            let name = parts[0].precomposedStringWithCanonicalMapping
            do { try validateName(name) } catch { throw FilePropertyError.malformedTags }
            guard seen.insert(name).inserted else { throw FilePropertyError.malformedTags }
            return Tag(name: name, raw: raw)
        }
    }

    private static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.unicodeScalars.contains(where: { $0.value == 0 || CharacterSet.newlines.contains($0) }) else {
            throw FilePropertyError.invalidTagName
        }
        guard name.utf8.count <= maximumTagNameUTF8Bytes else { throw FilePropertyError.tagNameTooLong }
    }

    /// NFC, case-sensitive deduplication preserves first-input order. Existing raw names and color
    /// suffixes are retained by canonical name; new tags use Finder's no-color suffix "\n0".
    private static func encodedTags(_ input: [String], original: Data?) throws -> Data? {
        guard input.count <= maximumTagCount else { throw FilePropertyError.tooManyTags }
        var seen = Set<String>()
        let names = try input.compactMap { value -> String? in
            let name = value.precomposedStringWithCanonicalMapping
            try validateName(name)
            return seen.insert(name).inserted ? name : nil
        }
        let old = try parseTags(original)
        if names.isEmpty { return nil }
        if names == old.map(\.name) { return original }
        let oldByName = Dictionary(uniqueKeysWithValues: old.map { ($0.name, $0.raw) })
        let strings = names.map { oldByName[$0] ?? "\($0)\n0" }
        let data = try PropertyListSerialization.data(fromPropertyList: strings, format: .binary, options: 0)
        guard data.count <= maximumTagDataBytes else { throw FilePropertyError.tagDataTooLarge }
        return data
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw FilePropertyError.cancelled }
    }

    private static func systemError(_ operation: String) -> FilePropertyError {
        .system(operation: operation, code: errno)
    }

    private static func typed(_ error: Error) -> FilePropertyError {
        (error as? FilePropertyError) ?? .system(operation: "属性编辑", code: EIO)
    }
}
