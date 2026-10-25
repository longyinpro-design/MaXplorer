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
        var occupied = try reservationKeys(reserved)
        var canonicalParents: [URL: URL] = [:]
        var scannedParents = Set<URL>()
        var result: [(source: URL, destination: URL)] = []
        for item in items {
            try Task.checkCancellation()
            guard item.url.isFileURL, !item.isNetworkLocation else { throw FileSystemError.invalidName }
            let directory = item.url.deletingLastPathComponent()
            let canonicalDirectory: URL
            if let cached = canonicalParents[directory] {
                canonicalDirectory = cached
            } else {
                canonicalDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
                canonicalParents[directory] = canonicalDirectory
            }
            if scannedParents.insert(canonicalDirectory).inserted {
                try readOccupiedNames(in: directory, canonicalDirectory: canonicalDirectory, occupied: &occupied)
            }
            let destination = try allocateDestination(
                for: item.url, isDirectory: item.isDirectory, in: directory,
                canonicalDirectory: canonicalDirectory, occupied: &occupied
            )
            result.append((source: item.url, destination: destination))
        }
        return result
    }

    /// Plans a name without creating it. Call off the UI actor; publication must remain exclusive.
    /// Files insert " copy" before the final extension (archive.tar.gz -> archive.tar copy.gz).
    /// Directories, including packages such as Example.app, append it to their complete name.
    static func keepBothDestination(
        for source: URL,
        isDirectory: Bool,
        in destinationDirectory: URL,
        reserved: Set<URL>
    ) throws -> URL {
        try Task.checkCancellation()
        guard source.isFileURL, destinationDirectory.isFileURL,
              !source.lastPathComponent.isEmpty, source.lastPathComponent != "/" else {
            throw FileSystemError.invalidName
        }
        guard access(destinationDirectory.path, W_OK | X_OK) == 0 else {
            throw posixError(errno, at: destinationDirectory)
        }
        let canonicalDirectory = destinationDirectory.resolvingSymlinksInPath().standardizedFileURL
        var occupied = try reservationKeys(reserved)
        try readOccupiedNames(in: destinationDirectory, canonicalDirectory: canonicalDirectory, occupied: &occupied)
        return try allocateDestination(
            for: source, isDirectory: isDirectory, in: destinationDirectory,
            canonicalDirectory: canonicalDirectory, occupied: &occupied
        )
    }

    private static func reservationKeys(_ reserved: Set<URL>) throws -> Set<String> {
        var occupied = Set<String>()
        for url in reserved {
            try Task.checkCancellation()
            occupied.insert(destinationReservationKey(for: url))
        }
        return occupied
    }

    private static func destinationKey(_ name: String, in canonicalDirectory: URL) -> String {
        canonicalDirectory.appendingPathComponent(name).path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func readOccupiedNames(
        in destinationDirectory: URL, canonicalDirectory: URL, occupied: inout Set<String>
    ) throws {
        try Task.checkCancellation()
        guard access(destinationDirectory.path, W_OK | X_OK) == 0 else {
            throw posixError(errno, at: destinationDirectory)
        }
        // Reading one level also catches case/NFC aliases on case-sensitive volumes.
        guard let stream = opendir(destinationDirectory.path) else {
            throw posixError(errno, at: destinationDirectory)
        }
        defer { closedir(stream) }
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw posixError(errno, at: destinationDirectory) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            occupied.insert(destinationKey(name, in: canonicalDirectory))
        }
    }

    private static func allocateDestination(
        for source: URL, isDirectory: Bool, in destinationDirectory: URL,
        canonicalDirectory: URL, occupied: inout Set<String>
    ) throws -> URL {
        try Task.checkCancellation()
        guard source.isFileURL, !source.lastPathComponent.isEmpty, source.lastPathComponent != "/" else {
            throw FileSystemError.invalidName
        }
        guard access(destinationDirectory.path, W_OK | X_OK) == 0 else {
            throw posixError(errno, at: destinationDirectory)
        }
        let extensionPart = isDirectory ? "" : source.pathExtension
        let baseName = extensionPart.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
        let suffix = extensionPart.isEmpty ? "" : ".\(extensionPart)"
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let copySuffix = attempt == 1 ? " copy" : " copy \(attempt)"
            let candidate = destinationDirectory.appendingPathComponent(baseName + copySuffix + suffix)
            var info = stat()
            let exists = lstat(candidate.path, &info) == 0
            if !exists {
                let code = errno
                guard code == ENOENT else { throw posixError(code, at: candidate) }
                let key = destinationKey(candidate.lastPathComponent, in: canonicalDirectory)
                if occupied.insert(key).inserted { return candidate }
            }
            let next = attempt.addingReportingOverflow(1)
            guard !next.overflow else { throw posixError(EOVERFLOW, at: destinationDirectory) }
            attempt = next.partialValue
        }
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

    static func destinationReservationKey(for url: URL) -> String {
        url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
            .standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
}
