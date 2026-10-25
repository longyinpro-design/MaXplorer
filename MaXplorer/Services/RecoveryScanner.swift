import Darwin
import Foundation

/// The directory entry itself, never the target of a symbolic link.
nonisolated fileprivate struct RecoveryIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let kind: mode_t
    let birthSeconds: Int
    let birthNanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        kind = info.st_mode & S_IFMT
        birthSeconds = info.st_birthtimespec.tv_sec
        birthNanoseconds = info.st_birthtimespec.tv_nsec
    }

    static func read(at url: URL) throws -> RecoveryIdentity {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        return RecoveryIdentity(info)
    }
}

nonisolated struct RecoveryResidue: Identifiable, Equatable, Sendable {
    let url: URL
    fileprivate let identity: RecoveryIdentity

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

nonisolated enum RecoveryScanner {
    private static let prefixes = [
        ".maxplorer-transfer-",
        ".maxplorer-backup-",
        ".maxplorer-probe-"
    ]

    static func scan(in directories: [URL]) -> [RecoveryResidue] {
        var seen = Set<URL>()
        var residues: [RecoveryResidue] = []

        for directory in directories {
            guard directory.isFileURL else { continue }
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            for entry in entries {
                let name = entry.lastPathComponent
                guard prefixes.contains(where: { name.hasPrefix($0) }) else { continue }
                let standardized = entry.standardizedFileURL
                guard let identity = try? RecoveryIdentity.read(at: standardized) else { continue }
                if seen.insert(standardized).inserted {
                    residues.append(RecoveryResidue(url: standardized, identity: identity))
                }
            }
        }

        return residues.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    // Identity checks reject stale scan results. They do not make recursive cleanup
    // atomic against another process concurrently replacing entries in the tree.
    static func remove(_ residue: RecoveryResidue) throws {
        try requireIdentity(residue.identity, at: residue.url)
        if residue.identity.kind == S_IFDIR {
            try makeWritable(residue.url, identity: residue.identity)
        }
        // Cleanup preparation may take time. Refuse a replacement before removal too.
        try requireIdentity(residue.identity, at: residue.url)
        try FileManager.default.removeItem(at: residue.url)
    }

    static func remove(at url: URL) throws {
        try remove(RecoveryResidue(url: url, identity: RecoveryIdentity.read(at: url)))
    }

    private static func requireIdentity(_ identity: RecoveryIdentity, at url: URL) throws {
        guard try RecoveryIdentity.read(at: url) == identity else {
            throw changedItemError(at: url)
        }
    }

    private static func changedItemError(at url: URL) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
            NSFilePathErrorKey: url.path,
            NSLocalizedDescriptionKey: "恢复项目在扫描后发生变化。请重新扫描后再清理。"
        ])
    }

    private static func makeWritable(_ url: URL, identity: RecoveryIdentity) throws {
        guard identity.kind == S_IFDIR else { return }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        guard RecoveryIdentity(info) == identity else {
            throw changedItemError(at: url)
        }
        // lchmod changes the entry itself if a symbolic link is substituted. It never
        // changes that link's target, and also works for mode-000 residue directories.
        guard lchmod(url.path, info.st_mode | 0o700) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
        }
        try requireIdentity(identity, at: url)
        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []) {
            let childIdentity = try RecoveryIdentity.read(at: child)
            try makeWritable(child, identity: childIdentity)
        }
        try requireIdentity(identity, at: url)
    }
}
