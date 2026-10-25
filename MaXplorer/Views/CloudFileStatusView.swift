import SwiftUI

struct CloudFileStatusView: View {
    let urls: [URL]
    @StateObject private var model = CloudFileStatusModel()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("云端状态与本地副本").font(.headline)
            Text("当前支持明确由 iCloud 管理的普通文件。其他提供商和未知状态不会被标为已同步。此处的下载不保证始终保留本机。")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            if model.isLoading { ProgressView("读取所选项目的元数据…") }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let pending = model.confirmation {
                        Text(pending.action == .download ? "确认请求下载" : "确认释放本地副本").font(.headline)
                        Text(pending.snapshot.url.path).textSelection(.enabled)
                        Text("当前状态：\(pending.snapshot.statusTitle)")
                        Text(pending.action == .download
                             ? "向 iCloud 提交下载请求，返回成功不代表下载已完成。之后请刷新状态。"
                             : "仅释放这个文件的本地副本，云端文件仍保留；需要时可重新下载。执行前会重新核验身份、上传和冲突状态。")
                    } else {
                        ForEach(Array(model.snapshots.enumerated()), id: \.offset) { _, snapshot in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(snapshot.url.path).font(.headline).textSelection(.enabled)
                                Text(snapshot.statusTitle)
                                if let failure = snapshot.failure ?? snapshot.metadata?.downloadingError ?? snapshot.metadata?.uploadingError {
                                    Text(failure.message).foregroundStyle(.red).textSelection(.enabled)
                                }
                                HStack {
                                    Button("请求下载") { model.prepare(.download, for: snapshot) }
                                        .disabled(!snapshot.canDownload || model.isRequesting)
                                    Button("释放本地副本…") { model.prepare(.evict, for: snapshot) }
                                        .disabled(!snapshot.canEvict || model.isRequesting)
                                }
                                if let reason = snapshot.downloadUnavailableReason {
                                    Text("下载：\(reason)").font(.caption).foregroundStyle(.secondary)
                                }
                                if let reason = snapshot.evictUnavailableReason {
                                    Text("释放：\(reason)").font(.caption).foregroundStyle(.secondary)
                                }
                                if let message = model.messages[snapshot.url] { Text(message).foregroundStyle(.secondary) }
                            }
                            Divider()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("永久保留本机、第三方云盘和文件夹释放暂不支持；不会通过删除文件代替释放。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("完成") { dismiss() }.disabled(model.isRequesting).keyboardShortcut(.cancelAction)
                Spacer()
                if model.isRequesting { ProgressView().controlSize(.small); Text("正在提交请求…") }
                else if let pending = model.confirmation {
                    Button("取消操作") { model.cancelConfirmation() }
                    Button("确认提交") { Task { await model.submit(confirmationID: pending.id) } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("刷新状态") { model.load(urls) }.disabled(model.isLoading)
                }
            }
        }
        .padding(20).frame(width: 650, height: 560)
        .interactiveDismissDisabled(model.isRequesting)
        .task { model.load(urls) }
        .onDisappear { model.cancelLoading() }
    }
}
