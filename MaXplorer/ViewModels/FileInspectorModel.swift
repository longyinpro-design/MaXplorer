import Foundation
import Combine

/// A cancelled waiter remains in the tail until its predecessor actually ends.
/// Cancellation never releases capacity occupied by noncooperative filesystem I/O.
actor FileInspectorWorkCoordinator {
    static let shared = FileInspectorWorkCoordinator()
    private var tail: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable () async throws -> (QuickViewContent, String?)) async throws -> (QuickViewContent, String?) {
        let predecessor = tail
        let work = Task {
            await predecessor?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task { _ = try? await work.value }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

/// Details use the browser's snapshot. Only a visible single file starts I/O.
@MainActor
final class FileInspectorModel: ObservableObject {
    enum Status: Equatable {
        case hidden, empty, multiple, directory, package, network, details, loading, ready, failed
    }
    typealias Loader = @Sendable (URL) async throws -> QuickViewContent
    typealias Decoder = @Sendable (URL, String.Encoding) async throws -> String
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var status: Status = .hidden
    @Published private(set) var content: QuickViewContent?
    @Published private(set) var decodedText: String?
    @Published private(set) var error: String?
    private struct Request {
        let item: FileItem
        let encoding: PreviewTextEncoding
        let generation: UInt64
    }
    private let coordinator: FileInspectorWorkCoordinator
    private let loader: Loader
    private let decoder: Decoder
    private var generation: UInt64 = 0
    private var activeTask: Task<Void, Never>?
    private var active = false
    private var pending: Request?
    private var currentItem: FileItem?
    private var currentEncoding: PreviewTextEncoding?
    init(
        coordinator: FileInspectorWorkCoordinator = .shared,
        loader: @escaping Loader = { try await LocalFileSystemService().quickViewContent(for: $0) },
        decoder: @escaping Decoder = { url, encoding in
            try await Task.detached(priority: .userInitiated) {
                try PreviewTextDecoder.read(url, encoding: encoding)
            }.value
        }
    ) {
        self.coordinator = coordinator
        self.loader = loader
        self.decoder = decoder
    }
    deinit { activeTask?.cancel() }

    func update(selection: [FileItem], isVisible: Bool, showsPreview: Bool = true,
                encoding: PreviewTextEncoding = .automatic) {
        items = selection
        let nextStatus: Status
        if !isVisible { nextStatus = .hidden }
        else if selection.isEmpty { nextStatus = .empty }
        else if selection.count > 1 { nextStatus = .multiple }
        else if selection[0].isNetworkLocation { nextStatus = .network }
        else if selection[0].isPackage { nextStatus = .package }
        else if selection[0].isDirectory { nextStatus = .directory }
        else if !showsPreview || selection[0].isAlias { nextStatus = .details }
        else { nextStatus = .loading }
        if nextStatus == .loading, currentItem == selection.first, currentEncoding == encoding { return }
        generation &+= 1
        activeTask?.cancel()
        pending = nil
        currentItem = nil
        currentEncoding = nil
        content = nil
        decodedText = nil
        error = nil
        status = nextStatus
        guard nextStatus == .loading, let item = selection.first else { return }
        currentItem = item
        currentEncoding = encoding
        pending = Request(item: item, encoding: encoding, generation: generation)
        startPendingIfIdle()
    }
    func cancel() { update(selection: items, isVisible: false) }
    private func startPendingIfIdle() {
        guard !active, let request = pending else { return }
        pending = nil
        active = true
        let loader = self.loader
        let decoder = self.decoder
        let coordinator = self.coordinator
        // Neither a queued request nor a blocked operation retains the model.
        // The shared tail also bounds work across destroyed/recreated inspectors.
        activeTask = Task { [weak self] in
            let result: Result<(QuickViewContent, String?), Error>
            do {
                let value = try await coordinator.run {
                    try Task.checkCancellation()
                    let content = try await loader(request.item.url)
                    try Task.checkCancellation()
                    var text: String?
                    if content.allowsTextEncoding, let encoding = request.encoding.stringEncoding {
                        text = try await decoder(content.url, encoding)
                        try Task.checkCancellation()
                    }
                    return (content, text)
                }
                result = .success(value)
            } catch { result = .failure(error) }
            self?.finished(request, result: result)
        }
    }
    private func finished(_ request: Request, result: Result<(QuickViewContent, String?), Error>?) {
        active = false
        activeTask = nil
        if request.generation == generation, let result {
            switch result {
            case .success(let value):
                content = value.0
                decodedText = value.1
                status = .ready
            case .failure(let failure):
                error = failure.localizedDescription
                status = .failed
            }
        }
        startPendingIfIdle()
    }
}
