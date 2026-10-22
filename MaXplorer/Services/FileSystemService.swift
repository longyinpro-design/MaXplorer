import Foundation
import ImageIO
import UniformTypeIdentifiers

struct VolumeCapacityStats: Equatable, Sendable {
    let used: UInt64
    let free: UInt64
    let total: UInt64
}

/// Reads capacity consistently for local and network-backed file URLs.
/// Network file systems do not always populate the "important usage" key, so
/// prefer the general available-capacity value and retain filesystem attributes
/// as a fallback.
nonisolated enum VolumeCapacityReader {
    static func stats(for url: URL) -> VolumeCapacityStats? {
        guard url.isFileURL else { return nil }

        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ])
        let fileSystemAttributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        let total = values?.volumeTotalCapacity
            ?? (fileSystemAttributes?[.systemSize] as? NSNumber)?.intValue
        let free = values?.volumeAvailableCapacity
            ?? values?.volumeAvailableCapacityForImportantUsage.map(Int.init)
            ?? (fileSystemAttributes?[.systemFreeSize] as? NSNumber)?.intValue

        guard let total, total > 0, let free, free >= 0 else { return nil }
        let totalBytes = UInt64(total)
        let freeBytes = min(UInt64(free), totalBytes)
        return VolumeCapacityStats(
            used: totalBytes - freeBytes,
            free: freeBytes,
            total: totalBytes
        )
    }
}

/// Controls whether the (potentially slow) per-file metadata is fetched during
/// a listing. Owner resolution and image capture-date reads are only worth
/// paying for when their columns are visible, so they default to off. Finder
/// tag colors cost one extended-attribute read per item, which is cheap locally
/// but a round trip on network volumes, so they are opt-in as well.
struct DirectoryListingOptions: Equatable, Sendable {
    var includeOwner: Bool
    var includeDateTaken: Bool
    var includeTags: Bool

    init(includeOwner: Bool = false, includeDateTaken: Bool = false, includeTags: Bool = false) {
        self.includeOwner = includeOwner
        self.includeDateTaken = includeDateTaken
        self.includeTags = includeTags
    }
}
protocol FileSystemService: Sendable {
    func listDirectory(at url: URL, showHiddenFiles: Bool, options: DirectoryListingOptions) async throws -> [FileItem]
    func fileItem(at url: URL, options: DirectoryListingOptions) async throws -> FileItem
    func createFolder(named name: String, in directory: URL) async throws -> URL
    func renameItem(at url: URL, to newName: String) async throws -> URL
    func moveItems(_ resolvedItems: [(source: URL, shouldOverwrite: Bool)], to directory: URL) async throws -> [URL]
    func moveToTrash(_ url: URL) async throws
    func deletePermanently(_ url: URL) async throws
    func quickViewContent(for url: URL) async throws -> QuickViewContent
}

extension FileSystemService {
    func moveItems(_ urls: [URL], to directory: URL) async throws -> [URL] {
        try await moveItems(urls.map { ($0, false) }, to: directory)
    }
}

struct LocalFileSystemService: FileSystemService {
    private let keys: [URLResourceKey] = [
        .contentModificationDateKey,
        .creationDateKey,
        .fileSizeKey,
        .isAliasFileKey,
        .isDirectoryKey,
        .isHiddenKey,
        .isPackageKey,
        .localizedTypeDescriptionKey
    ]

    func listDirectory(at url: URL, showHiddenFiles: Bool, options: DirectoryListingOptions) async throws -> [FileItem] {
        try await Task.detached(priority: .userInitiated) {
            let enumerationOptions: FileManager.DirectoryEnumerationOptions = showHiddenFiles ? [] : [.skipsHiddenFiles]
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: enumerationOptions
            )

            // Build items off the main actor with bounded concurrency. FileItem
            // construction is nonisolated, so no per-file hop to the main actor,
            // and at most `maxConcurrency` file-metadata reads run at once to
            // avoid thread explosion on large folders.
            let resourceKeys = keys
            let maxConcurrency = 6
            var items: [FileItem] = []
            items.reserveCapacity(urls.count)

            try await withThrowingTaskGroup(of: FileItem.self) { group in
                var nextIndex = 0
                let primeCount = min(maxConcurrency, urls.count)
                while nextIndex < primeCount {
                    let itemURL = urls[nextIndex]
                    group.addTask { try Self.makeFileItem(for: itemURL, resourceKeys: resourceKeys, options: options) }
                    nextIndex += 1
                }

                while let item = try await group.next() {
                    items.append(item)
                    if nextIndex < urls.count {
                        let itemURL = urls[nextIndex]
                        group.addTask { try Self.makeFileItem(for: itemURL, resourceKeys: resourceKeys, options: options) }
                        nextIndex += 1
                    }
                }
            }

            // Display order is applied by the browser (FileSorter), so the
            // listing is returned unsorted rather than sorting it twice.
            return items
        }.value
    }

    func fileItem(at url: URL, options: DirectoryListingOptions) async throws -> FileItem {
        let resourceKeys = keys
        return try await Task.detached(priority: .userInitiated) {
            try Self.makeFileItem(for: url, resourceKeys: resourceKeys, options: options)
        }.value
    }

    func createFolder(named name: String, in directory: URL) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let target = try uniqueURL(forFolderNamed: name, in: directory)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            return target
        }.value
    }

    func renameItem(at url: URL, to newName: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                throw FileSystemError.invalidName
            }

            let destination = url.deletingLastPathComponent().appendingPathComponent(trimmedName)
            guard destination != url else {
                return url
            }

            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw FileSystemError.itemAlreadyExists(trimmedName)
            }

            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }.value
    }

    func moveItems(_ resolvedItems: [(source: URL, shouldOverwrite: Bool)], to directory: URL) async throws -> [URL] {
        let destinationDirectory = directory.standardizedFileURL
        var moved: [URL] = []
        for (url, shouldOverwrite) in resolvedItems {
            let source = url.standardizedFileURL
            guard source.deletingLastPathComponent() != destinationDirectory else { continue }
            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            try await SafeFileOperations.perform(.move, sourceURL: source,
                destinationURL: destination, overwrite: shouldOverwrite) { _ in }
            moved.append(destination)
        }
        return moved
    }

    func moveToTrash(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
        }.value
    }

    func deletePermanently(_ url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.removeItem(at: url)
        }.value
    }

    func quickViewContent(for url: URL) async throws -> QuickViewContent {
        try await Task.detached(priority: .userInitiated) {
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isReadableKey,
                .localizedTypeDescriptionKey, .contentTypeKey
            ])
            guard values.isRegularFile == true, values.isDirectory != true, values.isPackage != true else {
                throw FileSystemError.previewUnavailable("Quick View is available for regular files, not folders or packages.")
            }
            guard values.isReadable == true else {
                throw FileSystemError.previewUnavailable("This file cannot be read. Check its permissions and try again.")
            }

            // Quick Look receives the original file. Never reinterpret document/image bytes
            // as text, or strip bytes from a text encoding we do not recognize.
            let typeDescription = values.localizedTypeDescription ?? "File"
            let size = ByteCountFormatter.string(fromByteCount: Int64(values.fileSize ?? 0), countStyle: .file)
            return QuickViewContent(
                url: url,
                title: url.lastPathComponent,
                detail: "\(typeDescription) • \(size)",
                allowsTextEncoding: values.contentType?.conforms(to: .plainText) == true
                    || values.contentType?.conforms(to: .sourceCode) == true
            )
        }.value
    }

    /// Fully off-main builder for a single directory entry.
    nonisolated private static func makeFileItem(for itemURL: URL, resourceKeys: [URLResourceKey], options: DirectoryListingOptions) throws -> FileItem {
        let values = try itemURL.resourceValues(forKeys: Set(resourceKeys))
        let isDirectory = values.isDirectory ?? false

        var aliasTargetURL: URL?
        if values.isAliasFile == true {
            aliasTargetURL = Self.aliasTargetURL(for: itemURL)
        }

        let aliasTargetValues = aliasTargetURL.flatMap(Self.fileTypeValues)
        // Owner resolution (uid → name via Directory Services) is slow, so only
        // pay for it when the Owner column is shown.
        let owner = options.includeOwner
            ? (try? FileManager.default.attributesOfItem(atPath: itemURL.path))?[.ownerAccountName] as? String
            : nil
        let dateTaken = options.includeDateTaken ? Self.captureDate(for: itemURL) : nil
        let tagColors = options.includeTags ? FinderTagReader.tagColors(for: itemURL) : []

        return FileItem(
            url: itemURL,
            name: itemURL.lastPathComponent,
            typeDescription: values.localizedTypeDescription ?? "",
            isDirectory: isDirectory,
            isPackage: values.isPackage ?? false,
            isAlias: values.isAliasFile ?? false,
            aliasTargetURL: aliasTargetURL,
            isAliasTargetDirectory: aliasTargetValues?.isDirectory ?? false,
            isAliasTargetPackage: aliasTargetValues?.isPackage ?? false,
            isHidden: values.isHidden ?? false,
            size: values.fileSize.map(Int64.init),
            modifiedAt: values.contentModificationDate,
            createdAt: values.creationDate,
            dateTaken: dateTaken,
            owner: owner,
            tagColors: tagColors
        )
    }

    nonisolated private static func aliasTargetURL(for url: URL) -> URL? {
        try? URL(resolvingAliasFileAt: url, options: [.withoutUI]).standardizedFileURL
    }

    nonisolated private static func fileTypeValues(for url: URL) -> URLResourceValues? {
        try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
    }

    nonisolated private static let captureDateExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "tiff", "tif", "png", "gif",
        "dng", "cr2", "cr3", "nef", "arw", "raf", "rw2", "orf"
    ]

    /// Best-effort "Date Taken" for image files, read from EXIF/TIFF metadata
    /// without decoding the full image. Returns nil for non-image files.
    nonisolated private static func captureDate(for url: URL) -> Date? {
        guard captureDateExtensions.contains(url.pathExtension.lowercased()) else {
            return nil
        }

        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return nil
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
               ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String),
           let date = parseExifDate(raw) {
            return date
        }

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let raw = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = parseExifDate(raw) {
            return date
        }

        return nil
    }

    /// Parses the EXIF `yyyy:MM:dd HH:mm:ss` format without a shared
    /// (non-thread-safe) DateFormatter, since listing runs concurrently.
    nonisolated private static func parseExifDate(_ string: String) -> Date? {
        let components = string.split { $0 == ":" || $0 == " " }.compactMap { Int($0) }
        guard components.count >= 6 else {
            return nil
        }

        var dateComponents = DateComponents()
        dateComponents.year = components[0]
        dateComponents.month = components[1]
        dateComponents.day = components[2]
        dateComponents.hour = components[3]
        dateComponents.minute = components[4]
        dateComponents.second = components[5]

        return Calendar.current.date(from: dateComponents)
    }


}

enum FileSystemError: LocalizedError {
    case invalidName
    case itemAlreadyExists(String)
    case previewUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Enter a valid name."
        case .itemAlreadyExists(let name):
            return "An item named \"\(name)\" already exists."
        case .previewUnavailable(let message):
            return message
        }
    }
}

nonisolated private func uniqueURL(forFolderNamed name: String, in directory: URL) throws -> URL {
    var candidate = directory.appendingPathComponent(name)
    var suffix = 2

    while FileManager.default.fileExists(atPath: candidate.path) {
        candidate = directory.appendingPathComponent("\(name) \(suffix)")
        suffix += 1
    }

    return candidate
}
