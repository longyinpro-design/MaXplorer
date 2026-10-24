import Foundation

nonisolated struct TransferPlanService {
    static func shouldShowPlan(for sources: [URL]) -> Bool {
        guard let firstSource = sources.first else { return false }
        if sources.count >= 20 {
            return true
        }

        var info = stat()
        guard stat(firstSource.path, &info) == 0 else {
            return true
        }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            return true
        }
        return info.st_size >= 1_000_000_000
    }

    static func makePlan(
        sources: [URL],
        destinationDirectory: URL,
        operation: CopyQueueOperation
    ) async throws -> TransferPlan {
        let conflictCount = conflictCount(
            sources: sources,
            destinationDirectory: destinationDirectory
        )

        var totalBytes: Int64 = 0
        var unreadableCount = 0
        for source in sources {
            try Task.checkCancellation()
            let values = try? source.resourceValues(forKeys: [
                .isDirectoryKey,
                .fileSizeKey,
                .isReadableKey
            ])
            if values?.isReadable == false {
                unreadableCount += 1
            }

            if values?.isDirectory == true {
                totalBytes += try await SafeFileOperations.totalByteCount(for: source)
            } else {
                totalBytes += Int64(values?.fileSize ?? 0)
            }
        }

        let freeBytes = VolumeCapacityReader.stats(for: destinationDirectory)
            .map { Int64(min($0.free, UInt64(Int64.max))) }
        let destinationWritable = FileManager.default.isWritableFile(atPath: destinationDirectory.path)
        let isNetworkDestination = (try? destinationDirectory.resourceValues(
            forKeys: [.volumeIsLocalKey]
        ).volumeIsLocal) == false

        var requiresAdditionalSpace = operation == .copy
        if operation == .move {
            let destinationDevice = deviceID(for: destinationDirectory)
            for source in sources {
                try Task.checkCancellation()
                guard let destinationDevice,
                      let sourceDevice = deviceID(for: source.deletingLastPathComponent()) else {
                    requiresAdditionalSpace = true
                    break
                }
                if sourceDevice != destinationDevice {
                    requiresAdditionalSpace = true
                    break
                }
            }
        }

        return TransferPlan(
            sources: sources,
            destinationDirectory: destinationDirectory,
            operation: operation,
            itemCount: sources.count,
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            requiredBytes: requiresAdditionalSpace ? totalBytes : 0,
            conflictCount: conflictCount,
            unreadableCount: unreadableCount,
            destinationWritable: destinationWritable,
            isNetworkDestination: isNetworkDestination,
            errorMessage: nil
        )
    }

    private static func conflictCount(sources: [URL], destinationDirectory: URL) -> Int {
        sources.reduce(into: 0) { count, source in
            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            if SafeFileOperations.entryExists(at: destination) {
                count += 1
            }
        }
    }

    private static func deviceID(for url: URL) -> dev_t? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return info.st_dev
    }
}
