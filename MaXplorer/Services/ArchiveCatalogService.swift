import Foundation
import Darwin
import CArchive

/// Metadata enumeration does not materialize payloads. Libarchive may have to decode
/// solid blocks to advance headers; a single native call cannot be interrupted.
nonisolated enum ArchiveCatalogService {
    static func catalog(archive: URL, limits: ArchiveReadLimits = .default) async throws -> ArchiveCatalog {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .background) { try readCatalog(archive, limits: limits) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Returns a private root inside the supplied destination. The caller owns
    /// successful staging roots and must publish safely and then remove the root.
    static func extract(
        catalog: ArchiveCatalog, selectedIDs: Set<String>, toStagingIn destination: URL,
        limits: ArchiveReadLimits = .default,
        progress: @escaping @Sendable (Int64) -> Void = { _ in }
    ) async throws -> URL {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .background) {
            try extractSelection(catalog, selectedIDs: selectedIDs, destination: destination, limits: limits, progress: progress)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func readCatalog(_ url: URL, limits: ArchiveReadLimits) throws -> ArchiveCatalog {
        try validate(limits)
        let source = try Source(url)
        let reader = try Reader(source)
        var builder = CatalogBuilder(limits: limits)
        while let header = try reader.next(ordinal: builder.headers.count, limits: limits) {
            try builder.add(header)
            try reader.skip()
        }
        try reader.checkEncryption()
        try source.validate()
        return ArchiveCatalog(archiveURL: source.url, formatName: reader.formatName,
                              entries: builder.entries.values.sorted { $0.path < $1.path },
                              identity: source.identity, headers: builder.headers)
    }

    private static func extractSelection(
        _ catalog: ArchiveCatalog, selectedIDs: Set<String>, destination: URL, limits: ArchiveReadLimits,
        progress: @escaping @Sendable (Int64) -> Void
    ) throws -> URL {
        try validate(limits)
        guard !selectedIDs.isEmpty else { throw ArchiveCatalogError.invalidCatalog("请选择要提取的项目。") }
        var builder = CatalogBuilder(limits: limits)
        for header in catalog.headers { try builder.add(header) }
        let rebuilt = builder.entries.values.sorted { $0.path < $1.path }
        guard rebuilt == catalog.entries else { throw ArchiveCatalogError.invalidCatalog("条目与原始目录不一致。") }
        let entriesByID = Dictionary(uniqueKeysWithValues: rebuilt.map { ($0.id, $0) })
        guard selectedIDs.allSatisfy({ entriesByID[$0] != nil }) else {
            throw ArchiveCatalogError.invalidCatalog("所选项目已不存在。")
        }
        let selectedDirectories = selectedIDs.compactMap { entriesByID[$0] }.filter { $0.kind == .directory }.map(\.path)
        var selected = Set<String>()
        for entry in rebuilt {
            try Task.checkCancellation()
            if selectedIDs.contains(entry.id) || selectedDirectories.contains(where: { entry.path.hasPrefix($0 + "/") }) {
                guard entry.isExtractable else { throw ArchiveCatalogError.unsupportedEntry(entry.path) }
                selected.insert(entry.id)
            }
        }
        let source = try Source(catalog.archiveURL)
        guard source.identity == catalog.identity else { throw ArchiveCatalogError.changedSource }
        let reader = try Reader(source)
        let staging = try Staging(in: destination)
        do {
            // Empty and implicit selected directories have no payload header.
            for entry in rebuilt where selected.contains(entry.id) && entry.kind == .directory {
                try staging.makeDirectory(entry.path)
            }
            var ordinal = 0
            var total: Int64 = 0
            let reporter = ExtractionProgress(callback: progress)
            while let header = try reader.next(ordinal: ordinal, limits: limits) {
                guard ordinal < catalog.headers.count, header == catalog.headers[ordinal] else {
                    throw ArchiveCatalogError.changedSource
                }
                ordinal += 1
                if selected.contains(header.entry.id), header.entry.kind == .file {
                    try staging.writeFile(header.entry, reader: reader, total: &total, limits: limits, progress: reporter)
                } else {
                    try reader.skip()
                }
            }
            guard ordinal == catalog.headers.count, reader.formatName == catalog.formatName else {
                throw ArchiveCatalogError.changedSource
            }
            try reader.checkEncryption()
            try source.validate()
            try staging.validate()
            try Task.checkCancellation()
            reporter.report(total, final: true)
            try Task.checkCancellation()
            return staging.url
        } catch {
            do { try staging.remove() }
            catch let cleanup { throw ArchiveCatalogError.cleanup("\(error.localizedDescription)；\(cleanup.localizedDescription)") }
            throw error
        }
    }

    private static func validate(_ limits: ArchiveReadLimits) throws {
        guard limits.maxEntries > 0, limits.maxEntryBytes >= 0, limits.maxTotalBytes >= 0,
              limits.maxPathBytes > 0, limits.maxDepth > 0 else {
            throw ArchiveCatalogError.limitExceeded("无效的限额设置。")
        }
    }

    private static func normalizedPath(_ raw: String, kind: ArchiveCatalogEntry.Kind, limits: ArchiveReadLimits) throws -> String {
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.contains("\\"),
              raw.utf8.count <= limits.maxPathBytes,
              !raw.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 127 || ($0.value < 32 && $0.value != 9 && $0.value != 10) }) else {
            throw ArchiveCatalogError.unsafePath(raw)
        }
        let pieces = raw.split(separator: "/", omittingEmptySubsequences: true)
        guard !pieces.contains("..") else { throw ArchiveCatalogError.unsafePath(raw) }
        let parts = pieces.filter { $0 != "." }.map(String.init)
        if let first = parts.first, first.count >= 2 {
            let bytes = Array(first.utf8)
            if bytes.count >= 2, bytes[1] == 58, (65...90).contains(bytes[0]) || (97...122).contains(bytes[0]) {
                throw ArchiveCatalogError.unsafePath(raw)
            }
        }
        // A conventional './' directory header denotes the archive root, not a file.
        if parts.isEmpty, kind == .directory, pieces.allSatisfy({ $0 == "." }) { return "" }
        guard !parts.isEmpty, parts.count <= limits.maxDepth else { throw ArchiveCatalogError.unsafePath(raw) }
        return parts.joined(separator: "/")
    }

    private static func pathKey(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    private struct CatalogBuilder {
        let limits: ArchiveReadLimits
        var headers: [ArchiveCatalogHeader] = []
        var entries: [String: ArchiveCatalogEntry] = [:]
        private var actual = Set<String>()
        private var spellings: [String: String] = [:]
        private var totalKnown: Int64 = 0
        init(limits: ArchiveReadLimits) { self.limits = limits }
        mutating func add(_ header: ArchiveCatalogHeader) throws {
            try Task.checkCancellation()
            guard headers.count < limits.maxEntries, header.entry.ordinal == headers.count else {
                throw ArchiveCatalogError.limitExceeded("归档条目数或顺序。")
            }
            let path = try normalizedPath(header.rawPath, kind: header.entry.kind, limits: limits)
            guard path == header.entry.path, header.entry.id == path else { throw ArchiveCatalogError.invalidCatalog("路径不匹配。") }
            guard actual.insert(pathKey(path)).inserted else { throw ArchiveCatalogError.invalidCatalog("重复条目：\(path)") }
            if let size = header.entry.size {
                guard size >= 0, size <= limits.maxEntryBytes, size <= limits.maxTotalBytes - totalKnown else {
                    throw ArchiveCatalogError.limitExceeded("条目或归档声明大小。")
                }
                totalKnown += size
            }
            if !path.isEmpty {
                let parts = path.split(separator: "/").map(String.init)
                for count in 1..<parts.count {
                    let parent = parts.prefix(count).joined(separator: "/")
                    try register(ArchiveCatalogEntry(id: parent, path: parent, kind: .directory, size: nil, modifiedAt: nil, ordinal: nil))
                }
                try register(header.entry)
            }
            headers.append(header)
        }
        private mutating func register(_ entry: ArchiveCatalogEntry) throws {
            let key = pathKey(entry.path)
            if let existing = spellings[key], !existing.utf8.elementsEqual(entry.path.utf8) {
                throw ArchiveCatalogError.invalidCatalog("大小写或 Unicode 名称冲突：\(entry.path)")
            }
            spellings[key] = entry.path
            if let existing = entries[entry.path] {
                guard existing.kind == .directory, entry.kind == .directory else {
                    throw ArchiveCatalogError.invalidCatalog("文件占据父目录：\(entry.path)")
                }
                if entry.ordinal != nil { entries[entry.path] = entry }
            } else {
                guard entries.count < limits.maxEntries else { throw ArchiveCatalogError.limitExceeded("包含隐含目录的条目数。") }
                entries[entry.path] = entry
            }
        }
    }

    private final class Source {
        let url: URL
        let fd: Int32
        let identity: ArchiveSourceIdentity
        init(_ url: URL) throws {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
                throw ArchiveCatalogError.invalidSource(url.path)
            }
            self.url = url.standardizedFileURL
            let value = open(self.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard value >= 0 else { throw posix(errno, self.url.path) }
            var info = stat()
            guard fstat(value, &info) == 0 else { let code = errno; close(value); throw posix(code, self.url.path) }
            guard info.st_mode & S_IFMT == S_IFREG else { close(value); throw ArchiveCatalogError.invalidSource(self.url.path) }
            fd = value; identity = ArchiveSourceIdentity(info)
            try validate()
        }
        deinit { close(fd) }
        func validate() throws {
            try Task.checkCancellation()
            var descriptor = stat(), path = stat()
            guard fstat(fd, &descriptor) == 0 else { throw posix(errno, url.path) }
            guard lstat(url.path, &path) == 0 else { throw posix(errno, url.path) }
            guard descriptor.st_mode & S_IFMT == S_IFREG, path.st_mode & S_IFMT == S_IFREG,
                  ArchiveSourceIdentity(descriptor) == identity, ArchiveSourceIdentity(path) == identity else {
                throw ArchiveCatalogError.changedSource
            }
        }
    }

    private final class Reader {
        let handle: OpaquePointer
        init(_ source: Source) throws {
            guard let handle = archive_read_new() else { throw ArchiveCatalogError.backend("无法分配读取器。") }
            do {
                // Do not register mtree/raw or external program filters.
                for status in [archive_read_support_filter_none(handle), archive_read_support_filter_gzip(handle),
                               archive_read_support_filter_bzip2(handle), archive_read_support_filter_xz(handle),
                               archive_read_support_format_zip(handle), archive_read_support_format_tar(handle),
                               archive_read_support_format_7zip(handle), archive_read_support_format_rar(handle),
                               archive_read_support_format_rar5(handle)] {
                    guard status == 0 else { throw Self.error(for: handle) }
                }
                guard archive_read_open_fd(handle, source.fd, 64 * 1024) == 0 else { throw Self.error(for: handle) }
            } catch { archive_read_free(handle); throw error }
            self.handle = handle
        }
        deinit { archive_read_free(handle) }
        var formatName: String { archive_format_name(handle).map { String(cString: $0) } ?? "Unknown" }
        func backendError() -> ArchiveCatalogError { Self.error(for: handle) }
        private static func error(for handle: OpaquePointer) -> ArchiveCatalogError {
            let message = archive_error_string(handle).map { String(cString: $0) } ?? "libarchive error"
            let lower = message.lowercased()
            if lower.contains("encrypt") || lower.contains("passphrase") || lower.contains("password") { return .encrypted }
            return .backend(message)
        }
        func checkEncryption() throws {
            // -1 / -2 mean unknown / unsupported, never an unencrypted assertion.
            if archive_read_has_encrypted_entries(handle) > 0 { throw ArchiveCatalogError.encrypted }
        }
        func next(ordinal: Int, limits: ArchiveReadLimits) throws -> ArchiveCatalogHeader? {
            try Task.checkCancellation()
            var entry: OpaquePointer?
            let status = archive_read_next_header(handle, &entry)
            if status == 1 { return nil }
            guard status == 0, let entry else { throw backendError() }
            if archive_entry_is_encrypted(entry) > 0 { throw ArchiveCatalogError.encrypted }
            guard let pointer = archive_entry_pathname_utf8(entry), let raw = String(validatingUTF8: pointer) else {
                throw ArchiveCatalogError.invalidCatalog("路径不是有效 UTF-8。")
            }
            let fileType = archive_entry_filetype(entry)
            let symlink = archive_entry_symlink(entry).map { String(cString: $0) }
            let hardlink = archive_entry_hardlink(entry).map { String(cString: $0) }
            let kind: ArchiveCatalogEntry.Kind
            if symlink != nil || hardlink != nil { kind = .unsupported }
            else if fileType == S_IFREG { kind = .file }
            else if fileType == S_IFDIR { kind = .directory }
            else { kind = .unsupported }
            let path = try normalizedPath(raw, kind: kind, limits: limits)
            let size = archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil
            let seconds = archive_entry_mtime_is_set(entry) != 0 ? archive_entry_mtime(entry) : nil
            let nanos = seconds == nil ? nil : archive_entry_mtime_nsec(entry)
            let date = seconds.map { Date(timeIntervalSince1970: Double($0) + Double(nanos ?? 0) / 1_000_000_000) }
            return ArchiveCatalogHeader(
                entry: ArchiveCatalogEntry(id: path, path: path, kind: kind, size: size, modifiedAt: date, ordinal: ordinal),
                rawPath: raw, fileType: fileType, symlink: symlink, hardlink: hardlink, mtimeSeconds: seconds, mtimeNanos: nanos
            )
        }
        func skip() throws {
            try Task.checkCancellation()
            guard archive_read_data_skip(handle) == 0 else { throw backendError() }
        }
    }

    /// One reporter per extraction, confined to its detached worker. Never invokes
    /// UI work itself; consumers receive the first bytes, throttled updates, and completion.
    private final class ExtractionProgress {
        let callback: @Sendable (Int64) -> Void
        private var lastTime: UInt64?
        private var lastBytes: Int64?
        init(callback: @escaping @Sendable (Int64) -> Void) { self.callback = callback }
        func report(_ bytes: Int64, final: Bool = false) {
            let now = DispatchTime.now().uptimeNanoseconds
            if final {
                guard lastBytes != bytes else { return }
            } else if let lastTime {
                guard now - lastTime >= 250_000_000 else { return }
            } else if bytes == 0 { return }
            lastTime = now; lastBytes = bytes
            callback(bytes)
        }
    }

    private final class Staging {
        let url: URL
        let parentURL: URL
        let name: String
        let parentFD: Int32
        let fd: Int32
        let parentIdentity: (dev_t, ino_t)
        let identity: (dev_t, ino_t)
        init(in destination: URL) throws {
            guard destination.isFileURL else { throw ArchiveCatalogError.invalidSource(destination.path) }
            parentURL = destination.resolvingSymlinksInPath().standardizedFileURL
            let parent = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw posix(errno, parentURL.path) }
            var parentInfo = stat()
            guard fstat(parent, &parentInfo) == 0 else { let code = errno; close(parent); throw posix(code, parentURL.path) }
            parentFD = parent; parentIdentity = (parentInfo.st_dev, parentInfo.st_ino)
            name = ".maxplorer-archive-" + UUID().uuidString
            url = parentURL.appendingPathComponent(name, isDirectory: true)
            guard mkdirat(parent, name, 0o700) == 0 else { let code = errno; close(parent); throw posix(code, url.path) }
            let root = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard root >= 0 else { let code = errno; unlinkat(parent, name, AT_REMOVEDIR); close(parent); throw posix(code, url.path) }
            var rootInfo = stat()
            guard fstat(root, &rootInfo) == 0 else {
                let code = errno; close(root); unlinkat(parent, name, AT_REMOVEDIR); close(parent); throw posix(code, url.path)
            }
            fd = root; identity = (rootInfo.st_dev, rootInfo.st_ino)
        }
        deinit { close(fd); close(parentFD) }
        func validate() throws {
            var parent = stat(), root = stat()
            guard lstat(parentURL.path, &parent) == 0 else { throw posix(errno, parentURL.path) }
            guard fstatat(parentFD, name, &root, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix(errno, url.path) }
            guard parent.st_dev == parentIdentity.0, parent.st_ino == parentIdentity.1,
                  root.st_dev == identity.0, root.st_ino == identity.1, root.st_mode & S_IFMT == S_IFDIR else {
                throw ArchiveCatalogError.invalidCatalog("临时目录或父目录发生变化。")
            }
        }
        func directoryFD(_ parts: ArraySlice<String>) throws -> Int32 {
            var current = dup(fd)
            guard current >= 0 else { throw posix(errno, url.path) }
            do {
                for part in parts {
                    try Task.checkCancellation()
                    if mkdirat(current, part, 0o700) != 0, errno != EEXIST { throw posix(errno, part) }
                    let child = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw posix(errno, part) }
                    close(current); current = child
                }
                return current
            } catch { close(current); throw error }
        }
        func makeDirectory(_ path: String) throws {
            let parts = path.split(separator: "/").map(String.init)
            let descriptor = try directoryFD(parts[...]); close(descriptor)
        }
        func writeFile(
            _ entry: ArchiveCatalogEntry, reader: Reader, total: inout Int64,
            limits: ArchiveReadLimits, progress: ExtractionProgress
        ) throws {
            let parts = entry.path.split(separator: "/").map(String.init)
            guard let name = parts.last else { throw ArchiveCatalogError.unsafePath(entry.path) }
            let parent = try directoryFD(parts.dropLast())
            defer { close(parent) }
            let output = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw posix(errno, entry.path) }
            var outputOpen = true
            defer { if outputOpen { close(output) } }
            var bytes: Int64 = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes { archive_read_data(reader.handle, $0.baseAddress, $0.count) }
                guard count >= 0 else { throw reader.backendError() }
                if count == 0 { break }
                guard Int64(count) <= limits.maxEntryBytes - bytes, Int64(count) <= limits.maxTotalBytes - total else {
                    throw ArchiveCatalogError.limitExceeded("实际提取的数据大小。")
                }
                var offset = 0
                while offset < count {
                    try Task.checkCancellation()
                    let written = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: offset), count - offset) }
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw posix(written == 0 ? EIO : errno, entry.path) }
                    offset += written
                }
                bytes += Int64(count); total += Int64(count)
                progress.report(total)
            }
            if let declared = entry.size, declared != bytes { throw ArchiveCatalogError.backend("条目数据长度与目录不一致：\(entry.path)") }
            guard fsync(output) == 0 else { throw posix(errno, entry.path) }
            let closeResult = close(output)
            outputOpen = false
            guard closeResult == 0 else { throw posix(errno, entry.path) }
        }
        func remove() throws {
            try removeContents(fd)
            var root = stat()
            guard fstatat(parentFD, name, &root, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix(errno, url.path) }
            guard root.st_dev == identity.0, root.st_ino == identity.1 else {
                throw ArchiveCatalogError.cleanup("临时目录被替换：\(url.path)")
            }
            guard unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else { throw posix(errno, url.path) }
        }
        private func removeContents(_ descriptor: Int32) throws {
            let enumeration = dup(descriptor)
            guard enumeration >= 0 else { throw posix(errno, url.path) }
            guard let stream = fdopendir(enumeration) else { let code = errno; close(enumeration); throw posix(code, url.path) }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let item = readdir(stream) else {
                    guard errno == 0 else { throw posix(errno, url.path) }
                    break
                }
                let name = withUnsafePointer(to: &item.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                var info = stat()
                guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix(errno, name) }
                if info.st_mode & S_IFMT == S_IFDIR {
                    let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw posix(errno, name) }
                    do { try removeContents(child) } catch { close(child); throw error }
                    close(child)
                    guard unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { throw posix(errno, name) }
                } else {
                    guard unlinkat(descriptor, name, 0) == 0 else { throw posix(errno, name) }
                }
            }
        }
    }

    private static func posix(_ code: Int32, _ path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
}
