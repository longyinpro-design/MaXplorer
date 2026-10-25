import Foundation
import Darwin

nonisolated enum CloudFileAction: String, Equatable, Sendable { case download, evict }
nonisolated enum CloudFileDownloadStatus: String, Equatable, Sendable { case unknown, notDownloaded, downloaded, current }
nonisolated enum CloudFileStatus: String, Equatable, Sendable {
    case unknown, unsupported, notDownloaded, downloaded, current
    case downloadRequested, downloading, uploading, conflicted, failed
}

nonisolated struct CloudFileFailure: Equatable, Sendable {
    let domain: String
    let code: Int
    let message: String
    init(_ error: Error) {
        let value = error as NSError
        domain = value.domain; code = value.code
        message = "\(value.localizedDescription)（\(value.domain) / \(value.code)）"
    }
}

nonisolated struct CloudFileMetadata: Equatable, Sendable {
    var isUbiquitousItem: Bool?
    var downloadStatus: CloudFileDownloadStatus = .unknown
    var isDownloading: Bool?
    var isUploading: Bool?
    var isUploaded: Bool?
    var downloadRequested: Bool?
    var hasUnresolvedConflicts: Bool?
    var downloadingError: CloudFileFailure?
    var uploadingError: CloudFileFailure?
}

/// A selected entry's no-follow identity. Metadata is included to reject stale
/// destructive requests, not to infer a provider or read a file's body.
nonisolated struct CloudFileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let links: nlink_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    let flags: UInt32
    var isOrdinaryFile: Bool { mode & S_IFMT == S_IFREG && links == 1 }
    var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
    fileprivate init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode
        links = value.st_nlink; size = value.st_size; flags = value.st_flags
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
}

nonisolated struct CloudFileSnapshot: Equatable, Sendable {
    let url: URL
    let metadata: CloudFileMetadata?
    let identity: CloudFileIdentity?
    let failure: CloudFileFailure?

    var status: CloudFileStatus {
        if failure != nil { return .failed }
        guard let metadata, let ubiquitous = metadata.isUbiquitousItem else { return .unknown }
        guard ubiquitous else { return .unsupported }
        if metadata.downloadingError != nil || metadata.uploadingError != nil { return .failed }
        if metadata.hasUnresolvedConflicts == true { return .conflicted }
        if metadata.isUploading == true { return .uploading }
        if metadata.isDownloading == true { return .downloading }
        if metadata.downloadRequested == true { return .downloadRequested }
        switch metadata.downloadStatus {
        case .unknown: return .unknown
        case .notDownloaded: return .notDownloaded
        case .downloaded: return .downloaded
        case .current: return .current
        }
    }
    var statusTitle: String {
        switch status {
        case .unknown: return "云端状态未知"
        case .unsupported: return "未确认支持的 iCloud 项目"
        case .notDownloaded: return "仅云端，尚未下载"
        case .downloaded: return "存在本地副本，但版本已陈旧"
        case .current: return "本地副本为设备已知最新版本"
        case .downloadRequested: return "下载请求已提交，等待系统处理"
        case .downloading: return "正在下载"
        case .uploading: return "正在上传"
        case .conflicted: return "存在未解决的云端冲突"
        case .failed: return "无法确认云端状态"
        }
    }
    var canDownload: Bool { downloadUnavailableReason == nil }
    var canEvict: Bool { evictUnavailableReason == nil }
    var downloadUnavailableReason: String? {
        if let failure { return failure.message }
        guard let metadata, metadata.isUbiquitousItem == true else { return "尚未确认此项目由 iCloud 管理。" }
        guard identity?.isRegularFile == true else { return "尚未确认普通文件的身份，不能提交下载请求。" }
        guard metadata.downloadStatus == .notDownloaded || metadata.downloadStatus == .downloaded else {
            return metadata.downloadStatus == .current ? "本地副本已为设备已知最新版本。" : "下载状态未知。"
        }
        guard metadata.isDownloading == false, metadata.downloadRequested == false else { return "下载已在进行、已请求或状态未知。" }
        guard metadata.hasUnresolvedConflicts == false else { return "冲突状态未知或仍存在冲突。" }
        if let error = metadata.downloadingError ?? metadata.uploadingError { return error.message }
        return nil
    }
    var evictUnavailableReason: String? {
        if let failure { return failure.message }
        guard let metadata, metadata.isUbiquitousItem == true else { return "尚未确认此项目由 iCloud 管理。" }
        guard identity?.isOrdinaryFile == true else { return "仅允许释放单个普通文件的本地副本，不支持文件夹、链接或缺失项目。" }
        guard metadata.downloadStatus == .current else { return "本地副本必须已是设备已知最新版本。" }
        guard metadata.isUploaded == true else { return "尚未确认文件数据已上传到 iCloud。" }
        guard metadata.isUploading == false, metadata.isDownloading == false, metadata.downloadRequested == false else {
            return "上传、下载或请求状态不满足安全释放条件。"
        }
        guard metadata.hasUnresolvedConflicts == false else { return "冲突状态未知或仍存在冲突。" }
        if let error = metadata.downloadingError ?? metadata.uploadingError { return error.message }
        return nil
    }
}

nonisolated struct CloudFileRequestReceipt: Equatable, Sendable {
    let action: CloudFileAction
    let url: URL
    var message: String {
        switch action {
        case .download: return "下载请求已提交；是否完成需要刷新状态确认。"
        case .evict: return "释放请求已提交；是否完成需要刷新状态确认。"
        }
    }
}

/// All operations are synchronous provider boundaries invoked on a detached worker.
/// Injection permits tests to avoid the user's account and real provider entirely.
nonisolated struct CloudFileAdapter: Sendable {
    let readMetadata: @Sendable (URL) throws -> CloudFileMetadata
    let startDownloading: @Sendable (URL) throws -> Void
    let evict: @Sendable (URL) throws -> Void

    static let foundation = CloudFileAdapter(
        readMetadata: { input in
            var url = input
            // URL caches must not satisfy a destructive request's state recheck.
            url.removeAllCachedResourceValues()
            let keys: Set<URLResourceKey> = [
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemIsDownloadingKey, .ubiquitousItemIsUploadingKey,
                .ubiquitousItemIsUploadedKey, .ubiquitousItemDownloadRequestedKey,
                .ubiquitousItemHasUnresolvedConflictsKey,
                .ubiquitousItemDownloadingErrorKey, .ubiquitousItemUploadingErrorKey
            ]
            let values = try url.resourceValues(forKeys: keys)
            let state: CloudFileDownloadStatus
            switch values.ubiquitousItemDownloadingStatus {
            case .notDownloaded: state = .notDownloaded
            case .downloaded: state = .downloaded
            case .current: state = .current
            default: state = .unknown
            }
            return CloudFileMetadata(
                isUbiquitousItem: values.isUbiquitousItem, downloadStatus: state,
                isDownloading: values.ubiquitousItemIsDownloading, isUploading: values.ubiquitousItemIsUploading,
                isUploaded: values.ubiquitousItemIsUploaded, downloadRequested: values.ubiquitousItemDownloadRequested,
                hasUnresolvedConflicts: values.ubiquitousItemHasUnresolvedConflicts,
                downloadingError: values.ubiquitousItemDownloadingError.map(CloudFileFailure.init),
                uploadingError: values.ubiquitousItemUploadingError.map(CloudFileFailure.init)
            )
        },
        startDownloading: { try FileManager.default.startDownloadingUbiquitousItem(at: $0) },
        evict: { try FileManager.default.evictUbiquitousItem(at: $0) }
    )
}

nonisolated enum CloudFileServiceError: LocalizedError, Sendable {
    case invalidURL
    case unsupportedEntry
    case staleSnapshot
    case unavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "云端操作需要指向本机文件系统的文件 URL。"
        case .unsupportedEntry: return "云端操作不支持符号链接或特殊文件。"
        case .staleSnapshot: return "文件身份或云端状态已发生变化，请刷新后重试。"
        case .unavailable(let reason): return reason
        }
    }
}

nonisolated struct CloudFileService: Sendable {
    let adapter: CloudFileAdapter
    init(adapter: CloudFileAdapter = .foundation) { self.adapter = adapter }

    /// Reads only caller-selected URLs. No enumeration, contents, thumbnails,
    /// account lookup, container lookup, FileProvider domains or token access.
    func inspect(_ urls: [URL]) async throws -> [CloudFileSnapshot] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .background) {
            var snapshots: [CloudFileSnapshot] = []
            for url in urls {
                try Task.checkCancellation()
                do { snapshots.append(try readSnapshot(url)) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    snapshots.append(CloudFileSnapshot(url: url, metadata: nil, identity: nil, failure: CloudFileFailure(error)))
                }
            }
            try Task.checkCancellation()
            return snapshots
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    func request(_ action: CloudFileAction, for snapshot: CloudFileSnapshot) async throws -> CloudFileRequestReceipt {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .background) {
            try Task.checkCancellation()
            let refreshed = try readSnapshot(snapshot.url)
            guard refreshed == snapshot else { throw CloudFileServiceError.staleSnapshot }
            let reason = action == .download ? refreshed.downloadUnavailableReason : refreshed.evictUnavailableReason
            if let reason { throw CloudFileServiceError.unavailable(reason) }
            // Recheck after the metadata reader as well as immediately before the
            // Foundation path-based API. A concurrent provider may still change
            // state after this boundary; it remains responsible for the operation.
            guard try Self.identity(at: refreshed.url) == refreshed.identity else { throw CloudFileServiceError.staleSnapshot }
            try Task.checkCancellation()
            switch action {
            case .download: try adapter.startDownloading(refreshed.url)
            case .evict: try adapter.evict(refreshed.url)
            }
            // Never check cancellation after submission: a completed API call is
            // not undone by cancellation, and it does not prove provider completion.
            return CloudFileRequestReceipt(action: action, url: refreshed.url)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private func readSnapshot(_ input: URL) throws -> CloudFileSnapshot {
        try Task.checkCancellation()
        guard input.isFileURL, input.host == nil || input.host == "" || input.host == "localhost",
              input.path != "/", !input.path.contains("\0"), !input.absoluteString.contains("%00") else {
            throw CloudFileServiceError.invalidURL
        }
        let url = input.standardizedFileURL
        let before = try Self.identity(at: url)
        if let before, !before.isRegularFile, before.mode & S_IFMT != S_IFDIR { throw CloudFileServiceError.unsupportedEntry }
        let metadata = try adapter.readMetadata(url)
        try Task.checkCancellation()
        guard try Self.identity(at: url) == before else { throw CloudFileServiceError.staleSnapshot }
        return CloudFileSnapshot(url: url, metadata: metadata, identity: before, failure: nil)
    }

    private static func identity(at url: URL) throws -> CloudFileIdentity? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return CloudFileIdentity(info) }
        let code = errno
        if code == ENOENT { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
