import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Only visible grid cells request thumbnails. Selection and command actions
/// remain owned by the same model used by the details table.
struct FileCollectionView<ContextActions: View>: View {
    @EnvironmentObject private var model: FileBrowserViewModel
    @EnvironmentObject private var settings: AppSettings
    let onRename: (FileItem) -> Void
    @ViewBuilder let contextActions: (Set<FileItem.ID>) -> ContextActions
    @FocusState private var isFocused: Bool
    @State private var keyboardItemID: FileItem.ID?
    @State private var folderDropTargetID: FileItem.ID?

    private var isTiles: Bool { settings.browserViewMode == .tiles }
    private var iconSize: CGFloat { settings.browserIconSize }
    private var minimumCellWidth: CGFloat { isTiles ? max(260, iconSize + 170) : iconSize + 48 }

    var body: some View {
        GeometryReader { geometry in
            let columnCount = max(1, Int((geometry.size.width - 24 + 12) / (minimumCellWidth + 12)))
            let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12), count: columnCount)
            ScrollViewReader { reader in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(model.displaySections) { section in
                            Section {
                                ForEach(section.items) { item in
                                    cell(for: item)
                                        .id(item.id)
                                }
                            } header: {
                                if model.groupingMode != .none {
                                    Text("\(section.title)（\(section.items.count)）")
                                        .font(.headline)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, 8)
                                        .accessibilityAddTraits(.isHeader)
                                }
                            }
                        }
                    }
                    .padding(12)
                    // Cancel old cells while preserving the scroll/focus node.
                    .id(model.currentURL)
                }
                .contextMenu { contextActions([]) }
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
                    guard press.modifiers.subtracting(.shift).isEmpty else { return .ignored }
                    let direction: FileBrowserNavigationDirection
                    switch press.key {
                    case .upArrow: direction = .up
                    case .downArrow: direction = .down
                    case .leftArrow: direction = .left
                    default: direction = .right
                    }
                    let current = keyboardItemID.flatMap { id in
                        model.displayedItems.firstIndex { $0.id == id }
                    } ?? model.displayedItems.firstIndex { model.selectedItemIDs.contains($0.id) }
                    guard let index = FileBrowserPresentation.navigationIndex(
                        from: current, direction: direction,
                        sectionCounts: model.displaySections.map { $0.items.count }, columns: columnCount
                    ) else { return .ignored }
                    let item = model.displayedItems[index]
                    keyboardItemID = item.id
                    model.select(item, mode: press.modifiers.contains(.shift) ? .range : .single)
                    reader.scrollTo(item.id)
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.isEmpty, model.selectedItem != nil else { return .ignored }
                    model.openSelected()
                    return .handled
                }
                .onChange(of: model.selectedItemIDs) { _, selection in
                    if selection.count == 1 { keyboardItemID = selection.first }
                    if selection.isEmpty { keyboardItemID = nil }
                }
            }
        }
    }

    private func cell(for item: FileItem) -> some View {
        let selected = model.selectedItemIDs.contains(item.id)
        return Group {
            if isTiles {
                HStack(spacing: 12) {
                    thumbnail(for: item)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).lineLimit(2)
                        Text(item.displayKind).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if !item.displaySize.isEmpty {
                            Text(item.displaySize).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: iconSize + 12, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    thumbnail(for: item)
                    Text(item.name)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(height: 34, alignment: .top)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(8)
        .background(selected ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            if folderDropTargetID == item.id {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .opacity(model.isCut(item) ? 0.45 : 1)
        .overlay {
            TableCellClickTarget(
                onSelect: { mode in
                    keyboardItemID = item.id
                    model.select(item, mode: mode)
                },
                onOpen: {
                    model.selectedItemIDs = [item.id]
                    model.openSelected()
                },
                onLongPress: { if !item.isNetworkLocation { onRename(item) } },
                isSelected: selected,
                dragURLs: { dragURLs(for: item) },
                onFocus: { isFocused = true }
            )
        }
        .contextMenu {
            contextActions(selected ? model.selectedItemIDs : [item.id])
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let destination = item.navigationURL else { return false }
            model.moveItems(urls, to: destination)
            return true
        } isTargeted: { targeted in
            folderDropTargetID = targeted && item.navigationURL != nil ? item.id : nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name)，\(item.displayKind)，\(item.displaySize)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction {
            model.selectedItemIDs = [item.id]
            model.openSelected()
        }
    }

    private func thumbnail(for item: FileItem) -> some View {
        FileThumbnailView(item: item, size: iconSize)
    }

    private func dragURLs(for item: FileItem) -> [URL] {
        guard item.url.isFileURL else { return [] }
        guard model.selectedItemIDs.contains(item.id) else { return [item.url] }
        return model.displayedItems
            .filter { model.selectedItemIDs.contains($0.id) && $0.url.isFileURL }
            .map(\.url)
    }
}

private struct FileThumbnailView: View {
    @EnvironmentObject private var model: FileBrowserViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.displayScale) private var displayScale
    let item: FileItem
    let size: CGFloat
    @State private var image: FileThumbnailImage?

    private var key: FileThumbnailKey {
        FileThumbnailKey(url: item.url, modifiedAt: item.modifiedAt,
                         fileSize: item.size, pixelSize: Int(ceil(size * displayScale)))
    }

    private var supportsThumbnail: Bool {
        guard item.url.isFileURL, !item.isDirectory, !item.isAlias, !item.isNetworkLocation,
              let type = UTType(filenameExtension: item.url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image.cgImage, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                FileItemIcon(item: item, folderIconStyle: settings.folderIconStyle,
                             allowsTagLoading: model.loadsTagColors, size: size)
            }
        }
        .frame(width: size, height: size)
        .task(id: key) {
            image = nil
            guard supportsThumbnail else { return }
            let loaded = await FileThumbnailService.shared.thumbnail(for: key)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

struct BrowserPresentationMenu: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var model: FileBrowserViewModel

    var body: some View {
        Menu {
            Picker("浏览视图", selection: $settings.browserViewMode) {
                ForEach(FileBrowserViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            Picker("图标大小", selection: $settings.browserIconSize) {
                Text("小").tag(48.0)
                Text("中").tag(80.0)
                Text("大").tag(120.0)
                Text("特大").tag(160.0)
            }
            .disabled(settings.browserViewMode == .details)
            Picker("分组依据", selection: $settings.browserGrouping) {
                ForEach(FileGroupingMode.allCases) { grouping in
                    Text(grouping.title).tag(grouping)
                }
            }
            Menu("排序依据") {
                ForEach(FileSortDescriptor.defaultSortColumns) { column in
                    Button(column.title) {
                        let current = FileSortDescriptor(model.sortOrder) ?? .fallback
                        model.sortOrder = FileSortDescriptor(column: column, ascending: current.ascending).comparators
                    }
                }
                Divider()
                Toggle("升序", isOn: Binding(
                    get: { (FileSortDescriptor(model.sortOrder) ?? .fallback).ascending },
                    set: { ascending in
                        let current = FileSortDescriptor(model.sortOrder) ?? .fallback
                        model.sortOrder = FileSortDescriptor(column: current.column, ascending: ascending).comparators
                    }
                ))
            }
        } label: {
            Image(systemName: settings.browserViewMode.systemImage)
                .frame(width: 26, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("浏览视图、图标大小、分组与排序")
        .accessibilityLabel("浏览视图与分组")
    }
}
