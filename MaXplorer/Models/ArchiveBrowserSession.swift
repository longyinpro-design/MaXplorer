import Foundation

/// A modeless directory panel may finish after its browser closes. Its request
/// identity must still be active before it can retain a future extraction.
nonisolated struct ArchiveBrowserSession {
    struct Request: Identifiable, Equatable, Sendable {
        let id = UUID()
        let archiveURL: URL
    }
    struct Selection: Sendable {
        let catalog: ArchiveCatalog
        let ids: Set<String>
        let destination: URL
    }
    private(set) var request: Request?
    private var pending: Selection?

    init() {}

    mutating func present(_ archive: URL) {
        pending = nil
        request = Request(archiveURL: archive.standardizedFileURL)
    }

    mutating func close(requestID: UUID? = nil) {
        guard let active = request, requestID == nil || requestID == active.id else { return }
        pending = nil
        request = nil
    }

    @discardableResult
    mutating func finish(requestID: UUID, catalog: ArchiveCatalog, ids: Set<String>, destination: URL) -> Bool {
        guard let active = request, active.id == requestID,
              active.archiveURL == catalog.archiveURL.standardizedFileURL else { return false }
        pending = Selection(catalog: catalog, ids: ids, destination: destination)
        request = nil
        return true
    }

    mutating func takePendingAfterDismissal() -> Selection? {
        guard request == nil else { return nil }
        defer { pending = nil }
        return pending
    }
}
