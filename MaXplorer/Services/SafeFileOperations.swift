import Foundation
import Darwin

/// One mutation lane covers both queue and service callers. Publication uses a
/// same-filesystem rename, never a remove-then-copy window. External writers are
/// detected by metadata snapshots; this is not a filesystem snapshot or journal.
nonisolated enum SafeFileOperations {
    private static let mutationLock = NSLock()

    static func entryExists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 || errno != ENOENT
    }

    static func totalByteCount(for url: URL) async throws -> Int64 {
        let worker = Task.detached(priority: .background) { try snapshot(url).bytes }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    static func perform(
        _ operation: CopyQueueOperation,
        sourceURL: URL,
        destinationURL: URL,
        overwrite: Bool,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let worker = Task.detached(priority: .background) {
            try transact(operation, source: sourceURL, destination: destinationURL,
                         overwrite: overwrite, progress: progress)
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func transact(
        _ operation: CopyQueueOperation, source: URL, destination: URL,
        overwrite: Bool, progress: @escaping @Sendable (Int64) -> Void
    ) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        try Task.checkCancellation()
        guard source.isFileURL, destination.isFileURL,
              source.path != "/", destination.path != "/" else {
            throw Failure("文件操作需要指向非根目录的文件 URL。")
        }
        // Resolve only the parents. The final symlink is the object being copied.
        let source = canonicalEntry(source)
        let destination = canonicalEntry(destination)
        let sourceParent = try DirectoryHandle(source.deletingLastPathComponent())
        let destinationParent = try DirectoryHandle(destination.deletingLastPathComponent())
        let sourceInfo = try requiredInfo(source)
        let destinationInfo = try info(destination)
        guard source != destination, !sourceInfo.sameObject(as: destinationInfo) else {
            throw Failure("源位置与目标位置指向同一文件系统对象。")
        }
        if sourceInfo.isDirectory,
           try hasAncestor(destination.deletingLastPathComponent(), matching: sourceInfo) {
            throw Failure("无法将文件夹复制或移动到其自身内部。")
        }
        if let destinationInfo, destinationInfo.isDirectory,
           try hasAncestor(source.deletingLastPathComponent(), matching: destinationInfo) {
            throw Failure("目标位置包含源项目，无法替换。")
        }
        if destinationInfo != nil && !overwrite { throw CocoaError(.fileWriteFileExists) }

        let before = try snapshot(source)
        // Editing an existing descendant does not change a directory's own
        // mtime/ctime. Include its complete old tree before an overwrite.
        let destinationBefore = destinationInfo?.isDirectory == true ? try snapshot(destination) : nil
        try Task.checkCancellation()
        try sourceParent.validate()
        try destinationParent.validate()
        // An exclusive rename is sufficient for a same-volume non-overwrite move.
        if operation == .move, destinationInfo == nil {
            if renameatx_np(sourceParent.fd, source.lastPathComponent,
                            destinationParent.fd, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 {
                progress(before.bytes)
                return
            }
            let code = errno
            guard code == EXDEV else { throw posix(code, destination) }
        }

        var template = Array(destination.deletingLastPathComponent()
            .appendingPathComponent(".maxplorer-transfer-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw posix(errno, destination) }
        let staging = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        let payload = staging.appendingPathComponent("payload")
        var published = false
        var keepRecovery = false
        do {
            let stagingHandle = try DirectoryHandle(staging)
            try copy(source, to: payload, progress: progress)
            guard try snapshot(source) == before else {
                throw Failure("复制期间源项目发生变化。未替换任何项目。")
            }
            try sourceParent.validate()
            try destinationParent.validate()
            guard try info(destination) == destinationInfo else {
                throw Failure("复制期间目标项目发生变化。未替换任何项目。")
            }
            if let destinationBefore, try snapshot(destination) != destinationBefore {
                throw Failure("复制期间目标内容发生变化。未替换任何项目。")
            }
            try Task.checkCancellation()
            // Darwin can reject renaming a write-disabled directory. Change
            // only our private copy, retain its fd across the swap, and restore
            // its exact mode immediately after publication (before source removal).
            let payloadInfo = try requiredInfo(payload)
            let payloadHandle = payloadInfo.isDirectory ? try DirectoryHandle(payload) : nil
            if let payloadHandle, fchmod(payloadHandle.fd, payloadInfo.mode | S_IWUSR) != 0 {
                throw posix(errno, payload)
            }
            let flags = destinationInfo == nil ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
            let renamed = renameatx_np(stagingHandle.fd, "payload", destinationParent.fd,
                                      destination.lastPathComponent, flags)
            let renameError = errno
            published = renamed == 0
            if let payloadHandle, fchmod(payloadHandle.fd, payloadInfo.mode) != 0, published {
                keepRecovery = true
                throw Failure("副本已保存到 \(destination.path)，但无法恢复其目录权限：\(posix(errno, destination).localizedDescription)")
            }
            guard published else { throw posix(renameError, destination) }
            // Publication is the commit point. Cancellation after it must not
            // remove the complete target or report an operation as cancelled.
            progress(before.bytes)
            if operation == .move {
                do {
                    try sourceParent.validate()
                    guard try snapshot(source, checkCancellation: false) == before else {
                        throw Failure("移除源项目之前，源项目已发生变化。")
                    }
                    try FileManager.default.removeItem(at: source)
                } catch {
                    throw Failure("完整副本位于 \(destination.path)，但无法完全移除源项目。已保留两个位置以供检查。\(error.localizedDescription)")
                }
            }
        } catch {
            let original = error
            if keepRecovery {
                throw Failure("\(original.localizedDescription) 恢复文件保留在 \(staging.path)。未移除源项目。")
            }
            do {
                if !published { try prepareToDiscard(staging) }
                try FileManager.default.removeItem(at: staging)
            }
            catch {
                throw Failure("\(original.localizedDescription) 恢复文件保留在 \(staging.path)：\(error.localizedDescription)")
            }
            throw original
        }
        do { try FileManager.default.removeItem(at: staging) }
        catch {
            throw Failure("目标项目已保存。恢复文件保留在 \(staging.path)：\(error.localizedDescription)")
        }
    }

    private static func canonicalEntry(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL
    }

    private static func hasAncestor(_ url: URL, matching object: Fingerprint) throws -> Bool {
        var current = url
        while true {
            if object.sameObject(as: try requiredInfo(current)) { return true }
            let parent = current.deletingLastPathComponent()
            if parent == current { return false }
            current = parent
        }
    }

    private static func copy(_ source: URL, to destination: URL,
                             progress: @escaping @Sendable (Int64) -> Void) throws {
        guard let state = copyfile_state_alloc() else { throw posix(ENOMEM, source) }
        defer { copyfile_state_free(state) }
        let context = CopyContext(progress: progress)
        let callback: copyfile_callback_t = { what, stage, state, from, to, rawContext in
            let callbackErrno = errno
            guard let rawContext else { return COPYFILE_QUIT }
            let context = Unmanaged<CopyContext>.fromOpaque(rawContext).takeUnretainedValue()
            if stage == COPYFILE_ERR {
                context.errorCode = callbackErrno == 0 ? EIO : callbackErrno
                return COPYFILE_QUIT
            }
            if Task.isCancelled {
                context.cancelled = true
                return COPYFILE_QUIT
            }
            // libcopyfile copies symlinks in a second pass, after directory
            // cleanup. Defer final directory permissions until that pass ends,
            // otherwise a 0555 parent prevents its symlinks from being created.
            if what == COPYFILE_RECURSE_DIR_CLEANUP, stage == COPYFILE_START,
               let from, let to {
                context.directories.append((String(cString: from), String(cString: to)))
                return COPYFILE_SKIP
            }
            if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_START { context.fileBytes = 0 }
            if what == COPYFILE_COPY_DATA, let state {
                var copied: off_t = 0
                if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
                    context.fileBytes = Int64(copied)
                    context.progress(context.finishedBytes + context.fileBytes)
                }
            }
            if what == COPYFILE_RECURSE_FILE, stage == COPYFILE_FINISH {
                context.finishedBytes += context.fileBytes
                context.fileBytes = 0
            }
            return COPYFILE_CONTINUE
        }
        let rawContext = Unmanaged.passUnretained(context).toOpaque()
        guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB),
                                 unsafeBitCast(callback, to: UnsafeRawPointer.self)) == 0,
              copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), rawContext) == 0 else {
            throw posix(errno, source)
        }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
        let result = copyfile(source.path, destination.path, state, flags)
        let code = errno
        // Keep the context alive across C callbacks, including recursive ones.
        withExtendedLifetime(context) {}
        if context.cancelled { throw CancellationError() }
        if result != 0 { throw posix(context.errorCode ?? (code == 0 ? EIO : code), source) }
        // Cleanup callbacks arrive child-first. No RECURSIVE or EXCL here:
        // these existing private directories need their final metadata only.
        for (from, to) in context.directories {
            try Task.checkCancellation()
            guard copyfile(from, to, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW)) == 0 else {
                throw posix(errno, URL(fileURLWithPath: from))
            }
        }
    }

    private final class CopyContext {
        let progress: @Sendable (Int64) -> Void
        var finishedBytes: Int64 = 0
        var fileBytes: Int64 = 0
        var directories: [(String, String)] = []
        var cancelled = false
        var errorCode: Int32?
        init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    }

    /// Only used for our unpublished replica, never for a replaced user item.
    /// lstat prevents chmod or recursion through copied symbolic links.
    private static func prepareToDiscard(_ url: URL) throws {
        let value = try requiredInfo(url)
        guard value.isDirectory else { return }
        guard chmod(url.path, value.mode | 0o700) == 0 else { throw posix(errno, url) }
        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
            try prepareToDiscard(child)
        }
    }

    private struct Snapshot: Equatable {
        var entries: [String: Fingerprint] = [:]
        var bytes: Int64 = 0
    }

    private static func snapshot(_ root: URL, checkCancellation: Bool = true) throws -> Snapshot {
        var result = Snapshot()
        func visit(_ url: URL, relative: String) throws {
            if checkCancellation { try Task.checkCancellation() }
            let entry = try requiredInfo(url)
            guard entry.kind == S_IFREG || entry.kind == S_IFDIR || entry.kind == S_IFLNK else {
                throw Failure("不支持的文件系统对象：\(url.path)。")
            }
            result.entries[relative] = entry
            if entry.kind == S_IFREG { result.bytes += Int64(entry.size) }
            if entry.isDirectory {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent)
                }
            }
        }
        try visit(root, relative: "")
        return result
    }

    private struct Fingerprint: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        let flags: UInt32
        var kind: mode_t { mode & S_IFMT }
        var isDirectory: Bool { kind == S_IFDIR }
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
            flags = value.st_flags
        }
        func sameObject(as other: Fingerprint?) -> Bool {
            guard let other else { return false }
            return device == other.device && inode == other.inode
        }
    }

    private static func info(_ url: URL) throws -> Fingerprint? {
        var value = stat()
        if lstat(url.path, &value) == 0 { return Fingerprint(value) }
        if errno == ENOENT { return nil }
        throw posix(errno, url)
    }
    private static func requiredInfo(_ url: URL) throws -> Fingerprint {
        guard let value = try info(url) else { throw posix(ENOENT, url) }
        return value
    }

    private final class DirectoryHandle {
        let fd: Int32
        let url: URL
        let identity: Fingerprint
        init(_ url: URL) throws {
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw posix(errno, url) }
            var value = stat()
            guard fstat(descriptor, &value) == 0 else {
                let code = errno
                close(descriptor)
                throw posix(code, url)
            }
            fd = descriptor; self.url = url; identity = Fingerprint(value)
        }
        deinit { close(fd) }
        func validate() throws {
            guard identity.sameObject(as: try info(url)) else {
                throw Failure("操作期间父目录发生变化：\(url.path)")
            }
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
    private static func posix(_ code: Int32, _ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
