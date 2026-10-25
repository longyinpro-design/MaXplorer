import AppKit
import SwiftUI

// MARK: – Colorful icon used for the tab + toolbar

struct SpaceAnalyzerIcon: View {
    var size: CGFloat = 13

    var body: some View {
        Canvas { ctx, s in
            let rects: [(CGRect, Color)] = [
                (CGRect(x: 0,            y: 0,            width: s.width * 0.57, height: s.height * 0.57), .blue),
                (CGRect(x: s.width*0.59, y: 0,            width: s.width * 0.41, height: s.height * 0.35), .green),
                (CGRect(x: s.width*0.59, y: s.height*0.37, width: s.width*0.41, height: s.height*0.20), .orange),
                (CGRect(x: 0,            y: s.height*0.59, width: s.width*0.34, height: s.height*0.41), .purple),
                (CGRect(x: s.width*0.36, y: s.height*0.59, width: s.width*0.64, height: s.height*0.41), .red),
            ]
            for (r, c) in rects {
                ctx.fill(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1.5), with: .color(c))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: – Main view

struct SpaceAnalyzerView: View {
    @EnvironmentObject private var viewModel: SpaceAnalyzerViewModel
    @EnvironmentObject private var tabs: BrowserTabsViewModel
    @EnvironmentObject private var settings: AppSettings
    @State private var mode: SpaceAnalyzerMode = .allFiles
    @State private var drillPath: [SpaceNode] = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
            Divider()
            statsBar
        }
        .background(ThemedSurfaceBackground())
        .onAppear { mode = settings.defaultSpaceAnalyzerMode }
        .onChange(of: mode) { _, _ in drillPath.removeAll() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            TextField("扫描文件夹", text: $viewModel.rootPath)
                .textFieldStyle(.plain)
                .disabled(viewModel.isScanning)
                .onSubmit { viewModel.refresh() }

            Picker("模式", selection: $mode) {
                ForEach(SpaceAnalyzerMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)

            if viewModel.isScanning {
                Button("取消扫描") { viewModel.cancelScan() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
            } else {
                Button("扫描") { viewModel.refresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ThemedBarBackground())
    }

    // MARK: Content area

    @ViewBuilder
    private var content: some View {
        switch viewModel.scanState {
        case .idle:
            idleView
        case .scanning(let count):
            scanningView(count: count)
        case .ready(let root):
            treemapView(root: root)
        case .failed(let msg):
            ContentUnavailableView("扫描失败", systemImage: "exclamationmark.triangle", description: Text(msg))
        }
    }

    private var idleView: some View {
        ContentUnavailableView {
            Label("尚未扫描", systemImage: "square.3.layers.3d")
        } description: {
            Text("在上方输入文件夹路径，然后点击“扫描”查看空间占用。")
        } actions: {
            Button("扫描主目录") {
                viewModel.startScan(url: FileManager.default.homeDirectoryForCurrentUser)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func scanningView(count: Int) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("正在扫描… 已找到 \(count) 项")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func treemapView(root: SpaceNode) -> some View {
        VStack(spacing: 0) {
            if mode == .drillDown {
                drillDownNavigation(root: root)
                Divider()
            }
            TreemapCanvas(
                root: drillPath.last ?? root,
                mode: mode,
                categories: viewModel.categories,
                tabs: tabs,
                onOpenDirectory: { node in drillPath.append(node) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: root.id) { _, _ in drillPath.removeAll() }
    }

    private func drillDownNavigation(root: SpaceNode) -> some View {
        HStack(spacing: 8) {
            Button {
                _ = drillPath.popLast()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(drillPath.isEmpty)
            .help("前往上一级文件夹")

            Button(root.name.isEmpty ? root.url.path : root.name) {
                drillPath.removeAll()
            }
            .buttonStyle(.plain)

            ForEach(Array(drillPath.enumerated()), id: \.element.id) { index, node in
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                Button(node.name) {
                    drillPath = Array(drillPath.prefix(index + 1))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(ThemedBarBackground())
    }

    // MARK: Stats bar

    private var statsBar: some View {
        HStack(spacing: 20) {
            if let stats = viewModel.volumeStats {
                let freePercent = Int((Double(stats.free) / Double(stats.total) * 100).rounded())
                Label(
                    "已用：\(ByteCountFormatter.string(fromByteCount: Int64(stats.used), countStyle: .file))",
                    systemImage: "internaldrive"
                )
                Text("可用：\(ByteCountFormatter.string(fromByteCount: Int64(stats.free), countStyle: .file))（\(freePercent)%）")
                    .foregroundStyle(freePercent < 10 ? .red : .secondary)
            } else {
                Text("无法获取卷信息").foregroundStyle(.secondary)
            }
            Spacer()
            if case .ready(let root) = viewModel.scanState {
                Text("已扫描：\(ByteCountFormatter.string(fromByteCount: Int64(root.size), countStyle: .file))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ThemedBarBackground())
    }
}

// MARK: – Treemap canvas

private struct TreemapCanvas: View {
    let root: SpaceNode
    let mode: SpaceAnalyzerMode
    let categories: FileCategoryService
    let tabs: BrowserTabsViewModel
    let onOpenDirectory: (SpaceNode) -> Void

    @State private var tileList: [(node: SpaceNode, frame: CGRect)] = []
    @State private var canvasSize: CGSize = .zero
    @State private var pendingResizeTask: Task<Void, Never>?

    private let minTileArea: CGFloat = 36  // 6×6 px minimum
    private let largeLayoutTileThreshold = 2_000

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ThemedSurfaceBackground()
                ForEach(tileList, id: \.node.id) { item in
                    TileView(
                        node: item.node,
                        size: item.frame.size,
                        mode: mode,
                        categories: categories,
                        tabs: tabs,
                        onOpenDirectory: onOpenDirectory
                    )
                    .frame(width: item.frame.width, height: item.frame.height)
                    // .position is layout-affecting (unlike .offset), so the tile's
                    // hit region — including its context menu — lands where it renders.
                    .position(x: item.frame.midX, y: item.frame.midY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onChange(of: geo.size) { _, size in scheduleRebuild(size: size) }
            .onAppear { rebuildLayout(size: geo.size) }
        }
        .onChange(of: root.id) { _, _ in rebuildNow() }
        .onChange(of: mode) { _, _ in rebuildNow() }
        .onDisappear { pendingResizeTask?.cancel() }
    }

    /// Small layouts follow a live resize directly. Large layouts wait until
    /// the drag pauses so a 20k-node tree cannot block the main actor on every
    /// intermediate window size.
    private func scheduleRebuild(size: CGSize) {
        canvasSize = size
        guard size.width > 0, size.height > 0 else { return }

        if tileList.count <= largeLayoutTileThreshold {
            pendingResizeTask?.cancel()
            rebuildLayout(size: size)
            return
        }

        pendingResizeTask?.cancel()
        pendingResizeTask = Task {
            guard (try? await Task.sleep(for: .milliseconds(120))) != nil else {
                return
            }
            rebuildLayout(size: size)
        }
    }

    private func rebuildNow() {
        pendingResizeTask?.cancel()
        rebuildLayout(size: canvasSize)
    }

    private func rebuildLayout(size: CGSize) {
        canvasSize = size
        guard size.width > 0, size.height > 0 else { return }
        let bounds = CGRect(origin: .zero, size: size)
        if mode == .drillDown {
            TreemapLayout.layoutDrillDown(nodes: root.children, in: bounds)
            tileList = root.children.map { ($0, $0.layoutFrame) }
        } else {
            TreemapLayout.layout(node: root, in: bounds, minimumArea: minTileArea)
            var leaves: [(node: SpaceNode, frame: CGRect)] = []
            collectLeaves(node: root, into: &leaves)
            tileList = leaves
        }
    }

    private func collectLeaves(node: SpaceNode, into result: inout [(node: SpaceNode, frame: CGRect)]) {
        let area = node.layoutFrame.width * node.layoutFrame.height
        guard area >= minTileArea else { return }

        if node.isDirectory && !node.children.isEmpty {
            let countBefore = result.count
            for child in node.children {
                collectLeaves(node: child, into: &result)
            }
            if result.count > countBefore {
                return
            }
        }

        result.append((node, node.layoutFrame))
    }
}

// MARK: – Individual tile

private struct TileView: View {
    let node: SpaceNode
    let size: CGSize
    let mode: SpaceAnalyzerMode
    let categories: FileCategoryService
    let tabs: BrowserTabsViewModel
    let onOpenDirectory: (SpaceNode) -> Void

    var body: some View {
        let color = node.isDirectory ? categories.directoryColor : categories.color(for: node.url)
        let showLabel = size.width > 40 && size.height > 22
        let shape = FolderTileShape()

        ZStack(alignment: .bottom) {
            color
                .clipShape(node.isDirectory && mode == .drillDown ? AnyShape(shape) : AnyShape(Rectangle()))
                .overlay {
                    if node.isDirectory && mode == .drillDown {
                        shape.stroke(Color(nsColor: .windowBackgroundColor).opacity(0.7), lineWidth: 0.7)
                    } else {
                        Rectangle().stroke(Color(nsColor: .windowBackgroundColor).opacity(0.6), lineWidth: 0.5)
                    }
                }

            if showLabel {
                Text(node.name)
                    .font(.system(size: min(11, size.height * 0.25)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .padding(.horizontal, 3)
                    .padding(.bottom, 2)
                    .frame(maxWidth: size.width - 4)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if mode == .drillDown && node.isDirectory {
                onOpenDirectory(node)
            }
        }
        .contextMenu {
            Button("打开") {
                if !node.isDirectory { RecentFilesStore.shared.record(node.url) }
                NSWorkspace.shared.open(node.url)
            }
            Button("浏览所在位置") {
                let target = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
                tabs.browseLocation(target)
            }
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path(percentEncoded: false), forType: .string)
            }
        }
        .tileTooltip(tooltip)
    }

    private var tooltip: String {
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(node.size), countStyle: .file)
        if node.isDirectory && mode == .drillDown {
            return "\(sizeText)\n\(node.descendantCount) 个项目\n\(node.name)\n\(node.url.path(percentEncoded: false))"
        }
        return "\(sizeText)\n\(node.name)\n\(node.url.path(percentEncoded: false))"
    }
}

private struct FolderTileShape: Shape {
    func path(in rect: CGRect) -> Path {
        let tabWidth = min(rect.width * 0.42, 56)
        let tabHeight = min(max(3, rect.height * 0.13), 12)
        let radius = min(5, min(rect.width, rect.height) * 0.08)
        var path = Path()
        path.move(to: CGPoint(x: radius, y: tabHeight))
        path.addLine(to: CGPoint(x: 0, y: tabHeight))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
        path.addLine(to: CGPoint(x: max(radius, tabWidth - radius), y: 0))
        path.addQuadCurve(to: CGPoint(x: tabWidth, y: radius), control: CGPoint(x: tabWidth, y: 0))
        path.addLine(to: CGPoint(x: tabWidth + tabHeight * 0.5, y: tabHeight))
        path.addLine(to: CGPoint(x: rect.width - radius, y: tabHeight))
        path.addQuadCurve(to: CGPoint(x: rect.width, y: tabHeight + radius), control: CGPoint(x: rect.width, y: tabHeight))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - radius))
        path.addQuadCurve(to: CGPoint(x: rect.width - radius, y: rect.height), control: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: radius, y: rect.height))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.height - radius), control: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}
