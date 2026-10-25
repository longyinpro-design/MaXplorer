import Foundation
import Darwin

nonisolated struct ArchiveReadLimits: Equatable, Sendable {
    var maxEntries: Int = 100_000
    var maxEntryBytes: Int64 = 2 * 1024 * 1024 * 1024
    var maxTotalBytes: Int64 = 4 * 1024 * 1024 * 1024
    var maxPathBytes: Int = 4096
    var maxDepth: Int = 128
    static let `default` = ArchiveReadLimits()
}

nonisolated struct ArchiveCatalogEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable { case file, directory, unsupported }
    let id: String
    let path: String
    let kind: Kind
    let size: Int64?
    let modifiedAt: Date?
    var isExtractable: Bool { kind != .unsupported }
    let ordinal: Int?
}

nonisolated struct ArchiveCatalog: Equatable, Sendable {
    let archiveURL: URL
    let formatName: String
    let entries: [ArchiveCatalogEntry]
    // Only filesystem identity and parsed header metadata, never a password or file payload.
    let identity: ArchiveSourceIdentity
    let headers: [ArchiveCatalogHeader]
}

nonisolated struct ArchiveSourceIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }
}

nonisolated struct ArchiveCatalogHeader: Equatable, Sendable {
    let entry: ArchiveCatalogEntry
    let rawPath: String
    let fileType: mode_t
    let symlink: String?
    let hardlink: String?
    let mtimeSeconds: Int?
    let mtimeNanos: Int?
}

nonisolated enum ArchiveCatalogError: LocalizedError {
    case invalidSource(String)
    case changedSource
    case unsafePath(String)
    case invalidCatalog(String)
    case limitExceeded(String)
    case backend(String)
    case encrypted
    case unsupportedEntry(String)
    case cleanup(String)

    var errorDescription: String? {
        switch self {
        case .invalidSource(let path): return "压缩包必须是可读取的普通文件：\(path)"
        case .changedSource: return "压缩包在读取后发生变化，请重新打开。"
        case .unsafePath(let path): return "压缩包包含不安全的路径：\(path)"
        case .invalidCatalog(let message): return "压缩包目录无效：\(message)"
        case .limitExceeded(let message): return "压缩包超过读取限制：\(message)"
        case .backend(let message): return "无法读取压缩包（格式、编码或数据不受支持或已损坏）：\(message)"
        case .encrypted: return "此压缩包已加密，当前无法读取加密内容。"
        case .unsupportedEntry(let path): return "无法提取链接或特殊文件：\(path)"
        case .cleanup(let message): return "解压失败，且无法完整清理临时目录：\(message)"
        }
    }
}
