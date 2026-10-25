import Foundation
import Darwin

nonisolated struct TransferPlanService {
    static func shouldShowPlan(for sources: [URL]) -> Bool {
        if sources.count >= 20 { return true }
        var totalBytes: Int64 = 0
        for source in sources {
            var info = stat()
            guard lstat(source.path, &info) == 0 else { return true }
            if (info.st_mode & S_IFMT) == S_IFDIR { return true }
            let (sum, overflow) = totalBytes.addingReportingOverflow(max(0, info.st_size))
            if overflow || sum >= 1_000_000_000 { return true }
            totalBytes = sum
        }
        return false
    }

    static func makePlan(
        sources: [URL],
        destinationDirectory: URL,
        operation: CopyQueueOperation,
        capacity: @Sendable (URL) -> Int64? = { availableBytes($0) },
        progress: @Sendable (Int, Int64) -> Void = { _, _ in }
    ) async throws -> TransferPlan {
        try Task.checkCancellation()
        guard destinationDirectory.isFileURL, sources.allSatisfy({ $0.isFileURL && $0.path != "/" }) else {
            throw POSIXError(.EINVAL)
        }
        var destinationInfo = stat()
        guard stat(destinationDirectory.path, &destinationInfo) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard (destinationInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw POSIXError(.ENOTDIR)
        }

        var totalBytes: Int64 = 0
        var requiredBytes: Int64 = 0
        var unreadableCount = 0
        var conflictCount = 0
        var scannedCount = 0
        for source in sources {
            try Task.checkCancellation()
            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            let conflicts = SafeFileOperations.entryExists(at: destination)
            if conflicts { conflictCount += 1 }
            var sourceInfo = stat()
            guard lstat(source.path, &sourceInfo) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // SafeFileOperations can rename a same-volume move directly only
            // when there is no destination. Overwrites always stage a full copy.
            let needsStaging = operation == .copy || conflicts || sourceInfo.st_dev != destinationInfo.st_dev
            // Enumerate lazily: a huge directory should not first allocate an
            // array containing every descendant before cancellation can run.
            var scanErrors = 0
            let enumerator = (sourceInfo.st_mode & S_IFMT) == S_IFDIR
                && access(source.path, R_OK | X_OK) == 0
                ? FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil,
                                                options: [], errorHandler: { _, _ in
                    scanErrors += 1
                    return !Task.isCancelled
                }) : nil
            var next: URL? = source
            while let entry = next {
                try Task.checkCancellation()
                var info = stat()
                guard lstat(entry.path, &info) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let kind = info.st_mode & S_IFMT
                scannedCount += 1
                if kind == S_IFREG {
                    totalBytes = try adding(max(0, info.st_size), to: totalBytes)
                    if needsStaging { requiredBytes = try adding(max(0, info.st_size), to: requiredBytes) }
                    if access(entry.path, R_OK) != 0 { unreadableCount += 1 }
                } else if kind == S_IFDIR {
                    if access(entry.path, R_OK | X_OK) != 0 {
                        unreadableCount += 1
                        enumerator?.skipDescendants()
                    }
                } else if kind != S_IFLNK {
                    throw POSIXError(.ENOTSUP)
                }
                if scannedCount == 1 || scannedCount.isMultiple(of: 128) {
                    progress(scannedCount, totalBytes)
                }
                try Task.checkCancellation()
                next = enumerator?.nextObject() as? URL
            }
            // Do not treat unreadable descendants as empty directories.
            unreadableCount += scanErrors
        }
        try Task.checkCancellation()
        progress(scannedCount, totalBytes)
        try Task.checkCancellation()
        let freeBytes = capacity(destinationDirectory).flatMap { $0 >= 0 ? $0 : nil }
        let destinationWritable = FileManager.default.isWritableFile(atPath: destinationDirectory.path)
        let isNetworkDestination = (try? destinationDirectory.resourceValues(
            forKeys: [.volumeIsLocalKey]
        ).volumeIsLocal) == false

        return TransferPlan(
            sources: sources,
            destinationDirectory: destinationDirectory,
            operation: operation,
            itemCount: sources.count,
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            requiredBytes: requiredBytes,
            conflictCount: conflictCount,
            unreadableCount: unreadableCount,
            destinationWritable: destinationWritable,
            isNetworkDestination: isNetworkDestination,
            errorMessage: unreadableCount > 0 ? "部分源项目不可读取，无法完成传输预检。请检查权限后重试。" : nil
        )
    }

    private static func availableBytes(_ url: URL) -> Int64? {
        VolumeCapacityReader.stats(for: url).map { Int64(min($0.free, UInt64(Int64.max))) }
    }

    private static func adding(_ bytes: Int64, to total: Int64) throws -> Int64 {
        let (sum, overflow) = total.addingReportingOverflow(bytes)
        guard !overflow else { throw POSIXError(.EOVERFLOW) }
        return sum
    }
}
