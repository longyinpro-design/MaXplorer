import Foundation
import Darwin

/// Validation and publication are serialized across queue and service callers.
/// Payload copying runs concurrently in private staging directories; only the
/// final checks, rename, and source removal take the mutation lane. Publication
/// uses a same-filesystem rename, never a remove-then-copy window. External
/// writers are detected by metadata snapshots; this is not a filesystem snapshot
/// or journal.
nonisolated enum SafeFileOperations {
    /// Faults are available only in the standalone safety-test build. The app
    /// has no runtime/environment switch capable of enabling them.
    enum FailurePoint: Hashable {
        case copyData, publishPayload, rollbackBackup, restorePermissions
        case cleanupStaging, cleanupBackup, probeSwap, publishSwap
    }
#if MAXPLORER_FAULT_TESTS
    private static let failureLock = NSLock()
    private static var injectedFailures: [FailurePoint: Int32] = [:]
    private static var observedFailures: Set<FailurePoint> = []
    private static var swapProbeCount = 0

    static func resetSwapCapabilitiesForTesting() {
        capabilityLock.lock()
        defer { capabilityLock.unlock() }
        swapCapabilities = [:]
        swapProbeCount = 0
    }

    static var swapProbeCountForTesting: Int {
        capabilityLock.lock()
        defer { capabilityLock.unlock() }
        return swapProbeCount
    }


    static func setFailuresForTesting(_ failures: [FailurePoint: Int32]) {
        failureLock.lock()
        defer { failureLock.unlock() }
        injectedFailures = failures
        observedFailures = []
    }

    static func observedFailureForTesting(_ point: FailurePoint) -> Bool {
        failureLock.lock()
        defer { failureLock.unlock() }
        return observedFailures.contains(point)
    }
#endif

    private static func injectedFailure(at point: FailurePoint) -> Int32? {
#if MAXPLORER_FAULT_TESTS
        failureLock.lock()
        defer { failureLock.unlock() }
        guard let code = injectedFailures.removeValue(forKey: point) else { return nil }
        observedFailures.insert(point)
        return code
#else
        return nil
#endif
    }

    private static func systemCall(at point: FailurePoint, _ operation: () -> Int32) -> Int32 {
        if let code = injectedFailure(at: point) {
            errno = code
            return -1
        }
        return operation()
    }

    private static func checkInjectedFailure(at point: FailurePoint, url: URL) throws {
        if let code = injectedFailure(at: point) { throw posix(code, url) }
    }

    private static let mutationLock = NSLock()
    private static let capabilityLock = NSLock()
    private static var swapCapabilities: [String: Bool] = [:]
    private static let fallbackOverrideLock = NSLock()
    private static var forceSwapFallbackOverride = false

    static func setForcedSwapFallbackForTesting(_ enabled: Bool) {
        fallbackOverrideLock.lock()
        forceSwapFallbackOverride = enabled
        fallbackOverrideLock.unlock()
    }

    private static func withMutationLock<T>(_ body: () throws -> T) rethrows -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return try body()
    }

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
        totalBytes: @escaping @Sendable (Int64) -> Void = { _ in },
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let worker = Task.detached(priority: .background) {
            try transact(operation, source: sourceURL, destination: destinationURL,
                         overwrite: overwrite, totalBytes: totalBytes, progress: progress)
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
    }

    private static func transact(
        _ operation: CopyQueueOperation, source: URL, destination: URL,
        overwrite: Bool,
        totalBytes: @escaping @Sendable (Int64) -> Void,
        progress: @escaping @Sendable (Int64) -> Void
    ) throws {
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
        let sourceParentURL = source.deletingLastPathComponent()
        let destinationParentURL = destination.deletingLastPathComponent()
        guard source != destination, !sourceInfo.sameObject(as: destinationInfo) else {
            throw Failure("源位置与目标位置指向同一文件系统对象。")
        }
        if sourceInfo.isDirectory,
           try hasAncestor(destinationParentURL, matching: sourceInfo) {
            throw Failure("无法将文件夹复制或移动到其自身内部。")
        }
        if let destinationInfo, destinationInfo.isDirectory,
           try hasAncestor(sourceParentURL, matching: destinationInfo) {
            throw Failure("目标位置包含源项目，无法替换。")
        }
        if destinationInfo != nil && !overwrite { throw CocoaError(.fileWriteFileExists) }

        let before = try snapshot(source)
        // The queue needs the total before byte progress starts. Reuse the
        // snapshot that change detection already requires instead of walking
        // the tree a second time.
        totalBytes(before.bytes)
        // Editing an existing descendant does not change a directory's own
        // mtime/ctime. Include its complete old tree before an overwrite.
        let destinationBefore = destinationInfo?.isDirectory == true ? try snapshot(destination) : nil
        try Task.checkCancellation()
        try sourceParent.validate()
        try destinationParent.validate()
        // An exclusive rename is sufficient for a same-volume non-overwrite move.
        if operation == .move, destinationInfo == nil {
            let renameResult = try withMutationLock { () -> Int32 in
                try sourceParent.validate()
                try destinationParent.validate()
                guard try info(source)?.sameObject(as: sourceInfo) == true else {
                    throw Failure("移动前源项目发生变化。未移动任何项目。")
                }
                guard try info(destination) == destinationInfo else {
                    throw Failure("移动前目标项目发生变化。未移动任何项目。")
                }
                if renameatx_np(sourceParent.fd, source.lastPathComponent,
                                destinationParent.fd, destination.lastPathComponent,
                                UInt32(RENAME_EXCL)) == 0 {
                    return 0
                }
                return errno
            }
            if renameResult == 0 {
                progress(before.bytes)
                return
            }
            guard renameResult == EXDEV else { throw posix(renameResult, destination) }
        }

        let swapSupported = destinationInfo != nil
            ? supportsSwapRename(at: destinationParentURL)
            : true
        if let free = VolumeCapacityReader.stats(for: destinationParentURL)?.free {
            let required = UInt64(max(0, before.bytes))
            if required > free {
                throw Failure("目标空间不足：需要 \(formattedBytes(before.bytes))，可用 \(formattedBytes(Int64(min(free, UInt64(Int64.max)))))。未修改任何项目。")
            }
        }

        var template = Array(destination.deletingLastPathComponent()
            .appendingPathComponent(".maxplorer-transfer-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw posix(errno, destination) }
        let staging = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        let payload = staging.appendingPathComponent("payload")
        var published = false
        var keepRecovery = false
        var backupToRemove: URL?
        do {
            let stagingHandle = try DirectoryHandle(staging)
            try copy(source, to: payload, progress: progress)

            try withMutationLock {
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

                if destinationInfo == nil {
                    let renamed = renameatx_np(
                        stagingHandle.fd,
                        "payload",
                        destinationParent.fd,
                        destination.lastPathComponent,
                        UInt32(RENAME_EXCL)
                    )
                    guard renamed == 0 else { throw posix(errno, destination) }
                    published = true
                } else if swapSupported {
                    let renamed = systemCall(at: .publishSwap) {
                        renameatx_np(stagingHandle.fd, "payload", destinationParent.fd,
                                     destination.lastPathComponent, UInt32(RENAME_SWAP))
                    }
                    if renamed == 0 {
                        published = true
                    } else {
                        let renameError = errno
                        guard isSwapUnsupported(renameError) else {
                            throw posix(renameError, destination)
                        }
                        markSwapUnsupported(at: destinationParentURL)
                        backupToRemove = try publishWithBackup(
                            stagingHandle: stagingHandle,
                            destinationParent: destinationParent,
                            destination: destination
                        )
                        published = true
                    }
                } else {
                    backupToRemove = try publishWithBackup(
                        stagingHandle: stagingHandle,
                        destinationParent: destinationParent,
                        destination: destination
                    )
                    published = true
                }

                if let payloadHandle, systemCall(at: .restorePermissions, { fchmod(payloadHandle.fd, payloadInfo.mode) }) != 0, published {
                    keepRecovery = true
                    let backupNote = backupToRemove.map { " 旧目标备份保留在 \($0.path)。" } ?? ""
                    throw Failure("副本已保存到 \(destination.path)，但无法恢复其目录权限：\(posix(errno, destination).localizedDescription)\(backupNote)")
                }
                guard published else { throw posix(errno, destination) }
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
            }
        } catch {
            let original = error
            let isCancellation = original is CancellationError
            let reported = isCancellation
                ? original
                : enrichedOperationError(
                    original,
                    destinationDirectory: destinationParentURL,
                    requiredBytes: before.bytes
                )
            let backupNote = backupToRemove.map { " 旧目标备份保留在 \($0.path)。" } ?? ""
            if keepRecovery {
                throw Failure("\(reported.localizedDescription) 恢复文件保留在 \(staging.path)。\(backupNote)未移除源项目。")
            }
            do {
                if !published { try prepareToDiscard(staging) }
                try FileManager.default.removeItem(at: staging)
            }
            catch {
                throw Failure("\(reported.localizedDescription) 恢复文件保留在 \(staging.path)：\(error.localizedDescription)\(backupNote)")
            }
            if isCancellation { throw CancellationError() }
            throw Failure("\(reported.localizedDescription)\(backupNote)")
        }
        do {
            try checkInjectedFailure(at: .cleanupStaging, url: staging)
            try FileManager.default.removeItem(at: staging)
        }
        catch {
            let backupNote = backupToRemove.map { " 旧目标备份保留在 \($0.path)。" } ?? ""
            throw Failure("目标项目已保存。恢复文件保留在 \(staging.path)：\(error.localizedDescription)\(backupNote)")
        }
        if let backupToRemove {
            do { try removeBackup(backupToRemove) }
            catch {
                throw Failure("目标项目已保存。旧目标备份保留在 \(backupToRemove.path)：\(error.localizedDescription)")
            }
        }
    }

    private static func canonicalEntry(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL
    }

    // MARK: - Volume capabilities

    private static func supportsSwapRename(at directory: URL) -> Bool {
        if isSwapFallbackForced() { return false }

        let volume = volumeIdentifier(for: directory)
        capabilityLock.lock()
        let cached = volume.flatMap { swapCapabilities[$0] }
        capabilityLock.unlock()
        if let cached { return cached }

#if MAXPLORER_FAULT_TESTS
        capabilityLock.lock()
        swapProbeCount += 1
        capabilityLock.unlock()
#endif
        guard let probe = try? makeSwapProbe(in: directory) else { return true }
        defer {
            close(probe.fd)
            try? FileManager.default.removeItem(at: probe.url)
        }

        if systemCall(at: .probeSwap, {
            renameatx_np(probe.fd, "a", probe.fd, "b", UInt32(RENAME_SWAP))
        }) == 0 {
            recordSwapCapability(true, volume: volume)
            return true
        }
        let code = errno
        guard isSwapUnsupported(code) else { return true }
        recordSwapCapability(false, volume: volume)
        return false
    }

    private static func markSwapUnsupported(at directory: URL) {
        recordSwapCapability(false, volume: volumeIdentifier(for: directory))
    }

    private static func recordSwapCapability(_ supported: Bool, volume: String?) {
        guard let volume else { return }
        capabilityLock.lock()
        // A real failed swap overrides a successful probe racing with it.
        if !supported || swapCapabilities[volume] == nil {
            swapCapabilities[volume] = supported
        }
        capabilityLock.unlock()
    }

    private static func isSwapUnsupported(_ code: Int32) -> Bool {
        code == EINVAL || code == ENOTSUP || code == ENOSYS || code == EXDEV
    }

    private static func isSwapFallbackForced() -> Bool {
        fallbackOverrideLock.lock()
        defer { fallbackOverrideLock.unlock() }
        return forceSwapFallbackOverride
    }

    private static func volumeIdentifier(for directory: URL) -> String? {
        var info = statfs()
        guard statfs(directory.path, &info) == 0 else { return nil }
        // A mount path can be reused for a different volume. Cache by the actual
        // mounted filesystem identity; the publication syscall still validates
        // capabilities and downgrades a cached success if the server changes.
        return "\(info.f_fsid.val.0):\(info.f_fsid.val.1)"
    }

    private static func makeSwapProbe(in directory: URL) throws -> (url: URL, fd: Int32) {
        var template = Array(
            directory.appendingPathComponent(".maxplorer-probe-XXXXXX").path.utf8CString
        )
        guard mkdtemp(&template) != nil else { throw posix(errno, directory) }
        let probeURL = URL(fileURLWithPath: String(cString: template), isDirectory: true)
        let fd = open(probeURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: probeURL)
            throw posix(errno, probeURL)
        }

        for name in ["a", "b"] {
            let fileDescriptor = openat(fd, name, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            if fileDescriptor < 0 {
                close(fd)
                try? FileManager.default.removeItem(at: probeURL)
                throw posix(errno, probeURL)
            }
            close(fileDescriptor)
        }
        return (probeURL, fd)
    }

    /// SMB and some non-APFS volumes cannot atomically swap two names. This
    /// fallback keeps the old destination under a private backup name until the
    /// staged payload has been published, and rolls it back on failure.
    private static func publishWithBackup(
        stagingHandle: DirectoryHandle,
        destinationParent: DirectoryHandle,
        destination: URL
    ) throws -> URL {
        let backupName = ".maxplorer-backup-\(UUID().uuidString)"
        let backupURL = destinationParent.url.appendingPathComponent(backupName)

        guard renameatx_np(
            destinationParent.fd,
            destination.lastPathComponent,
            destinationParent.fd,
            backupName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw posix(errno, destination)
        }

        guard systemCall(at: .publishPayload, {
            renameatx_np(stagingHandle.fd, "payload", destinationParent.fd,
                         destination.lastPathComponent, UInt32(RENAME_EXCL))
        }) == 0 else {
            let publishCode = errno
            let rollback = systemCall(at: .rollbackBackup) {
                renameatx_np(destinationParent.fd, backupName, destinationParent.fd,
                             destination.lastPathComponent, UInt32(RENAME_EXCL))
            }
            if rollback != 0 {
                throw Failure("发布失败，旧目标备份保留在 \(backupURL.path)，且无法恢复原名称。")
            }
            throw posix(publishCode, destination)
        }

        return backupURL
    }

    private static func removeBackup(_ url: URL) throws {
        try checkInjectedFailure(at: .cleanupBackup, url: url)
        try prepareToDiscard(url)
        try FileManager.default.removeItem(at: url)
    }

    private static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func enrichedOperationError(
        _ error: Error,
        destinationDirectory: URL,
        requiredBytes: Int64
    ) -> Error {
        let nsError = error as NSError
        if nsError.code == Int(ENOSPC) {
            let free = VolumeCapacityReader.stats(for: destinationDirectory)?.free
            let freeText = free.map { formattedBytes(Int64(min($0, UInt64(Int64.max)))) } ?? "未知"
            return Failure("目标空间不足：需要 \(formattedBytes(requiredBytes))，可用 \(freeText)。未替换任何项目。")
        }
        if nsError.code == Int(ENOTCONN) || nsError.code == Int(ETIMEDOUT) || nsError.code == Int(EHOSTDOWN) {
            return Failure("目标位置连接中断。未替换任何项目；恢复连接后请重试。")
        }
        return error
    }

    private static func hasAncestor(_ url: URL, matching object: Fingerprint) throws -> Bool {
        var current = url.standardizedFileURL
        while true {
            if object.sameObject(as: try requiredInfo(current)) { return true }
            if current.path == "/" { return false }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return false }
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
                // libcopyfile may report ECANCELED again after COPYFILE_QUIT.
                // Preserve the first failure so disk/network errors stay actionable.
                if context.errorCode == nil {
                    context.errorCode = callbackErrno == 0 ? EIO : callbackErrno
                }
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
                    if copied > 0, let code = SafeFileOperations.injectedFailure(at: .copyData) {
                        context.errorCode = code
                        return COPYFILE_QUIT
                    }
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
