import SwiftUI

struct TransferConflictPanel: View {
    let request: CopyConflictRequest
    let onResolve: (CopyConflictResolution) -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("处理同名项目：\(request.conflictingName)")
                .font(.headline).lineLimit(2)
            Text("第 \(request.conflictNumber) 个冲突，共 \(request.totalConflicts) 个")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) {
                entry("源项目", path: request.candidate.source.path, details: request.comparison?.source)
                Divider()
                entry("目标项目", path: request.candidate.destination.path, details: request.comparison?.destination)
            }
            .fixedSize(horizontal: false, vertical: true)
            if request.isPreparing {
                HStack { ProgressView().controlSize(.small); Text("正在读取并核对项目…") }
            }
            if request.candidate.isReserved {
                Text("此目标名已被本批或队列中的另一项预留。可以保留两者或跳过。")
                    .foregroundStyle(.orange)
            }
            if let error = request.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Button("重新读取", action: onRefresh).disabled(request.isPreparing)
            }
            Text("保留两者将使用新的名称；复制可撤销新副本，移动可移回。覆盖会替换整个目标项目，不能撤销。全部选择应用于剩余冲突。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("取消") { onResolve(.cancel) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("跳过") { onResolve(.skip) }.disabled(request.isPreparing)
                if request.totalConflicts > 1 {
                    Button("全部跳过") { onResolve(.skipAll) }.disabled(request.isPreparing)
                }
                Button("保留两者") { onResolve(.keepBoth) }.disabled(request.isPreparing)
                if request.totalConflicts > 1 {
                    Button("全部保留") { onResolve(.keepBothAll) }.disabled(request.isPreparing)
                }
            }
            HStack {
                Spacer()
                Button("覆盖", role: .destructive) { onResolve(.overwrite) }.disabled(!canOverwrite)
                if request.totalConflicts > 1 {
                    Button("全部覆盖", role: .destructive) { onResolve(.overwriteAll) }.disabled(!canOverwrite)
                }
            }
        }
        .padding(24).frame(width: 680)
        .accessibilityIdentifier("transferConflictPanel")
    }

    private var canOverwrite: Bool {
        !request.isPreparing && !request.candidate.isReserved && request.comparison != nil && request.errorMessage == nil
    }

    private func entry(_ title: String, path: String, details: SafeFileOperations.ConflictEntryDetails?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            Text(path).font(.caption).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
            if let details {
                Text("类型：\(details.kind)")
                Text("大小：\(ByteCountFormatter.string(fromByteCount: details.byteCount, countStyle: .file))")
                Text("修改：\(details.modifiedAt.formatted(date: .numeric, time: .standard))")
            } else {
                Text(request.candidate.isReserved ? "目标名预留中" : "属性尚未读取").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct CopyRetryConflictSheet: View {
    @ObservedObject var queue: CopyQueueViewModel
    let item: CopyQueueItem
    let onFinish: () -> Void
    @State private var request: CopyConflictRequest?
    @State private var reservations: Set<URL> = []
    @State private var actionTask: Task<Void, Never>?
    @State private var refreshID = UUID()

    var body: some View {
        Group {
            if let request {
                TransferConflictPanel(request: request, onResolve: resolve) { refreshID = UUID() }
            } else {
                VStack(spacing: 16) {
                    ProgressView("正在检查重试目标…")
                    Button("取消", action: onFinish).keyboardShortcut(.cancelAction)
                }.padding(32)
            }
        }
        .task(id: refreshID) { await load() }
        .onDisappear { actionTask?.cancel() }
    }

    private func load() async {
        reservations = queue.reservedDestinationURLs
        let reserved = reservations
        let source = item.sourceURL
        let destination = item.destinationURL
        do {
            let worker = Task.detached(priority: .utility) { () -> (Bool, Bool) in
                let key = BasicFileActions.destinationReservationKey(for: destination)
                let isReserved = reserved.contains { BasicFileActions.destinationReservationKey(for: $0) == key }
                return (SafeFileOperations.entryExists(at: destination), isReserved)
            }
            let (exists, isReserved) = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            if !exists && !isReserved {
                queue.retry(item.id)
                onFinish()
                return
            }
            var next = CopyConflictRequest(
                candidate: TransferConflictCandidate(source: source, destination: destination, isReserved: isReserved),
                conflictNumber: 1, totalConflicts: 1
            )
            if isReserved { next.isPreparing = false; request = next; return }
            request = next
            let comparison = try await SafeFileOperations.captureConflictComparison(sourceURL: source, destinationURL: destination)
            guard !Task.isCancelled else { return }
            next.comparison = comparison
            next.isPreparing = false
            request = next
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            request?.errorMessage = error.localizedDescription
            request?.isPreparing = false
        }
    }

    private func resolve(_ choice: CopyConflictResolution) {
        if choice == .cancel || choice == .skip || choice == .skipAll { onFinish(); return }
        guard let request, !request.isPreparing else { return }
        guard queue.reservedDestinationURLs == reservations else {
            self.request?.errorMessage = "队列的目标预留已变化，请重新读取。"
            self.request?.comparison = nil
            return
        }
        if choice == .overwrite || choice == .overwriteAll {
            guard !request.candidate.isReserved, let comparison = request.comparison, request.errorMessage == nil else { return }
            queue.retry(item.id, resolved: ResolvedTransferItem(
                source: item.sourceURL, destination: item.destinationURL,
                shouldOverwrite: true, approval: comparison.approval
            ))
            onFinish()
            return
        }
        self.request?.isPreparing = true
        self.request?.errorMessage = nil
        let reserved = reservations
        actionTask = Task {
            do {
                let worker = Task.detached(priority: .utility) {
                    try TransferConflictPlanner.keepBoth(
                        for: item.sourceURL, in: item.destinationURL.deletingLastPathComponent(), reserved: reserved
                    )
                }
                let resolved = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                guard reserved == queue.reservedDestinationURLs else {
                    self.request?.errorMessage = "队列的目标预留已变化，请重新读取。"
                    self.request?.comparison = nil
                    self.request?.isPreparing = false
                    return
                }
                queue.retry(item.id, resolved: resolved)
                onFinish()
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.request?.errorMessage = error.localizedDescription
                self.request?.isPreparing = false
            }
        }
    }
}
