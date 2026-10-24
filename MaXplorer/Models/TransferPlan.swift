import Foundation

nonisolated struct TransferPlan: Identifiable, Equatable, Sendable {
    let id = UUID()
    let sources: [URL]
    let destinationDirectory: URL
    let operation: CopyQueueOperation
    let itemCount: Int
    let totalBytes: Int64
    let freeBytes: Int64?
    let requiredBytes: Int64
    let conflictCount: Int
    let unreadableCount: Int
    let destinationWritable: Bool
    let isNetworkDestination: Bool
    let errorMessage: String?

    var hasEnoughSpace: Bool {
        guard let freeBytes else { return true }
        return freeBytes >= requiredBytes
    }

    var canProceed: Bool {
        errorMessage == nil && destinationWritable && hasEnoughSpace
    }
}
