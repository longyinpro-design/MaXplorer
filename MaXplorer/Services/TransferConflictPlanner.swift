import Foundation
import Darwin

/// All path canonicalization, existence checks and naming happen off the UI actor.
nonisolated enum TransferConflictPlanner {
    struct Plan: Sendable {
        let approvedItems: [ResolvedTransferItem]
        let conflicts: [TransferConflictCandidate]
    }

    static func preflight(sources: [URL], destinationDirectory: URL, reserved: Set<URL>) throws -> Plan {
        var occupied = Set(reserved.map { BasicFileActions.destinationReservationKey(for: $0) })
        var approved: [ResolvedTransferItem] = []
        var conflicts: [TransferConflictCandidate] = []
        for source in sources {
            try Task.checkCancellation()
            guard source.isFileURL, destinationDirectory.isFileURL else { throw FileSystemError.invalidName }
            let target = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            let key = BasicFileActions.destinationReservationKey(for: target)
            let isReserved = occupied.contains(key)
            occupied.insert(key)
            if isReserved || SafeFileOperations.entryExists(at: target) {
                conflicts.append(TransferConflictCandidate(source: source, destination: target, isReserved: isReserved))
            } else {
                approved.append(ResolvedTransferItem(source: source, destination: target))
            }
        }
        return Plan(approvedItems: approved, conflicts: conflicts)
    }

    static func keepBoth(for source: URL, in directory: URL, reserved: Set<URL>) throws -> ResolvedTransferItem {
        try Task.checkCancellation()
        var info = stat()
        guard lstat(source.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: source.path])
        }
        let target = try BasicFileActions.keepBothDestination(
            for: source, isDirectory: (info.st_mode & S_IFMT) == S_IFDIR,
            in: directory, reserved: reserved
        )
        return ResolvedTransferItem(source: source, destination: target)
    }
}
