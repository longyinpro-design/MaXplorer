import AppKit
import SwiftUI

struct ArchiveBrowserView: View {
    @StateObject private var model: ArchiveBrowserModel
    let onExtract: (ArchiveCatalog, Set<String>, URL) -> Void
    let onClose: () -> Void
    @State private var directoryPanel: NSOpenPanel?
    @State private var isActive = false

    init(archiveURL: URL, onExtract: @escaping (ArchiveCatalog, Set<String>, URL) -> Void, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: ArchiveBrowserModel(archiveURL: archiveURL))
        self.onExtract = onExtract
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "archivebox")
                Text(model.archiveURL.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let catalog = model.catalog { Text(catalog.formatName).font(.caption).foregroundStyle(.secondary) }
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
            }
            HStack {
                Button { model.goUp() } label: { Label("上一级", systemImage: "arrow.up") }.disabled(!model.canGoUp)
                Text(model.currentPath.isEmpty ? "/" : "/" + model.currentPath)
                    .font(.caption).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button("重新读取") { model.load() }.disabled(model.isLoading)
            }
            if model.isLoading {
                ProgressView("正在读取压缩包目录…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage {
                ContentUnavailableView("无法浏览压缩包", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.visibleEntries.isEmpty {
                ContentUnavailableView("此目录为空", systemImage: "folder")
            } else {
                List(selection: $model.selectedIDs) {
                    ForEach(model.visibleEntries) { entry in
                        HStack(spacing: 10) {
                            Image(systemName: entry.kind == .directory ? "folder" : (entry.isExtractable ? "doc" : "link"))
                            Text(ArchiveBrowserModel.name(of: entry.path)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if !entry.isExtractable { Text("不支持提取链接/特殊文件").foregroundStyle(.secondary) }
                            if let size = entry.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).foregroundStyle(.secondary) }
                        }
                        .contentShape(Rectangle()).tag(entry.id)
                        .onTapGesture(count: 2) { model.enter(entry) }
                        .accessibilityElement(children: .combine)
                    }
                }
                .onKeyPress(.return) {
                    guard model.selectedIDs.count == 1,
                          let entry = model.visibleEntries.first(where: { model.selectedIDs.contains($0.id) }),
                          entry.kind == .directory else { return .ignored }
                    model.enter(entry)
                    return .handled
                }
            }
            Text("只读目录浏览，不会自动解压。提取保留包内路径；选中目录包含其子项。覆盖同名顶层文件夹会整体替换，含链接或特殊文件时拒绝提取。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("ZIP/TAR/7z/RAR · RAR仅读取 · 加密/分卷包不支持").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("已选 \(model.selectedIDs.count) 项").font(.caption)
                Button("提取所选…", action: chooseDestination).disabled(!model.canExtractSelection)
            }
        }
        .padding(20).frame(minWidth: 760, minHeight: 500)
        .background(ResizableSheetWindowBridge(minSize: NSSize(width: 760, height: 500)))
        .onAppear { isActive = true; model.load() }
        .onDisappear {
            isActive = false
            directoryPanel?.cancel(nil)
            directoryPanel = nil
            model.cancel()
        }
        .accessibilityIdentifier("archiveBrowser")
    }

    private func chooseDestination() {
        guard isActive, directoryPanel == nil, let catalog = model.catalog, model.canExtractSelection else { return }
        let selection = model.selectedIDs
        let panel = NSOpenPanel()
        panel.title = "提取所选条目到"
        panel.prompt = "提取"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        directoryPanel = panel
        panel.begin { [weak panel] response in
            guard let panel else { return }
            let isCurrent = directoryPanel === panel
            if isCurrent { directoryPanel = nil }
            guard isActive, isCurrent, response == .OK, let destination = panel.url else { return }
            onExtract(catalog, selection, destination)
        }
    }
}
