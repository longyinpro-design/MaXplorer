import Foundation

nonisolated struct ResolvedTransferItem: Sendable, Equatable {
    let source: URL
    let destination: URL
    var shouldOverwrite = false
    var approval: SafeFileOperations.ConflictApproval? = nil
}

nonisolated struct TransferConflictCandidate: Sendable, Equatable {
    let source: URL
    let destination: URL
    let isReserved: Bool
}

nonisolated struct CopyConflictRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let candidate: TransferConflictCandidate
    let conflictNumber: Int
    let totalConflicts: Int
    var comparison: SafeFileOperations.ConflictComparison? = nil
    var isPreparing = true
    var errorMessage: String? = nil
    var conflictingName: String { candidate.destination.lastPathComponent }
}
