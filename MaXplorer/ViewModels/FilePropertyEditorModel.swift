import Combine
import Foundation

@MainActor
final class FilePropertyEditorModel: ObservableObject {
    struct Entry: Identifiable {
        let id: URL
        let snapshot: FilePropertySnapshot?
        let error: String?
        var editPermissions = false
        var permissions: String
        var editTags = false
        var tags: [String]
    }
    typealias Reader = @Sendable ([URL]) async -> [FilePropertyInspection]
    typealias Writer = @Sendable ([FilePropertyChange]) async -> [FilePropertyApplyResult]
    @Published var entries: [Entry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isApplying = false
    @Published private(set) var review: [FilePropertyChange] = []
    @Published private(set) var results: [FilePropertyApplyResult] = []
    @Published private(set) var error: String?
    private let reader: Reader
    private let writer: Writer
    private var generation = UUID()
    private var loadTask: Task<Void, Never>?

    init(reader: @escaping Reader = { await FilePropertyService.inspect($0) },
         writer: @escaping Writer = { await FilePropertyService.apply($0) }) {
        self.reader = reader; self.writer = writer
    }
    deinit { loadTask?.cancel() }

    func load(_ urls: [URL]) {
        guard !isApplying else { return }
        loadTask?.cancel()
        let id = UUID(); generation = id
        entries = []; review = []; results = []; error = nil; isLoading = true
        let reader = reader
        loadTask = Task { [weak self] in
            let inspected = await reader(urls)
            guard !Task.isCancelled, let self, self.generation == id else { return }
            self.entries = inspected.map { item in
                Entry(id: item.url, snapshot: item.snapshot, error: item.error?.localizedDescription,
                      permissions: item.snapshot.map { Self.octal($0.permissions) } ?? "",
                      tags: item.snapshot?.tagNames ?? [])
            }
            self.isLoading = false
        }
    }

    func prepareReview() {
        guard !isLoading, !isApplying, results.isEmpty else { return }
        error = nil; review = []
        var changes: [FilePropertyChange] = []
        for entry in entries where entry.editPermissions || entry.editTags {
            guard let snapshot = entry.snapshot else { continue }
            var permissions: UInt16?
            if entry.editPermissions {
                guard (1...3).contains(entry.permissions.count),
                      entry.permissions.allSatisfy({ "01234567".contains($0) }),
                      let value = UInt16(entry.permissions, radix: 8), value <= 0o777 else {
                    error = "\(entry.id.lastPathComponent)：权限须为 000–777 的八进制数字。"; return
                }
                if value != snapshot.permissions { permissions = value }
            }
            var tags: [String]?
            if entry.editTags {
                let normalized = entry.tags.map { $0.precomposedStringWithCanonicalMapping }
                guard normalized.count <= 100, normalized.allSatisfy({
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                    $0.utf8.count <= 255 && !$0.contains("\n") && !$0.contains("\r") && !$0.contains("\0")
                }), Set(normalized).count == normalized.count else {
                    error = "\(entry.id.lastPathComponent)：每行一个不重复标签，最多 100 个，每个不超过 255 UTF-8 字节；不能含空值、换行或 NUL。"; return
                }
                if normalized != snapshot.tagNames { tags = normalized }
            }
            if permissions != nil || tags != nil {
                changes.append(FilePropertyChange(snapshot: snapshot, permissions: permissions, tagNames: tags))
            }
        }
        guard !changes.isEmpty else { error = "请为需要修改的项目启用字段，并输入不同于原值的新值。"; return }
        review = changes
    }

    func returnToEditing() { guard !isApplying else { return }; review = []; error = nil }

    func applyReviewed() async {
        guard !review.isEmpty, !isApplying, results.isEmpty else { return }
        // Keep the reviewed values immutable even if a view binding changes.
        let changes = review
        isApplying = true; error = nil
        results = await writer(changes)
        isApplying = false; review = []
    }

    func cancelLoading() { loadTask?.cancel(); generation = UUID(); isLoading = false }
    static func octal(_ value: UInt16) -> String { String(format: "%03o", Int(value)) }
}
