import SwiftUI

/// Only the ordinary file workspace owns this pane; independent Quick View stays separate.
struct FileBrowserWorkspace: View {
    @EnvironmentObject private var settings: AppSettings
    @Binding var renameItem: FileItem?
    @Binding var renameText: String
    @Binding var itemsPendingTrash: [FileItem]

    var body: some View {
        HSplitView {
            FileTableView(renameItem: $renameItem, renameText: $renameText, itemsPendingTrash: $itemsPendingTrash)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            if settings.inspectorVisible {
                FileInspectorView()
                    .frame(minWidth: 240, idealWidth: settings.inspectorWidth, maxWidth: 520, maxHeight: .infinity)
                    .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { width in
                        guard width > 0 else { return }
                        let clamped = FileInspectorPreferences.clampedWidth(width)
                        if abs(settings.inspectorWidth - clamped) > 0.5 { settings.inspectorWidth = clamped }
                    }
            }
        }
    }
}

private struct FileInspectorView: View {
    @EnvironmentObject private var browser: FileBrowserViewModel
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var inspector = FileInspectorModel()
    @State private var encoding: PreviewTextEncoding = .automatic

    private struct Request: Equatable {
        let items: [FileItem]
        let preview: Bool
        let encoding: PreviewTextEncoding
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("右侧栏内容", selection: $settings.inspectorMode) {
                    Text("预览").tag(FileInspectorPreferences.Mode.preview)
                    Text("详情").tag(FileInspectorPreferences.Mode.details)
                }
                .pickerStyle(.segmented)
                Button { settings.inspectorVisible = false } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭右侧栏（⌘⌥I）")
                .accessibilityLabel("关闭右侧栏")
            }
            .padding(10)
            Divider()
            if settings.inspectorMode == .preview {
                previewBody
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView { details.padding(12) }
                    .frame(maxHeight: 210)
            } else {
                ScrollView { details.padding(12) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(ThemedContentBackground())
        .onChange(of: browser.selectedItems, initial: true) { _, _ in encoding = .automatic }
        .onChange(of: Request(items: browser.selectedItems, preview: settings.inspectorMode == .preview, encoding: encoding), initial: true) { _, request in
            inspector.update(selection: request.items, isVisible: true, showsPreview: request.preview, encoding: request.encoding)
        }
        .onDisappear { inspector.cancel() }
    }

    @ViewBuilder
    private var previewBody: some View {
        switch inspector.status {
        case .loading:
            ProgressView("正在准备预览…")
        case .ready:
            if let content = inspector.content {
                VStack(spacing: 0) {
                    if content.allowsTextEncoding {
                        Picker("文本编码", selection: $encoding) {
                            ForEach(PreviewTextEncoding.allCases) { value in
                                Text(value.displayName).tag(value)
                            }
                        }
                        .padding(8)
                    }
                    if content.isLegacyOfficeDocument {
                        Text("部分旧版或加密 Office 文件可能无法预览。可用默认应用打开查看。")
                            .font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                    if encoding == .automatic {
                        FilePreviewView(url: content.url).id(content.id)
                    } else {
                        ScrollView {
                            Text(inspector.decodedText ?? "")
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(12)
                        }
                    }
                }
            }
        case .failed:
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                Text(inspector.error ?? "无法预览此项目").font(.callout).multilineTextAlignment(.center)
                if encoding != .automatic {
                    Button("恢复自动预览") { encoding = .automatic }
                }
                Button("重试") {
                    inspector.cancel()
                    inspector.update(selection: browser.selectedItems, isVisible: true,
                                     showsPreview: true, encoding: encoding)
                }
            }
            .padding(16)
        case .multiple:
            placeholder("已选择多个项目", symbol: "doc.on.doc", detail: "选择单个文件以预览。")
        case .directory:
            placeholder("文件夹", symbol: "folder", detail: "可在详情中查看已有属性。")
        case .package:
            placeholder("软件包", symbol: "shippingbox", detail: "软件包不在此处预览。")
        case .network:
            placeholder("网络位置", symbol: "network", detail: "打开位置后选择文件以预览。")
        case .details:
            placeholder("仅显示详情", symbol: "info.circle", detail: "此项目不在侧栏中预览。")
        case .hidden, .empty:
            placeholder("没有选择项目", symbol: "doc.text.magnifyingglass", detail: "选择文件查看预览和详情。")
        }
    }

    @ViewBuilder
    private var details: some View {
        if inspector.items.count == 1, let item = inspector.items.first {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                detailRow("名称", item.name)
                detailRow("类型", item.displayKind)
                detailRow("大小", item.isDirectory ? "未计算文件夹大小" : (item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知"))
                detailRow("创建", item.displayCreated.isEmpty ? "未知" : item.displayCreated)
                detailRow("修改", item.displayModified.isEmpty ? "未知" : item.displayModified)
                detailRow("路径", item.url.path)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if inspector.items.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("已选择 \(inspector.items.count) 个项目").font(.headline)
                Text(multipleSizeSummary).font(.callout)
                Text("汇总仅使用已载入的文件大小，不递归计算文件夹。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("选择项目查看详情").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var multipleSizeSummary: String {
        var total: Int64 = 0
        for item in inspector.items where !item.isDirectory {
            guard let size = item.size, size >= 0 else { continue }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow else { return "已知文件大小超出可显示范围" }
            total = sum.partialValue
        }
        return "已知文件大小：" + ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Text(value).lineLimit(nil).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    private func placeholder(_ title: String, symbol: String, detail: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(detail))
    }
}
