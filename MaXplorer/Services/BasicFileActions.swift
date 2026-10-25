import Darwin
import Foundation

/// Filesystem work for basic actions. Call from a background task, never the UI actor.
nonisolated enum BasicFileActions {
    static func createEmptyFile(named name: String, in directory: URL) throws -> URL {
        try Task.checkCancellation()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard directory.isFileURL, !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0") else {
            throw FileSystemError.invalidName
        }
        let target = directory.appendingPathComponent(name)
        let descriptor = target.withUnsafeFileSystemRepresentation { path in
            guard let path else { errno = EINVAL; return Int32(-1) }
            return Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o666))
        }
        guard descriptor >= 0 else { throw posixError(errno, at: target) }
        guard Darwin.close(descriptor) == 0 else { throw posixError(errno, at: target) }
        return target
    }

    static func duplicateDestinations(
        for items: [FileItem],
        reserved: Set<URL> = []
    ) throws -> [(source: URL, destination: URL)] {
        try Task.checkCancellation()
        var occupied = Set(reserved.map(reservationKey))
        var result: [(source: URL, destination: URL)] = []
        for item in items {
            try Task.checkCancellation()
            let source = item.url
            guard source.isFileURL, !item.isNetworkLocation else { throw FileSystemError.invalidName }
            let directory = source.deletingLastPathComponent()
            guard access(directory.path, W_OK | X_OK) == 0 else { throw posixError(errno, at: directory) }
            let extensionPart = item.isDirectory ? "" : source.pathExtension
            let baseName = extensionPart.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
            let suffix = extensionPart.isEmpty ? "" : ".\(extensionPart)"
            var attempt = 1
            while true {
                try Task.checkCancellation()
                let copySuffix = attempt == 1 ? " copy" : " copy \(attempt)"
                let candidate = directory.appendingPathComponent(baseName + copySuffix + suffix)
                let key = reservationKey(candidate)
                if !occupied.contains(key) {
                    var info = stat()
                    if lstat(candidate.path, &info) != 0 {
                        // An unreadable parent or an overlong name is not a collision.
                        guard errno == ENOENT else { throw posixError(errno, at: candidate) }
                        occupied.insert(key)
                        result.append((source: source, destination: candidate))
                        break
                    }
                }
                attempt += 1
            }
        }
        return result
    }

    static func fileInfo(for item: FileItem) async throws -> FileInfo {
        try Task.checkCancellation()
        let fresh = try await LocalFileSystemService().fileItem(
            at: item.url,
            options: DirectoryListingOptions(includeOwner: true, includeDateTaken: true, includeTags: true)
        )
        try Task.checkCancellation()
        let attributes = try FileManager.default.attributesOfItem(atPath: item.url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber).map { String(format: "%03o", $0.intValue) }
        return FileInfo(
            name: fresh.name,
            path: fresh.url.path,
            kind: fresh.displayKind,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? fresh.size,
            createdAt: attributes[.creationDate] as? Date ?? fresh.createdAt,
            modifiedAt: attributes[.modificationDate] as? Date ?? fresh.modifiedAt,
            owner: attributes[.ownerAccountName] as? String,
            group: attributes[.groupOwnerAccountName] as? String,
            permissions: permissions,
            tagNames: FinderTagReader.tagNames(for: fresh.url),
            isDirectory: fresh.isDirectory,
            dateTaken: fresh.dateTaken
        )
    }

    private static func posixError(_ code: Int32, at url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }

    private static func reservationKey(_ url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
            .standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
