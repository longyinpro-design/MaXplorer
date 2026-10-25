import SwiftUI

struct RecentFilesView: View {
    @ObservedObject var store = RecentFilesStore.shared
    let onOpen: (URL) -> Void
    let onReveal: (URL) -> Void
    let onClose: () -> Void
    @State private var selection: URL?
    @State private var refreshID = UUID()
    @State private var isRefreshing = false
    @State private var confirmsClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近文件").font(.title2.bold())
                Spacer()
                if isRefreshing { ProgressView().controlSize(.small) }
                Button("刷新状态") { refreshID = UUID() }.disabled(isRefreshing)
            }
            Text("只记录 MaXplorer 请求打开的文件，最多 50 条。清空历史不会删除文件。")
                .font(.caption).foregroundStyle(.secondary)
            Table(store.entries, selection: $selection) {
                TableColumn("名称") { entry in Text(entry.name).lineLimit(1) }
                    .width(min: 140, ideal: 190)
                TableColumn("位置") { entry in
                    Text(entry.url.deletingLastPathComponent().path).lineLimit(1).help(entry.url.path)
                }
                TableColumn("上次打开") { entry in Text(entry.lastOpened, format: .dateTime.month().day().hour().minute()) }
                    .width(120)
                TableColumn("状态") { entry in Text(statusText(entry.status)) }
                    .width(95)
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                if let url = urls.first, let entry = store.entries.first(where: { $0.url == url }) {
                    Button("打开") { onOpen(url) }.disabled(entry.status != .available)
                    Button("打开所在文件夹") { onReveal(url) }
                    Divider()
                    Button("从历史移除") { remove(url) }
                }
            } primaryAction: { urls in
                if let url = urls.first, store.entries.contains(where: { $0.url == url && $0.status == .available }) {
                    onOpen(url)
                }
            }
            .overlay {
                if store.entries.isEmpty {
                    ContentUnavailableView("没有最近文件", systemImage: "clock",
                                           description: Text("从 MaXplorer 打开文件后会出现在这里。"))
                }
            }
            HStack {
                Button("清空历史…") { confirmsClear = true }.disabled(store.entries.isEmpty)
                Spacer()
                Button("移除记录") { if let selection { remove(selection) } }.disabled(selection == nil)
                Button("所在文件夹") { if let selection { onReveal(selection) } }.disabled(selection == nil)
                Button("打开") { if let selection { onOpen(selection) } }
                    .disabled(!store.entries.contains(where: { $0.url == selection && $0.status == .available }))
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 740, idealWidth: 820, minHeight: 440, idealHeight: 500)
        .task(id: refreshID) {
            isRefreshing = true
            await store.refreshAvailability()
            isRefreshing = false
        }
        .confirmationDialog("清空 MaXplorer 的最近文件记录？", isPresented: $confirmsClear) {
            Button("清空历史", role: .destructive) {
                store.clear()
                selection = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("文件本身不会被修改或删除。")
        }
    }

    private func remove(_ url: URL) {
        store.remove(url)
        selection = nil
        refreshID = UUID()
    }

    private func statusText(_ status: RecentFile.Availability) -> String {
        switch status {
        case .available: return "可用"
        case .missing: return "已移动或删除"
        case .unavailable: return "不可用或待检查"
        }
    }
}
