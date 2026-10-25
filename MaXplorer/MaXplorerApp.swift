import AppKit
import SwiftUI
import SwiftTerm

@main
struct MaXplorerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var tabs = BrowserTabsViewModel()
    @StateObject private var settings = AppSettings()

    private var model: FileBrowserViewModel {
        tabs.activeModel
    }

    var body: some Scene {
        WindowGroup("MaXplorer") {
            ContentView()
                .environmentObject(tabs)
                .environmentObject(settings)
                .environment(\.appColorTheme, settings.colorTheme)
                .preferredColorScheme(settings.preferredColorScheme)
                .tint(settings.colorTheme.tintColor)
                .background(WindowAppearanceBridge(
                    colorScheme: settings.preferredColorScheme,
                    colorTheme: settings.colorTheme
                ))
                .frame(minWidth: 1120, minHeight: 620)
                .onAppear {
                    tabs.updateMaximumConcurrentTabs(settings.maximumConcurrentTabs)
                    tabs.applyListingOptions(DirectoryListingOptions(columns: settings.visibleColumns))
                }
                .onChange(of: settings.maximumConcurrentTabs) { _, maximumConcurrentTabs in
                    tabs.updateMaximumConcurrentTabs(maximumConcurrentTabs)
                }
                .onChange(of: settings.visibleColumns) { _, visibleColumns in
                    tabs.applyListingOptions(DirectoryListingOptions(columns: visibleColumns))
                }
                .onChange(of: settings.defaultSort) { _, _ in
                    tabs.reapplyRememberedSorts()
                }
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoActionTitle.map { "撤销\($0)" } ?? "撤销") {
                    Task { await model.undoLastOperation() }
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)

                Button("撤销历史…") {
                    model.showUndoHistory()
                }
            }

            CommandGroup(replacing: .appInfo) {
                Button("关于 MaXplorer") {
                    model.showAbout()
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("新建标签页") {
                    tabs.addTab()
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!tabs.canAddTab)

                Button("复制标签页") {
                    tabs.duplicateTab(tabs.selectedTabID)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!tabs.canAddTab)

                Divider()

                Button("打开") {
                    model.openSelected()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.selectedItem == nil)

                Button("快速预览") {
                    model.quickViewSelectedItem()
                }
                .disabled(!model.canQuickViewSelectedItem)

                Button("新建文件夹") {
                    Task { await model.createFolder() }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!model.canCreateFolder)

                Button("新建文件…") {
                    model.showNewFile()
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(!model.canCreateFolder)

                Divider()

                Button("重命名") {
                    model.requestRenameSelected()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedItem?.isNetworkLocation ?? true)

                Button("批量重命名…") {
                    model.beginBatchRename()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(model.selectedItems.isEmpty)

                Button("复制副本") {
                    model.duplicateSelected()
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!model.canDuplicateSelected)

                Button("显示简介") {
                    model.showInfoSelected()
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!model.canShowInfo)

                Button(model.selectedItemsRequirePermanentDeletion ? "永久删除" : "移到废纸篓") {
                    model.requestTrashSelected()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!model.canTrashSelectedItems)

                Divider()

                Button("复制到…") {
                    model.chooseDestination(for: .copy)
                }
                .keyboardShortcut("c", modifiers: [.command, .option, .shift])
                .disabled(!model.canCopySelectedItem)

                Button("移动到…") {
                    model.chooseDestination(for: .move)
                }
                .keyboardShortcut("m", modifiers: [.command, .option, .shift])
                .disabled(!model.canCutSelectedItem)

                Divider()

                Button("压缩为 ZIP…") {
                    model.showCompressPanel(format: .zip)
                }
                .disabled(!model.canCompress(format: .zip))

                Button("压缩为 TAR.GZ…") {
                    model.showCompressPanel(format: .tarGz)
                }
                .disabled(!model.canCompress(format: .tarGz))

                Button("压缩为 TAR…") {
                    model.showCompressPanel(format: .tar)
                }
                .disabled(!model.canCompress(format: .tar))

                Button("压缩为 GZIP…") {
                    model.showCompressPanel(format: .gzip)
                }
                .disabled(!model.canCompress(format: .gzip))

                Button("解压…") {
                    model.showExtractPanel()
                }
                .disabled(!model.canExtractSelected)

                Divider()

                Button("添加到个人收藏") {
                    model.pinSelectedFolderToFavorites()
                }
                .disabled(!(model.selectedItem.map(model.canPinFolder) ?? false))

                Divider()

                Button("在访达中显示") {
                    model.revealSelectedInFinder()
                }
                .keyboardShortcut("r", modifiers: [.command, .control])
            }

            CommandGroup(replacing: .pasteboard) {
                Button("复制") {
                    if let terminal = focusedTerminal {
                        terminal.copy(self)
                    } else {
                        model.copySelectedItem()
                    }
                }
                .keyboardShortcut("c", modifiers: .command)

                Button("剪切") {
                    model.cutSelectedItem()
                }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!model.canCutSelectedItem)

                Button("粘贴") {
                    if let terminal = focusedTerminal {
                        terminal.paste(self)
                    } else {
                        model.pasteItems(maximumConcurrentCopies: settings.maximumConcurrentCopiedFiles)
                    }
                }
                .keyboardShortcut("v", modifiers: .command)

                Divider()

                Button("全选") {
                    model.selectAll()
                }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!model.canSelectAll)

                Button("复制路径") {
                    model.copySelectedPath()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
            }

            CommandMenu("显示") {
                Button("筛选项目") {
                    model.focusFilterField()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Button("搜索文件…") {
                    if tabs.isSearchActive {
                        tabs.searchModel?.focusSearchField()
                    } else {
                        tabs.openSearch(scopeRoot: model.currentURL)
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!model.canSearch || (!tabs.canAddTab && !tabs.isSearchActive))

                Button("选择匹配项…") {
                    model.showSelectPattern()
                }
                .disabled(!model.canSelectAll)

                Divider()

                Button("刷新") {
                    model.reload()
                }
                .keyboardShortcut("r", modifiers: .command)

                Picker("浏览视图", selection: $settings.browserViewMode) {
                    ForEach(FileBrowserViewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Picker("分组依据", selection: $settings.browserGrouping) {
                    ForEach(FileGroupingMode.allCases) { grouping in
                        Text(grouping.title).tag(grouping)
                    }
                }
                Divider()

                Toggle("显示隐藏文件", isOn: $tabs.showHiddenFiles)
                    .keyboardShortcut(".", modifiers: [.command, .shift])

                Toggle("显示替身", isOn: $tabs.showAliases)
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            CommandMenu("标签页") {
                Button("选择下一个标签页") {
                    tabs.selectNextTab()
                }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(!tabs.canCycleTabs)

                Button("选择上一个标签页") {
                    tabs.selectPreviousTab()
                }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(!tabs.canCycleTabs)
            }

            CommandMenu("前往") {
                Button("后退") {
                    model.goBack()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)

                Button("前进") {
                    model.goForward()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward)

                Button("上一级文件夹") {
                    model.goUp()
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!model.canGoUp)

                Button("前往文件夹…") {
                    model.showGoToFolder()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Divider()

                Button("最近文件…") {
                    model.isRecentFilesPresented = true
                }

                Button("主目录") {
                    model.navigate(to: FileManager.default.homeDirectoryForCurrentUser)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Button("下载") {
                    model.navigate(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
                }

                Divider()

                Button("连接服务器") {
                    model.showConnectToServer()
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            CommandMenu("工具") {
                Toggle("内置终端", isOn: Binding(
                    get: { model.isIntegratedTerminalPresented },
                    set: { model.isIntegratedTerminalPresented = $0 }
                ))
                    .keyboardShortcut("`", modifiers: .control)
                    .disabled(!model.currentURL.isFileURL)

                Divider()

                Button("在终端中打开") {
                    model.openSelectedInTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("复制路径") {
                    model.copySelectedPath()
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
            }

            CommandGroup(after: .help) {
                Button("MaXplorer 使用说明") {
                    model.showReadme()
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(tabs)
                .environmentObject(settings)
                .environment(\.appColorTheme, settings.colorTheme)
                .preferredColorScheme(settings.preferredColorScheme)
                .tint(settings.colorTheme.tintColor)
                .background(WindowAppearanceBridge(
                    colorScheme: settings.preferredColorScheme,
                    colorTheme: settings.colorTheme
                ))
        }
    }

    private var focusedTerminal: TerminalView? {
        var responder = NSApp.keyWindow?.firstResponder
        while let current = responder {
            if let terminal = current as? TerminalView {
                return terminal
            }
            responder = current.nextResponder
        }
        return nil
    }
}

private struct WindowAppearanceBridge: NSViewRepresentable {
    let colorScheme: ColorScheme
    let colorTheme: AppColorTheme

    func makeNSView(context: Context) -> WindowAppearanceView {
        WindowAppearanceView(colorScheme: colorScheme, colorTheme: colorTheme)
    }

    func updateNSView(_ nsView: WindowAppearanceView, context: Context) {
        guard nsView.colorScheme != colorScheme || nsView.colorTheme != colorTheme else { return }
        nsView.colorScheme = colorScheme
        nsView.colorTheme = colorTheme
    }
}

private final class WindowAppearanceView: NSView {
    var colorScheme: ColorScheme {
        didSet {
            applyAppearance()
        }
    }
    var colorTheme: AppColorTheme {
        didSet {
            applyAppearance()
        }
    }

    init(colorScheme: ColorScheme, colorTheme: AppColorTheme) {
        self.colorScheme = colorScheme
        self.colorTheme = colorTheme
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
    }

    private func applyAppearance() {
        let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        if window?.appearance?.name != appearanceName {
            window?.appearance = NSAppearance(named: appearanceName)
        }

        guard let window else { return }
        // Always transparent: with an opaque titlebar, NavigationSplitView's NSSplitView
        // draws a titlebar-height background (NSTitlebarBackgroundView) across the top of
        // the detail column. Our tab strip pushes the split view below the real titlebar,
        // so that band covers the browser toolbar. backgroundColor still tints the titlebar.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = titlebarBackgroundColor
    }

    private var titlebarBackgroundColor: NSColor {
        let base = colorScheme == .dark
            ? NSColor(calibratedWhite: 0.12, alpha: 1)
            : NSColor(calibratedWhite: 0.96, alpha: 1)

        let accent: NSColor
        switch colorTheme {
        case .default: return base
        case .water: accent = .systemBlue
        case .earth: accent = .systemGreen
        case .fire: accent = .systemOrange
        case .air: accent = .systemGray
        }

        let fraction: CGFloat = colorTheme == .air ? 0.10 : 0.16
        return base.blended(withFraction: fraction, of: accent) ?? base
    }
}
