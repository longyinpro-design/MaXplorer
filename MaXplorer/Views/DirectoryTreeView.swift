import AppKit
import SwiftUI

struct DirectoryTreeView: View {
    @StateObject private var tree = DirectoryTreeModel(roots: [
        FileManager.default.homeDirectoryForCurrentUser,
        URL(fileURLWithPath: "/", isDirectory: true)
    ])
    let selectedURL: URL?
    let showHiddenFiles: Bool
    let onNavigate: (URL) -> Void
    let onOpenInNewTab: (URL) -> Void
    let onDrop: ([URL], URL) -> Void

    private struct RevealRequest: Equatable {
        let url: URL?
        let hidden: Bool
    }

    var body: some View {
        ForEach(tree.roots) { root in
            DirectoryTreeRow(tree: tree, node: root, selectedURL: selectedURL,
                             showHiddenFiles: showHiddenFiles, onNavigate: onNavigate,
                             onOpenInNewTab: onOpenInNewTab, onDrop: onDrop)
        }
        .task(id: RevealRequest(url: selectedURL, hidden: showHiddenFiles)) {
            tree.setShowHiddenFiles(showHiddenFiles)
            if let selectedURL { await tree.reveal(selectedURL, showHiddenFiles: showHiddenFiles) }
        }
        .onDisappear { tree.cancelAll() }
    }
}

private struct DirectoryTreeRow: View {
    @ObservedObject var tree: DirectoryTreeModel
    let node: DirectoryTreeNode
    let selectedURL: URL?
    let showHiddenFiles: Bool
    let onNavigate: (URL) -> Void
    let onOpenInNewTab: (URL) -> Void
    let onDrop: ([URL], URL) -> Void

    var body: some View {
        if node.isExpandable {
            DisclosureGroup(isExpanded: Binding(
                get: { tree.isExpanded(node.id) },
                set: { tree.setExpanded(node.id, $0, showHiddenFiles: showHiddenFiles) }
            )) {
                if tree.isLoading(node.id) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在载入…").foregroundStyle(.secondary)
                    }
                } else if let error = tree.error(for: node.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(3).help(error)
                        Button("重试") { tree.retry(node.id) }
                    }
                } else {
                    ForEach(tree.children(for: node.id)) { child in
                        DirectoryTreeRow(tree: tree, node: child, selectedURL: selectedURL,
                                         showHiddenFiles: showHiddenFiles, onNavigate: onNavigate,
                                         onOpenInNewTab: onOpenInNewTab, onDrop: onDrop)
                    }
                }
            } label: {
                folderLabel
            }
        } else {
            folderLabel
        }
    }

    private var folderLabel: some View {
        Button { onNavigate(node.id) } label: {
            Label(node.name, systemImage: node.id.path == "/" ? "internaldrive" : "folder")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .background {
                    if selectedURL.map({ DirectoryTreeService.normalized($0) == node.id }) == true {
                        RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.18))
                    }
                }
        }
        .buttonStyle(.plain)
        .help(node.id.path)
        .accessibilityLabel(node.name)
        .accessibilityValue(selectedURL.map({ DirectoryTreeService.normalized($0) == node.id }) == true ? "当前文件夹" : "")
        .contextMenu {
            Button("在新标签页打开") { onOpenInNewTab(node.id) }
            if node.isExpandable && tree.isExpanded(node.id) {
                Button("刷新目录树") { tree.retry(node.id) }
            }
        }
        .onDrag { NSItemProvider(object: node.id as NSURL) } preview: {
            Label(node.name, systemImage: "folder")
                .padding(6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
            onDrop(urls, node.id)
            return true
        }
    }
}
