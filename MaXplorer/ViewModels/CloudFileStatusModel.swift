import Combine
import Foundation

@MainActor
final class CloudFileStatusModel: ObservableObject {
    struct Confirmation: Identifiable {
        let id = UUID()
        let action: CloudFileAction
        let snapshot: CloudFileSnapshot
    }
    @Published private(set) var snapshots: [CloudFileSnapshot] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRequesting = false
    @Published private(set) var confirmation: Confirmation?
    @Published private(set) var messages: [URL: String] = [:]
    @Published private(set) var error: String?
    private let service: CloudFileService
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?
    init(service: CloudFileService = CloudFileService()) { self.service = service }
    deinit { loadTask?.cancel() }

    func load(_ urls: [URL]) {
        guard !isRequesting else { return }
        loadTask?.cancel(); let id = UUID(); generation = id
        isLoading = true; error = nil; confirmation = nil; snapshots = []
        let service = service
        loadTask = Task { [weak self] in
            do {
                let values = try await service.inspect(urls)
                guard !Task.isCancelled, let self, self.generation == id else { return }
                self.snapshots = values; self.isLoading = false
            } catch {
                guard !Task.isCancelled, let self, self.generation == id else { return }
                self.error = CloudFileFailure(error).message; self.isLoading = false
            }
        }
    }
    func prepare(_ action: CloudFileAction, for snapshot: CloudFileSnapshot) {
        guard !isLoading, !isRequesting, snapshots.contains(snapshot) else { return }
        let reason = action == .download ? snapshot.downloadUnavailableReason : snapshot.evictUnavailableReason
        guard reason == nil else { error = reason; return }
        confirmation = Confirmation(action: action, snapshot: snapshot); error = nil
    }
    func cancelConfirmation() { guard !isRequesting else { return }; confirmation = nil }
    func submit(confirmationID: UUID) async {
        guard let pending = confirmation, pending.id == confirmationID, !isRequesting else { return }
        confirmation = nil; isRequesting = true; error = nil
        do {
            let receipt = try await service.request(pending.action, for: pending.snapshot)
            messages[receipt.url] = receipt.message
            // This metadata refresh is not a promise of background synchronization.
            do {
                if let refreshed = try await service.inspect([pending.snapshot.url]).first,
                   let index = snapshots.firstIndex(where: { $0.url == pending.snapshot.url }) {
                    snapshots[index] = refreshed
                }
            } catch { self.error = "请求已提交，刷新失败：\(CloudFileFailure(error).message)" }
        } catch { self.error = CloudFileFailure(error).message }
        isRequesting = false
    }
    func cancelLoading() { loadTask?.cancel(); generation = UUID(); isLoading = false; confirmation = nil }
}
