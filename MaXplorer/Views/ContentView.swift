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

    var body: some View {
        Group {
            if model.isIntegratedTerminalPresented,
               model.currentURL.isFileURL,
               model.detailDestination == .files,
               !tabs.isSpaceAnalyzerActive,
               !tabs.isCopyQueueActive {
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
            Button("OK") {
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
                    manualFolderError = model.errorMessage ?? "Path not found"
                    model.clearError()
                    return
                }

                settings.addManualFolderToHistory(folderURL)
                model.isGoToFolderPresented = false
            } onCancel: {
                model.isGoToFolderPresented = false
            }
        }
        .sheet(item: $model.quickViewContent) { content in
            QuickViewSheet(content: content) {
                model.clearQuickView()
            }
        }
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
        .confirmationDialog(
            copyConflictTitle,
            isPresented: Binding(
                get: { model.copyConflictRequest != nil },
                set: { if !$0 { model.copyConflictRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Overwrite", role: .destructive) {
                model.resolveCopyConflict(.overwrite)
            }

            if model.copyConflictRequest?.totalConflicts ?? 0 > 1 {
                Button("Overwrite All", role: .destructive) {
                    model.resolveCopyConflict(.overwriteAll)
                }
            }

            Button("Skip") {
                model.resolveCopyConflict(.skip)
            }

            if model.copyConflictRequest?.totalConflicts ?? 0 > 1 {
                Button("Skip All") {
                    model.resolveCopyConflict(.skipAll)
                }
            }

            Button("Cancel", role: .cancel) {
                model.resolveCopyConflict(.cancel)
            }
        } message: {
            Text(copyConflictMessage)
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

            Button("Cancel", role: .cancel) {
                itemsPendingTrash = []
            }
        } message: {
            if itemsPendingTrash.contains(where: model.requiresPermanentDeletion) {
                Text(deletionConfirmationMessage)
            } else if itemsPendingTrash.count == 1, let itemPendingTrash = itemsPendingTrash.first {
                Text(itemPendingTrash.name)
            } else {
                Text("\(itemsPendingTrash.count) selected items")
            }
        }
        .environmentObject(model)
    }

    private var deletionConfirmationTitle: String {
        let permanentCount = itemsPendingTrash.filter(model.requiresPermanentDeletion).count
        if permanentCount == itemsPendingTrash.count, permanentCount > 0 {
            return permanentCount == 1 ? "Delete item permanently?" : "Delete items permanently?"
        }
        if permanentCount > 0 {
            return "Delete selected items?"
        }
        return itemsPendingTrash.count == 1 ? "Move item to Trash?" : "Move items to Trash?"
    }

    private var deletionConfirmationButtonTitle: String {
        itemsPendingTrash.contains(where: model.requiresPermanentDeletion) ? "Delete" : "Move to Trash"
    }

    private var deletionConfirmationMessage: String {
        let permanentCount = itemsPendingTrash.filter(model.requiresPermanentDeletion).count
        if permanentCount == itemsPendingTrash.count {
            let name = itemsPendingTrash.first?.name ?? "The selected items"
            return "\(name) will be permanently deleted because this network volume does not support Trash. This action cannot be undone."
        }
        return "Items on network volumes will be permanently deleted because those volumes do not support Trash. Other items will be moved to Trash."
    }

    private var browserNavigationView: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if tabs.isCopyQueueActive {
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
                        FileTableView(
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

    private var copyConflictTitle: String {
        guard let request = model.copyConflictRequest else { return "" }
        return "\"\(request.conflictingName)\" already exists at the destination"
    }

    private var copyConflictMessage: String {
        guard let request = model.copyConflictRequest else { return "" }
        if request.totalConflicts > 1 {
            return "Conflict \(request.conflictNumber) of \(request.totalConflicts)"
        }
        return "An item with this name already exists. Choose how to handle the conflict."
    }
}

private struct QuickViewSheet: View {
    let content: QuickViewContent
    let onClose: () -> Void
    @State private var textEncoding: PreviewTextEncoding = .automatic
    @State private var decodedText: String?
    @State private var decodingError: String?
    @State private var openError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(content.title)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(content.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Button("Open in Default App") {
                    if !NSWorkspace.shared.open(content.url) {
                        openError = "No application could open this file. Check that a compatible application is installed."
                    }
                }

                Button("Done", action: onClose)
                    // Return belongs to the system preview's password field.
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            .background(ThemedBarBackground())

            if content.isLegacyOfficeDocument {
                Text("Some older Office files or encryption methods may not preview correctly. If content is missing or a known password is rejected, choose Open in Default App.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            if content.allowsTextEncoding {
                Picker("Text encoding", selection: $textEncoding) {
                    ForEach(PreviewTextEncoding.allCases) { encoding in
                        Text(encoding.rawValue).tag(encoding)
                    }
                }
                .fixedSize()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            Group {
                if textEncoding == .automatic {
                    FilePreviewView(url: content.url)
                } else {
                    ScrollView {
                        Text(decodedText ?? decodingError ?? "Loading…")
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ThemedContentBackground())
        }
        .frame(minWidth: 680, minHeight: 460)
        .alert("Unable to Open File", isPresented: Binding(
            get: { openError != nil },
            set: { if !$0 { openError = nil } }
        )) {
            Button("OK") { openError = nil }
        } message: {
            Text(openError ?? "")
        }
        .task(id: textEncoding) {
            decodedText = nil
            decodingError = nil
            guard let encoding = textEncoding.stringEncoding else { return }
            let url = content.url
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    try PreviewTextDecoder.read(url, encoding: encoding)
                }.value
                try Task.checkCancellation()
                decodedText = text
            } catch {
                if !Task.isCancelled { decodingError = error.localizedDescription }
            }
        }
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
                    if tab.id == tabs.spaceAnalyzerTabID {
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
                            Button("Close Space Analyzer") { tabs.closeSpaceAnalyzer() }
                        }
                    } else if tab.id == tabs.copyQueueTabID {
                        CopyQueueTabButton(
                            isSelected: tab.id == tabs.selectedTabID,
                            width: tabWidth,
                            onSelect: { tabs.selectTab(tab.id) },
                            onClose: { tabs.closeCopyQueue() }
                        )
                        .contextMenu {
                            Button("Close Copy Queue") { tabs.closeCopyQueue() }
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
                            Button("Paste") {
                                tabs.pasteItems(
                                    to: tab.id,
                                    maximumConcurrentCopies: settings.maximumConcurrentCopiedFiles
                                )
                            }
                            .disabled(!tabs.canPasteItems(to: tab.id))

                            Divider()

                            Button("Duplicate Tab") {
                                tabs.duplicateTab(tab.id)
                            }
                            .keyboardShortcut("d", modifiers: [.command, .shift])

                            Divider()

                            Button("Sort by Name") {
                                tabs.sortTabsByName()
                            }

                            Button("Close Duplicate Tabs") {
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
        .modernTooltip(isEnabled ? "Open a new tab (⌘T)" : "Maximum number of tabs reached")
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
        .accessibilityLabel("Close Tab")
        .modernTooltip(isEnabled ? "Close Tab" : "At least one tab must remain open")
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
                    Text(isScanning ? "Scanning…" : "Space Analyzer")
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
                    Text("Copy Queue")
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
        VStack(spacing: 0) {
            List(selection: Binding<String?>(
            get: {
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
                ForEach(model.sidebarLocations.filter { $0.group == .favorites }) { location in
                    Label(location.name, systemImage: location.systemImage)
                        .sidebarHover()
                        .tag(location.url.absoluteString)
                        .contextMenu {
                            if location.url.isFileURL {
                                Button("Analyze Space under Selected Folder") {
                                    tabs.openSpaceAnalyzer(url: location.url)
                                }
                                Divider()
                            }
                            if location.canRemoveFromFavorites {
                                Button("Remove from Favorites") {
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
                Text(SidebarLocation.Group.favorites.rawValue)
            }
            .dropDestination(for: URL.self) { urls, _ in
                _ = model.pinDroppedFavorites(urls)
            }

            if model.sidebarLocations.contains(where: { $0.group == .devices }) {
                Section(SidebarLocation.Group.devices.rawValue) {
                    ForEach(model.sidebarLocations.filter { $0.group == .devices }) { location in
                        Label(location.name, systemImage: location.systemImage)
                            .sidebarHover()
                            .tag(location.url.absoluteString)
                            .contextMenu {
                                if location.url.isFileURL {
                                    Button("Analyze Space under Selected Folder") {
                                        tabs.openSpaceAnalyzer(url: location.url)
                                    }
                                }
                            }
                    }
                }
            }

            Section("Disk") {
                Button {
                    tabs.openSpaceAnalyzer()
                } label: {
                    HStack(spacing: 6) {
                        SpaceAnalyzerIcon(size: 15)
                        Text("Space Analyzer")
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
                    Label("Connect to Server", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)

                ForEach(model.sidebarLocations.filter { $0.group == .network }) { location in
                    Label(location.name, systemImage: location.systemImage)
                        .sidebarHover()
                        .tag(location.url.absoluteString)
                }
            } header: {
                Text(SidebarLocation.Group.network.rawValue)
            }

            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            VStack(spacing: 2) {
                SidebarDockedButton(
                    title: "Settings",
                    systemImage: "gearshape",
                    isSelected: !tabs.isSpaceAnalyzerActive && model.detailDestination == .settings,
                    usesAccentColor: false,
                    action: tabs.showSettings
                )

                SidebarDockedButton(
                    title: "About",
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
                Label("Copy Queue", systemImage: "doc.on.clipboard")

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
                        help: "Go back to the previous folder (⌘[)",
                        isDisabled: !model.canGoBack
                    ) {
                        model.goBack()
                    }

                    ToolbarIconButton(
                        systemName: "chevron.forward",
                        help: "Go forward to the next folder (⌘])",
                        isDisabled: !model.canGoForward
                    ) {
                        model.goForward()
                    }

                    ToolbarIconButton(
                        systemName: "arrow.up.to.line.compact",
                        help: "Go to the enclosing folder (⌘↑)",
                        isDisabled: !model.canGoUp
                    ) {
                        model.goUp()
                    }

                    ToolbarIconButton(
                        systemName: "arrow.clockwise",
                        help: "Reload the current folder (⌘R)"
                    ) {
                        model.reload()
                    }
                }

                ToolbarButtonGroup {
                    ToolbarIconButton(
                        systemName: "folder.badge.plus",
                        help: "Create a new folder in the current folder (⌘⇧N)",
                        isDisabled: !model.canCreateFolder
                    ) {
                        Task { await model.createFolder() }
                    }

                    ToolbarIconButton(
                        systemName: "terminal",
                        help: "Open Terminal at the current folder (⌘⇧T)"
                    ) {
                        model.openCurrentFolderInTerminal()
                    }

                    ToolbarToggleButton(
                        systemName: "terminal.fill",
                        help: model.isIntegratedTerminalPresented ? "Close integrated terminal (⌃` )" : "Open integrated terminal (⌃` )",
                        isOn: $model.isIntegratedTerminalPresented
                    )

                    ToolbarIconButton(
                        systemName: "arrow.up.forward.square",
                        help: "Reveal the selected item in Finder (⌃⌘R)"
                    ) {
                        model.revealSelectedInFinder()
                    }
                }

                ToolbarButtonGroup {
                    ToolbarIconButton(
                        systemName: "network.badge.shield.half.filled",
                        help: "Connect to a network server (⌘K)"
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
                    .modernTooltip("Analyze disk space usage")
                }

                ToolbarButtonGroup {
                    ToolbarToggleButton(
                        systemName: "eye.fill",
                        help: tabs.showHiddenFiles ? "Hide hidden files (⌘⇧.)" : "Show hidden files (⌘⇧.)",
                        isOn: $tabs.showHiddenFiles
                    )

                    ToolbarToggleButton(
                        systemName: "a.square.fill",
                        help: tabs.showAliases ? "Hide aliases (⌘⇧A)" : "Show aliases (⌘⇧A)",
                        isOn: $tabs.showAliases,
                        iconSize: 22
                    )
                }

                ToolbarButtonGroup {
                    Menu {
                        Section("Show Columns") {
                            ForEach(FileColumn.allCases) { column in
                                Toggle(column.title, isOn: Binding(
                                    get: { settings.visibleColumns.contains(column) },
                                    set: { _ in settings.toggleColumn(column) }
                                ))
                                .disabled(column.isRequired)
                            }
                        }

                        Divider()

                        Button("Reset Columns") {
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
                    .modernTooltip("Choose which columns are shown (or right-click a column header)")
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                    FilterTextField(
                        text: $model.filterText,
                        placeholder: "Filter current folder",
                        proxy: model.filterFocusProxy
                    )
                    .frame(minWidth: 160, idealWidth: 220, maxWidth: 220)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
                .layoutPriority(1)
                .modernTooltip("Filter items shown in the current folder")
            }
            .symbolRenderingMode(.hierarchical)
            }

            HStack(spacing: 8) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .foregroundStyle(.secondary)

                TextField("Path", text: $model.pathText)
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
                .modernTooltip("Copy the selected item path, or the current folder path if nothing is selected (⌘⌥C)")
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

private struct CopyQueueView: View {
    @ObservedObject var queue: CopyQueueViewModel
    @EnvironmentObject private var tabs: BrowserTabsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Copy Queue")
                    .font(.headline)

                Spacer()

                Text("\(queue.activeCopyCount) active")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(16)
            .background(ThemedBarBackground())

            if queue.items.isEmpty && queue.history.isEmpty {
                ContentUnavailableView(
                    "No Copy Operations",
                    systemImage: "doc.on.clipboard",
                    description: Text("Active transfers and completed history will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !queue.items.isEmpty {
                        Section("Tasks") {
                            ForEach(queue.items) { item in
                                CopyQueueRow(
                                    item: item,
                                    onOpenDestination: {
                                        tabs.openOrSelectLocation(item.destinationURL.deletingLastPathComponent())
                                    },
                                    onCancel: { queue.cancel(item.id) }
                                )
                                .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                            }
                        }
                    }

                    if !queue.history.isEmpty {
                        Section("History") {
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
                Text(item.operation == .move ? "Moved" : "Copied")
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
    let onOpenDestination: () -> Void
    let onCancel: () -> Void

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

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!item.state.isActive)
            .foregroundStyle(item.state.isActive ? .secondary : .tertiary)
            .modernTooltip("Cancel this copy operation")
        }
    }

    private var stateText: String {
        switch item.state {
        case .pending:
            return "Pending"
        case .running:
            return item.operation == .move ? "Moving" : "Copying"
        case .completed:
            return "Complete"
        case .failed(let reason):
            return "Aborted: \(reason)"
        case .cancelled:
            return "Cancelled"
        }
    }

    private var destinationFolderURL: URL {
        item.destinationURL.deletingLastPathComponent()
    }

    private var speedText: String {
        guard item.state == .running, item.bytesPerSecond > 0 else {
            return "Speed --"
        }

        return "\(Self.byteFormatter.string(fromByteCount: Int64(item.bytesPerSecond))) /s"
    }

    private var etaText: String {
        guard let estimatedSecondsRemaining = item.estimatedSecondsRemaining else {
            return "ETA --"
        }

        return "ETA \(Self.durationFormatter.string(from: estimatedSecondsRemaining) ?? "--")"
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

                    Text("Settings")
                        .font(.system(size: 30, weight: .bold, design: .rounded))

                    Text("Tune appearance, tabs, and copy behavior.")
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
                    Text("OK")
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

private struct FileTableView: View {
    @EnvironmentObject private var model: FileBrowserViewModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var tabs: BrowserTabsViewModel
    @Binding var renameItem: FileItem?
    @Binding var renameText: String
    @Binding var itemsPendingTrash: [FileItem]
    @State private var isDropTargeted = false
    @State private var folderDropTargetID: FileItem.ID?

    var body: some View {
        ZStack {
            // Column customization gives the header the native right-click
            // menu for showing and hiding columns (as in Finder), plus
            // drag-to-reorder and remembered widths. Every column is declared
            // here; visibility comes from the customization, which AppSettings
            // keeps in sync with the toolbar column chooser.
            Table(model.displayedItems, selection: Binding(
                get: { model.selectedItemIDs },
                set: { model.selectedItemIDs = $0 }
            ), sortOrder: $model.sortOrder, columnCustomization: $settings.columnCustomization) {
                TableColumn("Name", value: \.name) { item in
                    nameCell(for: item)
                }
                .width(min: 220, ideal: 320)
                .customizationID(FileColumn.name.id)
                // Like Finder, Name is always shown and cannot be hidden.
                .disabledCustomizationBehavior(.visibility)

                TableColumn("Kind", value: \.displayKind) { item in
                    columnText(item.displayKind, for: item)
                }
                .width(min: 120, ideal: 170)
                .customizationID(FileColumn.kind.id)

                TableColumn("Size", value: \.sortSize) { item in
                    columnText(item.displaySize, for: item, monospacedDigit: true)
                }
                .width(min: 80, ideal: 110)
                .customizationID(FileColumn.size.id)

                TableColumn("Date Modified", value: \.sortModifiedAt) { item in
                    columnText(item.displayModified, for: item)
                }
                .width(min: 150, ideal: 180)
                .customizationID(FileColumn.dateModified.id)

                TableColumn("Date Created", value: \.sortCreatedAt) { item in
                    columnText(item.displayCreated, for: item)
                }
                .width(min: 150, ideal: 180)
                .customizationID(FileColumn.dateCreated.id)

                TableColumn("Date Taken", value: \.sortDateTaken) { item in
                    columnText(item.displayDateTaken, for: item)
                }
                .width(min: 150, ideal: 180)
                .customizationID(FileColumn.dateTaken.id)

                TableColumn("Owner", value: \.sortOwner) { item in
                    columnText(item.displayOwner, for: item)
                }
                .width(min: 100, ideal: 140)
                .customizationID(FileColumn.owner.id)
            }
            .onKeyPress(.space, phases: .down) { press in
                guard press.modifiers.isEmpty, model.canQuickViewSelectedItem else {
                    return .ignored
                }
                model.quickViewSelectedItem()
                return .handled
            }
            .alternatingRowBackgrounds(settings.showsBandedFileRows ? .enabled : .disabled)
            .listRowSeparator(settings.showsBandedFileRows ? .visible : .hidden)
            .scrollContentBackground(.hidden)
            .background(ThemedContentBackground())
            .dropDestination(for: URL.self) { urls, _ in
                model.importItems(urls, maximumConcurrentCopies: settings.maximumConcurrentCopiedFiles)
                return true
            } isTargeted: { isDropTargeted = $0 }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                        .padding(2)
                        .allowsHitTesting(false)
                }
            }
            .contextMenu(forSelectionType: FileItem.ID.self) { selection in
                Button("Open") {
                    model.selectedItemIDs = selection
                    model.openSelected()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Quick View") {
                    model.selectedItemIDs = selection
                    model.quickViewSelectedItem()
                }
                .disabled(!canQuickView(selection: selection))

                Menu("Open With") {
                    let applications = openWithApplications(selection: selection)
                    if applications.isEmpty {
                        Text("No Applications Found")
                    } else {
                        ForEach(applications) { application in
                            Button(application.name) {
                                model.selectedItemIDs = selection
                                model.openSelected(with: application)
                            }
                        }
                    }
                }
                .disabled(!canOpenWith(selection: selection))

                Divider()

                Button("Cut") {
                    model.selectedItemIDs = selection
                    model.cutSelectedItems()
                }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!canCut(selection: selection))

                Button("Copy") {
                    model.selectedItemIDs = selection
                    model.copySelectedItems()
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!canCut(selection: selection))

                Button("Rename") {
                    startRename(selection: selection)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!canEdit(selection: selection))

                Button(trashActionTitle(selection: selection), role: .destructive) {
                    startTrash(selection: selection)
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!canTrash(selection: selection))

                Divider()

                Button("Add to Favorites") {
                    pinFolder(selection: selection)
                }
                .disabled(!canPin(selection: selection))

                Divider()

                Button("Analyze Space under Selected Folder") {
                    guard let id = selection.first,
                          let item = model.items.first(where: { $0.id == id }),
                          item.isDirectory else { return }
                    model.selectedItemIDs = selection
                    tabs.openSpaceAnalyzer(url: item.url)
                }
                .disabled(!canAnalyzeSpace(selection: selection))

                Button("Copy Path") {
                    model.selectedItemIDs = selection
                    model.copySelectedPath()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button("Open in Terminal") {
                    model.selectedItemIDs = selection
                    model.openSelectedInTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("Reveal in Finder") {
                    model.selectedItemIDs = selection
                    model.revealSelectedInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .control])
            } primaryAction: { selection in
                model.selectedItemIDs = selection
                model.openSelected()
            }

            if model.isLoading {
                ProgressView()
                    .controlSize(.large)
                    .padding(22)
                    .background {
                        ThemedControlBackground()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
            } else if model.displayedItems.isEmpty {
                ContentUnavailableView(
                    model.filterText.isEmpty ? "No Items" : "No Matching Items",
                    systemImage: model.filterText.isEmpty ? (model.isBrowsingNetwork ? "network.slash" : "folder") : "magnifyingglass",
                    description: Text(emptyDescription)
                )
            }
        }
    }

    private func startRename(selection: Set<FileItem.ID>) {
        guard let id = selection.first, let item = model.items.first(where: { $0.id == id }) else {
            return
        }

        model.selectedItemIDs = [id]
        renameItem = item
        renameText = item.name
    }

    private func startTrash(selection: Set<FileItem.ID>) {
        let items = model.items.filter { selection.contains($0.id) && !$0.isNetworkLocation }
        guard !items.isEmpty else {
            return
        }

        model.selectedItemIDs = Set(items.map(\.id))
        itemsPendingTrash = items
    }

    private func pinFolder(selection: Set<FileItem.ID>) {
        guard let id = selection.first else {
            return
        }

        model.selectedItemIDs = [id]
        model.pinSelectedFolderToFavorites()
    }

    private func selectedItem(for selection: Set<FileItem.ID>) -> FileItem? {
        guard selection.count == 1, let id = selection.first else {
            return nil
        }

        return model.items.first { $0.id == id }
    }

    private func canPin(selection: Set<FileItem.ID>) -> Bool {
        guard let item = selectedItem(for: selection) else {
            return false
        }

        return model.canPinFolder(item)
    }

    private func canQuickView(selection: Set<FileItem.ID>) -> Bool {
        guard let item = selectedItem(for: selection) else {
            return false
        }

        return model.canQuickView(item)
    }

    private func canOpenWith(selection: Set<FileItem.ID>) -> Bool {
        guard let item = selectedItem(for: selection) else {
            return false
        }

        return model.canOpenWith(item)
    }

    private func openWithApplications(selection: Set<FileItem.ID>) -> [OpenWithApplication] {
        guard let item = selectedItem(for: selection) else {
            return []
        }

        return model.openWithApplications(for: item)
    }

    private func canCut(selection: Set<FileItem.ID>) -> Bool {
        selection.contains { id in
            model.items.first { $0.id == id }?.isNetworkLocation == false
        }
    }

    private func canEdit(selection: Set<FileItem.ID>) -> Bool {
        guard selection.count == 1, let id = selection.first, let item = model.items.first(where: { $0.id == id }) else {
            return false
        }

        return !item.isNetworkLocation
    }

    private func canTrash(selection: Set<FileItem.ID>) -> Bool {
        selection.contains { id in
            model.items.first { $0.id == id }?.isNetworkLocation == false
        }
    }

    private func trashActionTitle(selection: Set<FileItem.ID>) -> String {
        let items = model.items.filter { selection.contains($0.id) }
        return items.contains(where: model.requiresPermanentDeletion) ? "Delete Permanently" : "Move to Trash"
    }

    private func canAnalyzeSpace(selection: Set<FileItem.ID>) -> Bool {
        guard selection.count == 1, let id = selection.first,
              let item = model.items.first(where: { $0.id == id }) else { return false }
        return item.isDirectory && !item.isNetworkLocation
    }

    private var emptyDescription: String {
        if !model.filterText.isEmpty {
            return "The current-folder filter did not match loaded items."
        }

        if model.isBrowsingNetwork {
            return "No local SMB servers or mounted network volumes were found. Use Connect to Server for a known address."
        }

        return "This folder is empty or unavailable."
    }

    @ViewBuilder
    private func nameCell(for item: FileItem) -> some View {
        let isFolderTarget = folderDropTargetID == item.id
        HStack(spacing: 8) {
            FileItemIcon(item: item, folderIconStyle: settings.folderIconStyle)
            Text(item.name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(model.isCut(item) ? 0.45 : 1)
        .background(
            isFolderTarget ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .overlay { rowClickTarget(for: item) }
        .draggable(item.url)
        .dropDestination(for: URL.self) { urls, _ in
            guard let dest = item.navigationURL else { return false }
            model.moveItems(urlsExpandingSelection(urls), to: dest)
            return true
        } isTargeted: { targeted in
            folderDropTargetID = (targeted && item.navigationURL != nil) ? item.id : nil
        }
    }

    /// If the dragged URL is one of the currently selected items, return all
    /// selected URLs so a multi-selection drag moves everything at once.
    private func urlsExpandingSelection(_ droppedURLs: [URL]) -> [URL] {
        let droppedStd = Set(droppedURLs.map(\.standardizedFileURL))
        let selectedURLs = model.displayedItems
            .filter { model.selectedItemIDs.contains($0.id) }
            .map(\.url)
        let selectedStd = Set(selectedURLs.map(\.standardizedFileURL))
        return droppedStd.isDisjoint(with: selectedStd) ? droppedURLs : selectedURLs
    }

    private func rowClickTarget(for item: FileItem) -> some View {
        TableCellClickTarget { mode in
            model.select(item, mode: mode)
        } onOpen: {
            model.selectedItemIDs = [item.id]
            model.openSelected()
        } onLongPress: {
            guard !item.isNetworkLocation else { return }
            startRename(selection: [item.id])
        }
    }

    @ViewBuilder
    private func columnText(_ text: String, for item: FileItem, monospacedDigit: Bool = false) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .font(monospacedDigit ? .body.monospacedDigit() : .body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay { rowClickTarget(for: item) }
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: FileBrowserViewModel

    var body: some View {
        HStack(spacing: 10) {
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("Loading")
            } else {
                if model.selectedItems.isEmpty {
                    Text("\(model.displayedItems.count) of \(model.items.count) items")
                } else if let selectedFileSize = model.selectedFileSize {
                    Text("\(model.selectedItems.count) selected • \(ByteCountFormatter.string(fromByteCount: selectedFileSize, countStyle: .file))")
                } else {
                    Text("\(model.selectedItems.count) selected")
                }
            }

          //  Spacer()

            if let stats = model.volumeStats {
                let freePercent = Int((Double(stats.free) / Double(stats.total) * 100).rounded())
                HStack(spacing: 12) {
                    Label(
                        "Used: \(ByteCountFormatter.string(fromByteCount: Int64(stats.used), countStyle: .file))",
                        systemImage: "internaldrive"
                    )
                    Text("Free: \(ByteCountFormatter.string(fromByteCount: Int64(stats.free), countStyle: .file)) (\(freePercent)%)")
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

private struct TableCellClickTarget: NSViewRepresentable {
    let onSelect: (SelectionMode) -> Void
    let onOpen: () -> Void
    let onLongPress: () -> Void

    func makeNSView(context: Context) -> TableCellClickTargetNSView {
        let view = TableCellClickTargetNSView()
        view.onSelect = onSelect
        view.onOpen = onOpen
        view.onLongPress = onLongPress
        return view
    }

    func updateNSView(_ nsView: TableCellClickTargetNSView, context: Context) {
        nsView.onSelect = onSelect
        nsView.onOpen = onOpen
        nsView.onLongPress = onLongPress
    }
}

private final class TableCellClickTargetNSView: NSView {
    var onSelect: (SelectionMode) -> Void = { _ in }
    var onOpen: () -> Void = {}
    var onLongPress: () -> Void = {}

    private var longPressTimer: Timer?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // This overlay handles selection itself, so native table mouseDown never
        // gets a chance to transfer focus away from a text field or terminal.
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView {
                window?.makeFirstResponder(table)
                break
            }
            ancestor = view.superview
        }

        if event.modifierFlags.contains(.shift) {
            onSelect(.range)
        } else if event.modifierFlags.contains(.command) {
            onSelect(.toggle)
        } else {
            onSelect(.single)
        }

        if event.clickCount >= 2 {
            cancelLongPress()
            onOpen()
        } else if event.modifierFlags.intersection([.shift, .command]).isEmpty {
            scheduleLongPress()
        }
    }

    override func mouseUp(with event: NSEvent) {
        cancelLongPress()
    }

    override func mouseDragged(with event: NSEvent) {
        cancelLongPress()
    }

    deinit { longPressTimer?.invalidate() }

    private func scheduleLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.longPressTimer = nil
            self?.onLongPress()
        }
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }
}

private struct FileItemIcon: View {
    let item: FileItem
    let folderIconStyle: FolderIconStyle

    private var isPlainFolder: Bool {
        item.isDirectory && !item.isPackage
    }

    var body: some View {
        Group {
            if item.isNetworkLocation {
                Image(systemName: "server.rack")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.mint)
                    .font(.system(size: 15, weight: .semibold))
            } else if item.isDirectory && folderIconStyle == .xplorer {
                Image(systemName: "folder.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.yellow)
                    .font(.system(size: 17, weight: .medium))
            } else {
                Image(nsImage: FileIconCache.icon(for: item, untinted: isPlainFolder && !item.tagColors.isEmpty))
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: 20, height: 20)
        .overlay(alignment: isPlainFolder ? .center : .bottomTrailing) {
            if !item.tagColors.isEmpty {
                FinderTagDots(colors: item.tagColors)
                    // Sit inside the folder's body, just below the tab.
                    .offset(x: isPlainFolder ? 0 : 2, y: 2)
            }
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
        .accessibilityLabel("Tagged")
    }
}

/// NSWorkspace returns the exact same icon Finder shows: correct type-specific
/// icons for documents, apps, aliases (with arrow badge), packages, and all
/// folder variants. Looking it up is not free, so rows reuse cached images
/// instead of asking again every time the table re-renders or re-sorts.
private enum FileIconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 4000
        return cache
    }()

    private static let plainFolderIcon = NSWorkspace.shared.icon(for: .folder)

    /// `untinted` swaps in the generic folder icon, because Finder tints the
    /// icon of a tagged folder with its tag color and the tag is shown as a dot
    /// instead.
    static func icon(for item: FileItem, untinted: Bool) -> NSImage {
        if untinted {
            return plainFolderIcon
        }

        let modified = item.modifiedAt?.timeIntervalSinceReferenceDate ?? 0
        let key = "\(item.url.path)|\(modified)" as NSString
        if let icon = cache.object(forKey: key) {
            return icon
        }

        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

private struct RenameSheet: View {
    let item: FileItem
    @Binding var renameText: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename")
                .font(.headline)

            TextField("Name", text: $renameText)
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
                Button("Cancel", action: onCancel)
                Button("Rename", action: onSave)
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
            Text("Connect to Server")
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
                Button("Cancel", action: onCancel)
                Button("Connect", action: onConnect)
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
            Text("Go to Folder")
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
                Button("Cancel", action: onCancel)
                Button("Go", action: onGo)
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
    var prompt = "Path"
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
                    Text("No previous connections")
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
