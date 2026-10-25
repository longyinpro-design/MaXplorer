import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var tabs: BrowserTabsViewModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            BrowserTabStrip()
            ActiveBrowserView(model: tabs.activeModel)
                .id(tabs.activeTab.id)
                .environmentObject(tabs.activeModel)
        }
        .onAppear {
            let tabs = tabs
            settings.onServerConnectionSucceeded = { [weak tabs] mountedVolumeURL in
                tabs?.openLocationInNewTab(mountedVolumeURL)
            }
        }
        .onDisappear {
            settings.onServerConnectionSucceeded = nil
        }
        .background(ThemedSurfaceBackground(intensity: 0.55))
    }
}

private struct ActiveBrowserView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var tabs: BrowserTabsViewModel
    @ObservedObject var model: FileBrowserViewModel
    @State private var renameItem: FileItem?
    @State private var renameText = ""
    @State private var itemsPendingTrash: [FileItem] = []
    @State private var serverAddress = "smb://"
    @State private var manualFolderPath = ""
    @State private var manualFolderError: String?
    @State private var selectPatternText = ""
    @State private var selectPatternMode: SearchMatchMode = .glob

    var body: some View {
        Group {
            if model.isIntegratedTerminalPresented,
               model.currentURL.isFileURL,
               model.detailDestination == .files,
               !tabs.isSpaceAnalyzerActive,
               !tabs.isCopyQueueActive,
               !tabs.isSearchActive {
                VSplitView {
                    browserNavigationView
                        .layoutPriority(1)

                    IntegratedTerminalView(directoryURL: model.currentURL) {
                        model.isIntegratedTerminalPresented = false
                    }
                    .id(model.currentURL)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 180, idealHeight: 196)
                }
            } else {
                browserNavigationView
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .alert("MaXplorer", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("确定") {
                model.clearError()
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $renameItem) { item in
            RenameSheet(item: item, renameText: $renameText) {
                Task {
                    await model.renameSelected(to: renameText)
                    renameItem = nil
                }
            } onCancel: {
                renameItem = nil
            }
        }
        .sheet(isPresented: $model.isSelectPatternPresented) {
            SelectItemsSheet(
                pattern: $selectPatternText,
                mode: $selectPatternMode
            ) {
                model.selectItems(matching: selectPatternText, mode: selectPatternMode)
                model.isSelectPatternPresented = false
            } onCancel: {
                model.isSelectPatternPresented = false
            }
        }
        .onChange(of: model.isSelectPatternPresented) { _, isPresented in
            guard isPresented else { return }
            selectPatternText = ""
            selectPatternMode = .glob
        }
        .sheet(isPresented: $model.isNewFilePresented) {
            NewFileSheet { name in
                model.isNewFilePresented = false
                Task { await model.createFile(named: name) }
            } onCancel: {
                model.isNewFilePresented = false
            }
        }
        .sheet(item: $model.infoItem) { item in
            FileInfoSheet(item: item, model: model)
        }
        .onChange(of: model.infoItem) { _, item in
            if item == nil {
                model.cancelInfoLoad()
            }
        }
        .sheet(isPresented: $model.isTransferPlanPresented, onDismiss: {
            model.cancelTransferPlan()
        }) {
            TransferPlanSheet(model: model)
        }
        .sheet(isPresented: $model.isArchiveOperationPresented) {
            ArchiveProgressSheet(model: model)
        }
        .sheet(isPresented: $model.isRecoveryNoticePresented) {
            RecoveryResidueSheet(model: model)
        }
        .sheet(isPresented: $model.isUndoHistoryPresented) {
            UndoHistorySheet(journal: model.undoJournal)
        }
        .sheet(isPresented: $model.isBatchRenamePresented) {
            BatchRenameSheet(model: model)
        }
        .sheet(isPresented: $model.isRecentFilesPresented) {
            RecentFilesView { url in
                model.isRecentFilesPresented = false
                model.openRecentFile(url)
            } onReveal: { url in
                model.isRecentFilesPresented = false
                tabs.browseLocation(url.deletingLastPathComponent())
            } onClose: {
                model.isRecentFilesPresented = false
            }
        }
        .confirmationDialog(
            "目标位置存在同名项目",
            isPresented: Binding(
                get: { model.archiveConflictRequest != nil },
                set: { if !$0 { model.cancelArchiveConflictPrompt() } }
            ),
            titleVisibility: .visible
        ) {
            Button("覆盖", role: .destructive) {
                model.resolveArchiveConflict(.overwrite)
            }
            Button("跳过同名项目") {
                model.resolveArchiveConflict(.skip)
            }
            Button("取消", role: .cancel) {
                model.resolveArchiveConflict(.cancel)
            }
        } message: {
            if let request = model.archiveConflictRequest {
                if request.isCompression {
                    Text("目标位置已有“\(request.archiveName)”。覆盖会替换现有压缩文件。")
                } else {
                    Text("“\(request.archiveName)”中有 \(request.conflictCount) 个顶层项目与目标位置同名。")
                }
            }
        }
        .sheet(isPresented: $model.isConnectToServerPresented) {
            ConnectToServerSheet(
                serverAddress: $serverAddress,
                history: settings.serverConnectionHistory
            ) {
                model.connectToServer(serverAddress) { serverURL in
                    settings.expectServerConnection(to: serverURL)
                }
            } onCancel: {
                model.isConnectToServerPresented = false
            }
        }
        .sheet(isPresented: $model.isGoToFolderPresented) {
            GoToFolderSheet(
                folderPath: $manualFolderPath,
                history: settings.manualFolderHistory,
                errorMessage: manualFolderError
            ) {
                guard let folderURL = model.navigateToManualFolder(manualFolderPath) else {
                    manualFolderError = model.errorMessage ?? "找不到路径"
                    model.clearError()
                    return
                }

                settings.addManualFolderToHistory(folderURL)
                model.isGoToFolderPresented = false
            } onCancel: {
                model.isGoToFolderPresented = false
            }
        }
        .background(QuickViewWindowPresenter(
            content: $model.quickViewContent,
            colorTheme: settings.colorTheme,
            colorScheme: settings.preferredColorScheme
        ))
        .sheet(isPresented: $model.isReadmePresented) {
            ReadmeSheet {
                model.isReadmePresented = false
            }
        }
        .onChange(of: model.isGoToFolderPresented) { _, isPresented in
            guard isPresented else {
                return
            }

            manualFolderPath = model.currentURL.isFileURL ? model.currentURL.path : ""
            manualFolderError = nil
        }
        .sheet(isPresented: Binding(
            get: { model.copyConflictRequest != nil },
            set: { if !$0 { model.resolveCopyConflict(.cancel) } }
        )) {
            if let request = model.copyConflictRequest {
                TransferConflictPanel(request: request, onResolve: model.resolveCopyConflict,
                                      onRefresh: model.refreshCopyConflictComparison)
            }
        }
        .onAppear {
            model.copyQueue.maximumConcurrentCopies = settings.maximumConcurrentCopiedFiles
            model.copyQueue.historyLimit = settings.transferHistoryLimit
        }
        .onChange(of: settings.maximumConcurrentCopiedFiles) { _, maximumConcurrentCopiedFiles in
            model.copyQueue.maximumConcurrentCopies = maximumConcurrentCopiedFiles
        }
        .onChange(of: settings.transferHistoryLimit) { _, transferHistoryLimit in
            model.copyQueue.historyLimit = transferHistoryLimit
        }
        .onChange(of: model.renameRequest) { _, item in
            guard let item else {
                return
            }

            renameItem = item
            renameText = item.name
            model.clearRenameRequest()
        }
        .onChange(of: model.trashRequest) { _, items in
            guard !items.isEmpty else {
                return
            }

            itemsPendingTrash = items
            model.clearTrashRequest()
        }
        .confirmationDialog(
            deletionConfirmationTitle,
            isPresented: Binding(
                get: { !itemsPendingTrash.isEmpty },
                set: { if !$0 { itemsPendingTrash = [] } }
            )
        ) {
            Button(deletionConfirmationButtonTitle, role: .destructive) {
                guard !itemsPendingTrash.isEmpty else {
                    return
                }

                let pendingItems = itemsPendingTrash
                Task {
                    await model.deleteItems(pendingItems)
                    itemsPendingTrash = []
                }
            }

            Button("取消", role: .cancel) {
                itemsPendingTrash = []
            }
        } message: {
            if itemsPendingTrash.contains(where: model.requiresPermanentDeletion) {
                Text(deletionConfirmationMessage)
            } else if itemsPendingTrash.count == 1, let itemPendingTrash = itemsPendingTrash.first {
                Text(itemPendingTrash.name)
            } else {
                Text("已选择 \(itemsPendingTrash.count) 项")
            }
        }
        .environmentObject(model)
    }

    private var deletionConfirmationTitle: String {
        let permanentCount = itemsPendingTrash.filter(model.requiresPermanentDeletion).count
        if permanentCount == itemsPendingTrash.count, permanentCount > 0 {
            return permanentCount == 1 ? "要永久删除此项目吗？" : "要永久删除这些项目吗？"
        }
        if permanentCount > 0 {
            return "要删除所选项目吗？"
        }
        return itemsPendingTrash.count == 1 ? "要将此项目移到废纸篓吗？" : "要将这些项目移到废纸篓吗？"
    }

    private var deletionConfirmationButtonTitle: String {
        itemsPendingTrash.contains(where: model.requiresPermanentDeletion) ? "删除" : "移到废纸篓"
    }

    private var deletionConfirmationMessage: String {
        let permanentCount = itemsPendingTrash.filter(model.requiresPermanentDeletion).count
        if permanentCount == itemsPendingTrash.count {
            let name = itemsPendingTrash.first?.name ?? "所选项目"
            return "此网络卷不支持废纸篓，因此将永久删除“\(name)”。此操作无法撤销。"
        }
        return "网络卷上的项目将被永久删除，因为这些卷不支持废纸篓。其他项目将移到废纸篓。"
    }

    private var browserNavigationView: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if tabs.isSearchActive {
                SearchResultsSurface(
                    model: model,
                    renameItem: $renameItem,
                    renameText: $renameText,
                    itemsPendingTrash: $itemsPendingTrash
                )
            } else if tabs.isCopyQueueActive {
                CopyQueueView(queue: model.copyQueue)
            } else if tabs.isSpaceAnalyzerActive {
                SpaceAnalyzerView()
                    .environmentObject(tabs.spaceAnalyzerViewModel)
                    .environmentObject(tabs)
            } else {
                switch model.detailDestination {
                case .copyQueue:
                    CopyQueueView(queue: model.copyQueue)
                case .about:
                    AboutView()
                case .settings:
                    SettingsSurface()
                case .files:
                    VStack(spacing: 0) {
                        BrowserToolbar()
                        FileBrowserWorkspace(
                            renameItem: $renameItem,
                            renameText: $renameText,
                            itemsPendingTrash: $itemsPendingTrash
                        )
                        StatusBar()
                    }
                    .onKeyPress(.delete) {
                        guard model.canGoBack else {
                            return .ignored
                        }

                        model.goBack()
                        return .handled
                    }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 300, alignment: .leading)
    }


}

private struct BrowserTabStrip: View {
    @EnvironmentObject private var tabs: BrowserTabsViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.appColorTheme) private var colorTheme
    @Environment(\.colorScheme) private var colorScheme

    // Chrome-like sizing: tabs share the available width but never grow past a
    // comfortable maximum, and shrink to fit as more tabs open.
    private let maxTabWidth: CGFloat = 190
    private let tabSpacing: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = 16
            let addButtonWidth: CGFloat = 30
            let availableWidth = max(
                44,
                proxy.size.width - horizontalPadding - addButtonWidth - tabSpacing * CGFloat(max(tabs.tabs.count - 1, 0))
            )
            let tabWidth = min(maxTabWidth, availableWidth / CGFloat(max(tabs.tabs.count, 1)))

            HStack(spacing: tabSpacing) {
                ForEach(tabs.tabs) { tab in
                    if tab.id == tabs.searchTabID {
                        SearchTabButton(
                            model: tab.model,
                            isSelected: tab.id == tabs.selectedTabID,
                            width: tabWidth,
                            onSelect: { tabs.selectTab(tab.id) },
                            onClose: { tabs.closeSearch() }
                        )
                        .contextMenu {
                            Button("关闭搜索") { tabs.closeSearch() }
                        }
                    } else if tab.id == tabs.spaceAnalyzerTabID {
                        SpaceAnalyzerTabButton(
                            isSelected: tab.id == tabs.selectedTabID,
                            viewModel: tabs.spaceAnalyzerViewModel,
                            width: tabWidth,
                            tabID: tab.id,
                            onSelect: { tabs.selectTab(tab.id) },
                            onClose: { tabs.closeSpaceAnalyzer() },
                            onReorder: { draggedID in tabs.moveTab(draggedID, before: tab.id) }
                        )
                        .contextMenu {
                            Button("关闭空间分析") { tabs.closeSpaceAnalyzer() }
                        }
                    } else if tab.id == tabs.copyQueueTabID {
                        CopyQueueTabButton(
                            isSelected: tab.id == tabs.selectedTabID,
                            width: tabWidth,
                            onSelect: { tabs.selectTab(tab.id) },
                            onClose: { tabs.closeCopyQueue() }
                        )
                        .contextMenu {
                            Button("关闭传输队列") { tabs.closeCopyQueue() }
                        }
                    } else {
                        BrowserTabButton(
                            model: tab.model,
                            isSelected: tab.id == tabs.selectedTabID,
                            width: tabWidth,
                            tabID: tab.id,
                            canClose: tabs.tabs.count > 1,
                            onSelect: { tabs.selectTab(tab.id) },
                            onClose: { tabs.closeTab(tab.id) },
                            onReorder: { draggedID in tabs.moveTab(draggedID, before: tab.id) },
                            onDropFiles: { droppedURLs in
                                // Expand a single dragged URL to the full selection of whatever
                                // tab the drag originated from. Mirrors urlsExpandingSelection()
                                // used by folder-row drops.
                                let droppedStd = Set(droppedURLs.map(\.standardizedFileURL))
                                let expanded: [URL] = tabs.tabs.first(where: { t in
                                    let selStd = Set(
                                        t.model.displayedItems
                                            .filter { t.model.selectedItemIDs.contains($0.id) }
                                            .map { $0.url.standardizedFileURL }
                                    )
                                    return !selStd.isDisjoint(with: droppedStd)
                                }).map { t in
                                    t.model.displayedItems
                                        .filter { t.model.selectedItemIDs.contains($0.id) }
                                        .map(\.url)
                                } ?? droppedURLs

                                tabs.selectTab(tab.id)
                                tab.model.importItems(expanded, maximumConcurrentCopies: settings.maximumConcurrentCopiedFiles)
                            }
                        )
                        .contextMenu {
                            Button("粘贴") {
                                tabs.pasteItems(
                                    to: tab.id,
                                    maximumConcurrentCopies: settings.maximumConcurrentCopiedFiles
                                )
                            }
                            .disabled(!tabs.canPasteItems(to: tab.id))

                            Divider()

                            Button("复制标签页") {
                                tabs.duplicateTab(tab.id)
                            }
                            .keyboardShortcut("d", modifiers: [.command, .shift])

                            Divider()

                            Button("按名称排序") {
                                tabs.sortTabsByName()
                            }

                            Button("关闭重复标签页") {
                                tabs.closeDuplicateTabs()
                            }
                        }
                    }
                }

                AddTabButton(isEnabled: tabs.canAddTab) {
                    tabs.addTab()
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(ThemedBarBackground())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.separator.opacity(0.75))
                    .frame(height: 1)
            }
        }
        .frame(height: 34)
    }
}

private struct AddTabButton: View {
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(
                    (isHovering && isEnabled) ? Color.primary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .onHover { isHovering = $0 }
        .modernTooltip(isEnabled ? "新建标签页（⌘T）" : "已达到标签页数量上限")
    }
}

private struct BrowserTabButton: View {
    @ObservedObject var model: FileBrowserViewModel
    @Environment(\.appColorTheme) private var colorTheme
    @Environment(\.colorScheme) private var colorScheme
    let isSelected: Bool
    let width: CGFloat
    let tabID: UUID
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onReorder: (UUID) -> Void
    let onDropFiles: ([URL]) -> Void

    @State private var isHovering = false
    @State private var isDropTargeted = false
    @State private var springLoadTask: Task<Void, Never>?

    private let cornerRadius: CGFloat = 10

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    if width >= 62 {
                        Image(systemName: model.isBrowsingNetwork ? "network" : "folder.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .symbolRenderingMode(.hierarchical)
                    }

                    Text(model.tabTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TabCloseButton(isEnabled: canClose, action: onClose)
        }
        .padding(.leading, max(7, min(11, width / 12)))
        .padding(.trailing, 5)
        .frame(width: width, height: 26, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background(tabBackground, in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(borderStyle, lineWidth: isDropTargeted ? 2 : 1)
        }
        .shadow(color: isSelected ? .black.opacity(0.12) : .clear, radius: 3, y: 1)
        .animation(.easeOut(duration: 0.13), value: isHovering)
        .animation(.easeOut(duration: 0.13), value: isSelected)
        .animation(.easeOut(duration: 0.13), value: isDropTargeted)
        .onHover { isHovering = $0 }
        .draggable(tabID.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            guard let identifier = ids.first, let uuid = UUID(uuidString: identifier) else {
                return false
            }

            onReorder(uuid)
            return true
        }
        // dropDestination(for: URL.self) only matches SwiftUI Transferable-encoded
        // drags. NSTableView puts files on the pasteboard using AppKit conventions
        // (public.file-url / NSFilenamesPboardType). onDrop registers as a full
        // NSDraggingDestination and accepts those types correctly.
        .onDrop(of: [.fileURL, .url], isTargeted: $isDropTargeted) { providers in
            cancelSpringLoad()
            Task { @MainActor in
                let urls = await loadDroppedURLs(from: providers)
                guard !urls.isEmpty else { return }
                onSelect()
                onDropFiles(urls)
            }
            return !providers.isEmpty
        }
        .onChange(of: isDropTargeted) { _, targeted in
            if targeted { scheduleSpringLoad() } else { cancelSpringLoad() }
        }
        .modernTooltip(model.currentLocationText)
    }

    /// Loads file URLs from the NSItemProviders supplied by the drop session.
    private func loadDroppedURLs(from providers: [NSItemProvider]) async -> [URL] {
        var result: [URL] = []
        for provider in providers {
            guard provider.canLoadObject(ofClass: NSURL.self) else { continue }
            let url: URL? = await withCheckedContinuation { cont in
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    cont.resume(returning: (object as? NSURL) as URL?)
                }
            }
            if let url { result.append(url) }
        }
        return result
    }

    // Chrome-style spring loading: hovering a dragged file over a tab switches
    // to it after a short delay so items can be dropped into that folder.
    private func scheduleSpringLoad() {
        springLoadTask?.cancel()
        springLoadTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else {
                return
            }

            onSelect()
        }
    }

    private func cancelSpringLoad() {
        springLoadTask?.cancel()
        springLoadTask = nil
    }

    private var borderStyle: AnyShapeStyle {
        if isDropTargeted {
            return AnyShapeStyle(colorTheme.tintColor)
        }

        if isSelected {
            return AnyShapeStyle(Color(nsColor: .separatorColor).opacity(0.7))
        }

        return AnyShapeStyle(Color.clear)
    }

    private var tabBackground: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(colorTheme.surfaceTint(for: colorScheme, intensity: 1.5))
        }

        if isHovering {
            return AnyShapeStyle(Color.primary.opacity(0.09))
        }

        return AnyShapeStyle(Color.clear)
    }
}

private struct TabCloseButton: View {
    let isEnabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 17, height: 17)
                .background(
                    isHovering && isEnabled ? Color.primary.opacity(0.12) : .clear,
                    in: Circle()
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(isEnabled ? .secondary : .quaternary)
        .onHover { isHovering = $0 }
        .accessibilityLabel("关闭标签页")
        .modernTooltip(isEnabled ? "关闭标签页" : "至少保留一个标签页")
    }
}

private struct SpaceAnalyzerTabButton: View {
    @Environment(\.appColorTheme) private var colorTheme
    let isSelected: Bool
    @ObservedObject var viewModel: SpaceAnalyzerViewModel
    let width: CGFloat
    let tabID: UUID
    let onSelect: () -> Void
    let onClose: () -> Void
    let onReorder: (UUID) -> Void

    @State private var isHovering = false
    private let cornerRadius: CGFloat = 10
    private var isScanning: Bool { viewModel.isScanning }
    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    if isScanning {
                        ProgressView().controlSize(.mini).frame(width: 11, height: 11)
                    } else if width >= 62 {
                        SpaceAnalyzerIcon(size: 11)
                    }
                    Text(isScanning ? "正在扫描…" : "空间分析")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TabCloseButton(isEnabled: true, action: onClose)
        }
        .padding(.leading, max(7, min(11, width / 12)))
        .padding(.trailing, 5)
        .frame(width: width, height: 26, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background(tabBackground, in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(borderStyle, lineWidth: isSelected ? 1 : 0.5)
        }
        .shadow(color: isSelected ? .black.opacity(0.12) : .clear, radius: 3, y: 1)
        .animation(.easeOut(duration: 0.13), value: isHovering)
        .animation(.easeOut(duration: 0.13), value: isSelected)
        .onHover { isHovering = $0 }
        .draggable(tabID.uuidString)
        .dropDestination(for: String.self) { ids, _ in
            guard let identifier = ids.first, let uuid = UUID(uuidString: identifier) else { return false }
            onReorder(uuid)
            return true
        }
    }

    private var tabBackground: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(colorTheme.tintColor.opacity(0.18)) }
        if isHovering { return AnyShapeStyle(colorTheme.tintColor.opacity(0.09)) }
        return AnyShapeStyle(Color.clear)
    }

    private var borderStyle: AnyShapeStyle {
        isSelected ? AnyShapeStyle(colorTheme.tintColor.opacity(0.5)) : AnyShapeStyle(Color.clear)
    }
}

private struct SearchTabButton: View {
    @Environment(\.appColorTheme) private var colorTheme
    @ObservedObject var model: FileBrowserViewModel
    let isSelected: Bool
    let width: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    private var title: String {
        let query = model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? "搜索" : "搜索：\(query)"
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    if model.isSearching {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 11, height: 11)
                    } else if width >= 62 {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TabCloseButton(isEnabled: true, action: onClose)
        }
        .padding(.leading, max(7, min(11, width / 12)))
        .padding(.trailing, 5)
        .frame(width: width, height: 26, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background(
            isSelected ? colorTheme.tintColor.opacity(0.18) :
                (isHovering ? colorTheme.tintColor.opacity(0.09) : Color.clear),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? colorTheme.tintColor.opacity(0.5) : Color.clear, lineWidth: 1)
        }
        .onHover { isHovering = $0 }
    }
}

private struct CopyQueueTabButton: View {
    @Environment(\.appColorTheme) private var colorTheme
    let isSelected: Bool
    let width: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    if width >= 62 {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text("传输队列")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TabCloseButton(isEnabled: true, action: onClose)
        }
        .padding(.leading, max(7, min(11, width / 12)))
        .padding(.trailing, 5)
        .frame(width: width, height: 26, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .background(
            isSelected ? colorTheme.tintColor.opacity(0.18) :
                (isHovering ? colorTheme.tintColor.opacity(0.09) : Color.clear),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? colorTheme.tintColor.opacity(0.5) : Color.clear, lineWidth: 1)
        }
        .onHover { isHovering = $0 }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: FileBrowserViewModel
    @EnvironmentObject private var tabs: BrowserTabsViewModel
    @Environment(\.appColorTheme) private var colorTheme
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("sidebar.favoritesExpanded") private var favoritesExpanded = true
    @AppStorage("sidebar.networkExpanded") private var networkExpanded = true
    private let copyQueueSelectionID = "maxplorer://copy-queue"
    private let spaceAnalyzerSelectionID = "maxplorer://space-analyzer"

    var body: some View {
        let locations = model.sidebarLocations
        VStack(spacing: 0) {
            List(selection: Binding<String?>(
            get: {
                if tabs.isSearchActive { return nil }
                if tabs.isSpaceAnalyzerActive { return spaceAnalyzerSelectionID }
                if tabs.isCopyQueueActive { return copyQueueSelectionID }
                switch model.detailDestination {
                case .copyQueue: return copyQueueSelectionID
                case .settings, .about: return nil
                case .files: return model.currentURL.absoluteString
                }
            },
            set: { selection in
                guard let selection else {
                    return
                }

                // List can write its selection during a view update; defer so the
                // navigation's @Published changes land outside that update.
                Task { @MainActor in
                    switch selection {
                    case spaceAnalyzerSelectionID:
                        tabs.openSpaceAnalyzer()
                    case copyQueueSelectionID:
                        tabs.showCopyQueue()
                    default:
                        if let url = URL(string: selection) {
                            tabs.browseLocation(url)
                        }
                    }
                }
            }
        )) {
            Section(isExpanded: $favoritesExpanded) {
                ForEach(locations.filter { $0.group == .favorites }) { location in
                    Label(location.name, systemImage: location.systemImage)
                        .sidebarHover()
                        .tag(location.url.absoluteString)
                        .contextMenu {
                            if location.url.isFileURL {
                                Button("分析所选文件夹的空间占用") {
                                    tabs.openSpaceAnalyzer(url: location.url)
                                }
                                Divider()
                            }
                            if location.canRemoveFromFavorites {
                                Button("从个人收藏移除") {
                                    model.removeFavorite(location.url)
                                }
                            }
                        }
                        .draggable(location.url)
                        .dropDestination(for: URL.self) { urls, _ in
                            _ = handleFavoriteDrop(urls, before: location)
                        }
                }
            } header: {
                Text(SidebarLocation.Group.favorites.displayName)
            }
            .dropDestination(for: URL.self) { urls, _ in
                _ = model.pinDroppedFavorites(urls)
            }

            if locations.contains(where: { $0.group == .devices }) {
                Section(SidebarLocation.Group.devices.displayName) {
                    ForEach(locations.filter { $0.group == .devices }) { location in
                        Label(location.name, systemImage: location.systemImage)
                            .sidebarHover()
                            .tag(location.url.absoluteString)
                            .contextMenu {
                                if location.url.isFileURL {
                                    Button("分析所选文件夹的空间占用") {
                                        tabs.openSpaceAnalyzer(url: location.url)
                                    }
                                }
                            }
                    }
                }
            }

            Section("浏览") {
                Button {
                    model.isRecentFilesPresented = true
                } label: {
                    Label("最近文件…", systemImage: "clock")
                }
                .buttonStyle(.plain)
                .sidebarHover()
            }

            Section("目录树") {
                DirectoryTreeView(
                    selectedURL: !tabs.isSearchActive && !tabs.isSpaceAnalyzerActive &&
                        !tabs.isCopyQueueActive && model.detailDestination == .files ? model.currentURL : nil,
                    showHiddenFiles: model.showHiddenFiles,
                    onNavigate: tabs.browseLocation,
                    onOpenInNewTab: tabs.openLocationInNewTab,
                    onDrop: { urls, destination in model.moveItems(urls, to: destination) }
                )
            }

            Section("磁盘") {
                Button {
                    tabs.openSpaceAnalyzer()
                } label: {
                    HStack(spacing: 6) {
                        SpaceAnalyzerIcon(size: 15)
                        Text("空间分析")
                    }
                }
                .buttonStyle(.plain)
                .sidebarHover()
                .tag(spaceAnalyzerSelectionID)

                CopyQueueSidebarRow(queue: model.copyQueue)
                    .tag(copyQueueSelectionID)
            }

            Section(isExpanded: $networkExpanded) {
                Button {
                    model.showConnectToServer()
                } label: {
                    Label("连接服务器", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)

                ForEach(locations.filter { $0.group == .network }) { location in
                    Label(location.name, systemImage: location.systemImage)
                        .sidebarHover()
                        .tag(location.url.absoluteString)
                }
            } header: {
                Text(SidebarLocation.Group.network.displayName)
            }

            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            VStack(spacing: 2) {
                SidebarDockedButton(
                    title: "设置",
                    systemImage: "gearshape",
                    isSelected: !tabs.isSpaceAnalyzerActive && model.detailDestination == .settings,
                    usesAccentColor: false,
                    action: tabs.showSettings
                )

                SidebarDockedButton(
                    title: "关于",
                    systemImage: "info.circle",
                    isSelected: !tabs.isSpaceAnalyzerActive && model.detailDestination == .about,
                    usesAccentColor: true,
                    action: tabs.showAbout
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
        }
        .symbolRenderingMode(.hierarchical)
        .background(ThemedBarBackground())
    }

    private func handleFavoriteDrop(_ urls: [URL], before location: SidebarLocation) -> Bool {
        var didHandle = false

        for url in urls {
            if model.isPinnedFavorite(url) {
                model.moveFavorite(url, before: location.url)
            } else {
                model.pinFavorite(url)
            }

            didHandle = true
        }

        return didHandle
    }
}

private struct SidebarDockedButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let usesAccentColor: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .padding(.vertical, 5)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .foregroundStyle(usesAccentColor ? Color.blue : Color.primary)
        .background {
            if isSelected || isHovering {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(isSelected ? 0.12 : 0.07))
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

private struct CopyQueueSidebarRow: View {
    @ObservedObject var queue: CopyQueueViewModel

    var body: some View {
        ZStack(alignment: .leading) {
            if queue.hasActiveOperations {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.accentColor.opacity(0.22))
                        .frame(width: proxy.size.width * queue.overallProgress)
                }
                .allowsHitTesting(false)
            }

            HStack(spacing: 8) {
                Label("传输队列", systemImage: "doc.on.clipboard")

                Spacer(minLength: 8)

                if queue.hasActiveOperations {
                    Text(queue.overallProgress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 5)
        }
        .frame(minHeight: 24)
        .contentShape(Rectangle())
        .animation(.linear(duration: 0.15), value: queue.overallProgress)
        .accessibilityValue(queue.hasActiveOperations ? queue.overallProgress.formatted(.percent) : "")
    }
}

private struct BrowserToolbar: View {
    @EnvironmentObject private var model: FileBrowserViewModel
    @EnvironmentObject private var tabs: BrowserTabsViewModel
    @EnvironmentObject private var settings: AppSettings
    @FocusState private var pathFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ToolbarButtonGroup {
                    ToolbarIconButton(
                        systemName: "chevron.backward",
                        help: "返回上一个文件夹（⌘[）",
                        isDisabled: !model.canGoBack
                    ) {
                        model.goBack()
                    }

                    ToolbarIconButton(
                        systemName: "chevron.forward",
                        help: "前往下一个文件夹（⌘]）",
                        isDisabled: !model.canGoForward
                    ) {
                        model.goForward()
                    }

                    ToolbarIconButton(
                        systemName: "arrow.up.to.line.compact",
                        help: "前往上一级文件夹（⌘↑）",
                        isDisabled: !model.canGoUp
                    ) {
                        model.goUp()
                    }

                    ToolbarIconButton(
                        systemName: "arrow.clockwise",
                        help: "刷新当前文件夹（⌘R）"
                    ) {
                        model.reload()
                    }
                }

                ToolbarButtonGroup {
                    ToolbarIconButton(
                        systemName: "folder.badge.plus",
                        help: "在当前文件夹中新建文件夹（⌘⇧N）",
                        isDisabled: !model.canCreateFolder
                    ) {
                        Task { await model.createFolder() }
                    }

                    ToolbarIconButton(
                        systemName: "terminal",
                        help: "在当前文件夹打开终端（⌘⇧T）"
                    ) {
                        model.openCurrentFolderInTerminal()
                    }

                    ToolbarToggleButton(
                        systemName: "terminal.fill",
                        help: model.isIntegratedTerminalPresented ? "关闭内置终端（⌃`）" : "打开内置终端（⌃`）",
                        isOn: $model.isIntegratedTerminalPresented
                    )

                    ToolbarIconButton(
                        systemName: "arrow.up.forward.square",
                        help: "在访达中显示所选项目（⌃⌘R）"
                    ) {
                        model.revealSelectedInFinder()
                    }
                }

                ToolbarButtonGroup {
                    ToolbarIconButton(
                        systemName: "network.badge.shield.half.filled",
                        help: "连接网络服务器（⌘K）"
                    ) {
                        model.showConnectToServer()
                    }
                }

                ToolbarButtonGroup {
                    Button {
                        tabs.openSpaceAnalyzer(url: model.currentURL.isFileURL ? model.currentURL : nil)
                    } label: {
                        SpaceAnalyzerIcon(size: 14)
                            .frame(width: 26, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .modernTooltip("分析磁盘空间占用")
                }

                ToolbarButtonGroup {
                    ToolbarIconButton(
                        systemName: "magnifyingglass",
                        help: "搜索文件（⌘⇧F）",
                        isDisabled: !model.canSearch
                    ) {
                        tabs.openSearch(scopeRoot: model.currentURL)
                    }

                    ToolbarToggleButton(
                        systemName: "eye.fill",
                        help: tabs.showHiddenFiles ? "隐藏隐藏文件（⌘⇧.）" : "显示隐藏文件（⌘⇧.）",
                        isOn: $tabs.showHiddenFiles
                    )

                    ToolbarToggleButton(
                        systemName: "a.square.fill",
                        help: tabs.showAliases ? "隐藏替身（⌘⇧A）" : "显示替身（⌘⇧A）",
                        isOn: $tabs.showAliases,
                        iconSize: 22
                    )
                }

                ToolbarButtonGroup {
                    BrowserPresentationMenu(model: model)
                    Menu {
                        Section("显示列") {
                            ForEach(FileColumn.allCases) { column in
                                Toggle(column.title, isOn: Binding(
                                    get: { settings.visibleColumns.contains(column) },
                                    set: { _ in settings.toggleColumn(column) }
                                ))
                                .disabled(column.isRequired)
                            }
                        }

                        Divider()

                        Button("重置列") {
                            settings.resetColumns()
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 26, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .modernTooltip("选择要显示的列，也可右键点击列标题")
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                    FilterTextField(
                        text: $model.filterText,
                        placeholder: "筛选当前文件夹",
                        proxy: model.filterFocusProxy
                    )
                    .frame(minWidth: 160, idealWidth: 220, maxWidth: 220)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
                .layoutPriority(1)
                .modernTooltip("筛选当前文件夹中显示的项目")
            }
            .symbolRenderingMode(.hierarchical)
            }

            HStack(spacing: 8) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .foregroundStyle(.secondary)

                TextField("路径", text: $model.pathText)
                    .textFieldStyle(.plain)
                    .focused($pathFocused)
                    .onSubmit {
                        model.submitPath()
                    }

                Button {
                    model.copySelectedPath()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .modernTooltip("复制所选项目的路径；未选择项目时复制当前文件夹路径（⌘⌥C）")
            }
            .symbolRenderingMode(.hierarchical)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .background(ThemedBarBackground())
        .onExitCommand {
            pathFocused = false
        }
    }
}

private struct SearchResultsSurface: View {
    @ObservedObject var model: FileBrowserViewModel
    @Binding var renameItem: FileItem?
    @Binding var renameText: String
    @Binding var itemsPendingTrash: [FileItem]

    var body: some View {
        VStack(spacing: 0) {
            SearchToolbar(model: model)
            SearchConditionsBar(model: model)
            FileTableView(
                renameItem: $renameItem,
                renameText: $renameText,
                itemsPendingTrash: $itemsPendingTrash
            )
            StatusBar()
        }
        .environmentObject(model)
    }
}

private struct SearchToolbar: View {
    @ObservedObject var model: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 10) {
            BrowserPresentationMenu(model: model)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                FilterTextField(
                    text: $model.searchQuery,
                    placeholder: model.searchMode.placeholder,
                    proxy: model.searchFocusProxy
                )
                .frame(minWidth: 180, idealWidth: 300, maxWidth: .infinity)
                .accessibilityLabel("搜索文件名")

                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                        model.focusSearchField()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .modernTooltip("清除搜索")
                    .accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))

            Picker("范围", selection: $model.searchScope) {
                ForEach(SearchScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 112)
            .modernTooltip(model.searchScope.description)
            .accessibilityLabel("搜索范围")

            Picker("匹配", selection: $model.searchMode) {
                ForEach(SearchMatchMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 88)
            .accessibilityLabel("搜索匹配方式")

            if model.isSearching {
                Button("取消搜索") {
                    model.cancelSearch()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("停止搜索并保留已找到的结果")
            }

            ToolbarIconButton(systemName: "arrow.clockwise", help: "重新搜索") {
                model.reload()
            }

            Spacer(minLength: 8)

            SearchStatusView(model: model)
        }
        .padding(12)
        .background(ThemedBarBackground())
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                model.focusSearchField()
            }
        }
    }
}

private struct SearchStatusView: View {
    @ObservedObject var model: FileBrowserViewModel

    private var hasQuery: Bool { model.hasSearchCriteria }

    var body: some View {
        HStack(spacing: 8) {
            if let error = model.searchErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if model.isSearching {
                ProgressView()
                    .controlSize(.small)
                Text("\(model.searchUsesIndex ? "已核对索引候选" : "已扫描") \(model.searchScannedCount) 项，找到 \(model.displayedItems.count) 项")
            } else if hasQuery {
                Text("\(model.displayedItems.count) 项")
            } else {
                Text("输入名称或设置筛选条件")
            }
            if model.searchSkippedCount > 0 {
                Text("跳过 \(model.searchSkippedCount) 项")
                    .foregroundStyle(.secondary)
                    .help("路径不符合当前范围/可见性规则，或目录及元数据不可读取")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("searchStatus")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

private struct CopyQueueView: View {
    @ObservedObject var queue: CopyQueueViewModel
    @EnvironmentObject private var tabs: BrowserTabsViewModel
    @State private var pendingRetryItem: CopyQueueItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("传输队列")
                    .font(.headline)

                if queue.isPaused {
                    Text("已暂停")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Spacer()

                if queue.failedCount > 0 {
                    Button("重试失败项（\(queue.failedCount)）") {
                        queue.retryAllFailed()
                    }
                    .controlSize(.small)
                }

                Button(queue.isPaused ? "继续" : "暂停") {
                    if queue.isPaused {
                        queue.resume()
                    } else {
                        queue.pause()
                    }
                }
                .controlSize(.small)
                .disabled(queue.isPaused ? !queue.canResume : !queue.canPause)

                Text(queue.isPaused ? "\(queue.activeCopyCount) 项未完成（停止新任务调度）" : "\(queue.activeCopyCount) 项未完成")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(16)
            .background(ThemedBarBackground())

            if queue.items.isEmpty && queue.history.isEmpty {
                ContentUnavailableView(
                    "暂无传输任务",
                    systemImage: "doc.on.clipboard",
                    description: Text("正在进行的传输和已完成的记录会显示在这里。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !queue.items.isEmpty {
                        Section("任务") {
                            ForEach(queue.items) { item in
                                CopyQueueRow(
                                    item: item,
                                    isPaused: queue.isPaused,
                                    onOpenDestination: {
                                        tabs.openOrSelectLocation(item.destinationURL.deletingLastPathComponent())
                                    },
                                    onCancel: { queue.cancel(item.id) },
                                    onPause: { queue.pauseItem(item.id) },
                                    onResume: { queue.resumeItem(item.id) },
                                    onRetry: {
                                        pendingRetryItem = item
                                    },
                                    onDismiss: { queue.dismiss(item.id) }
                                )
                                .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                            }
                        }
                    }

                    if !queue.history.isEmpty {
                        Section("历史记录") {
                            ForEach(queue.history) { item in
                                CopyQueueHistoryRow(item: item)
                                    .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14))
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(item: $pendingRetryItem) { item in
            CopyRetryConflictSheet(queue: queue, item: item) { pendingRetryItem = nil }
        }
    }
}

private struct CopyQueueHistoryRow: View {
    let item: CopyQueueHistoryItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.operation == .move ? "arrow.right.doc.on.clipboard" : "doc.on.doc")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(item.destinationURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(item.operation == .move ? "已移动" : "已复制")
                Text(item.completedAt, style: .time)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CopyQueueRow: View {
    let item: CopyQueueItem
    let isPaused: Bool
    let onOpenDestination: () -> Void
    let onCancel: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(stateText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button(action: onOpenDestination) {
                        Text(destinationFolderURL.path)
                            .font(.caption)
                            .underline()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.link)
                    .help(destinationFolderURL.path)
                }

                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)

                HStack(spacing: 12) {
                    Text(speedText)
                    Text(etaText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }

            Spacer(minLength: 8)

            if item.state == .running {
                switch item.transferPhase {
                case .transferring:
                    Button("暂停此项", action: onPause).buttonStyle(.borderless).controlSize(.small)
                case .pauseRequested, .paused:
                    Button("继续此项", action: onResume).buttonStyle(.borderless).controlSize(.small)
                case .finalizing, .cancelling, .finished:
                    EmptyView()
                }
            }
            if item.state.canRetry {
                HStack(spacing: 8) {
                    Button("重试", action: onRetry)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .modernTooltip("重新执行此传输")

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .modernTooltip("从队列中移除此记录")
                }
            } else {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!item.state.isActive)
                .foregroundStyle(item.state.isActive ? .secondary : .tertiary)
                .modernTooltip("取消此传输任务")
            }
        }
    }

    private var stateText: String {
        switch item.state {
        case .pending:
            return isPaused ? "已暂停" : "等待中"
        case .running:
            switch item.transferPhase {
            case .pauseRequested: return "正在暂停…"
            case .paused: return "此项已暂停（仅本次运行可继续）"
            case .finalizing: return "正在完成"
            case .cancelling: return "正在取消…"
            case .finished: return "正在收尾"
            case .transferring: return item.operation == .move ? "正在移动" : "正在复制"
            }
        case .completed:
            return "已完成"
        case .failed(let reason):
            return "已中止：\(reason)"
        case .cancelled:
            return "已取消"
        }
    }

    private var destinationFolderURL: URL {
        item.destinationURL.deletingLastPathComponent()
    }

    private var speedText: String {
        guard item.state == .running, item.transferPhase == .transferring, item.bytesPerSecond > 0 else {
            return "速度 --"
        }

        return "\(Self.byteFormatter.string(fromByteCount: Int64(item.bytesPerSecond))) /s"
    }

    private var etaText: String {
        guard let estimatedSecondsRemaining = item.estimatedSecondsRemaining else {
            return "预计剩余 --"
        }

        return "预计剩余 \(Self.durationFormatter.string(from: estimatedSecondsRemaining) ?? "--")"
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}

private struct SettingsSurface: View {
    @EnvironmentObject private var model: FileBrowserViewModel
    @Environment(\.appColorTheme) private var colorTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 10) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(colorTheme.tintColor)

                    Text("设置")
                        .font(.system(size: 30, weight: .bold, design: .rounded))

                    Text("调整外观、标签页和文件传输设置。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                SettingsView()
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))

                Button {
                    model.dismissAuxiliaryDetail()
                } label: {
                    Text("确定")
                        .font(.headline)
                        .frame(minWidth: 72)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [colorTheme.backdropTint(for: colorScheme), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }
}

private struct ToolbarButtonGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(4)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ToolbarIconButton: View {
    let systemName: String
    let help: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? .tertiary : .primary)
        .disabled(isDisabled)
        .modernTooltip(help)
    }
}

private struct ToolbarToggleButton: View {
    let systemName: String
    let help: String
    @Binding var isOn: Bool
    var iconSize: CGFloat = 14

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isOn ? Color.accentColor.opacity(0.22) : .clear)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? Color.accentColor : .primary)
        .modernTooltip(help)
    }
}

private struct ModernTooltipModifier: ViewModifier {
    let text: String
    var usesCursorPosition: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @State private var isPresented = false
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                hoverTask?.cancel()

                if hovering {
                    hoverTask = Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled else {
                            return
                        }

                        await MainActor.run {
                            if isHovering {
                                isPresented = true
                            }
                        }
                    }
                } else {
                    isPresented = false
                }
            }
            .background(
                TooltipAnchorView(
                    text: text,
                    isPresented: isPresented,
                    colorScheme: colorScheme,
                    usesCursorPosition: usesCursorPosition
                )
            )
    }
}

private struct TooltipAnchorView: NSViewRepresentable {
    let text: String
    let isPresented: Bool
    let colorScheme: ColorScheme
    var usesCursorPosition: Bool = false

    func makeNSView(context: Context) -> TooltipAnchorNSView {
        TooltipAnchorNSView()
    }

    func updateNSView(_ nsView: TooltipAnchorNSView, context: Context) {
        nsView.update(text: text, isPresented: isPresented, colorScheme: colorScheme,
                      usesCursorPosition: usesCursorPosition)
    }
}

private final class TooltipAnchorNSView: NSView {
    private var text = ""
    private var isPresented = false
    private var colorScheme: ColorScheme = .light
    private var usesCursorPosition = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTooltipVisibility()
    }

    func update(text: String, isPresented: Bool, colorScheme: ColorScheme, usesCursorPosition: Bool) {
        self.text = text
        self.isPresented = isPresented
        self.colorScheme = colorScheme
        self.usesCursorPosition = usesCursorPosition
        updateTooltipVisibility()
    }

    private func updateTooltipVisibility() {
        guard isPresented, window != nil else {
            TooltipWindowPresenter.shared.hide(anchor: self)
            return
        }

        TooltipWindowPresenter.shared.show(text: text, anchor: self, colorScheme: colorScheme,
                                           usesCursorPosition: usesCursorPosition)
    }
}

@MainActor
private final class TooltipWindowPresenter {
    static let shared = TooltipWindowPresenter()

    private var panel: NSPanel?
    private weak var currentAnchor: NSView?
    // Set when a right-click dismisses the tooltip. Blocks re-presentation
    // (SwiftUI's isPresented is still true, so updateNSView would otherwise call
    // show() again right on top of the context menu) until the pointer leaves the
    // anchor and a fresh hover begins.
    private var isSuppressed = false

    private init() {
        // A right-click opens a context menu; dismiss any visible tooltip first
        // so the two don't overlap. The panel ignores mouse events, so we watch
        // the event stream globally rather than hit-testing the panel itself.
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            self?.dismiss()
            return event
        }
    }

    /// Force-hides the current tooltip and suppresses re-presentation.
    func dismiss() {
        panel?.orderOut(nil)
        currentAnchor = nil
        isSuppressed = true
    }

    func show(text: String, anchor: NSView, colorScheme: ColorScheme, usesCursorPosition: Bool = false) {
        guard !isSuppressed else { return }
        currentAnchor = anchor

        let rootView = TooltipBubble(text: text)
            .environment(\.colorScheme, colorScheme)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.setFrameSize(hostingView.fittingSize)

        let panel = panel ?? makePanel()
        panel.contentView = hostingView

        let panelSize = hostingView.fittingSize
        let origin: NSPoint
        if usesCursorPosition {
            let cursor = NSEvent.mouseLocation
            let screenBounds = NSScreen.screens.first(where: { $0.frame.contains(cursor) })?.visibleFrame
                ?? NSScreen.main?.visibleFrame ?? .zero
            let rawX = cursor.x + 14
            let rawY = cursor.y - panelSize.height - 10
            origin = NSPoint(
                x: min(rawX, screenBounds.maxX - panelSize.width - 4),
                y: max(rawY, screenBounds.minY + 4)
            )
        } else {
            let screenFrame = anchor.window?.convertToScreen(anchor.convert(anchor.bounds, to: nil)) ?? .zero
            origin = NSPoint(
                x: screenFrame.midX - (panelSize.width / 2),
                y: screenFrame.maxY + 8
            )
        }

        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func hide(anchor: NSView) {
        // A hover-exit lifts the right-click suppression so later hovers work.
        isSuppressed = false

        guard currentAnchor === anchor else {
            return
        }

        panel?.orderOut(nil)
        currentAnchor = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        return panel
    }
}

private struct TooltipBubble: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(foregroundColor)
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 360)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.28), radius: 14, y: 7)
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .textColor)
    }

    private var foregroundColor: Color {
        colorScheme == .dark ? Color(nsColor: .labelColor) : Color(nsColor: .windowBackgroundColor)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color(nsColor: .separatorColor) : Color(nsColor: .separatorColor).opacity(0.75)
    }
}

extension View {
    func modernTooltip(_ text: String) -> some View {
        modifier(ModernTooltipModifier(text: text))
    }

    /// Like modernTooltip but positions the popup at the current cursor location
    /// rather than above the anchor view — suited for large tiles and map surfaces.
    func tileTooltip(_ text: String) -> some View {
        modifier(ModernTooltipModifier(text: text, usesCursorPosition: true))
    }

    func sidebarHover() -> some View {
        modifier(SidebarHoverModifier())
    }
}

/// A subtle glass hover highlight for sidebar rows.
private struct SidebarHoverModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isHovering {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.thinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.primary.opacity(0.05))
                        }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 10) {
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("正在载入")
            } else {
                if model.selectedItems.isEmpty {
                    Text("共 \(model.items.count) 项，显示 \(model.displayedItems.count) 项")
                } else if let selectedFileSize = model.selectedFileSize {
                    Text("已选择 \(model.selectedItems.count) 项 • \(ByteCountFormatter.string(fromByteCount: selectedFileSize, countStyle: .file))")
                } else {
                    Text("已选择 \(model.selectedItems.count) 项")
                }
            }

          //  Spacer()

            if let stats = model.volumeStats {
                let freePercent = Int((Double(stats.free) / Double(stats.total) * 100).rounded())
                HStack(spacing: 12) {
                    Label(
                        "已用：\(ByteCountFormatter.string(fromByteCount: Int64(stats.used), countStyle: .file))",
                        systemImage: "internaldrive"
                    )
                    Text("可用：\(ByteCountFormatter.string(fromByteCount: Int64(stats.free), countStyle: .file))（\(freePercent)%）")
                        .foregroundStyle(freePercent < 10 ? .red : .secondary)
                }
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .font(.footnote)
        .padding(.horizontal, 26)
        .padding(.vertical, 7)
        .background(ThemedBarBackground())
    }
}

struct TableCellClickTarget: NSViewRepresentable {
    let onSelect: (SelectionMode) -> Void
    let onOpen: () -> Void
    let onLongPress: () -> Void
    var isSelected = false
    var dragURLs: () -> [URL] = { [] }
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> TableCellClickTargetNSView {
        let view = TableCellClickTargetNSView()
        view.onSelect = onSelect
        view.onOpen = onOpen
        view.onLongPress = onLongPress
        view.isSelected = isSelected
        view.dragURLs = dragURLs
        view.onFocus = onFocus
        return view
    }

    func updateNSView(_ nsView: TableCellClickTargetNSView, context: Context) {
        nsView.onSelect = onSelect
        nsView.onOpen = onOpen
        nsView.onLongPress = onLongPress
        nsView.isSelected = isSelected
        nsView.dragURLs = dragURLs
        nsView.onFocus = onFocus
    }
}

struct FileItemIcon: View {
    let item: FileItem
    let folderIconStyle: FolderIconStyle
    let allowsTagLoading: Bool
    let size: CGFloat
    @State private var tagColors: [FinderTagColor]
    @State private var icon: NSImage?

    init(item: FileItem, folderIconStyle: FolderIconStyle, allowsTagLoading: Bool, size: CGFloat = 20) {
        self.item = item
        self.folderIconStyle = folderIconStyle
        self.allowsTagLoading = allowsTagLoading
        self.size = size
        _tagColors = State(initialValue: item.tagColors)
        _icon = State(initialValue: FileIconCache.cachedIcon(for: item))
    }

    private var isPlainFolder: Bool {
        item.isDirectory && !item.isPackage
    }

    private var iconRequestID: String {
        let modified = item.modifiedAt?.timeIntervalSinceReferenceDate ?? 0
        return "\(item.url.path)|\(modified)|\(folderIconStyle.rawValue)"
    }

    var body: some View {
        Group {
            if item.isNetworkLocation {
                Image(systemName: "server.rack")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.mint)
                    .font(.system(size: size * 0.75, weight: .semibold))
            } else if item.isDirectory && folderIconStyle == .xplorer {
                Image(systemName: "folder.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.yellow)
                    .font(.system(size: size * 0.85, weight: .medium))
            } else if isPlainFolder && !tagColors.isEmpty {
                Image(nsImage: FileIconCache.plainFolderIcon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(nsImage: icon ?? (item.isDirectory ? FileIconCache.plainFolderIcon : FileIconCache.placeholderIcon))
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: isPlainFolder ? .center : .bottomTrailing) {
            if !tagColors.isEmpty {
                FinderTagDots(colors: tagColors)
                    // Sit inside the folder's body, just below the tab.
                    .offset(x: isPlainFolder ? 0 : 2, y: 2)
            }
        }
        .task(id: item.id) {
            guard allowsTagLoading, tagColors.isEmpty else {
                return
            }

            let colors = await FinderTagLoader.colors(for: item.url)
            guard !Task.isCancelled else {
                return
            }
            tagColors = colors
        }
        .task(id: iconRequestID) {
            guard !(item.isDirectory && folderIconStyle == .xplorer),
                  !(isPlainFolder && !tagColors.isEmpty) else {
                return
            }

            if let cached = FileIconCache.cachedIcon(for: item) {
                icon = cached
                return
            }

            icon = nil
            let loaded = await FileIconCache.loadIcon(for: item)
            guard !Task.isCancelled else {
                return
            }
            icon = loaded
        }
        .onChange(of: item.id) { _, _ in
            tagColors = item.tagColors
            icon = FileIconCache.cachedIcon(for: item)
        }
    }
}

/// Finder-style overlapping tag dots, drawn inside the item's icon instead of
/// tinting the whole folder.
private struct FinderTagDots: View {
    let colors: [FinderTagColor]

    var body: some View {
        HStack(spacing: -3) {
            ForEach(colors, id: \.self) { tagColor in
                Circle()
                    .fill(tagColor.color)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
        .accessibilityLabel("已添加标签")
    }
}

/// NSWorkspace returns the exact same icon Finder shows: correct type-specific
/// icons for documents, apps, aliases (with arrow badge), packages, and all
/// folder variants. Cache hits are synchronous; misses load off the main actor
/// so a network or launch-services lookup cannot stall row rendering.
@MainActor
private enum FileIconCache {
    static let plainFolderIcon = NSWorkspace.shared.icon(for: .folder)
    static let placeholderIcon = NSWorkspace.shared.icon(for: .data)

    static func cachedIcon(for item: FileItem) -> NSImage? {
        FileIconStore.shared.icons.object(forKey: key(for: item))
    }

    static func loadIcon(for item: FileItem) async -> NSImage? {
        let cachedKey = key(for: item)
        if let cached = FileIconStore.shared.icons.object(forKey: cachedKey) {
            return cached
        }

        let path = item.url.path
        let modified = item.modifiedAt?.timeIntervalSinceReferenceDate ?? 0
        let box = await Task.detached(priority: .utility) {
            let key = iconKey(path: path, modified: modified)
            let icon = NSWorkspace.shared.icon(forFile: path)
            FileIconStore.shared.icons.setObject(icon, forKey: key)
            return FileIconBox(icon)
        }.value
        return box.icon
    }

    private static func key(for item: FileItem) -> NSString {
        let modified = item.modifiedAt?.timeIntervalSinceReferenceDate ?? 0
        return iconKey(path: item.url.path, modified: modified)
    }

    private nonisolated static func iconKey(path: String, modified: TimeInterval) -> NSString {
        "\(path)|\(modified)" as NSString
    }
}

private nonisolated final class FileIconStore: @unchecked Sendable {
    static let shared = FileIconStore()

    let icons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 4000
        return cache
    }()
}

private nonisolated final class FileIconBox: @unchecked Sendable {
    let icon: NSImage

    init(_ icon: NSImage) {
        self.icon = icon
    }
}

private struct RecoveryResidueSheet: View {
    @ObservedObject var model: FileBrowserViewModel
    @State private var confirmCleanup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("发现未完成的传输残留")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    model.dismissRecoveryNotice()
                }
            }

            Text("以下临时目录可能包含上一次传输尚未发布的数据。应用不会自动删除它们，请确认后保留或清理。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            List(model.recoveryResidues) { residue in
                VStack(alignment: .leading, spacing: 4) {
                    Text(residue.name)
                        .font(.system(size: 13, weight: .medium))
                    Text(residue.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.plain)

            HStack {
                Button("保留") {
                    model.dismissRecoveryNotice()
                }
                Spacer()
                Button("清理残留", role: .destructive) {
                    confirmCleanup = true
                }
                .disabled(model.recoveryResidues.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 380)
        .confirmationDialog(
            "清理传输残留？",
            isPresented: $confirmCleanup
        ) {
            Button("清理", role: .destructive) {
                model.cleanUpRecoveryResidues()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("清理后这些临时目录及其中的数据将无法恢复。")
        }
    }
}

private struct BatchRenameSheet: View {
    @ObservedObject var model: FileBrowserViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("批量重命名（\(model.batchRenameItemCount) 项）")
                    .font(.headline)
                Spacer()
                if model.batchRenameIsRunning {
                    ProgressView(value: model.batchRenameProgress)
                        .frame(width: 120)
                }
            }

            HStack(spacing: 8) {
                Text("名称模板")
                    .frame(width: 64, alignment: .trailing)
                TextField("模板", text: $model.batchRenameOptions.template)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("名称模板")
                Text("查找")
                    .frame(width: 32, alignment: .trailing)
                TextField("查找", text: $model.batchRenameOptions.findText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .accessibilityLabel("查找文本")
                Text("替换为")
                    .frame(width: 48, alignment: .trailing)
                TextField("替换为", text: $model.batchRenameOptions.replaceText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                    .accessibilityLabel("替换文本")
            }

            .disabled(model.batchRenameIsRunning)

            Text(BatchRenameOptions.templateHelp)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Picker("大小写", selection: $model.batchRenameOptions.caseMode) {
                    ForEach(RenameCaseMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .frame(width: 190)

                Toggle("保留扩展名", isOn: $model.batchRenameOptions.keepsExtension)
                    .toggleStyle(.checkbox)

                Toggle("区分大小写查找", isOn: $model.batchRenameOptions.replaceCaseSensitive)
                    .toggleStyle(.checkbox)
            }

            .disabled(model.batchRenameIsRunning)

            HStack(spacing: 20) {
                Stepper(
                    "起始序号 \(model.batchRenameOptions.startNumber)",
                    value: $model.batchRenameOptions.startNumber,
                    in: 0...999_999
                )
                .frame(width: 170)

                Stepper(
                    "步长 \(model.batchRenameOptions.step)",
                    value: $model.batchRenameOptions.step,
                    in: 1...1_000
                )
                .frame(width: 130)

                Stepper(
                    "序号位数 \(model.batchRenameOptions.padding)",
                    value: $model.batchRenameOptions.padding,
                    in: 0...6
                )
                .frame(width: 140)
            }

            .disabled(model.batchRenameIsRunning)

            preview

            HStack(spacing: 12) {
                if model.batchRenameIsRunning {
                    Text("正在重命名…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if model.batchRenameIssueCount > 0 {
                    Text("\(model.batchRenameIssueCount) 项存在问题，修正后才能应用")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else {
                    Text("\(model.batchRenameChangeCount) 项将被重命名")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("取消") {
                    if model.batchRenameIsRunning {
                        model.cancelBatchRename()
                    } else {
                        model.isBatchRenamePresented = false
                    }
                }
                .keyboardShortcut(.cancelAction)

                Button("应用") {
                    model.applyBatchRename()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.batchRenameCanApply)
            }
        }
        .padding(20)
        .frame(width: 700)
        .interactiveDismissDisabled(model.batchRenameIsRunning)
        .onDisappear {
            if !model.batchRenameIsRunning { model.cancelBatchRename() }
        }
        .onChange(of: model.batchRenameOptions) { _, _ in
            model.refreshBatchRenamePreview()
        }
    }

    private var preview: some View {
        ZStack {
            List(model.batchRenamePreview) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.originalName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.proposedName)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(item.issue == nil ? Color.primary : Color.red)
                    }
                    .font(.system(.body, design: .monospaced))

                    if let issue = item.issue {
                        Text(issue)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .listStyle(.plain)

            if model.batchRenamePreviewIsLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(height: 240)
    }
}

private struct UndoHistorySheet: View {
    @ObservedObject var journal: FileUndoJournal
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("撤销历史")
                    .font(.headline)
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            if journal.entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本次运行还没有可撤销的操作。")
                        .font(.system(size: 13))
                    Text("重命名、移动和非覆盖复制完成后会出现在这里。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List(journal.entries) { entry in
                    UndoHistoryRow(entry: entry)
                        .padding(.vertical, 3)
                }
                .listStyle(.plain)
            }

            Divider()

            Text("撤销记录只保留本次运行期间最近 \(journal.limit) 次操作，退出 MaXplorer 后自动清空。覆盖操作无法撤销，会在列表中标注“不可撤销”。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 560, height: 420)
        .onExitCommand {
            dismiss()
        }
    }
}

private struct UndoHistoryRow: View {
    let entry: FileUndoEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.isRestorable ? "arrow.uturn.backward.circle" : "exclamationmark.triangle")
                .font(.system(size: 15))
                .foregroundStyle(entry.isRestorable ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.affectedCount > 1 ? "\(entry.title)（\(entry.affectedCount) 项）" : entry.title)
                        .font(.system(size: 13, weight: .medium))
                    if !entry.isRestorable {
                        Text("不可撤销")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(entry.historyDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Text(entry.createdAt, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .accessibilityLabel("记录时间")
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ArchiveProgressSheet: View {
    @ObservedObject var model: FileBrowserViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.archiveOperationTitle)
                .font(.headline)

            if let error = model.archiveOperationError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("请稍候…")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                if model.archiveOperationError == nil {
                    Button("取消") {
                        model.cancelArchiveOperation()
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button("关闭") {
                        model.dismissArchiveOperation()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .interactiveDismissDisabled(model.archiveOperationError == nil)
    }
}

private struct TransferPlanSheet: View {
    @ObservedObject var model: FileBrowserViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("传输计划")
                .font(.headline)

            if model.isPreparingTransferPlan || model.transferPlan == nil {
                if let error = model.transferPlanError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("正在计算文件数、大小和目标空间…")
                            Text("已扫描 \(model.transferPlanScannedCount) 项 · \(byteText(model.transferPlanScannedBytes))")
                                .monospacedDigit()
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                    }
                }
            } else if let plan = model.transferPlan {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    planRow("操作", plan.operation == .move ? "移动" : "复制")
                    planRow("目标", plan.destinationDirectory.path)
                    planRow("项目", "\(plan.itemCount) 项")
                    planRow("总大小", byteText(plan.totalBytes))
                    planRow("所需空间", plan.requiredBytes == 0 ? "不需要额外空间" : byteText(plan.requiredBytes))
                    planRow("可用空间", plan.freeBytes.map(byteText) ?? "未知")
                    planRow("冲突", plan.conflictCount == 0 ? "无" : "\(plan.conflictCount) 项")
                    planRow("权限", permissionText(plan))
                    if plan.isNetworkDestination {
                        planRow("目标类型", "网络卷")
                    }
                }

                if plan.freeBytes == nil {
                    Label("无法获取目标可用容量。可继续传输，执行时仍会检查并报告空间不足。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                if !plan.hasEnoughSpace {
                    Label("目标空间不足，无法开始传输。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if !plan.destinationWritable {
                    Label("目标文件夹不可写。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if plan.unreadableCount > 0 {
                    Label("\(plan.unreadableCount) 个项目不可读，传输时可能失败。", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Spacer()
                Button("取消") {
                    model.cancelTransferPlan()
                }
                .keyboardShortcut(.cancelAction)
                Button("开始传输") {
                    model.confirmTransferPlan()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!(model.transferPlan?.canProceed ?? false))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(model.isPreparingTransferPlan)
    }

    @ViewBuilder
    private func planRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func permissionText(_ plan: TransferPlan) -> String {
        if plan.unreadableCount > 0 {
            return "\(plan.unreadableCount) 项不可读"
        }
        return plan.destinationWritable ? "正常" : "目标不可写"
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct NewFileSheet: View {
    let onCreate: (String) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @FocusState private var isFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建文件")
                .font(.headline)

            TextField("文件名", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .focused($isFocused)
                .onSubmit(create)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("新建", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            isFocused = true
        }
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        onCreate(trimmedName)
    }
}

private struct FileInfoSheet: View {
    let item: FileItem
    @ObservedObject var model: FileBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var copiedPath = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: item.isDirectory ? "folder" : "doc")
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.headline)
                    Text(item.url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            Divider()

            if model.infoItems.count > 1 {
                Picker("所选项目（\(model.infoItems.count) 项）", selection: Binding(
                    get: { item.id },
                    set: { id in
                        guard let selected = model.infoItems.first(where: { $0.id == id }) else { return }
                        model.showInfo(for: selected)
                    }
                )) {
                    ForEach(model.infoItems) { selected in
                        Text(selected.name).tag(selected.id)
                    }
                }
                .accessibilityLabel("切换所选项目的简介")
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                infoRow("类型", item.displayKind)
                infoRow("大小", sizeText)
                infoRow("位置", item.url.deletingLastPathComponent().path)
                infoRow("创建", dateText(model.infoDetails?.createdAt ?? item.createdAt))
                infoRow("修改", dateText(model.infoDetails?.modifiedAt ?? item.modifiedAt))
                infoRow("拍摄", dateText(model.infoDetails?.dateTaken ?? item.dateTaken))
                infoRow("所有者", model.infoDetails?.owner ?? item.owner ?? "—")
                infoRow("群组", model.infoDetails?.group ?? "—")
                infoRow("权限", model.infoDetails?.permissions ?? "—")
                infoRow("标签", tagText)
            }

            if let error = model.infoError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(copiedPath ? "已复制" : "复制路径") {
                    SystemActions.copyPath(item.url)
                    copiedPath = true
                }

                Spacer()

                Button("完成") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onChange(of: item.id) { _, _ in copiedPath = false }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private var sizeText: String {
        if item.isDirectory {
            if model.isInfoSizeLoading {
                return "计算中…"
            }
            guard let size = model.infoFolderSize else {
                return "—"
            }
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }

        guard let size = item.size else {
            return "—"
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    private func dateText(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }

    private var tagText: String {
        let tags = model.infoDetails?.tagNames ?? []
        return tags.isEmpty ? "—" : tags.joined(separator: "，")
    }
}

private struct SelectItemsSheet: View {
    @Binding var pattern: String
    @Binding var mode: SearchMatchMode
    let onSelect: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    private var trimmedPattern: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("选择匹配项")
                .font(.headline)

            Text("按文件名在当前列表中选中匹配项，不会改变当前文件夹内容。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField(mode.placeholder, text: $pattern)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit(onSelect)

                Picker("匹配方式", selection: $mode) {
                    ForEach(SearchMatchMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 90)
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("选择", action: onSelect)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedPattern.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            isFocused = true
        }
    }
}

private struct RenameSheet: View {
    let item: FileItem
    @Binding var renameText: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名")
                .font(.headline)

            TextField("名称", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit(onSave)

            Text(item.url.deletingLastPathComponent().path)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("重命名", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}

private struct ConnectToServerSheet: View {
    @Binding var serverAddress: String
    let history: [String]
    let onConnect: () -> Void
    let onCancel: () -> Void

    private var trimmedAddress: String {
        serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接服务器")
                .font(.headline)

            HistoryComboBox(
                text: $serverAddress,
                history: history,
                prompt: "smb://server/share",
                onCommit: onConnect
            )
                .frame(width: 390, height: 26)

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("连接", action: onConnect)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedAddress.isEmpty || trimmedAddress == "smb://")
            }
        }
        .padding(20)
    }
}

private struct GoToFolderSheet: View {
    @Binding var folderPath: String
    let history: [String]
    let errorMessage: String?
    let onGo: () -> Void
    let onCancel: () -> Void

    private var trimmedPath: String {
        folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("前往文件夹")
                .font(.headline)

            HistoryComboBox(text: $folderPath, history: history, onCommit: onGo)
                .frame(width: 420, height: 26)

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("前往", action: onGo)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedPath.isEmpty)
            }
        }
        .padding(20)
    }
}

private struct HistoryComboBox: View {
    @Binding var text: String
    let history: [String]
    var prompt = "路径"
    let onCommit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(onCommit)

            Divider()
                .frame(height: 16)

            Menu {
                if history.isEmpty {
                    Text("暂无连接记录")
                } else {
                    ForEach(history, id: \.self) { address in
                        Button(address) {
                            text = address
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(history.isEmpty ? .tertiary : .secondary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
        }
        .padding(.leading, 7)
        .background(ThemedControlBackground())
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: isFocused ? 2 : 1
                )
        }
    }
}
