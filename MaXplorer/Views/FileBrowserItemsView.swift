import AppKit
import SwiftUI

struct FileTableView: View {
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
            Group {
                if settings.browserViewMode == .details {
                    detailsTable
                } else {
                    FileCollectionView(
                        onRename: { startRename(selection: [$0.id]) },
                        contextActions: contextActions
                    )
                }
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


            if model.isLoading && model.displayedItems.isEmpty {
                ProgressView()
                    .controlSize(.large)
                    .padding(22)
                    .background {
                        ThemedControlBackground()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
            } else if model.displayedItems.isEmpty {
                if model.isSearchActive {
                    if !model.hasSearchCriteria {
                        ContentUnavailableView(
                            "搜索文件",
                            systemImage: "magnifyingglass",
                            description: Text("输入名称、内容关键词或设置属性筛选。已启用条件同时满足才返回。")
                        )
                    } else if let error = model.searchErrorMessage {
                        ContentUnavailableView(
                            "搜索失败",
                            systemImage: "exclamationmark.triangle",
                            description: Text(error)
                        )
                    } else {
                        ContentUnavailableView(
                            model.searchUsesIndex ? "索引中未找到匹配" : "没有匹配的项目",
                            systemImage: "magnifyingglass",
                            description: Text(model.searchUsesIndex
                                ? "未索引、不支持或尚未更新的文件可能遗漏。可清除内容条件后按名称和属性查找。"
                                : "尝试其他关键词、范围或筛选条件。")
                        )
                    }
                } else {
                    ContentUnavailableView(
                        model.filterText.isEmpty ? "没有项目" : "没有匹配的项目",
                        systemImage: model.filterText.isEmpty ? (model.isBrowsingNetwork ? "network.slash" : "folder") : "magnifyingglass",
                        description: Text(emptyDescription)
                    )
                }
            }
        }
        .onChange(of: settings.browserGrouping, initial: true) { _, grouping in
            model.groupingMode = grouping
        }
    }

    private var detailsTable: some View {
            // Column customization gives the header the native right-click
            // menu for showing and hiding columns (as in Finder), plus
            // drag-to-reorder and remembered widths. Every column is declared
            // here; visibility comes from the customization, which AppSettings
            // keeps in sync with the toolbar column chooser.
            Table(of: FileItem.self, selection: Binding(
                get: { model.selectedItemIDs },
                set: { model.selectedItemIDs = $0 }
            ), sortOrder: $model.sortOrder, columnCustomization: $settings.columnCustomization) {
                TableColumn("名称", value: \.name) { item in
                    nameCell(for: item)
                }
                .width(min: 220, ideal: 320)
                .customizationID(FileColumn.name.id)
                // Like Finder, Name is always shown and cannot be hidden.
                .disabledCustomizationBehavior(.visibility)

                TableColumn("类型", value: \.displayKind) { item in
                    columnText(item.displayKind, for: item)
                }
                .width(min: 120, ideal: 170)
                .customizationID(FileColumn.kind.id)

                TableColumn("大小", value: \.sortSize) { item in
                    columnText(item.displaySize, for: item, monospacedDigit: true)
                }
                .width(min: 80, ideal: 110)
                .customizationID(FileColumn.size.id)

                TableColumn("修改日期", value: \.sortModifiedAt) { item in
                    columnText(item.displayModified, for: item)
                }
                .width(min: 150, ideal: 180)
                .customizationID(FileColumn.dateModified.id)

                TableColumn("创建日期", value: \.sortCreatedAt) { item in
                    columnText(item.displayCreated, for: item)
                }
                .width(min: 150, ideal: 180)
                .customizationID(FileColumn.dateCreated.id)

                TableColumn("拍摄日期", value: \.sortDateTaken) { item in
                    columnText(item.displayDateTaken, for: item)
                }
                .width(min: 150, ideal: 180)
                .customizationID(FileColumn.dateTaken.id)

                TableColumn("所有者", value: \.sortOwner) { item in
                    columnText(item.displayOwner, for: item)
                }
                .width(min: 100, ideal: 140)
                .customizationID(FileColumn.owner.id)
            } rows: {
                ForEach(model.displaySections) { section in
                    if model.groupingMode == .none {
                        ForEach(section.items) { TableRow($0) }
                    } else {
                        Section(section.title) {
                            ForEach(section.items) { TableRow($0) }
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: FileItem.ID.self) { selection in
                contextActions(selection)
            } primaryAction: { selection in
                model.selectedItemIDs = selection
                model.openSelected()
            }
    }

    @ViewBuilder
    private func contextActions(_ selection: Set<FileItem.ID>) -> some View {
                Button("新建文件…") {
                    model.showNewFile()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!model.canCreateFolder)

                Divider()

                Button("打开") {
                    model.selectedItemIDs = selection
                    model.openSelected()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("快速预览") {
                    model.selectedItemIDs = selection
                    model.quickViewSelectedItem()
                }
                .disabled(!canQuickView(selection: selection))

                Menu("打开方式") {
                    let applications = openWithApplications(selection: selection)
                    if applications.isEmpty {
                        Text("未找到可用应用")
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

                Button("显示简介") {
                    model.selectedItemIDs = selection
                    model.showInfoSelected()
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!hasLocalSelection(selection))

                Button("复制副本") {
                    model.selectedItemIDs = selection
                    model.duplicateSelected()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!hasLocalSelection(selection))

                Divider()

                Button("剪切") {
                    model.selectedItemIDs = selection
                    model.cutSelectedItems()
                }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!canCut(selection: selection))

                Button("复制") {
                    model.selectedItemIDs = selection
                    model.copySelectedItems()
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!canCut(selection: selection))

                Button("复制到…") {
                    model.selectedItemIDs = selection
                    model.chooseDestination(for: .copy)
                }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                .disabled(!hasLocalSelection(selection))

                Button("移动到…") {
                    model.selectedItemIDs = selection
                    model.chooseDestination(for: .move)
                }
                .keyboardShortcut("m", modifiers: [.command, .option, .shift])
                .disabled(!hasLocalSelection(selection))

                Divider()

                Button("压缩为 ZIP…") {
                    model.selectedItemIDs = selection
                    model.showCompressPanel(format: .zip)
                }
                .disabled(!canCompress(selection: selection))

                Button("压缩为 7z…") {
                    model.selectedItemIDs = selection
                    model.showCompressPanel(format: .sevenZip)
                }
                .disabled(!canCompress(selection: selection))

                Button("压缩为 TAR.GZ…") {
                    model.selectedItemIDs = selection
                    model.showCompressPanel(format: .tarGz)
                }
                .disabled(!canCompress(selection: selection))

                Button("压缩为 TAR…") {
                    model.selectedItemIDs = selection
                    model.showCompressPanel(format: .tar)
                }
                .disabled(!canCompress(selection: selection))

                Button("压缩为 GZIP…") {
                    model.selectedItemIDs = selection
                    model.showCompressPanel(format: .gzip)
                }
                .disabled(!canCompress(selection: selection, format: .gzip))

                Button("浏览压缩包…") {
                    model.selectedItemIDs = selection
                    model.showArchiveBrowser()
                }
                .disabled(!(selectedItem(for: selection).map { ArchiveService.isBrowsable($0.url) } ?? false))

                Button("解压…") {
                    model.selectedItemIDs = selection
                    model.showExtractPanel()
                }
                .disabled(!canExtract(selection: selection))

                Button("重命名") {
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

                Button("添加到个人收藏") {
                    pinFolder(selection: selection)
                }
                .disabled(!canPin(selection: selection))

                Divider()

                Button("分析所选文件夹的空间占用") {
                    guard let id = selection.first,
                          let item = model.items.first(where: { $0.id == id }),
                          item.isDirectory else { return }
                    model.selectedItemIDs = selection
                    tabs.openSpaceAnalyzer(url: item.url)
                }
                .disabled(!canAnalyzeSpace(selection: selection))

                Button("复制路径") {
                    model.selectedItemIDs = selection
                    model.copySelectedPath()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])

                Button("在终端中打开") {
                    model.selectedItemIDs = selection
                    model.openSelectedInTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("在访达中显示") {
                    model.selectedItemIDs = selection
                    model.revealSelectedInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .control])
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

    private func hasLocalSelection(_ selection: Set<FileItem.ID>) -> Bool {
        canCut(selection: selection)
    }

    private func canCompress(selection: Set<FileItem.ID>, format: ArchiveFormat = .zip) -> Bool {
        let items = model.items.filter { selection.contains($0.id) && !$0.isNetworkLocation }
        guard items.count == selection.count else { return false }
        if format == .gzip && (items.count != 1 || items.first?.isDirectory != false) { return false }
        guard let firstParent = items.first?.url.deletingLastPathComponent() else {
            return false
        }
        return items.allSatisfy { $0.url.deletingLastPathComponent() == firstParent }
    }

    private func canExtract(selection: Set<FileItem.ID>) -> Bool {
        guard selection.count == 1,
              let item = selectedItem(for: selection),
              !item.isNetworkLocation else {
            return false
        }
        return ArchiveService.isArchive(item.url)
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
        return items.contains(where: model.requiresPermanentDeletion) ? "永久删除" : "移到废纸篓"
    }

    private func canAnalyzeSpace(selection: Set<FileItem.ID>) -> Bool {
        guard selection.count == 1, let id = selection.first,
              let item = model.items.first(where: { $0.id == id }) else { return false }
        return item.isDirectory && !item.isNetworkLocation
    }

    private var emptyDescription: String {
        if !model.filterText.isEmpty {
            return "当前筛选条件与已载入的项目均不匹配。"
        }

        if model.isBrowsingNetwork {
            return "未找到本地 SMB 服务器或已挂载的网络卷。如果知道服务器地址，请使用“连接服务器”。"
        }

        return "此文件夹为空或当前无法访问。"
    }

    @ViewBuilder
    private func nameCell(for item: FileItem) -> some View {
        let isFolderTarget = folderDropTargetID == item.id
        HStack(spacing: 8) {
            FileItemIcon(
                item: item,
                folderIconStyle: settings.folderIconStyle,
                allowsTagLoading: model.loadsTagColors
            )
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
        TableCellClickTarget(
            onSelect: { mode in
                model.select(item, mode: mode)
            },
            onOpen: {
                model.selectedItemIDs = [item.id]
                model.openSelected()
            },
            onLongPress: {
                guard !item.isNetworkLocation else { return }
                startRename(selection: [item.id])
            },
            isSelected: model.selectedItemIDs.contains(item.id),
            dragURLs: { dragURLs(for: item) }
        )
    }

    /// Files to put on the drag pasteboard. Dragging one row of a multi-row
    /// selection carries the whole selection, matching Finder's behavior.
    private func dragURLs(for item: FileItem) -> [URL] {
        guard item.url.isFileURL else { return [] }
        guard model.selectedItemIDs.contains(item.id) else { return [item.url] }
        let selected = model.displayedItems
            .filter { model.selectedItemIDs.contains($0.id) && $0.url.isFileURL }
            .map(\.url)
        return selected.isEmpty ? [item.url] : selected
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
